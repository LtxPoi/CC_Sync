#!/usr/bin/env python
"""module_helper.py — CLI helper for module-manager.sh

Extracts all embedded Python code blocks from module-manager.sh into a single
dispatched CLI tool.  Called by module-manager.sh via:

    python lib/module_helper.py <subcommand> [args...]

All arguments are passed via sys.argv (no bash string interpolation).
"""

import json
import os
import subprocess
import sys
import tomllib
import urllib.request

# ── encoding safety (Windows defaults to GBK) ──────────────────────
sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

DEFAULT_REF = "main"
MODULE_TYPE = "skill"


def _safe_download(url, out, timeout=30, max_bytes=10 * 1024 * 1024):
    """Download file via gh api (authenticated) with timeout and size limit.
    Falls back to urllib if gh is unavailable."""
    # Try gh api first (authenticated, handles private repos)
    gh_cmd = os.environ.get("GH_CMD", "gh")
    # Extract owner/repo/ref/path from raw.githubusercontent.com URL
    # Format: https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}
    import re as _re
    m = _re.match(r"https://raw\.githubusercontent\.com/([^/]+/[^/]+)/([^/]+)/(.*)", url)
    if m:
        repo, ref, path = m.group(1), m.group(2), m.group(3)
        api_url = f"repos/{repo}/contents/{path}?ref={ref}"
        try:
            result = subprocess.run(
                [gh_cmd, "api", api_url, "--header", "Accept: application/vnd.github.raw+json"],
                capture_output=True, timeout=timeout,
            )
            if result.returncode == 0 and len(result.stdout) > 0:
                if len(result.stdout) > max_bytes:
                    raise ValueError(f"Download exceeds {max_bytes // (1024*1024)}MB limit")
                with open(out, "wb") as f:
                    f.write(result.stdout)
                return
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass  # gh not available or timed out, fall back to urllib

    # Fallback: direct urllib download (unauthenticated)
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        total = 0
        with open(out, "wb") as f:
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                total += len(chunk)
                if total > max_bytes:
                    raise ValueError(f"Download exceeds {max_bytes // (1024*1024)}MB limit")
                f.write(chunk)


# ── TOML helpers ────────────────────────────────────────────────────

def _toml_escape(s):
    """Escape a string for TOML double-quoted values."""
    return str(s).replace("\\", "\\\\").replace('"', '\\"')


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

    # Group by repo@ref to minimise API calls
    repos = {}
    for name, mod in modules.items():
        src = mod.get("source", {})
        repo = src.get("repo", "")
        ref = src.get("ref", DEFAULT_REF)
        if repo:
            key = f"{repo}@{ref}"
            repos.setdefault(key, []).append((name, mod))

    updates, up_to_date, errors = [], [], []

    for key, mods in repos.items():
        repo, ref = key.rsplit("@", 1)
        try:
            result = subprocess.run(
                [gh, "api", f"repos/{repo}/commits/{ref}", "-q", ".sha"],
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
            for name, mod in mods:
                stored = mod.get("commit_sha", "")
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
    """Read TOML manifest -> JSON to stdout."""
    manifest = sys.argv[2]
    try:
        with open(manifest, "rb") as f:
            data = tomllib.load(f)
        json.dump(data, sys.stdout, ensure_ascii=False)
    except FileNotFoundError:
        json.dump({"version": 1, "modules": {}}, sys.stdout)
    except Exception as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)


def cmd_manifest_write():
    """Read JSON from stdin -> write TOML to file."""
    manifest = sys.argv[2]
    data = json.load(sys.stdin)
    lines = [
        "# Module Manager manifest — auto-generated",
        f'version = {data.get("version", 1)}',
        "",
    ]

    for name in sorted(data.get("modules", {})):
        mod = data["modules"][name]
        lines.append(f'[modules."{name}"]')
        for key in ["type", "install_path", "commit_sha", "installed_at", "last_updated"]:
            val = mod.get(key, "")
            if val:
                lines.append(f'{key} = "{_toml_escape(val)}"')
        lines.append("")
        src = mod.get("source", {})
        if src:
            lines.append(f'[modules."{name}".source]')
            for key in ["kind", "repo", "path", "ref", "url"]:
                val = src.get(key, "")
                if val:
                    lines.append(f'{key} = "{_toml_escape(val)}"')
            lines.append("")

    dirname = os.path.dirname(manifest)
    if dirname:
        os.makedirs(dirname, exist_ok=True)
    with open(manifest, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


def cmd_json_to_vars():
    """Parse JSON object -> bash variable assignments. (Legacy, kept for compat.)"""
    d = json.loads(sys.argv[2])
    for k, v in d.items():
        v = str(v).replace("'", "'\"'\"'")
        print(f"{k}='{v}'")


def cmd_tab_vars():
    """Output module fields as tab-separated values in fixed order.
    Reads JSON from stdin (piped from bash via: echo "$json" | py_helper tab-vars).
    Fields: name, kind, repo, path, ref, install_path, latest_sha"""
    obj = json.loads(sys.stdin.readline())
    fields = ["name", "kind", "repo", "path", "ref", "install_path", "latest_sha"]
    print("\t".join(str(obj.get(f, "")) for f in fields))


def cmd_module_exists():
    """Check whether a module name exists in manifest JSON (stdin). Prints 'yes'/'no'."""
    data = json.load(sys.stdin)
    name = sys.argv[2]
    print("yes" if name in data.get("modules", {}) else "no")


def cmd_manifest_add_module():
    """Add/overwrite a module entry. Reads JSON from stdin, prints updated JSON."""
    name, sha, today = sys.argv[2], sys.argv[3], sys.argv[4]
    kind, repo, path, ref = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
    data = json.load(sys.stdin)
    source = {"kind": kind, "ref": ref}
    if repo:
        source["repo"] = repo
    if path:
        source["path"] = path
    data["modules"][name] = {
        "type": MODULE_TYPE,
        "install_path": name,
        "commit_sha": sha,
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

    def download_dir(repo, path, ref, dest):
        os.makedirs(dest, exist_ok=True)
        result = subprocess.run(
            [gh, "api", f"repos/{repo}/contents/{path}?ref={ref}", "-q", "."],
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=30,
        )
        if result.returncode != 0:
            print(f"  API error for {path}: {result.stderr.strip()}", file=sys.stderr)
            return False

        items = json.loads(result.stdout)
        if isinstance(items, dict):
            items = [items]

        ok = True
        for item in items:
            name = item["name"]
            if item["type"] == "dir":
                if not download_dir(repo, item["path"], ref, os.path.join(dest, name)):
                    ok = False
            elif item["type"] == "file":
                url = item.get("download_url", "")
                if not url:
                    continue
                out = os.path.join(dest, name)
                try:
                    _safe_download(url, out)
                except Exception as e:
                    print(f"  Failed: {name} ({e})", file=sys.stderr)
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
            src = mod.get("source", {})
            source_str = _format_source_str(src)[:35]
            updated = mod.get("last_updated", "?")
            mtype = mod.get("type", "?")
            print(f"  {name:<25} {mtype:<8} {source_str:<35} {updated}")
        print()
    else:
        print("No tracked modules.")
        print()

    # Detect unmanaged directories
    tracked_paths = {mod.get("install_path", name) for name, mod in modules.items()}
    unmanaged = []
    if os.path.isdir(skills_dir):
        for d in sorted(os.listdir(skills_dir)):
            full = os.path.join(skills_dir, d)
            if os.path.isdir(full) and d not in tracked_paths and not d.startswith("."):
                unmanaged.append(d)

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
    """Check for upstream updates.  Exit codes: 0=up-to-date, 1=errors, 10=updates."""
    data, target, modules, gh = _prepare_check()

    if not modules:
        print("No modules tracked.")
        sys.exit(0)

    updates, up_to_date, errors = _fetch_latest_shas(modules, target, gh)

    if updates is None:
        # target not found
        print(f'Module "{target}" not found in manifest.')
        sys.exit(1)

    if updates:
        print(f"Updates available ({len(updates)}):")
        for name, old, new, _mod in updates:
            print(f"  {name}: {old[:8]} -> {new[:8]}")
        print()

    if up_to_date:
        print(f"Up to date ({len(up_to_date)}):")
        for name in up_to_date:
            print(f"  {name}")
        print()

    if errors:
        print(f"Check failed ({len(errors)}):")
        for name, err in errors:
            print(f"  {name}: {err}")
        print()

    # Exit code: 10 = updates available, 0 = all up to date, 1 = errors
    if errors and not updates:
        sys.exit(1)
    elif updates:
        sys.exit(10)
    else:
        sys.exit(0)


def cmd_update_check():
    """Emit one JSON line per module needing update (for bash to consume)."""
    data, target, modules, gh = _prepare_check()

    if target != "--all":
        if target not in modules:
            sys.exit(1)
        modules = {target: modules[target]}

    updates, _up_to_date, errors = _fetch_latest_shas(modules, target, gh)

    if updates is None:
        sys.exit(1)

    # Print warnings for errors
    for name, err in errors:
        print(f"Warning: skipped {name}: {err}", file=sys.stderr)

    # Emit JSON lines for modules needing update
    for name, _stored, latest, mod in updates:
        src = mod.get("source", {})
        print(
            json.dumps(
                {
                    "name": name,
                    "latest_sha": latest,
                    "kind": src.get("kind"),
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
    data = json.load(sys.stdin)
    data["modules"][name]["commit_sha"] = sha
    data["modules"][name]["last_updated"] = today
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_module_get_path():
    """Print install_path for a module. JSON stdin."""
    data = json.load(sys.stdin)
    name = sys.argv[2]
    print(data["modules"][name].get("install_path", name))


def cmd_manifest_delete_module():
    """Delete a module from manifest JSON. stdin -> stdout."""
    data = json.load(sys.stdin)
    name = sys.argv[2]
    del data["modules"][name]
    json.dump(data, sys.stdout, ensure_ascii=False)


def cmd_restore_count():
    """Print total number of modules in manifest. JSON stdin."""
    data = json.load(sys.stdin)
    print(len(data.get("modules", {})))


def cmd_restore_list_missing():
    """List modules missing locally. One JSON line per missing module. JSON stdin."""
    data = json.load(sys.stdin)
    skills_dir = sys.argv[2]

    for name, mod in data.get("modules", {}).items():
        install_path = mod.get("install_path", name)
        dest = os.path.join(skills_dir, install_path)
        if not os.path.isdir(dest):
            src = mod.get("source", {})
            print(
                json.dumps(
                    {
                        "name": name,
                        "kind": src.get("kind", ""),
                        "repo": src.get("repo", ""),
                        "path": src.get("path", ""),
                        "ref": src.get("ref", DEFAULT_REF),
                        "install_path": install_path,
                    }
                )
            )


# ── Dispatch table ──────────────────────────────────────────────────

COMMANDS = {
    "manifest-read": cmd_manifest_read,
    "manifest-write": cmd_manifest_write,
    "json-to-vars": cmd_json_to_vars,
    "tab-vars": cmd_tab_vars,
    "module-exists": cmd_module_exists,
    "manifest-add-module": cmd_manifest_add_module,
    "download-github-subdir": cmd_download_github_subdir,
    "list": cmd_list,
    "check": cmd_check,
    "update-check": cmd_update_check,
    "manifest-update-sha": cmd_manifest_update_sha,
    "module-get-path": cmd_module_get_path,
    "manifest-delete-module": cmd_manifest_delete_module,
    "restore-count": cmd_restore_count,
    "restore-list-missing": cmd_restore_list_missing,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: {sys.argv[0]} <subcommand> [args...]", file=sys.stderr)
        print(f"Subcommands: {', '.join(sorted(COMMANDS))}", file=sys.stderr)
        sys.exit(1)
    COMMANDS[sys.argv[1]]()


if __name__ == "__main__":
    main()
