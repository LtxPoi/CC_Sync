#!/usr/bin/env bash
# module-manager.sh — Third-party module manager for Claude Code
# Manages skills/plugins/MCP servers in ~/.claude/skills/
# Usage: module-manager.sh <command> [options]
#
# Commands:
#   list                            List all tracked modules + detect unmanaged
#   check [name|--all]              Check upstream for new commits
#   bump <name|--all> [--to <sha>]  Approve a new pin (no download)
#   update [name|--all]             Install the pinned SHA on disk
#   install <source> [--name X]     Install a new module
#   remove <name>                   Remove a module
#   adopt <name> <source>           Track an existing directory in the manifest
#   adopt --bulk <owner/repo>       Bulk-adopt matching directories
#   restore                         Download all modules from manifest (new device)
#   prune [--all|--confirm N..]     List/delete untracked directories
#
# Pin model: each module has both `pin` (user-approved SHA) and `commit_sha`
# (currently installed). check/bump operate on pin; update reconciles
# commit_sha to pin. They diverge only between a bump and the next update.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Config ---
# normalize_path converts Git Bash paths (/c/Users/...) to Windows paths (C:/Users/...)
# so Python (native Windows) can resolve them correctly.
SKILLS_DIR=$(normalize_path "${HOME}/.claude/skills")
MANIFEST="${SKILLS_DIR}/modules.toml"
TODAY=$(date -u +%Y-%m-%d)  # UTC — avoids cross-timezone diff noise in synced modules.toml

detect_gh || exit 1
MODULE_HELPER=$(normalize_path "$SCRIPT_DIR/lib/module_helper.py")

# --- 临时目录清理 trap ---
_CLEANUP_DIRS=()
# Mid-swap state held by cmd_update between the bak displacement and the
# new install's mv-into-place. Format: name<US>dest<US>bak_path. Set after
# bak-displacement, cleared on either successful install or completed
# rollback. The cleanup trap consults it on SIGINT to print a recovery
# command — without this, Ctrl+C between mv-out and mv-in leaves $dest
# missing with no on-screen hint that the data is at $bak_path.
_PENDING_ROLLBACK=""
_cleanup_temps() {
    if [ -n "$_PENDING_ROLLBACK" ]; then
        local _name _dest _bak
        # || true: a malformed (<3-field) _PENDING_ROLLBACK must not abort the
        # trap under set -e and leak the _CLEANUP_DIRS cleanup below.
        IFS=$'\x1f' read -r _name _dest _bak <<< "$_PENDING_ROLLBACK" || true
        if [ -n "$_bak" ] && [ ! -d "$_dest" ] && [ -d "$_bak" ]; then
            echo "" >&2
            echo -e "${RED}✗${NC} ${_name}: 更新中断，源目录已位移但新内容未就位" >&2
            echo "    手动恢复：mv -- '$_bak' '$_dest'" >&2
        fi
    fi
    local d
    for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do
        [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_temps EXIT INT TERM

# --- 仓库格式验证 ---
_validate_repo_format() {
    # owner/repo — alphanumeric + _ . - ; reject . / .. / leading-dash in either component
    # (GitHub rejects these with 404; also closes defense-in-depth gaps)
    if [[ ! "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo -e "${RED}错误：无效的仓库格式 '$1'（应为 owner/repo）${NC}" >&2
        return 1
    fi
    local owner="${1%%/*}" name="${1##*/}"
    if [[ "$owner" == "." || "$owner" == ".." || "$name" == "." || "$name" == ".." ]]; then
        echo -e "${RED}错误：仓库名不能为 . 或 ..（收到 '$1'）${NC}" >&2
        return 1
    fi
}

# Validate a git ref / branch / 40-hex SHA for safe use at gh-api / git-fetch
# boundaries. Single source mirroring lib/module_helper.py's _validate_ref:
# charset [A-Za-z0-9_./-], 1–256 chars, no leading dash (would parse as a CLI
# flag). Every bash caller that hands a ref to gh/git routes through here.
_validate_ref_format() {
    if [ -z "$1" ] || [ "${#1}" -gt 256 ] || [[ "$1" == -* ]] \
        || [[ ! "$1" =~ ^[A-Za-z0-9_./-]+$ ]]; then
        echo -e "${RED}错误：无效的 ref '$1'（仅允许 A-Za-z0-9_./- 、1-256 字符、不能以 - 开头）${NC}" >&2
        return 1
    fi
}

py_helper() {
    PYTHONIOENCODING=utf-8 python "$MODULE_HELPER" "$@"
}

# ─── TOML ↔ JSON bridge ──────────────────────────────────────────
# Read TOML manifest → JSON to stdout
# Write JSON from stdin → TOML manifest
# This lets bash pipe data between commands while Python handles parsing.

manifest_json() {
    py_helper manifest-read "$MANIFEST"
}

save_manifest() {
    # Reads JSON from stdin, writes TOML to $MANIFEST
    py_helper manifest-write "$MANIFEST"
}

# ─── Shared Python micro-helpers ─────────────────────────────────
# Small Python operations reused across multiple commands.

# Check whether a module name exists in the manifest JSON.
# Prints "yes" or "no".
module_exists() {
    echo "$1" | py_helper module-exists "$2"
}

# Check whether a directory name matches any tracked module — by manifest
# key OR by install_path. Use this for prune-side gates: a module 'foo'
# with install_path 'bar' lives at SKILLS_DIR/bar, but module_exists("bar")
# returns "no" because "bar" isn't a manifest key. Prints "yes" or "no".
path_tracked() {
    echo "$1" | py_helper path-tracked "$2"
}

# Add or overwrite a module entry in the manifest JSON.
# Reads JSON from $1 (data), prints updated JSON to stdout.
# Args: data name sha pin today kind repo path ref
# For fresh install / adopt, pass sha as pin (they start equal). They
# diverge only when bump moves pin ahead of the installed commit_sha.
manifest_add_module() {
    echo "$1" | py_helper manifest-add-module "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# ─── Validation helpers ───────────────────────────────────────────

# Validate module name: alphanumeric, hyphens, underscores, dots only.
# Rejects path traversal (../), slashes, and shell metacharacters.
_validate_module_name() {
    local name="$1"
    if [[ "$name" == "." || "$name" == ".." ]]; then
        echo -e "${RED}错误：无效的模块名 '$name'${NC}" >&2
        return 1
    fi
    # Require an alphanumeric/underscore lead to keep names from looking like
    # CLI flags downstream (e.g. "-evil" passed where rm/mv won't get a slash prefix).
    if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo -e "${RED}错误：模块名 '$name' 只能包含 A-Z a-z 0-9 _ - .（首字符须为字母/数字/下划线）${NC}" >&2
        return 1
    fi
}

# ─── GitHub helpers ───────────────────────────────────────────────

# URL-encode a string via Python's urllib.parse.quote (matches helper's Python side).
# Bash has no builtin quoting; we shell out to python for correctness.
_url_encode() {
    PYTHONIOENCODING=utf-8 python -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

get_head_sha() {
    local repo="$1" ref="${2:-main}"
    local sha enc_ref
    # gh-api boundary: validate before interpolating repo into the URL
    _validate_repo_format "$repo" || return 1
    _validate_ref_format "$ref" || return 1
    enc_ref=$(_url_encode "$ref")
    sha=$("$GH" api "repos/${repo}/commits/${enc_ref}" -q '.sha' 2>/dev/null) || return 1
    # Validate: must be 40-char hex (reject null, empty, error messages)
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

# Get the latest commit SHA that touched a specific subdirectory.
# Uses the commits list API with path filter (equivalent to git log -1 -- path).
get_path_sha() {
    local repo="$1" path="$2" ref="${3:-main}"
    local sha enc_ref enc_path
    # gh-api boundary: validate before interpolating repo into the URL
    _validate_repo_format "$repo" || return 1
    _validate_ref_format "$ref" || return 1
    enc_ref=$(_url_encode "$ref")
    # path: keep forward slashes (they are path separators, not delimiters)
    enc_path=$(PYTHONIOENCODING=utf-8 python -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe='/'))" "$path")
    sha=$("$GH" api "repos/${repo}/commits?sha=${enc_ref}&path=${enc_path}&per_page=1" -q '.[0].sha' 2>/dev/null) || return 1
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

# Download a subdirectory from GitHub via API (no full clone needed)
download_github_subdir() {
    local repo="$1" subpath="$2" ref="$3" dest
    dest=$(normalize_path "$4")
    # Same gh-api boundary as download_github_repo — validate repo/ref here too
    # (the Python cmd_download_github_subdir re-validates as the inner layer).
    _validate_repo_format "$repo" || return 1
    _validate_ref_format "$ref" || return 1
    py_helper download-github-subdir "$GH" "$repo" "$subpath" "$ref" "$dest"
}

# Download a whole GitHub repo at a specific ref OR commit SHA via shallow fetch.
# GitHub's smart-HTTP transport has allowAnySHA1InWant enabled by default
# since 2019, so `git fetch --depth 1 origin <sha>` works the same as
# `--branch <ref>`. Callers pass a 40-char SHA (the pinned commit) so the
# downloaded tree matches the manifest's recorded SHA exactly — no race
# window between the SHA query and the download.
download_github_repo() {
    local repo="$1" ref_or_sha="$2" dest
    dest=$(normalize_path "$3")
    # Reusable boundary: validate both args internally (defense-in-depth) so a
    # future caller passing an unvalidated manifest value can't reach git with a
    # crafted repo/ref. Routed through the shared _validate_* helpers (single
    # source — see _validate_ref_format), symmetric with the Python twins.
    _validate_repo_format "$repo" || return 1
    _validate_ref_format "$ref_or_sha" || return 1
    local tmp_clone
    tmp_clone=$(safe_mktemp)
    _CLEANUP_DIRS+=("$tmp_clone")

    # Capture git's stderr so failures surface a diagnosable message — host
    # refusing allowAnySHA1InWant, network error, malformed pinned SHA, etc.
    # Order matters: `2>&1` first (stderr → captured stream), then `>/dev/null`
    # (stdout → devnull), so $() captures only stderr. --quiet already
    # suppresses progress noise, leaving the real error.
    local fetch_err fetch_ok=true
    fetch_err=$(
        (
            cd "$tmp_clone" && \
            git init -q && \
            git remote add origin "https://github.com/${repo}.git" && \
            git -c protocol.version=2 fetch --depth 1 --quiet origin "$ref_or_sha" && \
            git checkout -q FETCH_HEAD
        ) 2>&1 >/dev/null
    ) || fetch_ok=false

    if ! $fetch_ok; then
        echo -e "${RED}✗ Failed to fetch '$ref_or_sha' from https://github.com/${repo}.git${NC}" >&2
        if [ -n "$fetch_err" ]; then
            echo "$fetch_err" >&2
        fi
        rm -rf "$tmp_clone" 2>/dev/null || true
        return 1
    fi

    mkdir -p "$dest"
    # Strip ALL symlinks from the clone FIRST, then copy — eliminates the
    # window where $dest contained nested symlinks between the cp and the
    # subsequent find-delete cleanup. cp -a preserves symlinks (including
    # nested ones), so the previous two-phase approach left a brief period
    # where a malicious upstream symlink under a subdirectory could be
    # consumed by anything reading $dest concurrently. Doing the strip on
    # the clone side leaves $dest symlink-free by construction.
    find "$tmp_clone" -type l -delete 2>/dev/null || true
    local copy_errors=0
    # Re-apply the top-level filters: top-level symlinks (already deleted by
    # the strip above) and .git stay excluded; -type l guard kept as a
    # defense-in-depth no-op in case the find -delete missed something.
    (set -o pipefail; cd "$tmp_clone" && find . -maxdepth 1 ! -name . ! -name .git ! -type l -print0 \
        | xargs -0 -I '{}' cp -a '{}' "$dest"/) || copy_errors=1
    rm -rf "$tmp_clone" 2>/dev/null || true
    return $copy_errors
}

_download_to_tmp() {
    local kind="$1" repo="$2" path="$3" ref="$4" tmp_dest="$5"
    if [[ "$kind" == "github-subdir" ]]; then
        download_github_subdir "$repo" "$path" "$ref" "$tmp_dest"
    elif [[ "$kind" == "github-repo" ]]; then
        download_github_repo "$repo" "$ref" "$tmp_dest"
    else
        echo -e "  ${YELLOW}⚠${NC} Unsupported source kind: $kind" >&2
        return 1
    fi
}

# ─── Parse source string ─────────────────────────────────────────
# Returns: kind\trepo\tpath\tref  (tab-separated)

parse_source() {
    local src="$1"
    # Reject embedded tabs/newlines: the function emits tab-separated output, so a
    # tab inside src would shift downstream `IFS=$'\t' read` parsing.
    if [[ "$src" == *$'\t'* || "$src" == *$'\n'* ]]; then
        echo -e "${RED}错误：来源字符串不能包含制表符或换行${NC}" >&2
        return 1
    fi
    if [[ "$src" == https://* ]]; then
        # url-kind is an unimplemented placeholder (rejected downstream as
        # unsupported). Park the URL in the repo field, not ref, so a future
        # implementer finds it in a sensible slot.
        printf 'url\t%s\t\t' "$src"
    elif [[ "$src" == *:* ]]; then
        # owner/repo:path/to/skill
        local repo="${src%%:*}"
        local path="${src#*:}"
        printf 'github-subdir\t%s\t%s\tmain' "$repo" "$path"
    else
        # owner/repo (whole repo)
        printf 'github-repo\t%s\t\tmain' "$src"
    fi
}

# ─── Commands ─────────────────────────────────────────────────────

cmd_list() {
    local data
    data=$(manifest_json)

    py_helper list "$data" "$SKILLS_DIR"
}

cmd_check() {
    local target="${1:---all}"
    local data
    data=$(manifest_json)

    # SKILLS_DIR is where cmd_check writes the .check_state.json sidecar so
    # bump --latest can verify upstream hasn't moved since this review.
    GH_CMD="$GH" py_helper check "$data" "$target" "$SKILLS_DIR"
}

cmd_update() {
    local target="${1:---all}"
    local data
    data=$(manifest_json)

    # Get modules that need updating (reuse check logic)
    local needs_update
    local check_tmpdir
    check_tmpdir=$(safe_mktemp)
    _CLEANUP_DIRS+=("$check_tmpdir")
    local check_stderr="${check_tmpdir}/stderr.txt"
    needs_update=$(GH_CMD="$GH" py_helper update-check "$data" "$target" 2>"$check_stderr") || {
        local rc=$?
        if [[ -s "$check_stderr" ]]; then
            echo -e "${RED}✗${NC} Update check failed:" >&2
            cat "$check_stderr" >&2
        fi
        rm -rf "$check_tmpdir" 2>/dev/null || true
        return $rc
    }
    # update-check exits 0 even when some modules failed their lookup (per-module
    # warnings go to stderr). Surface those warnings before proceeding so the user
    # isn't blind to silently skipped modules.
    if [[ -s "$check_stderr" ]]; then
        cat "$check_stderr" >&2
    fi
    rm -rf "$check_tmpdir" 2>/dev/null || true

    if [[ -z "$needs_update" ]]; then
        echo -e "${GREEN}✓${NC} All modules up to date"
        return 0
    fi

    local count=0
    local errors=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name kind repo path ref install_path pin_sha from_sha
        # py_helper tab-vars emits US (\x1f), not \t — \t is IFS whitespace
        # in bash so empty fields collapse, mis-binding path/ref/install_path
        # for github-repo modules where `path` is intentionally empty. \x1f
        # is non-whitespace, so consecutive delimiters yield empty fields.
        IFS=$'\x1f' read -r name kind repo path ref install_path pin_sha from_sha <<< "$(echo "$line" | py_helper tab-vars)"

        # Validate install_path from manifest (prevent path traversal)
        if ! _validate_module_name "$install_path" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} ${name}: invalid install_path '${install_path}', skipping"
            errors=$((errors + 1))
            continue
        fi

        # Defensive: pin_sha must be a 40-char SHA. Python emits it from the
        # pin field (set on install / adopt / bump). Anything else is a sign
        # of a malformed manifest entry — skip rather than pass an arbitrary
        # string to git fetch / gh api.
        if [[ ! "$pin_sha" =~ ^[0-9a-f]{40}$ ]]; then
            echo -e "  ${RED}✗${NC} ${name}: invalid pin SHA '${pin_sha:0:20}...', skipping"
            errors=$((errors + 1))
            continue
        fi

        echo -e "→ Updating ${name}..."
        if [[ -n "$from_sha" ]]; then
            echo -e "  ${from_sha:0:8} → ${pin_sha:0:8}"
            [[ -n "$repo" ]] && \
                echo "  compare: https://github.com/${repo}/compare/${from_sha}...${pin_sha}"
        else
            echo -e "  → ${pin_sha:0:8} (fresh install)"
        fi
        local dest="${SKILLS_DIR}/${install_path}"

        local ok=true
        local tmp_dest
        tmp_dest=$(safe_mktemp)
        _CLEANUP_DIRS+=("$tmp_dest")

        # Download by pin_sha (not by ref). For github-subdir, the GitHub
        # Contents API accepts SHAs as the ?ref= parameter. For github-repo,
        # download_github_repo now uses `git fetch --depth 1 origin <sha>`.
        # Net effect: the downloaded tree matches the pinned SHA exactly,
        # closing the race window between SHA query and clone-by-branch.
        if ! _download_to_tmp "$kind" "$repo" "$path" "$pin_sha" "$tmp_dest"; then ok=false; fi

        if ! $ok; then
            rm -rf "$tmp_dest" 2>/dev/null || true
            echo -e "  ${RED}✗${NC} ${name} download failed"
            errors=$((errors + 1))
            continue
        fi

        # Swap with backup. _safe_bak_path (from lib/common.sh) returns a
        # non-clobbering path: prefers .bak, falls back to .bak.<epoch> on
        # collision, refuses if both slots are occupied. The previous plain
        # `mv "$dest" "${dest}.bak"` silently clobbered a leftover .bak from
        # an earlier interrupted cmd_update, losing the prior rollback state.
        local bak_path=""
        if [ -d "$dest" ]; then
            if ! bak_path=$(_safe_bak_path "$dest"); then
                echo -e "  ${RED}✗${NC} ${name}: 无法分配备份路径" >&2
                rm -rf "$tmp_dest" 2>/dev/null || true
                errors=$((errors + 1))
                continue
            fi
            if ! mv -- "$dest" "$bak_path"; then
                echo -e "  ${RED}✗${NC} ${name}: 备份位移失败 ($dest -> $bak_path)" >&2
                rm -rf "$tmp_dest" 2>/dev/null || true
                errors=$((errors + 1))
                continue
            fi
            # Arm the SIGINT-rollback hint between this point and the new
            # mv-into-place below. Cleared on every code path that resolves
            # the swap (success, fallback-copy success, or rollback).
            _PENDING_ROLLBACK="${name}"$'\x1f'"${dest}"$'\x1f'"${bak_path}"
        fi
        if mv "$tmp_dest" "$dest" 2>/dev/null; then
            _PENDING_ROLLBACK=""
            [ -n "$bak_path" ] && rm -rf -- "$bak_path" 2>/dev/null || true
        elif (mkdir -p "$dest" && cp -rf "$tmp_dest"/. "$dest"/); then
            _PENDING_ROLLBACK=""
            # Commit point: dest holds the new data. tmp_dest cleanup is best-effort —
            # the EXIT trap will catch it if rm fails here, so don't roll back the
            # successful copy just because the temp removal stumbled.
            rm -rf "$tmp_dest" 2>/dev/null || true
            [ -n "$bak_path" ] && rm -rf -- "$bak_path" 2>/dev/null || true
        else
            rm -rf "$dest" 2>/dev/null || true
            if [ -n "$bak_path" ] && [ -d "$bak_path" ]; then
                if ! mv -- "$bak_path" "$dest"; then
                    echo -e "  ${RED}✗${NC} CRITICAL: backup restore failed for ${name}! Backup at $bak_path" >&2
                fi
            fi
            _PENDING_ROLLBACK=""
            ok=false
        fi

        if $ok; then
            # Update manifest entry — commit_sha = pin_sha (now installed)
            data=$(echo "$data" | py_helper manifest-update-sha "$name" "$pin_sha" "$TODAY")
            echo -e "  ${GREEN}✓${NC} ${name} updated"
            count=$((count + 1))
        else
            echo -e "  ${RED}✗${NC} ${name} failed"
            errors=$((errors + 1))
        fi
    done <<< "$needs_update"

    # Save updated manifest only if at least one module was updated. Surface
    # save_manifest's exit code: a silent failure here means a module's SHA
    # change applied to disk but the manifest still records the stale SHA,
    # so the next /update would re-pull the same module.
    if [[ $count -gt 0 ]]; then
        if ! echo "$data" | save_manifest; then
            echo -e "${RED}✗${NC} manifest 保存失败 — 已更新模块的新 SHA 未持久化" >&2
            errors=$((errors + 1))
        fi
    fi

    echo ""
    echo "Updated: $count, Failed: $errors"
}

cmd_install() {
    local source_str="" name_override=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)
                # Reject empty string so basename-fallback doesn't silently
                # override a deliberate (but empty) override.
                if [[ -z "${2:-}" ]]; then
                    echo -e "${RED}错误：--name 不能为空${NC}" >&2
                    exit 1
                fi
                name_override="$2"
                shift 2
                ;;
            *)      source_str="$1"; shift ;;
        esac
    done

    [[ -z "$source_str" ]] && { echo "用法：module-manager.sh install <source> [--name <name>]" >&2; exit 1; }

    # Parse source — propagate parse_source's failure (e.g. tab/newline rejection)
    # so empty fields don't slip past as "URL kind requires --name" downstream.
    local parsed
    parsed=$(parse_source "$source_str") || exit 1
    IFS=$'\t' read -r kind repo path ref <<< "$parsed"

    # Validate repo format
    if [[ ("$kind" == "github-subdir" || "$kind" == "github-repo") && -n "$repo" ]]; then
        _validate_repo_format "$repo" || exit 1
    fi

    # Determine install name
    local install_name
    if [[ -n "$name_override" ]]; then
        install_name="$name_override"
    elif [[ "$kind" == "github-subdir" ]]; then
        install_name=$(basename "$path")
    elif [[ "$kind" == "github-repo" ]]; then
        install_name=$(basename "$repo")
    else
        echo -e "${RED}错误：URL 类型的来源必须指定 --name${NC}" >&2
        exit 1
    fi

    # Validate module name (prevent path traversal / shell metacharacters)
    _validate_module_name "$install_name" || exit 1

    local dest="${SKILLS_DIR}/${install_name}"

    # Check for conflict — match any existing entry, not just directories. A bare
    # file at $dest would otherwise sneak past, fail mv, then trip set -e in the
    # mkdir/cp fallback without ever emitting the CONFLICT_INSTALL marker.
    if [[ -e "$dest" || -L "$dest" ]]; then
        echo -e "${RED}错误：路径已存在：$dest${NC}" >&2
        # Marker is the parsing contract with the SKILL.md install-conflict flow.
        # Changing the prefix is a breaking change — update both sides together.
        echo "CONFLICT_INSTALL: $dest" >&2
        exit 2
    fi

    # Get commit SHA (path-specific for subdir modules, repo-level otherwise)
    local sha=""
    if [[ "$kind" != "url" && -n "$repo" ]]; then
        echo -e "→ Getting version info..."
        if [[ "$kind" == "github-subdir" && -n "$path" ]]; then
            sha=$(get_path_sha "$repo" "$path" "${ref:-main}") || {
                echo -e "${RED}错误：无法访问 $repo（路径：$path）${NC}" >&2
                exit 1
            }
        else
            sha=$(get_head_sha "$repo" "${ref:-main}") || {
                echo -e "${RED}错误：无法访问 $repo${NC}" >&2
                exit 1
            }
        fi
    fi

    # Download to temp, then move into place
    echo -e "→ Installing ${install_name}..."
    local tmp_dest
    tmp_dest=$(safe_mktemp)
    _CLEANUP_DIRS+=("$tmp_dest")
    local dl_ok=true
    if [[ "$kind" == "github-subdir" ]]; then
        download_github_subdir "$repo" "$path" "${ref:-main}" "$tmp_dest" || dl_ok=false
    elif [[ "$kind" == "github-repo" ]]; then
        download_github_repo "$repo" "${ref:-main}" "$tmp_dest" || dl_ok=false
    elif [[ "$kind" == "url" ]]; then
        echo -e "${RED}错误：URL 类型的来源尚未实现${NC}" >&2
        rm -rf "$tmp_dest" 2>/dev/null || true
        exit 1
    fi
    if ! $dl_ok; then
        rm -rf "$tmp_dest" 2>/dev/null || true
        exit 1
    fi
    if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
        # Cross-filesystem fallback: explicit error path so a partial cp doesn't leave
        # half-written dest with no manifest entry and no clear signal to the user.
        if ! (mkdir -p "$dest" && cp -rf "$tmp_dest"/. "$dest"/); then
            echo -e "${RED}错误：写入 $dest 失败（mv 与 cp 均未成功）${NC}" >&2
            rm -rf "$dest" 2>/dev/null || true
            rm -rf "$tmp_dest" 2>/dev/null || true
            exit 1
        fi
        rm -rf "$tmp_dest" 2>/dev/null || true
    fi

    # Add to manifest
    local data
    data=$(manifest_json)
    data=$(manifest_add_module "$data" "$install_name" "$sha" "$sha" "$TODAY" "$kind" "$repo" "$path" "${ref:-main}")
    echo "$data" | save_manifest

    echo -e "${GREEN}✓${NC} Installed: ${install_name}"
    echo "  Source: ${source_str}"
    [[ -n "$sha" ]] && echo "  Commit: ${sha:0:8}"
    echo "  Path:   ${dest}"
}

cmd_remove() {
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "用法：module-manager.sh remove <name>" >&2; exit 1; }

    local data
    data=$(manifest_json)

    # Check if module exists in manifest
    if [[ "$(module_exists "$data" "$name")" != "yes" ]]; then
        echo -e "${RED}错误：manifest 中未找到模块 '$name'${NC}" >&2
        exit 1
    fi

    # Get install path
    local install_path
    install_path=$(echo "$data" | py_helper module-get-path "$name")

    # Validate install_path from manifest before rm -rf — defends against a
    # corrupted/poisoned modules.toml that pushes "../somewhere" into the path.
    _validate_module_name "$install_path" || exit 1

    local dest="${SKILLS_DIR}/${install_path}"

    # Remove from manifest FIRST (so a save failure doesn't orphan the directory)
    data=$(echo "$data" | py_helper manifest-delete-module "$name")
    echo "$data" | save_manifest
    echo -e "${GREEN}✓${NC} Removed ${name} from manifest"

    # Best-effort: scrub the check-state sidecar entry. Without this, a
    # re-install with the same name later hits a stale candidate that
    # bump --latest would refuse against, forcing the user to re-check.
    py_helper check-state-delete "$name" "$SKILLS_DIR" 2>/dev/null || true

    # Then remove directory
    if [[ -d "$dest" ]]; then
        if rm -rf "$dest" 2>/dev/null; then
            echo -e "${GREEN}✓${NC} Removed directory: ${dest}"
        else
            echo -e "${RED}✗${NC} 删除目录失败：${dest}（manifest 已清除，目录残留）" >&2
            exit 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} Directory not found: ${dest}"
    fi
}

cmd_adopt() {
    local arg1="${1:-}"
    local arg2="${2:-}"
    local arg3="${3:-}"

    if [[ "$arg1" == "--bulk" ]]; then
        # Accept `adopt --bulk <repo>` or `adopt --bulk --dry-run <repo>` in
        # either order: --dry-run first OR repo first. --dry-run lists matches
        # without touching the manifest; the SKILL.md flow uses dry-run first
        # to drive AskUserQuestion, then re-invokes without --dry-run on
        # confirmation. Bulk-adopt was previously a single shot — SKILL.md
        # promised a confirmation step the script didn't actually support.
        local dry_run="false"
        local repo=""
        for arg in "$arg2" "$arg3"; do
            case "$arg" in
                "")        : ;;
                --dry-run) dry_run="true" ;;
                *)         repo="$arg" ;;
            esac
        done
        [[ -z "$repo" ]] && { echo "用法：module-manager.sh adopt --bulk [--dry-run] <owner/repo>" >&2; exit 1; }
        cmd_adopt_bulk "$repo" "$dry_run"
        return
    fi

    # Single adopt: adopt <name> <source>
    local name="$arg1"
    local source_str="$arg2"
    [[ -z "$name" || -z "$source_str" ]] && { echo "用法：module-manager.sh adopt <name> <source>" >&2; exit 1; }

    _validate_module_name "$name" || exit 1

    # Verify directory exists
    local dest="${SKILLS_DIR}/${name}"
    [[ -d "$dest" ]] || { echo -e "${RED}错误：目录不存在：$dest${NC}" >&2; exit 1; }

    # Parse source — propagate parse_source's failure so we don't write a manifest
    # entry with empty kind on tab/newline rejection.
    local parsed
    parsed=$(parse_source "$source_str") || exit 1
    IFS=$'\t' read -r kind repo path ref <<< "$parsed"

    # Reject URL sources (not yet implemented for adopt)
    if [[ "$kind" == "url" ]]; then
        echo -e "${RED}错误：adopt 不支持 URL 来源，请使用 owner/repo 或 owner/repo:path 格式。${NC}" >&2
        exit 1
    fi

    # Validate repo format
    if [[ ("$kind" == "github-subdir" || "$kind" == "github-repo") && -n "$repo" ]]; then
        _validate_repo_format "$repo" || exit 1
    fi

    # Get current commit SHA (path-specific for subdir modules)
    local sha=""
    if [[ -n "$repo" ]]; then
        if [[ "$kind" == "github-subdir" && -n "$path" ]]; then
            sha=$(get_path_sha "$repo" "$path" "${ref:-main}") || {
                echo -e "${YELLOW}⚠${NC} Cannot reach $repo (path: $path), using empty SHA"
                echo -e "${YELLOW}  注意：空 SHA 模块在 check + bump 之前无法 update / restore${NC}"
            }
        else
            sha=$(get_head_sha "$repo" "${ref:-main}") || {
                echo -e "${YELLOW}⚠${NC} Cannot reach $repo, using empty SHA"
                echo -e "${YELLOW}  注意：空 SHA 模块在 check + bump 之前无法 update / restore${NC}"
            }
        fi
    fi

    # Add to manifest
    local data
    data=$(manifest_json)
    data=$(manifest_add_module "$data" "$name" "$sha" "$sha" "$TODAY" "$kind" "$repo" "$path" "${ref:-main}")
    echo "$data" | save_manifest
    echo -e "${GREEN}✓${NC} Adopted: ${name} (${source_str})"
}

cmd_adopt_bulk() {
    local repo="$1"
    local dry_run="${2:-false}"
    _validate_repo_format "$repo" || exit 1

    if [[ "$dry_run" == "true" ]]; then
        echo -e "→ [DRY RUN] Scanning ${repo} for matching skills (manifest will NOT be modified)..."
    else
        echo -e "→ Scanning ${repo} for matching skills..."
    fi

    # Get the list of skill directories in the remote repo
    local remote_skills
    remote_skills=$("$GH" api "repos/${repo}/contents/skills" -q 'if type == "array" then .[].name else .name end' 2>/dev/null) || {
        echo -e "${RED}错误：无法列出 $repo 中的 skills${NC}" >&2
        exit 1
    }

    # Read current manifest
    local data
    data=$(manifest_json)

    local adopted=0 skipped=0

    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue

        # Validate remote skill name (prevent path traversal from API responses)
        if ! _validate_module_name "$skill_name" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${NC} Skipped invalid name: ${skill_name}"
            continue
        fi

        local local_dir="${SKILLS_DIR}/${skill_name}"

        # Skip if not present locally
        if [[ ! -d "$local_dir" ]]; then
            continue
        fi

        # Skip if already tracked
        if [[ "$(module_exists "$data" "$skill_name")" == "yes" ]]; then
            echo -e "  ${GRAY}skip${NC} ${skill_name} (already tracked)"
            skipped=$((skipped + 1))
            continue
        fi

        # Get path-specific SHA for each skill
        local sha=""
        sha=$(get_path_sha "$repo" "skills/${skill_name}" "main") || {
            echo -e "  ${YELLOW}⚠${NC} Cannot get SHA for skills/${skill_name}, using empty"
            echo -e "  ${YELLOW}  注意：空 SHA 模块在 check + bump 之前无法 update / restore${NC}"
        }

        # Add to manifest (pin = sha at adoption time; user can bump later)
        data=$(manifest_add_module "$data" "$skill_name" "$sha" "$sha" "$TODAY" \
            "github-subdir" "$repo" "skills/${skill_name}" "main")
        echo -e "  ${GREEN}✓${NC} ${skill_name}"
        adopted=$((adopted + 1))
    done <<< "$remote_skills"

    # Save only if at least one module was adopted AND this is not a dry run
    if [[ $adopted -gt 0 && "$dry_run" != "true" ]]; then
        echo "$data" | save_manifest
    fi

    echo ""
    if [[ "$dry_run" == "true" ]]; then
        echo "[DRY RUN] Would adopt: $adopted, Would skip: $skipped (manifest unchanged)"
        echo "To proceed: bash module-manager.sh adopt --bulk ${repo}"
    else
        echo "Adopted: $adopted, Skipped: $skipped"
        echo "Manifest: $MANIFEST"
    fi
}

cmd_restore() {
    local data
    data=$(manifest_json)

    local total
    total=$(echo "$data" | py_helper restore-count)

    if [[ "$total" == "0" ]]; then
        echo "No modules in manifest."
        exit 0
    fi

    echo -e "→ Restoring $total modules from manifest..."

    # Get list of modules to restore (missing locally)
    local to_restore
    to_restore=$(echo "$data" | py_helper restore-list-missing "$SKILLS_DIR")

    if [[ -z "$to_restore" ]]; then
        echo -e "${GREEN}✓${NC} All modules already present locally"
        return 0
    fi

    local restored=0 failed=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name kind repo path ref install_path pin_sha from_sha
        # py_helper tab-vars emits US (\x1f), not \t — \t is IFS whitespace
        # in bash so empty fields collapse, mis-binding path/ref/install_path
        # for github-repo modules where `path` is intentionally empty. \x1f
        # is non-whitespace, so consecutive delimiters yield empty fields.
        IFS=$'\x1f' read -r name kind repo path ref install_path pin_sha from_sha <<< "$(echo "$line" | py_helper tab-vars)"

        # Validate install_path from manifest (prevent path traversal)
        if ! _validate_module_name "$install_path" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} ${name}: invalid install_path '${install_path}', skipping"
            failed=$((failed + 1))
            continue
        fi

        # Defensive: pin_sha must be a 40-char SHA (set on install/adopt/bump).
        if [[ ! "$pin_sha" =~ ^[0-9a-f]{40}$ ]]; then
            echo -e "  ${RED}✗${NC} ${name}: invalid pin SHA '${pin_sha:0:20}...', skipping"
            failed=$((failed + 1))
            continue
        fi

        local dest="${SKILLS_DIR}/${install_path}"
        # 防御：dest 已存在且非目录（异常残留文件）时拒绝还原。restore-list-missing
        # 用 os.path.isdir 判断缺失，会把这种残留文件当成"缺失"重新还原；若随后
        # mv 与 mkdir/cp 双双失败，下方 fallback 的 rm -rf "$dest" 会删掉这个
        # 预先存在的文件（数据丢失）。提前拦截并报错，避免静默删除。
        if [ -e "$dest" ] && [ ! -d "$dest" ]; then
            echo -e "  ${RED}✗${NC} ${name}: ${dest} 已存在且不是目录，跳过（请手动检查）"
            failed=$((failed + 1))
            continue
        fi
        echo -e "→ Restoring ${name} (${pin_sha:0:8})..."

        local tmp_dest ok=true
        tmp_dest=$(safe_mktemp)
        _CLEANUP_DIRS+=("$tmp_dest")
        # Download by pin (matches the manifest's recorded SHA exactly).
        if ! _download_to_tmp "$kind" "$repo" "$path" "$pin_sha" "$tmp_dest"; then ok=false; fi

        if $ok; then
            if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
                # Cross-filesystem fallback: guard the cp so a failure doesn't
                # abort the whole restore under `set -e`. Account it as a
                # per-module failure and continue, mirroring cmd_install's
                # graceful path but loop-scoped.
                if ! (mkdir -p "$dest" && cp -rf "$tmp_dest"/. "$dest"/); then
                    echo -e "  ${RED}✗${NC} ${name}: 写入 ${dest} 失败（mv 与 cp 均未成功）"
                    rm -rf "$dest" 2>/dev/null || true
                    rm -rf "$tmp_dest" 2>/dev/null || true
                    failed=$((failed + 1))
                    continue
                fi
                rm -rf "$tmp_dest" 2>/dev/null || true
            fi
            echo -e "  ${GREEN}✓${NC} ${name}"
            restored=$((restored + 1))
        else
            rm -rf "$tmp_dest" 2>/dev/null || true
            echo -e "  ${RED}✗${NC} ${name}"
            failed=$((failed + 1))
        fi
    done <<< "$to_restore"

    echo ""
    echo "Restored: $restored, Failed: $failed, Already present: $((total - restored - failed))"
}

cmd_prune() {
    local mode="list"
    local names=()

    case "${1:-}" in
        --all)
            mode="all"
            if [[ $# -gt 1 ]]; then
                echo "用法：module-manager.sh prune --all（不接受其他参数）" >&2
                exit 1
            fi
            ;;
        --confirm)
            mode="confirm"
            shift
            names=("$@")
            if [[ ${#names[@]} -eq 0 ]]; then
                echo "用法：module-manager.sh prune --confirm <name>..." >&2
                exit 1
            fi
            ;;
        "")
            mode="list"
            ;;
        *)
            echo "用法：module-manager.sh prune [--all | --confirm <name>...]" >&2
            exit 1
            ;;
    esac

    local data
    data=$(manifest_json)

    if [[ "$mode" == "list" ]]; then
        py_helper list-untracked "$data" "$SKILLS_DIR"
        return
    fi

    if [[ "$mode" == "all" ]]; then
        local untracked
        untracked=$(py_helper list-untracked "$data" "$SKILLS_DIR")
        if [[ -z "$untracked" ]]; then
            echo -e "${GREEN}✓${NC} 没有未管理目录，无需清理。"
            return 0
        fi
        local removed=0 errors=0
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if ! _validate_module_name "$name" 2>/dev/null; then
                echo -e "  ${RED}✗${NC} ${name}: 名称非法，跳过"
                errors=$((errors + 1))
                continue
            fi
            # 防御深度：list-untracked 已按 tracked_paths 过滤，但若任何环节
            # （Python helper 输出格式漂移、CR/LF 拆分、JSON 编码异常）让一个
            # tracked 名字误入此循环，下面的 rm -rf 会删掉受管模块。在删之前
            # 再问一次 manifest（含 install_path），碰到 tracked 名字直接拒绝。
            if [[ "$(path_tracked "$data" "$name")" == "yes" ]]; then
                echo -e "  ${RED}✗${NC} ${name}: 仍在 manifest 中——拒绝删除（请用 remove）"
                errors=$((errors + 1))
                continue
            fi
            local dest="${SKILLS_DIR}/${name}"
            if [[ -d "$dest" ]]; then
                if rm -rf "$dest" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${NC} 已删除 ${name}/"
                    removed=$((removed + 1))
                else
                    echo -e "  ${RED}✗${NC} ${name}: 删除失败"
                    errors=$((errors + 1))
                fi
            else
                echo -e "  ${YELLOW}⚠${NC} ${name}: 目录已不存在，跳过"
            fi
        done <<< "$untracked"
        echo ""
        echo "已清理: $removed, 失败: $errors"
        # Match --confirm's contract: non-zero exit when any deletion failed
        [[ $errors -gt 0 ]] && return 1
        return 0
    fi

    # mode == "confirm"
    local removed=0 errors=0
    for name in "${names[@]}"; do
        if ! _validate_module_name "$name"; then
            errors=$((errors + 1))
            continue
        fi
        # Refuse to delete a directory still tracked in the manifest — caller is
        # confused; the right command for managed modules is `remove`, which also
        # clears the entry. path_tracked checks BOTH manifest keys AND
        # install_paths (a module 'foo' with install_path 'bar' lives at
        # SKILLS_DIR/bar, but module_exists('bar') would return no).
        if [[ "$(path_tracked "$data" "$name")" == "yes" ]]; then
            echo -e "  ${RED}✗${NC} ${name}: 仍在 manifest 中——请使用 remove，而非 prune" >&2
            errors=$((errors + 1))
            continue
        fi
        local dest="${SKILLS_DIR}/${name}"
        if [[ ! -d "$dest" ]]; then
            echo -e "  ${YELLOW}⚠${NC} ${name}: 目录不存在 (${dest})，跳过"
            continue
        fi
        if rm -rf "$dest" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} 已删除 ${name}/"
            removed=$((removed + 1))
        else
            echo -e "  ${RED}✗${NC} ${name}: 删除失败"
            errors=$((errors + 1))
        fi
    done
    echo ""
    echo "已清理: $removed, 失败: $errors"
    [[ $errors -gt 0 ]] && return 1
    return 0
}

cmd_bump() {
    # Move a module's `pin` field to a new SHA. Pin is the user-approved
    # SHA; update will install exactly that. Bump itself does no download —
    # the user-visible state change is "approval lock-in", not "fetch".
    #
    # Usage: bump <name|--all> [--to <sha>|--latest]
    #   --to <sha>: pin to a specific 40-char SHA (existence verified)
    #   --latest:   pin to upstream tip of the tracking ref (default)
    #   --all:      bump every module to its --latest (--to is rejected;
    #               sharing one SHA across modules is not meaningful)
    local target="" sha_arg="" use_latest=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --to)
                if [[ -z "${2:-}" ]]; then
                    echo -e "${RED}错误：--to 需要 SHA 参数${NC}" >&2
                    exit 1
                fi
                sha_arg="$2"
                shift 2
                ;;
            --latest)
                use_latest=true
                shift
                ;;
            --all)
                if [[ -n "$target" ]]; then
                    echo -e "${RED}错误：不能同时指定模块名和 --all${NC}" >&2
                    exit 1
                fi
                target="--all"
                shift
                ;;
            -*)
                echo -e "${RED}错误：不识别的选项 '$1'${NC}" >&2
                exit 1
                ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                else
                    echo -e "${RED}错误：多余参数 '$1'${NC}" >&2
                    exit 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        echo "用法：module-manager.sh bump <name|--all> [--to <sha>|--latest]" >&2
        exit 1
    fi
    if [[ "$target" == "--all" && -n "$sha_arg" ]]; then
        echo -e "${RED}错误：--all 与 --to <sha> 不能同时使用${NC}" >&2
        exit 1
    fi
    # --to and --latest are mutually exclusive when both are explicit. Without
    # this check the single-module path silently took --latest (sha_arg
    # dropped), so the user who typed both got tip-of-upstream instead of the
    # SHA they explicitly named.
    if $use_latest && [[ -n "$sha_arg" ]]; then
        echo -e "${RED}错误：--to 与 --latest 不能同时使用${NC}" >&2
        exit 1
    fi
    # No explicit choice → default to --latest
    if [[ -z "$sha_arg" ]]; then
        use_latest=true
    fi

    local data
    data=$(manifest_json)

    if [[ "$target" == "--all" ]]; then
        local names
        names=$(echo "$data" | py_helper module-names)
        if [[ -z "$names" ]]; then
            echo "manifest 中没有模块。"
            return 0
        fi
        local bumped=0 unchanged=0 errors=0
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            local new_pin cur_pin repo
            # bump --latest goes through check-candidate-verify: requires a
            # recent `check <name>` to have recorded the candidate SHA, and
            # refuses if upstream has moved since. Closes the TOCTOU race
            # between review and pin write.
            if ! new_pin=$(echo "$data" | GH_CMD="$GH" py_helper check-candidate-verify "$name" "$SKILLS_DIR" 2>&1); then
                echo -e "  ${YELLOW}⚠${NC} ${name}: ${new_pin}"
                errors=$((errors + 1))
                continue
            fi
            cur_pin=$(echo "$data" | py_helper module-get-pin "$name")
            if [[ "$cur_pin" == "$new_pin" ]]; then
                echo -e "  =  ${name}: 已 pin 到 latest (${cur_pin:0:8})"
                unchanged=$((unchanged + 1))
                continue
            fi
            repo=$(echo "$data" | py_helper module-get-repo "$name")
            echo -e "  ${GREEN}↑${NC} ${name}: ${cur_pin:0:8} → ${new_pin:0:8}"
            if [[ -n "$repo" && -n "$cur_pin" ]]; then
                echo "       compare: https://github.com/${repo}/compare/${cur_pin}...${new_pin}"
            fi
            data=$(echo "$data" | py_helper manifest-set-pin "$name" "$new_pin" "$TODAY")
            bumped=$((bumped + 1))
        done <<< "$names"

        if [[ $bumped -gt 0 ]]; then
            if ! echo "$data" | save_manifest; then
                echo -e "${RED}✗${NC} manifest 保存失败 — pin 变更未持久化" >&2
                return 1
            fi
        fi
        echo ""
        echo "Bumped: $bumped, Unchanged: $unchanged, Errors: $errors"
        if [[ $bumped -gt 0 ]]; then
            echo "Run 'bash module-manager.sh update' to install the new pins."
        fi
        [[ $errors -gt 0 ]] && return 1
        return 0
    fi

    # Single module bump
    _validate_module_name "$target" || exit 1
    if [[ "$(module_exists "$data" "$target")" != "yes" ]]; then
        echo -e "${RED}错误：manifest 中未找到模块 '$target'${NC}" >&2
        exit 1
    fi

    local new_pin
    if $use_latest; then
        # See --all path: check-candidate-verify enforces "review came first
        # and upstream still matches what you reviewed".
        new_pin=$(echo "$data" | GH_CMD="$GH" py_helper check-candidate-verify "$target" "$SKILLS_DIR") || exit 1
    else
        if [[ ! "$sha_arg" =~ ^[0-9a-f]{40}$ ]]; then
            echo -e "${RED}错误：SHA 须为 40 字符十六进制（收到 ${sha_arg:0:20}...）${NC}" >&2
            exit 1
        fi
        echo "$data" | GH_CMD="$GH" py_helper verify-sha "$target" "$sha_arg" || exit 1
        new_pin="$sha_arg"
    fi

    local cur_pin
    cur_pin=$(echo "$data" | py_helper module-get-pin "$target")
    if [[ "$cur_pin" == "$new_pin" ]]; then
        echo -e "=  ${target}: 已 pin 到 ${cur_pin:0:8}，无变化"
        return 0
    fi

    local repo
    repo=$(echo "$data" | py_helper module-get-repo "$target")
    echo -e "${GREEN}↑${NC} ${target}: pin ${cur_pin:0:8} → ${new_pin:0:8}"
    if [[ -n "$repo" && -n "$cur_pin" ]]; then
        echo "  compare: https://github.com/${repo}/compare/${cur_pin}...${new_pin}"
    fi
    data=$(echo "$data" | py_helper manifest-set-pin "$target" "$new_pin" "$TODAY")
    if ! echo "$data" | save_manifest; then
        echo -e "${RED}✗${NC} manifest 保存失败 — pin 变更未持久化" >&2
        return 1
    fi
    echo ""
    echo "Run 'bash module-manager.sh update $target' to install."
}

# ─── Main ─────────────────────────────────────────────────────────

case "${1:-}" in
    list)     cmd_list ;;
    check)    shift; cmd_check "${1:---all}" ;;
    bump)     shift; cmd_bump "$@" ;;
    update)   shift; cmd_update "${1:---all}" ;;
    install)  shift; cmd_install "$@" ;;
    remove)   shift; cmd_remove "$@" ;;
    adopt)    shift; cmd_adopt "$@" ;;
    restore)  cmd_restore ;;
    prune)    shift; cmd_prune "$@" ;;
    *)
        echo "module-manager.sh — Third-party module manager"
        echo ""
        echo "Commands:"
        echo "  list                            List tracked modules"
        echo "  check [name|--all]              Check upstream for new commits"
        echo "  bump <name|--all> [--to <sha>]  Approve a new pin (no download)"
        echo "  update [name|--all]             Install pinned SHA on disk"
        echo "  install <source> [--name X]     Install new module"
        echo "  remove <name>                   Remove a module"
        echo "  adopt <name> <source>           Track existing directory"
        echo "  adopt --bulk <owner/repo>       Bulk-adopt from repo"
        echo "  restore                         Restore from manifest"
        echo "  prune                           List untracked directories"
        echo "  prune --all                     Delete all untracked directories"
        echo "  prune --confirm <name>...       Delete specific untracked directories"
        echo ""
        echo "Pin/update flow:"
        echo "  check                       — see what's new upstream"
        echo "  bump <name> [--to|--latest] — lock in a new approved SHA"
        echo "  update <name>               — install the approved SHA"
        exit 1
        ;;
esac
