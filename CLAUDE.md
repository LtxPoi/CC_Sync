# CC_Sync

Multi-repo sync, cross-device handoff, and module management for Claude Code.

## File Map

| File | Role |
|------|------|
| `sync.sh` | Main entry point: repo discovery, config sync, pull/commit/push, handoff, dotfiles push |
| `module-manager.sh` | Install/update/remove/restore third-party skills from GitHub |
| `lib/common.sh` | Shared bash helpers: `get_machine_name`, `compute_cc_hash`, `normalize_path`, `detect_gh`, `file_mtime`, `safe_mktemp` |
| `lib/handoff.py` | HANDOFF.md parser/writer (called by sync.sh and preflight.py) |
| `lib/module_helper.py` | Python helper for module-manager.sh |
| `HANDOFF.md` | Cross-device task relay (registry comment + device sections) |
| `.claude/skills/sync/SKILL.md` | /sync skill definition: instructs Claude how to run and interpret sync.sh |
| `.claude/skills/module-manager/SKILL.md` | /module-manager skill definition |
| `.claude/hooks/preflight.py` | Session startup hook: checks .machine-name, pending handoff tasks |

## Key Concepts

- **dotfiles repo**: User-owned git repo storing Claude Code config. Mapped via `CONFIG_MAP`. Subdirectory: `claude-code-config/`.
- **`.env`**: Machine-local config (gitignored). Created by first-run wizard. Keys: `DOTFILES_PATH` (required), `ENABLE_REPO_SYNC`, `WORKSPACE_ROOTS` (semicolon-separated), `TOPIC`.
- **`HANDOFF.md`**: Registry comment (`<!-- registry: ... -->`) defines valid device sections. `(none)` = no pending tasks. Only registered device names are section boundaries.
- **`CONFIG_MAP`**: Declarative array mapping dotfiles paths to local paths. Format: `"repo_relative|local_absolute|display_name"`.

## Prerequisites

- Python 3.10+ (for `tomllib` in module_helper.py)
- `gh` CLI (authenticated via `gh auth login`)
- `git`

## First Run

When `.env` does not exist:
- **Interactive terminal**: First-run wizard launches automatically
- **Non-interactive** (Claude Code Bash tool): Exits with error. User must run `bash sync.sh` in an interactive terminal first.

## Commands

```bash
bash sync.sh                        # Full sync (6 steps)
bash sync.sh device list             # List registered devices
bash sync.sh device add <name>       # Register device in HANDOFF.md
bash sync.sh device remove <name>    # Unregister device
bash sync.sh repo-sync enable        # Enable project repo sync
bash sync.sh repo-sync unignore <n>  # Restore ignored repo
bash module-manager.sh restore       # Restore all skill modules from manifest
bash module-manager.sh list          # List tracked modules
```

## Code Constraints

### Functions and Scope

- **All helper functions must be defined at module level** (top of script, outside conditionals). A function inside an `if` block will not exist when that branch is not taken. Step 3 callers will get `command not found`.
- **`local` keyword is only valid inside functions.** In the main execution body (while loops, etc.), use plain variable assignment.

### .env File Safety

- **All values must be double-quoted** when writing: `KEY="value"`. Unquoted semicolons (`E:/Work;F:/Personal`) will be split by `source` into separate commands.
- **Use in-loop elif replacement + found-flag append** when modifying keys. Never unconditionally append after the loop (creates duplicate keys).
- **Strip quotes from old values** when reading (`.strip('"')`) to handle both legacy and new formats.

### Python File I/O

- **Always use `newline="\n"`** in `open(..., "w")`. Windows defaults to CRLF, causing git phantom diffs.
- **Always use `encoding="utf-8"`**. Windows defaults to GBK/cp936.

### Clone Return Codes

`_interactive_clone_menu` return code contract:
- `0` = cloned successfully
- `1` = user skipped / invalid input
- `2` = added to .sync_ignore
- `3` = git clone execution failed (caller must create `.error` file)

New return codes must be added to both the function and the caller dispatch.

### Path Handling (Windows / Git Bash)

- **`dirname "C:/foo"` returns `"C:"`** not `"C:/"`. Fix after dirname: `[[ "$parent_dir" =~ ^[A-Za-z]:$ ]] && parent_dir="${parent_dir}/"`
- **Pass paths from bash to Python via `normalize_path`** (lib/common.sh). Python cannot resolve `/c/Users/...` paths.
- **MSYS2 auto-converts `/f`, `/v`** to paths. Wrap Windows-native commands in `cmd.exe //c "..."`.

### Multi-Root Repo Lookup

- `_find_repo_dir` returns the first directory name match across `WS_ROOTS`. The Step 3 caller must verify `remote.origin.url` matches the expected GitHub URL before processing. Without this, a same-named directory in another root could be auto-pushed to the wrong remote.

### Sync Step Dependencies

- `KNOWN_REPOS` is built in Step 1 and immediately available. `REPO_ORDER` is built inside Step 3's while loop. Step 2 code can only reference `KNOWN_REPOS`.
- `WS_ROOTS` is parsed from `.env` at load time. `_find_repo_dir` depends on it.

## Verification

```bash
bash -n sync.sh              # Syntax check
bash sync.sh                 # Full run
```

## Do NOT

- Do not `source` .env with unquoted values containing semicolons or spaces
- Do not use `((var++))` in bash scripts with `set -e` when var could be 0 (evaluates to falsy, exits script). Use `var=$((var + 1))`
- Do not place function definitions inside conditional blocks
- Do not write files without `newline="\n"` on Windows
- Do not assume a repo directory's remote matches the expected URL in multi-root setups
