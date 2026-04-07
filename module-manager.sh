#!/usr/bin/env bash
# module-manager.sh — Third-party module manager for Claude Code
# Manages skills/plugins/MCP servers in ~/.claude/skills/
# Usage: module-manager.sh <command> [options]
#
# Commands:
#   list                        List all tracked modules + detect unmanaged
#   check [name|--all]          Check for upstream updates
#   update [name|--all]         Pull updates from upstream
#   install <source> [--name X] Install a new module
#   remove <name>               Remove a module
#   adopt <name> <source>       Track an existing directory in the manifest
#   adopt --bulk <owner/repo>   Bulk-adopt matching directories
#   restore                     Download all modules from manifest (new device)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# --- Config ---
# normalize_path converts Git Bash paths (/c/Users/...) to Windows paths (C:/Users/...)
# so Python (native Windows) can resolve them correctly.
SKILLS_DIR=$(normalize_path "${HOME}/.claude/skills")
MANIFEST="${SKILLS_DIR}/modules.toml"
TODAY=$(date +%Y-%m-%d)

detect_gh || exit 1
MODULE_HELPER=$(normalize_path "$SCRIPT_DIR/lib/module_helper.py")

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

# Parse a JSON object string into bash variable assignments, then eval.
# Usage: eval "$(json_to_vars "$json_line")"
json_to_vars() {
    py_helper json-to-vars "$1"
}

# Check whether a module name exists in the manifest JSON.
# Prints "yes" or "no".
module_exists() {
    echo "$1" | py_helper module-exists "$2"
}

# Add or overwrite a module entry in the manifest JSON.
# Reads JSON from $1 (data), prints updated JSON to stdout.
# Args: data name sha today kind repo path ref
manifest_add_module() {
    echo "$1" | py_helper manifest-add-module "$2" "$3" "$4" "$5" "$6" "$7" "$8"
}

# ─── GitHub helpers ───────────────────────────────────────────────

get_head_sha() {
    local repo="$1" ref="${2:-main}"
    local sha
    sha=$("$GH" api "repos/${repo}/commits/${ref}" -q '.sha' 2>/dev/null) || return 1
    # Validate: must be 40-char hex (reject null, empty, error messages)
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    echo "$sha"
}

# Download a subdirectory from GitHub via API (no full clone needed)
download_github_subdir() {
    local repo="$1" subpath="$2" ref="$3" dest
    dest=$(normalize_path "$4")
    py_helper download-github-subdir "$GH" "$repo" "$subpath" "$ref" "$dest"
}

# Download a whole GitHub repo via shallow clone
download_github_repo() {
    local repo="$1" ref="$2" dest
    dest=$(normalize_path "$3")
    local tmp_clone
    tmp_clone=$(safe_mktemp)

    if ! git clone --depth 1 --branch "$ref" --single-branch \
         "https://github.com/${repo}.git" "$tmp_clone" 2>/dev/null; then
        echo "${RED}✗ Failed to clone branch '$ref' from https://github.com/${repo}.git${NC}" >&2
        rm -rf "$tmp_clone"
        return 1
    fi

    mkdir -p "$dest"
    # Copy contents, exclude .git
    (cd "$tmp_clone" && find . -maxdepth 1 ! -name . ! -name .git -exec cp -rf {} "$dest"/ \;)
    rm -rf "$tmp_clone"
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
    if [[ "$src" == https://* ]]; then
        printf 'url\t\t\t%s' "$src"
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

    GH_CMD="$GH" py_helper check "$data" "$target"
}

cmd_update() {
    local target="${1:---all}"
    local data
    data=$(manifest_json)

    # Get modules that need updating (reuse check logic)
    local needs_update
    local check_tmpdir
    check_tmpdir=$(safe_mktemp)
    local check_stderr="${check_tmpdir}/stderr.txt"
    needs_update=$(GH_CMD="$GH" py_helper update-check "$data" "$target" 2>"$check_stderr") || {
        local rc=$?
        if [[ -s "$check_stderr" ]]; then
            echo -e "${RED}✗${NC} Update check failed:" >&2
            cat "$check_stderr" >&2
        fi
        rm -rf "$check_tmpdir"
        return $rc
    }
    rm -rf "$check_tmpdir"

    if [[ -z "$needs_update" ]]; then
        echo -e "${GREEN}✓${NC} All modules up to date"
        return 0
    fi

    local count=0
    local errors=0

    while IFS= read -r line; do
        local name kind repo path ref install_path latest_sha
        eval "$(json_to_vars "$line")"

        echo -e "→ Updating ${name}..."
        local dest="${SKILLS_DIR}/${install_path}"

        local ok=true
        local tmp_dest
        tmp_dest=$(safe_mktemp)

        if ! _download_to_tmp "$kind" "$repo" "$path" "$ref" "$tmp_dest"; then ok=false; fi

        if ! $ok; then
            rm -rf "$tmp_dest" 2>/dev/null
            echo -e "  ${RED}✗${NC} ${name} download failed"
            errors=$((errors + 1))
            continue
        fi

        # Swap with backup
        [ -d "$dest" ] && mv "$dest" "${dest}.bak"
        if mv "$tmp_dest" "$dest" 2>/dev/null; then
            rm -rf "${dest}.bak" 2>/dev/null
        elif (mkdir -p "$dest" && cp -rf "$tmp_dest"/. "$dest"/ && rm -rf "$tmp_dest"); then
            rm -rf "${dest}.bak" 2>/dev/null
        else
            rm -rf "$dest" 2>/dev/null
            [ -d "${dest}.bak" ] && mv "${dest}.bak" "$dest"
            ok=false
        fi

        if $ok; then
            # Update manifest entry
            data=$(echo "$data" | py_helper manifest-update-sha "$name" "$latest_sha" "$TODAY")
            echo -e "  ${GREEN}✓${NC} ${name} updated"
            count=$((count + 1))
        else
            echo -e "  ${RED}✗${NC} ${name} failed"
            errors=$((errors + 1))
        fi
    done <<< "$needs_update"

    # Save updated manifest
    echo "$data" | save_manifest

    echo ""
    echo "Updated: $count, Failed: $errors"
}

cmd_install() {
    local source_str="" name_override=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name_override="$2"; shift 2 ;;
            *)      source_str="$1"; shift ;;
        esac
    done

    [[ -z "$source_str" ]] && { echo "Usage: module-manager.sh install <source> [--name <name>]"; exit 1; }

    # Parse source
    IFS=$'\t' read -r kind repo path ref <<< "$(parse_source "$source_str")"

    # Determine install name
    local install_name
    if [[ -n "$name_override" ]]; then
        install_name="$name_override"
    elif [[ "$kind" == "github-subdir" ]]; then
        install_name=$(basename "$path")
    elif [[ "$kind" == "github-repo" ]]; then
        install_name=$(basename "$repo")
    else
        echo "Error: --name is required for URL sources" >&2
        exit 1
    fi

    local dest="${SKILLS_DIR}/${install_name}"

    # Check for conflict
    if [[ -d "$dest" ]]; then
        echo "Error: Directory already exists: $dest" >&2
        exit 2
    fi

    # Get commit SHA
    local sha=""
    if [[ "$kind" != "url" && -n "$repo" ]]; then
        echo -e "→ Getting version info..."
        sha=$(get_head_sha "$repo" "${ref:-main}") || {
            echo "Error: Cannot reach $repo" >&2
            exit 1
        }
    fi

    # Download to temp, then move into place
    echo -e "→ Installing ${install_name}..."
    local tmp_dest
    tmp_dest=$(safe_mktemp)
    local dl_ok=true
    if [[ "$kind" == "github-subdir" ]]; then
        download_github_subdir "$repo" "$path" "${ref:-main}" "$tmp_dest" || dl_ok=false
    elif [[ "$kind" == "github-repo" ]]; then
        download_github_repo "$repo" "${ref:-main}" "$tmp_dest" || dl_ok=false
    elif [[ "$kind" == "url" ]]; then
        echo "Error: URL source not yet implemented" >&2
        rm -rf "$tmp_dest"
        exit 1
    fi
    if ! $dl_ok; then
        rm -rf "$tmp_dest"
        exit 1
    fi
    if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
        mkdir -p "$dest"
        cp -rf "$tmp_dest"/. "$dest"/
        rm -rf "$tmp_dest"
    fi

    # Add to manifest
    local data
    data=$(manifest_json)
    data=$(manifest_add_module "$data" "$install_name" "$sha" "$TODAY" "$kind" "$repo" "$path" "${ref:-main}")
    echo "$data" | save_manifest

    echo -e "${GREEN}✓${NC} Installed: ${install_name}"
    echo "  Source: ${source_str}"
    [[ -n "$sha" ]] && echo "  Commit: ${sha:0:8}"
    echo "  Path:   ${dest}"
}

cmd_remove() {
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "Usage: module-manager.sh remove <name>"; exit 1; }

    local data
    data=$(manifest_json)

    # Check if module exists in manifest
    if [[ "$(module_exists "$data" "$name")" != "yes" ]]; then
        echo "Error: Module '$name' not found in manifest" >&2
        exit 1
    fi

    # Get install path
    local install_path
    install_path=$(echo "$data" | py_helper module-get-path "$name")

    local dest="${SKILLS_DIR}/${install_path}"

    # Remove directory
    if [[ -d "$dest" ]]; then
        rm -rf "$dest"
        echo -e "${GREEN}✓${NC} Removed directory: ${dest}"
    else
        echo -e "${YELLOW}⚠${NC} Directory not found: ${dest} (removing manifest entry only)"
    fi

    # Remove from manifest
    data=$(echo "$data" | py_helper manifest-delete-module "$name")
    echo "$data" | save_manifest

    echo -e "${GREEN}✓${NC} Removed ${name} from manifest"
}

cmd_adopt() {
    local arg1="${1:-}"
    local arg2="${2:-}"

    if [[ "$arg1" == "--bulk" ]]; then
        [[ -z "$arg2" ]] && { echo "Usage: module-manager.sh adopt --bulk <owner/repo>"; exit 1; }
        cmd_adopt_bulk "$arg2"
        return
    fi

    # Single adopt: adopt <name> <source>
    local name="$arg1"
    local source_str="$arg2"
    [[ -z "$name" || -z "$source_str" ]] && { echo "Usage: module-manager.sh adopt <name> <source>"; exit 1; }

    # Verify directory exists
    local dest="${SKILLS_DIR}/${name}"
    [[ -d "$dest" ]] || { echo "Error: Directory not found: $dest" >&2; exit 1; }

    # Parse source
    IFS=$'\t' read -r kind repo path ref <<< "$(parse_source "$source_str")"

    # Get current commit SHA
    local sha=""
    if [[ -n "$repo" ]]; then
        sha=$(get_head_sha "$repo" "${ref:-main}") || {
            echo -e "${YELLOW}⚠${NC} Cannot reach $repo, using empty SHA"
        }
    fi

    # Add to manifest
    local data
    data=$(manifest_json)
    data=$(manifest_add_module "$data" "$name" "$sha" "$TODAY" "$kind" "$repo" "$path" "${ref:-main}")
    echo "$data" | save_manifest
    echo -e "${GREEN}✓${NC} Adopted: ${name} (${source_str})"
}

cmd_adopt_bulk() {
    local repo="$1"

    echo -e "→ Scanning ${repo} for matching skills..."

    # Get the list of skill directories in the remote repo
    local remote_skills
    remote_skills=$("$GH" api "repos/${repo}/contents/skills" -q 'if type == "array" then .[].name else .name end' 2>/dev/null) || {
        echo "Error: Cannot list skills in $repo" >&2
        exit 1
    }

    # Get HEAD SHA
    local sha
    sha=$(get_head_sha "$repo" "main") || {
        echo "Error: Cannot get HEAD for $repo" >&2
        exit 1
    }

    # Read current manifest
    local data
    data=$(manifest_json)

    local adopted=0 skipped=0

    while IFS= read -r skill_name; do
        [[ -z "$skill_name" ]] && continue
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

        # Add to manifest
        data=$(manifest_add_module "$data" "$skill_name" "$sha" "$TODAY" \
            "github-subdir" "$repo" "skills/${skill_name}" "main")
        echo -e "  ${GREEN}✓${NC} ${skill_name}"
        adopted=$((adopted + 1))
    done <<< "$remote_skills"

    # Save
    echo "$data" | save_manifest

    echo ""
    echo "Adopted: $adopted, Skipped: $skipped"
    echo "Manifest: $MANIFEST"
}

cmd_restore() {
    local data
    data=$(manifest_json)

    local total missing
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
        local name kind repo path ref install_path
        eval "$(json_to_vars "$line")"

        local dest="${SKILLS_DIR}/${install_path}"
        echo -e "→ Restoring ${name}..."

        local tmp_dest ok=true
        tmp_dest=$(safe_mktemp)
        if ! _download_to_tmp "$kind" "$repo" "$path" "$ref" "$tmp_dest"; then ok=false; fi

        if $ok; then
            if ! mv "$tmp_dest" "$dest" 2>/dev/null; then
                mkdir -p "$dest"
                cp -rf "$tmp_dest"/. "$dest"/
                rm -rf "$tmp_dest"
            fi
            echo -e "  ${GREEN}✓${NC} ${name}"
            restored=$((restored + 1))
        else
            rm -rf "$tmp_dest" 2>/dev/null
            echo -e "  ${RED}✗${NC} ${name}"
            failed=$((failed + 1))
        fi
    done <<< "$to_restore"

    echo ""
    echo "Restored: $restored, Failed: $failed, Already present: $((total - restored - failed))"
}

# ─── Main ─────────────────────────────────────────────────────────

case "${1:-}" in
    list)     cmd_list ;;
    check)    shift; cmd_check "${1:---all}" ;;
    update)   shift; cmd_update "${1:---all}" ;;
    install)  shift; cmd_install "$@" ;;
    remove)   shift; cmd_remove "$@" ;;
    adopt)    shift; cmd_adopt "$@" ;;
    restore)  cmd_restore ;;
    *)
        echo "module-manager.sh — Third-party module manager"
        echo ""
        echo "Commands:"
        echo "  list                        List tracked modules"
        echo "  check [name|--all]          Check for updates"
        echo "  update [name|--all]         Update modules"
        echo "  install <source> [--name X] Install new module"
        echo "  remove <name>               Remove a module"
        echo "  adopt <name> <source>       Track existing directory"
        echo "  adopt --bulk <owner/repo>   Bulk-adopt from repo"
        echo "  restore                     Restore from manifest"
        exit 1
        ;;
esac
