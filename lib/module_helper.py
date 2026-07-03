#!/usr/bin/env python
"""module_helper.py — CLI helper for module-manager.sh

Extracts all embedded Python code blocks from module-manager.sh into a single
dispatched CLI tool.  Called by module-manager.sh via:

    python lib/module_helper.py <subcommand> [args...]

All arguments are passed via sys.argv (no bash string interpolation).
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import tomllib
import urllib.request
from datetime import datetime, timezone
from urllib.parse import quote, urlparse

# ── encoding safety (Windows defaults to GBK) ──────────────────────
# newline="\n" is load-bearing: bash callers that read multi-line stdout via
# `$(...)` + `read -r` (e.g. cmd_prune --all) preserve any embedded \r and
# fail downstream regex validation on every line except the last.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
sys.stderr.reconfigure(encoding="utf-8", newline="\n")

DEFAULT_REF = "main"
MODULE_TYPE = "skill"
_REPO_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$")
# git ref grammar narrowed: alnum + _ / . - only, no leading dash (would parse
# as a git CLI flag), length-capped. Defends gh-api/git-fetch/display sites
# against a poisoned modules.toml that smuggles shell-meta or option-prefix
# refs past the user's review. Symmetric with _validate_repo.
_REF_RE = re.compile(r"^[A-Za-z0-9_./-]+$")
_REF_MAX_LEN = 256


def _validate_repo(repo):
    """Reject repo strings that could manipulate the gh api URL (e.g. '../x/y')."""
    if not _REPO_RE.match(repo):
        raise ValueError(f"无效的仓库格式：{repo!r}")
    owner, name = repo.split("/", 1)
    if owner in (".", "..") or name in (".", ".."):
        raise ValueError(f"仓库名不能为 . 或 ..：{repo!r}")


def _validate_ref(ref):
    """Reject refs that could route into gh-api / git-fetch / display text
    as something other than a ref. Char set [A-Za-z0-9_./-]+ with length
    cap; leading `-` rejected (would be parsed as a CLI flag downstream)."""
    if not ref or len(ref) > _REF_MAX_LEN:
        raise ValueError(f"无效的 ref：{ref!r}（须为 1-{_REF_MAX_LEN} 字符）")
    if ref.startswith("-"):
        raise ValueError(f"ref 不能以 - 开头：{ref!r}")
    if not _REF_RE.match(ref):
        raise ValueError(f"无效的 ref：{ref!r}（仅允许 A-Z a-z 0-9 _ . / -）")


def _safe_source(mod):
    """Return a module's `source` as a dict, tolerating a poisoned/corrupt
    manifest where `mod` itself isn't a dict (e.g. `[[modules.x]]` parses to a
    list) or `source` isn't a dict (e.g. `source = "x"`). Returns {} in those
    cases so callers get a clean empty-source path instead of an AttributeError
    traceback — the threat model explicitly names a poisoned modules.toml."""
    if not isinstance(mod, dict):
        return {}
    src = mod.get("source")
    return src if isinstance(src, dict) else {}


def _read_json_stdin():
    """Read+parse JSON from stdin with a clean Chinese error on corruption."""
    try:
        return json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"错误：stdin JSON 解析失败 ({e})", file=sys.stderr)
        sys.exit(1)


def _safe_download(url, out, timeout=30, max_bytes=10 * 1024 * 1024):
    """Download file via gh api (authenticated) with timeout and size limit.
    Falls back to urllib if gh is unavailable. Both paths stream with a
    running byte count so an oversized response is aborted mid-read, not
    after fully buffering into memory."""
    # Try gh api first (authenticated, handles private repos)
    gh_cmd = os.environ.get("GH_CMD", "gh")
    # Extract owner/repo/ref/path from raw.githubusercontent.com URL
    # Format: https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}
    m = re.match(r"https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.*)", url)
    if m:
        repo = f"{m.group(1)}/{m.group(2)}"
        try:
            _validate_repo(repo)
            _validate_ref(m.group(3))
        except ValueError:
            pass  # invalid repo/ref → fall through to urllib fallback (SSRF guard catches it)
        else:
            ref, path = m.group(3), m.group(4)
            api_url = f"repos/{repo}/contents/{quote(path, safe='/')}?ref={quote(ref, safe='')}"
            try:
                # stderr=DEVNULL: we don't consume it, so piping it would risk blocking
                # gh once the pipe buffer fills (64 KB typical). Falls through to urllib
                # on nonzero exit anyway, so stderr content isn't actionable here.
                proc = subprocess.Popen(
                    [gh_cmd, "api", api_url, "--header", "Accept: application/vnd.github.raw+json"],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                )
                # Watchdog: proc.stdout.read blocks indefinitely if gh stalls mid-stream
                # (network hang). proc.wait(timeout=…) only fires after read returns,
                # so we need an independent timer to kill a stalled process.
                watchdog = threading.Timer(timeout, proc.kill)
                watchdog.daemon = True
                watchdog.start()
                gh_succeeded = False
                try:
                    total = 0
                    with open(out, "wb") as f:
                        while True:
                            chunk = proc.stdout.read(8192)
                            if not chunk:
                                break
                            total += len(chunk)
                            if total > max_bytes:
                                proc.kill()
                                try:
                                    f.close()
                                    os.unlink(out)
                                except OSError:
                                    pass
                                raise ValueError(f"Download exceeds {max_bytes // (1024*1024)}MB limit")
                            f.write(chunk)
                    try:
                        proc.wait(timeout=timeout)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        raise
                    if proc.returncode == 0 and total > 0:
                        gh_succeeded = True
                        return
                    # gh failed; fall through to urllib
                finally:
                    watchdog.cancel()
                    if proc.poll() is None:
                        proc.kill()
                    # Cleanup partial output on any non-success exit (watchdog
                    # kill, gh non-zero, size-limit raise). Without this, a
                    # truncated file lingers and downstream consumers (mv into
                    # place, manifest commit) may treat it as a valid download.
                    if not gh_succeeded:
                        try:
                            os.unlink(out)
                        except OSError:
                            pass
            except FileNotFoundError:
                pass  # gh not installed, fall back to urllib

    # Fallback: direct urllib download (unauthenticated)
    # Only allow HTTPS from trusted GitHub domains (prevent SSRF via crafted API responses)
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.netloc.endswith(
        (".githubusercontent.com", ".github.com")
    ):
        raise ValueError(f"Untrusted download URL: {url}")
    req = urllib.request.Request(url)
    urllib_succeeded = False
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            total = 0
            with open(out, "wb") as f:
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > max_bytes:
                        try:
                            f.close()
                            os.unlink(out)
                        except OSError:
                            pass
                        raise ValueError(f"Download exceeds {max_bytes // (1024*1024)}MB limit")
                    f.write(chunk)
        urllib_succeeded = True
    finally:
        # Symmetric with the gh path: any non-success (network error mid-read,
        # ValueError already unlinked) cleans up the partial file so callers
        # don't mistake it for a complete download.
        if not urllib_succeeded:
            try:
                os.unlink(out)
            except OSError:
                pass


# ── TOML helpers ────────────────────────────────────────────────────

def _toml_escape(s):
    """Escape a string for TOML double-quoted values.
    Handles \\ " and all ASCII control chars (TOML 1.0 forbids raw \\x00-\\x1f)."""
    s = str(s)
    s = s.replace("\\", "\\\\")
    s = s.replace('"', '\\"')
    out = []
    for ch in s:
        code = ord(ch)
        if ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif code < 0x20 or code == 0x7F:
            out.append(f"\\u{code:04x}")
        elif 0xD800 <= code <= 0xDFFF:
            # Lone surrogates can't survive UTF-8 encoding on write — replace
            # rather than crash the atomic write with UnicodeEncodeError.
            out.append("\\uFFFD")
        else:
            out.append(ch)
    return "".join(out)


# ── Shared: fetch latest SHAs from GitHub ───────────────────────────

def _fetch_latest_shas(modules, target, gh):
    """Filter by target -> group by repo@ref -> gh API query -> compare SHAs.

    Returns (updates, up_to_date, errors):
      updates:    [(name, stored_sha, latest_sha, mod_dict), ...]
      up_to_date: [name, ...]
      errors:     [(name, error_msg), ...]

    Returns (None, None, None) when *target* is not '--all' and the name
    is missing from *modules* (caller should treat as "not found").
    """
    if target != "--all":
        if target not in modules:
            return None, None, None  # signal "not found"
        modules = {target: modules[target]}

    # Group by (repo, ref, path) tuple for path-specific SHA queries
    repos = {}
    for name, mod in modules.items():
        src = _safe_source(mod)
        repo = src.get("repo", "")
        ref = src.get("ref", DEFAULT_REF)
        kind = src.get("kind", "")
        # Only use path for github-subdir modules (github-repo may have stale path values)
        path = src.get("path", "") if kind == "github-subdir" else ""
        if repo:
            key = (repo, ref, path)
            repos.setdefault(key, []).append((name, mod))

    updates, up_to_date, errors = [], [], []

    for (repo, ref, path), mods in repos.items():
        try:
            # Re-validate repo + ref at use-site — modules.toml is user-controlled but could
            # also be corrupted, and '../x/y' in repo would retarget the gh api URL while
            # a crafted ref would smuggle into the gh-api path or the display string.
            try:
                _validate_repo(repo)
                _validate_ref(ref)
            except ValueError as ve:
                for name, _ in mods:
                    errors.append((name, str(ve)))
                continue
            if path:
                # Path-specific query: latest commit touching this subdirectory
                cmd = [gh, "api",
                       f"repos/{repo}/commits?sha={quote(ref, safe='')}&path={quote(path, safe='/')}&per_page=1",
                       "-q", ".[0].sha"]
            else:
                # Whole-repo query (github-repo kind or no path)
                cmd = [gh, "api",
                       f"repos/{repo}/commits/{quote(ref, safe='')}", "-q", ".sha"]
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                encoding="utf-8",
                timeout=15,
            )
            if result.returncode != 0:
                for name, _ in mods:
                    errors.append((name, result.stderr.strip()))
                continue
            latest = result.stdout.strip()
            # Validate SHA format (must be 40-char hex; reject null/empty/error)
            if not re.fullmatch(r"[0-9a-f]{40}", latest):
                for name, _ in mods:
                    errors.append((name, f"Invalid SHA from API: {latest!r}"))
                continue
            for name, mod in mods:
                # Compare against pin (user-approved SHA), not commit_sha.
                # Auto-migration in cmd_manifest_read guarantees pin is set.
                # When pin != commit_sha (pending install), check still
                # reports new upstream commits relative to the last
                # approval — which is what the user actually wants to see.
                stored = mod.get("pin", "") or mod.get("commit_sha", "")
                if stored != latest:
                    updates.append((name, stored, latest, mod))
                else:
                    up_to_date.append(name)
        except Exception as e:
            for name, _ in mods:
                errors.append((name, str(e)))

    return updates, up_to_date, errors


# ── Subcommands ─────────────────────────────────────────────────────

def cmd_manifest_read():
    """Read TOML manifest -> JSON to stdout.

    Auto-migrates legacy entries that lack the `pin` field by setting
    pin=commit_sha, so callers can assume `pin` is always present.
    The migrated value persists on the next manifest-write."""
    manifest = sys.argv[2]
    try:
        with open(manifest, "rb") as f:
            data = tomllib.load(f)
        for mod in data.get("modules", {}).values():
            if "pin" not in mod and mod.get("commit_sha"):
                mod["pin"] = mod["commit_sha"]
        json.dump(data, sys.stdout, ensure_ascii=False)
    except FileNotFoundError:
        json.dump({"version": 1, "modules": {}}, sys.stdout)
    except Exception as e:
        print(f"错误：读取 manifest 失败 ({e})", file=sys.stderr)
        sys.exit(1)


def cmd_manifest_write():
    """Read JSON from stdin -> write TOML to file."""
    manifest = sys.argv[2]
    data = _read_json_stdin()
    lines = [
        "# Module Manager manifest — auto-generated",
        f'version = {data.get("version", 1)}',
        "",
    ]

    for name in sorted(data.get("modules", {})):
        mod = data["modules"][name]
        escaped_name = _toml_escape(name)
        lines.append(f'[modules."{escaped_name}"]')
        for key in ["type", "install_path", "commit_sha", "pin", "installed_at", "last_updated"]:
            val = mod.get(key, "")
            if val:
                lines.append(f'{key} = "{_toml_escape(val)}"')
        lines.append("")
        src = _safe_source(mod)
        if src:
            lines.append(f'[modules."{escaped_name}".source]')
            for key in ["kind", "repo", "path", "ref", "url"]:
                val = src.get(key, "")
                if val:
                    lines.append(f'{key} = "{_toml_escape(val)}"')
            lines.append("")

    dirname = os.path.dirname(manifest) or "."
    os.makedirs(dirname, exist_ok=True)
    # Atomic write: write to temp file, then replace (prevents truncation on crash)
    fd, tmp_path = tempfile.mkstemp(dir=dirname, suffix=".toml.tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines))
        os.replace(tmp_path, manifest)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def cmd_tab_vars():
    """Output module fields separated by ASCII US (\\x1f, Unit Separator) in fixed order.
    Reads JSON from stdin (piped from bash via: echo "$json" | py_helper tab-vars).
    Fields: name, kind, repo, path, ref, install_path, latest_sha

    The delimiter is \\x1f (Unit Separator), not \\t. Bash treats whitespace
    delimiters specially in `IFS`: runs of whitespace collapse into a single
    separator and empty fields between them are dropped. With \\t, a record
    like `name\\tgithub-repo\\towner/repo\\t\\tmain\\tname\\tsha` (path field
    intentionally empty for github-repo modules) re-binds to
    path=main, ref=name, install_path=sha — silently corrupting updates.
    \\x1f is non-whitespace, so consecutive delimiters preserve empty fields.
    The dispatch key stays `tab-vars` for backwards compatibility with any
    out-of-tree caller, but the on-wire format is US-separated."""
    try:
        obj = json.loads(sys.stdin.readline())
    except json.JSONDecodeError as e:
        print(f"错误：tab-vars 输入 JSON 解析失败 ({e})", file=sys.stderr)
        sys.exit(1)
    fields = ["name", "kind", "repo", "path", "ref", "install_path", "pin_sha", "from_sha"]
    print("\x1f".join(str(obj.get(f, "")) for f in fields))


def cmd_module_exists():
    """Check whether a module name exists in manifest JSON (stdin). Prints 'yes'/'no'."""
    data = _read_json_stdin()
    name = sys.argv[2]
    print("yes" if name in data.get("modules", {}) else "no")


def cmd_path_tracked():
    """Return 'yes' if the given directory name matches any tracked module —
    either by manifest key (name) or by install_path. Prints 'yes'/'no'.

    install_path is always a single-segment directory name: manifest-add-module
    writes it equal to the module key, and update/restore reject any value
    containing '/' (path-traversal guard). cmd_module_exists checks only
    manifest keys; this helper additionally checks install_path so a legacy or
    hand-edited manifest whose install_path is absent or differs from its key is
    still recognized as tracked — used by prune --confirm to refuse deletion of
    any tracked directory."""
    data = _read_json_stdin()
    name = sys.argv[2]
    modules = data.get("modules", {})
    if name in modules:
        print("yes")
        return
    for mod_name, mod in modules.items():
        if mod.get("install_path", mod_name) == name:
            print("yes")
            return
    print("no")


def cmd_manifest_add_module():
    """Add/overwrite a module entry. Reads JSON from stdin, prints updated JSON.

    Args: name sha pin today kind repo path ref

    pin is the user-approved SHA; commit_sha is the currently-installed SHA.
    For fresh install / adopt they are equal; they diverge only when bump
    moves pin ahead and update has not yet installed it."""
    if len(sys.argv) < 10:
        print("错误：manifest-add-module 参数不足（需要 name sha pin today kind repo path ref）", file=sys.stderr)
        sys.exit(1)
    name, sha, pin, today = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
    kind, repo, path, ref = sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9]
    data = _read_json_stdin()
    source = {"kind": kind, "ref": ref}
    if repo:
        source["repo"] = repo
    if path:
        source["path"] = path
    data.setdefault("modules", {})[name] = {
        "type": MODULE_TYPE,
        "install_path": name,
        "commit_sha": sha,
        "pin": pin or sha,
        "installed_at": today,
        "last_updated": today,
        "source": source,
    }
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_download_github_subdir():
    """Recursively download a subdirectory from GitHub via API."""
    gh = sys.argv[2]
    repo = sys.argv[3]
    subpath = sys.argv[4]
    ref = sys.argv[5]
    dest = sys.argv[6]
    # Inner-layer validation (bash download_github_subdir validates too): repo is
    # interpolated raw into the gh-api URL below, and ref should stay charset-
    # bounded even though it is quote()-d. Mirrors download_github_repo.
    try:
        _validate_repo(repo)
        _validate_ref(ref)
    except ValueError as e:
        print(f"错误：{e}", file=sys.stderr)
        sys.exit(1)

    def download_dir(repo, path, ref, dest):
        os.makedirs(dest, exist_ok=True)
        result = subprocess.run(
            [gh, "api", f"repos/{repo}/contents/{quote(path, safe='/')}?ref={quote(ref, safe='')}", "-q", "."],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
        if result.returncode != 0:
            print(f"  {path} 的 API 调用失败：{result.stderr.strip()}", file=sys.stderr)
            return False

        items = json.loads(result.stdout)
        if isinstance(items, dict):
            items = [items]

        ok = True
        resolved_dest = os.path.realpath(dest)
        for item in items:
            # Defensive: GitHub API could return malformed entries (schema drift,
            # partial truncation, forked API). .get() + skip-on-missing instead of
            # raw subscript that KeyErrors and aborts the entire download batch.
            raw_name = item.get("name") if isinstance(item, dict) else None
            item_type = item.get("type") if isinstance(item, dict) else None
            if not raw_name or not item_type:
                print(f"  跳过（条目残缺，缺少 name/type）：{item!r}", file=sys.stderr)
                continue
            # Sanitize filename to prevent path traversal from API responses.
            # os.path.basename is cross-platform: on POSIX it strips up to last "/",
            # on Windows (ntpath) it strips up to last "\" OR "/" — both are safe
            # against "foo/bar" or "..\\x" style injection. The (".", "..") guard
            # covers the remaining dot-entries that basename alone lets through.
            name = os.path.basename(raw_name)
            if not name or name in (".", ".."):
                continue
            target = os.path.realpath(os.path.join(dest, name))
            if not target.startswith(resolved_dest + os.sep):
                print(f"  跳过（检测到路径穿越）：{raw_name}", file=sys.stderr)
                continue
            if item_type == "dir":
                if not download_dir(repo, item.get("path", ""), ref, os.path.join(dest, name)):
                    ok = False
            elif item_type == "file":
                url = item.get("download_url", "")
                if not url:
                    continue
                out = os.path.join(dest, name)
                try:
                    _safe_download(url, out)
                except Exception as e:
                    print(f"  下载失败：{name} ({e})", file=sys.stderr)
                    ok = False
        return ok

    sys.exit(0 if download_dir(repo, subpath, ref, dest) else 1)


def _format_source_str(src):
    """Format a module source dict into a display string."""
    kind = src.get("kind", "?")
    if kind == "github-subdir":
        return f'{src.get("repo", "")}:{src.get("path", "")}'
    elif kind == "github-repo":
        return src.get("repo", "")
    return src.get("url", "")[:40]


def _list_unmanaged(modules, skills_dir):
    """Return sorted list of subdirs of skills_dir that aren't tracked in modules."""
    tracked_paths = {mod.get("install_path", name) for name, mod in modules.items()}
    if not os.path.isdir(skills_dir):
        return []
    return [
        d for d in sorted(os.listdir(skills_dir))
        if os.path.isdir(os.path.join(skills_dir, d))
        and d not in tracked_paths
        and not d.startswith(".")
    ]


def cmd_list():
    """Print formatted table of tracked modules + detect unmanaged dirs."""
    data = json.loads(sys.argv[2])
    modules = data.get("modules", {})
    skills_dir = sys.argv[3]

    # List tracked modules
    if modules:
        print(f"Tracked modules ({len(modules)}):")
        print(f'  {"Name":<25} {"Type":<8} {"Source":<35} {"Updated"}')
        print(f'  {"-"*25} {"-"*8} {"-"*35} {"-"*10}')
        for name in sorted(modules):
            mod = modules[name]
            src = _safe_source(mod)
            source_str = _format_source_str(src)[:35]
            updated = mod.get("last_updated", "?")
            mtype = mod.get("type", "?")
            print(f"  {name:<25} {mtype:<8} {source_str:<35} {updated}")
        print()
    else:
        print("No tracked modules.")
        print()

    # Detect unmanaged directories
    unmanaged = _list_unmanaged(modules, skills_dir)

    if unmanaged:
        print(f"Unmanaged directories ({len(unmanaged)}):")
        for d in unmanaged:
            print(f"  {d}/")
        print()
        print('Use "adopt" to track them, or they will be ignored.')


def _prepare_check():
    """Shared init for check / update-check subcommands."""
    data = json.loads(sys.argv[2])
    target = sys.argv[3]
    modules = data.get("modules", {})
    gh = os.environ.get("GH_CMD", "gh")
    return data, target, modules, gh


def cmd_check():
    """Check for upstream updates.  Exit codes: 0=up-to-date, 1=errors, 10=updates.

    Side effect: records each successfully-queried module's upstream SHA
    in the machine-local check-state sidecar
    (~/.claude/skills/.check_state.json). `bump --latest` reads that
    back to verify upstream hasn't moved between this review and the
    pin write."""
    data, target, modules, gh = _prepare_check()
    skills_dir = sys.argv[4]

    if not modules:
        print("No modules tracked.")
        sys.exit(0)

    updates, up_to_date, errors = _fetch_latest_shas(modules, target, gh)

    if updates is None:
        # target not found
        print(f'manifest 中未找到模块 "{target}"。')
        sys.exit(1)

    # Record candidate SHAs for every module we successfully queried.
    # up_to_date modules store the existing pin (which equals the
    # queried SHA by definition of up_to_date), so a "no updates" check
    # still arms a subsequent bump-back via --to <sha>.
    candidates = _load_check_state(skills_dir)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    for name, _stored, latest, _mod in updates:
        candidates[name] = {"sha": latest, "checked_at": now}
    for name in up_to_date:
        pin = modules[name].get("pin", "") or modules[name].get("commit_sha", "")
        if re.fullmatch(r"[0-9a-f]{40}", pin):
            candidates[name] = {"sha": pin, "checked_at": now}
    try:
        _save_check_state(skills_dir, candidates)
    except OSError as e:
        # Don't fail check on a sidecar write error — bump --latest will
        # surface a clear "no candidate" message of its own.
        print(f"warning: 候选 SHA 写入失败：{e}", file=sys.stderr)

    if updates:
        print(f"Updates available ({len(updates)}):")
        for name, old, new, mod in updates:
            src = _safe_source(mod)
            repo = src.get("repo", "")
            ref = src.get("ref", DEFAULT_REF)
            print(f"  {name}: {old[:8]} -> {new[:8]} on {ref}")
            if repo and old:
                print(f"    compare: https://github.com/{repo}/compare/{old}...{new}")
        print()
        print("To roll forward: bash module-manager.sh bump <name|--all> [--to <sha>|--latest]")
        print("Then to install: bash module-manager.sh update [<name>|--all]")
        print()

    if up_to_date:
        print(f"Up to date ({len(up_to_date)}):")
        for name in up_to_date:
            print(f"  {name}")
        print()

    if errors:
        print(f"Check failed ({len(errors)}):")
        for name, err in errors:
            # Indent continuation lines so a multi-line gh stderr (with
            # internal newlines) doesn't land at column 0, where any
            # downstream consumer scanning aggregated output for marker
            # lines (===PRUNE_BEGIN=== etc.) could be confused. Defense
            # in depth — sync's marker scan doesn't run on module-manager
            # output today, but the cost of prefixing is zero.
            err_indented = err.replace("\n", "\n    ")
            print(f"  {name}: {err_indented}")
        print()

    # Exit code: 10 = updates available, 0 = all up to date, 1 = errors
    if errors and not updates:
        sys.exit(1)
    elif updates:
        sys.exit(10)
    else:
        sys.exit(0)


def cmd_update_check():
    """Emit one JSON line per module with pin != commit_sha (needs install).

    No upstream query is performed — pin and commit_sha are both local. Pin
    is the user-approved SHA (set by install / adopt / bump); commit_sha is
    the SHA currently materialized on disk. They differ only when bump has
    advanced the pin but update has not yet pulled it.

    The downloaded SHA (pin_sha) and the previously installed SHA (from_sha)
    are both emitted so cmd_update can print a compare URL before each
    install."""
    data = json.loads(sys.argv[2])
    target = sys.argv[3]
    modules = data.get("modules", {})

    if target != "--all":
        if target not in modules:
            print(f'错误：manifest 中未找到模块 "{target}"', file=sys.stderr)
            sys.exit(1)
        modules = {target: modules[target]}

    for name, mod in modules.items():
        pin = mod.get("pin", "") or mod.get("commit_sha", "")
        commit_sha = mod.get("commit_sha", "")
        # No pin → no approved target. Module entries created before pin
        # existed get pin=commit_sha via auto-migration on read, so this
        # branch only fires for malformed entries (both fields empty).
        # Warn so update --all doesn't silently report "all up to date"
        # while a corrupted module sits in an unrecoverable state.
        if not pin:
            if not commit_sha:
                print(
                    f"warning: module '{name}' has no pin or commit_sha — "
                    f"manifest entry malformed, skipping",
                    file=sys.stderr,
                )
            continue
        if pin == commit_sha:
            continue
        src = _safe_source(mod)
        print(
            json.dumps(
                {
                    "name": name,
                    "pin_sha": pin,
                    "from_sha": commit_sha,
                    "kind": src.get("kind", ""),
                    "repo": src.get("repo", ""),
                    "path": src.get("path", ""),
                    "ref": src.get("ref", DEFAULT_REF),
                    "install_path": mod.get("install_path", name),
                }
            )
        )


def cmd_manifest_update_sha():
    """Update commit_sha and last_updated for a module. JSON stdin -> JSON stdout."""
    name, sha, today = sys.argv[2], sys.argv[3], sys.argv[4]
    data = _read_json_stdin()
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    data["modules"][name]["commit_sha"] = sha
    data["modules"][name]["last_updated"] = today
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_module_get_path():
    """Print install_path for a module. JSON stdin."""
    data = _read_json_stdin()
    name = sys.argv[2]
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    print(data["modules"][name].get("install_path", name))


def cmd_manifest_delete_module():
    """Delete a module from manifest JSON. stdin -> stdout."""
    data = _read_json_stdin()
    name = sys.argv[2]
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    del data["modules"][name]
    json.dump(data, sys.stdout, ensure_ascii=False)


_MODULE_NAME_PRINT_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")


def cmd_list_untracked():
    """Print untracked directories in skills_dir, one per line.
    Args: argv[2] = manifest JSON string; argv[3] = skills_dir path.
    Output is the parsing contract for module-manager.sh's `prune` command.

    Filters names to the same character set _validate_module_name accepts in
    module-manager.sh — `[A-Za-z0-9_][A-Za-z0-9_.-]*`. Any name outside that
    set is warn-and-skipped on stderr. The downstream SKILL.md workflow
    splices these names directly into a shell command (`prune --confirm
    <name>...` for partial prune), so this is the boundary where shell-meta
    characters MUST be rejected — module-manager.sh's own _validate_module_name
    runs after Bash has already parsed the command line, which is too late to
    block command substitution in an unquoted argument. The strict regex
    subsumes the prior CR/LF skip (CR/LF, whitespace, $, backtick, etc. all
    fall outside the allowed set)."""
    data = json.loads(sys.argv[2])
    modules = data.get("modules", {})
    skills_dir = sys.argv[3]
    for d in _list_unmanaged(modules, skills_dir):
        if not _MODULE_NAME_PRINT_RE.match(d):
            print(
                f"warning: skipping unmanaged dir with disallowed characters in name: {d!r}",
                file=sys.stderr,
            )
            continue
        print(d)


def cmd_restore_count():
    """Print total number of modules in manifest. JSON stdin."""
    data = _read_json_stdin()
    print(len(data.get("modules", {})))


def cmd_restore_list_missing():
    """List modules missing locally. One JSON line per missing module. JSON stdin."""
    data = _read_json_stdin()
    skills_dir = sys.argv[2]

    for name, mod in data.get("modules", {}).items():
        install_path = mod.get("install_path", name)
        dest = os.path.join(skills_dir, install_path)
        if not os.path.isdir(dest):
            src = _safe_source(mod)
            # Restore downloads exactly the pinned SHA, not the ref's current
            # tip, so the restored install matches the manifest's commit_sha.
            pin = mod.get("pin", "") or mod.get("commit_sha", "")
            print(
                json.dumps(
                    {
                        "name": name,
                        "pin_sha": pin,
                        "from_sha": "",
                        "kind": src.get("kind", ""),
                        "repo": src.get("repo", ""),
                        "path": src.get("path", ""),
                        "ref": src.get("ref", DEFAULT_REF),
                        "install_path": install_path,
                    }
                )
            )


# ── Pin / bump support ──────────────────────────────────────────────


def cmd_manifest_set_pin():
    """Set pin and last_updated for a module. JSON stdin -> JSON stdout.
    commit_sha is NOT touched — that happens on the next update."""
    name, pin, today = sys.argv[2], sys.argv[3], sys.argv[4]
    if not re.fullmatch(r"[0-9a-f]{40}", pin):
        print(f"错误：无效的 commit SHA：{pin!r}（须为 40 字符十六进制）", file=sys.stderr)
        sys.exit(1)
    data = _read_json_stdin()
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    data["modules"][name]["pin"] = pin
    data["modules"][name]["last_updated"] = today
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_module_get_pin():
    """Print the pin SHA for a module. JSON stdin -> stdout."""
    data = _read_json_stdin()
    name = sys.argv[2]
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    mod = data["modules"][name]
    print(mod.get("pin", "") or mod.get("commit_sha", ""))


def cmd_module_get_repo():
    """Print the repo (owner/repo) for a module, empty for URL-kind. JSON stdin."""
    data = _read_json_stdin()
    name = sys.argv[2]
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    print(_safe_source(data["modules"][name]).get("repo", ""))


def cmd_module_names():
    """Print one module name per line, sorted. JSON stdin."""
    data = _read_json_stdin()
    for name in sorted(data.get("modules", {})):
        print(name)


def cmd_latest_sha():
    """Query upstream latest SHA for one module. JSON stdin -> SHA to stdout.

    Returns the latest commit SHA at the module's tracking ref (path-aware
    for github-subdir). On error, prints to stderr and exits 1."""
    data = _read_json_stdin()
    name = sys.argv[2]
    gh = os.environ.get("GH_CMD", "gh")
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    mod = data["modules"][name]
    src = _safe_source(mod)
    repo = src.get("repo", "")
    ref = src.get("ref", DEFAULT_REF)
    kind = src.get("kind", "")
    path = src.get("path", "") if kind == "github-subdir" else ""
    if not repo:
        print(f"错误：模块 '{name}' 没有 repo（URL-kind 模块不支持 bump）", file=sys.stderr)
        sys.exit(1)
    try:
        _validate_repo(repo)
        _validate_ref(ref)
    except ValueError as e:
        print(f"错误：{e}", file=sys.stderr)
        sys.exit(1)
    if path:
        cmd = [gh, "api",
               f"repos/{repo}/commits?sha={quote(ref, safe='')}&path={quote(path, safe='/')}&per_page=1",
               "-q", ".[0].sha"]
    else:
        cmd = [gh, "api",
               f"repos/{repo}/commits/{quote(ref, safe='')}", "-q", ".sha"]
    result = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", timeout=15,
    )
    if result.returncode != 0:
        print(f"错误：查询 {repo}@{ref} 失败：{result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    latest = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", latest):
        print(f"错误：API 返回的 SHA 格式无效：{latest!r}", file=sys.stderr)
        sys.exit(1)
    print(latest)


def cmd_verify_sha():
    """Verify a SHA exists in a module's repo. JSON stdin.
    Args: name sha. Exits 0 on existence, 1 otherwise."""
    data = _read_json_stdin()
    name = sys.argv[2]
    sha = sys.argv[3]
    gh = os.environ.get("GH_CMD", "gh")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        print(f"错误：SHA 须为 40 字符十六进制（收到 {sha!r}）", file=sys.stderr)
        sys.exit(1)
    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)
    src = _safe_source(data["modules"][name])
    repo = src.get("repo", "")
    if not repo:
        print(f"错误：模块 '{name}' 没有 repo，无法验证 SHA", file=sys.stderr)
        sys.exit(1)
    try:
        _validate_repo(repo)
    except ValueError as e:
        print(f"错误：{e}", file=sys.stderr)
        sys.exit(1)
    result = subprocess.run(
        [gh, "api", f"repos/{repo}/commits/{sha}", "-q", ".sha"],
        capture_output=True, text=True, encoding="utf-8", timeout=15,
    )
    if result.returncode != 0:
        print(f"错误：仓库 {repo} 中找不到 SHA {sha}：{result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    actual = result.stdout.strip()
    if actual != sha:
        print(f"错误：SHA 验证返回 {actual!r}，与请求的 {sha!r} 不符", file=sys.stderr)
        sys.exit(1)


# ── Check-state sidecar (machine-local, not synced) ─────────────────
# Records the SHA each module's upstream tracking ref showed at the
# moment of `check`. `bump --latest` reads this back, queries upstream
# again, and refuses if upstream moved between review and pin write.
# Closes the TOCTOU race between `check` (review) and `bump` (approve).

_CHECK_STATE_BASENAME = ".check_state.json"
_CHECK_CANDIDATE_DEFAULT_STALENESS = 24 * 3600  # 24 hours


def _check_state_path(skills_dir):
    return os.path.join(skills_dir, _CHECK_STATE_BASENAME)


def _load_check_state(skills_dir):
    """Load candidate-SHA state. Returns {} on missing/corrupt/malformed —
    a damaged sidecar forces re-check, never crashes the calling command."""
    p = _check_state_path(skills_dir)
    try:
        with open(p, "r", encoding="utf-8", newline="\n") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    cands = data.get("candidates")
    if not isinstance(cands, dict):
        return {}
    return cands


def _save_check_state(skills_dir, candidates):
    """Atomic write via tempfile + os.replace. UTF-8 + \\n newlines."""
    p = _check_state_path(skills_dir)
    parent = os.path.dirname(p) or "."
    os.makedirs(parent, exist_ok=True)
    tmp_fd, tmp_path = tempfile.mkstemp(
        prefix=".check_state.", suffix=".tmp", dir=parent
    )
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"candidates": candidates}, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp_path, p)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def cmd_check_candidate_verify():
    """Verify a stored candidate SHA matches upstream's current SHA.

    Args (stdin): JSON manifest data.
    Argv: argv[2] = module name, argv[3] = skills_dir,
          argv[4] = staleness threshold in seconds (optional, default 86400).

    On success: prints verified SHA to stdout, exits 0.
    On failure (missing / stale / mismatch / network error): prints a
    Chinese error to stderr and exits 1."""
    data = _read_json_stdin()
    name = sys.argv[2]
    skills_dir = sys.argv[3]
    staleness = (
        int(sys.argv[4]) if len(sys.argv) > 4
        else _CHECK_CANDIDATE_DEFAULT_STALENESS
    )

    if name not in data.get("modules", {}):
        print(f"错误：manifest 中未找到模块 '{name}'", file=sys.stderr)
        sys.exit(1)

    candidates = _load_check_state(skills_dir)
    cand = candidates.get(name)
    if not isinstance(cand, dict):
        print(
            f"错误：模块 '{name}' 没有已审阅的候选 SHA。"
            f"请先运行 'check {name}' 审阅 compare URL，再 bump。",
            file=sys.stderr,
        )
        sys.exit(1)

    cand_sha = cand.get("sha", "")
    cand_at = cand.get("checked_at", "")
    if not re.fullmatch(r"[0-9a-f]{40}", cand_sha):
        print(
            f"错误：模块 '{name}' 的候选 SHA 损坏。"
            f"请重新运行 'check {name}'。",
            file=sys.stderr,
        )
        sys.exit(1)

    # Staleness check — malformed timestamps count as stale so bump refuses.
    # Negative-age clamp: a future-dated checked_at means clock skew (small,
    # tolerated up to 5 minutes) or sidecar tampering (large, rejected).
    # The upstream-match check below is the real defense — this branch
    # documents the assumption explicitly and surfaces tampering early.
    try:
        checked_at = datetime.fromisoformat(cand_at)
        if checked_at.tzinfo is None:
            checked_at = checked_at.replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - checked_at).total_seconds()
    except (ValueError, TypeError):
        age = staleness + 1
    if age < -300:
        print(
            f"错误：模块 '{name}' 的候选时间戳指向未来"
            f"（约 {int(-age)} 秒后），疑似 sidecar 篡改。"
            f"请重新运行 'check {name}'。",
            file=sys.stderr,
        )
        sys.exit(1)
    if age > staleness:
        hours = int(age // 3600)
        print(
            f"错误：模块 '{name}' 的候选 SHA 已过期（{hours} 小时前审阅）。"
            f"请重新运行 'check {name}' 后再 bump。",
            file=sys.stderr,
        )
        sys.exit(1)

    # Query upstream fresh and compare. Same logic as cmd_latest_sha so
    # the network shape stays identical to what `check` saw.
    gh = os.environ.get("GH_CMD", "gh")
    mod = data["modules"][name]
    src = _safe_source(mod)
    repo = src.get("repo", "")
    ref = src.get("ref", DEFAULT_REF)
    kind = src.get("kind", "")
    path = src.get("path", "") if kind == "github-subdir" else ""
    if not repo:
        print(
            f"错误：模块 '{name}' 没有 repo（URL-kind 模块不支持 bump）",
            file=sys.stderr,
        )
        sys.exit(1)
    try:
        _validate_repo(repo)
        _validate_ref(ref)
    except ValueError as e:
        print(f"错误：{e}", file=sys.stderr)
        sys.exit(1)
    if path:
        cmd = [gh, "api",
               f"repos/{repo}/commits?sha={quote(ref, safe='')}&path={quote(path, safe='/')}&per_page=1",
               "-q", ".[0].sha"]
    else:
        cmd = [gh, "api",
               f"repos/{repo}/commits/{quote(ref, safe='')}", "-q", ".sha"]
    result = subprocess.run(
        cmd, capture_output=True, text=True, encoding="utf-8", timeout=15,
    )
    if result.returncode != 0:
        print(f"错误：查询 {repo}@{ref} 失败：{result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    latest = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", latest):
        print(f"错误：API 返回的 SHA 格式无效：{latest!r}", file=sys.stderr)
        sys.exit(1)

    if cand_sha != latest:
        print(
            f"错误：上游 SHA 在 check 之后发生变化。\n"
            f"  审阅时间：{cand_at}\n"
            f"  审阅时:   {cand_sha[:8]}\n"
            f"  当前上游: {latest[:8]}\n"
            f"  请重新运行 'check {name}' 审阅新的 compare URL，再 bump。",
            file=sys.stderr,
        )
        sys.exit(1)

    print(latest)


def cmd_check_state_delete():
    """Remove a module's candidate entry from the check-state sidecar.
    Argv: argv[2] = module name, argv[3] = skills_dir.
    No-op if the file doesn't exist or the name isn't present. Best-effort:
    silently swallows write errors because the calling `remove` flow has
    already removed the module — a leftover sidecar entry only forces a
    re-check on a future re-install with the same name."""
    name = sys.argv[2]
    skills_dir = sys.argv[3]
    candidates = _load_check_state(skills_dir)
    if name not in candidates:
        return
    del candidates[name]
    try:
        _save_check_state(skills_dir, candidates)
    except OSError:
        pass


# ── Dispatch table ──────────────────────────────────────────────────

COMMANDS = {
    "manifest-read": cmd_manifest_read,
    "manifest-write": cmd_manifest_write,
    "tab-vars": cmd_tab_vars,
    "module-exists": cmd_module_exists,
    "path-tracked": cmd_path_tracked,
    "manifest-add-module": cmd_manifest_add_module,
    "manifest-set-pin": cmd_manifest_set_pin,
    "module-get-pin": cmd_module_get_pin,
    "module-get-repo": cmd_module_get_repo,
    "module-names": cmd_module_names,
    "latest-sha": cmd_latest_sha,
    "verify-sha": cmd_verify_sha,
    "check-candidate-verify": cmd_check_candidate_verify,
    "check-state-delete": cmd_check_state_delete,
    "download-github-subdir": cmd_download_github_subdir,
    "list": cmd_list,
    "check": cmd_check,
    "update-check": cmd_update_check,
    "manifest-update-sha": cmd_manifest_update_sha,
    "module-get-path": cmd_module_get_path,
    "manifest-delete-module": cmd_manifest_delete_module,
    "restore-count": cmd_restore_count,
    "restore-list-missing": cmd_restore_list_missing,
    "list-untracked": cmd_list_untracked,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: {sys.argv[0]} <subcommand> [args...]", file=sys.stderr)
        print(f"Subcommands: {', '.join(sorted(COMMANDS))}", file=sys.stderr)
        sys.exit(1)
    COMMANDS[sys.argv[1]]()


if __name__ == "__main__":
    main()
