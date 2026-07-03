[中文](./README.md)

# CC_Sync

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![GitHub release](https://img.shields.io/github/v/release/koagaroon/CC_Sync)](https://github.com/koagaroon/CC_Sync/releases) ![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)

Multi-repo sync, cross-device task handoff, and module management for Claude Code.

## Features

- **Batch repo sync** — Auto-discover GitHub repos by topic, one-command pull/commit/push
- **Cross-device config sync** — settings.json, skills, hooks, keybindings via dotfiles repo
- **Cross-device task handoff** — Relay pending tasks between machines via HANDOFF.md
- **Third-party module management** — Install/update/remove/restore skills from GitHub
- **First-run wizard** — Interactive .env setup, beginner-friendly
- **Multi-workspace support** — Repos spread across different directories? No problem
- **Deletion anti-resurrection** — A local ledger tracks each config file's sync history, so a config deleted on one device won't be quietly pushed back by another
- **Version-pinned modules** — Module updates follow a "check → approve → install" flow; you review changes before upgrading, nothing auto-follows upstream
- **Confirmation-first safety model** — Sensitive config imports, cross-device task execution, and new skill imports all ask for your consent; no silent actions

## Prerequisites

### 1. Git

- **Windows**: Open **PowerShell** and run:
  ```powershell
  winget install --id Git.Git -e
  ```
- **macOS**: Open **Terminal** and run: `brew install git`
- **Linux**: Open **Terminal** and run: `sudo apt install git`

### 2. Python 3.10+

- **Windows**: Continue in **PowerShell**:
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  Restart PowerShell, then run `python --version` and confirm the version is >= 3.10
- **macOS**: Continue in **Terminal**: `brew install python`
- **Linux**: Continue in **Terminal**: `sudo apt install python3`

### 3. GitHub CLI (gh)

- **Windows**: Continue in **PowerShell**:
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**: Continue in **Terminal**: `brew install gh`
- **Linux**: See [GitHub CLI docs](https://cli.github.com/)

After installing, continue in the same **PowerShell** (or **Terminal**) and run:

```bash
gh auth login
```

Follow prompts: GitHub.com > HTTPS > Login with a web browser, then authorize in your browser.

### 4. Claude Code

You need a working Claude Code CLI. See [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) if not installed.

## Quick Start

### Step 1: Clone This Repo

Open a terminal (Windows: **PowerShell** or **Git Bash**; macOS/Linux: **Terminal**):

```bash
git clone https://github.com/koagaroon/CC_Sync.git
```

### Step 2: Tag Your GitHub Repos

Continue in the same terminal. For each repo you want to sync:

```bash
gh repo edit <your-username>/<repo-name> --add-topic claude-code-workspace
```

> Don't know your username? Continue in the same terminal: `gh api user -q .login`

### Step 3: First-Time Setup

> **This step MUST run in an interactive terminal** (not inside Claude Code). Windows: open **Git Bash**. macOS/Linux: use **Terminal**.

In the terminal, navigate to your cloned CC_Sync directory (replace with your actual path):

```bash
# Windows example (replace with your actual path)
cd /c/Projects/CC_Sync

# macOS/Linux example
cd ~/Projects/CC_Sync
```

Then run:

```bash
bash sync.sh
```

The wizard asks:

**Q1: Dotfiles repo path** — Enter a path for storing Claude Code config as a git repo. If you don't have one yet, enter a new path — the script creates the directory, initializes a git repo, and can create a matching private GitHub repo for you. Examples: `C:/dotfiles` or `D:/config/dotfiles` (Windows), `~/dotfiles` (macOS/Linux)

> Windows paths are case-insensitive (`C:/Dotfiles` and `c:/dotfiles` are equivalent).

> ⚠️ The dotfiles repo must stay **private**. Its GitHub visibility is checked before every sync; a PUBLIC repo aborts the sync to protect your personal config from leaking.

**Q2: Enable repo sync?** — Type `y` to enable. Then:
- **Repo directory**: Where your repos live. Multiple paths with `;` (e.g., `D:/Projects;E:/Work`)
- **GitHub topic**: Press Enter for the default (`claude-code-workspace`)

After setup, the script runs a full sync immediately.

## Daily Use (In Claude Code)

From now on, **everything happens in Claude Code**:

### Getting Started

1. Open **Claude Code**
2. Navigate to the CC_Sync directory (use `cd` if needed)

### Syncing

Say to Claude:

- "sync"
- "push everything"
- "pull all repos"
- "check repo status"

Or type: `/sync`

Claude automatically:

- Shows sync summary (which repos succeeded, failed, or unchanged)
- Asks you to resolve config conflicts via multiple-choice (only metadata like timestamps and line counts is shown by default; pick "show full diff" to see the actual changes)
- Asks for your consent before first importing sensitive configs from dotfiles — `settings.json`, `keybindings.json`, `statusline.sh`, `CLAUDE.md` — since these control Claude's behavior
- Asks whether to import new skill directories that appear in dotfiles
- Asks what to do when a config file was deleted on another device — remove the local copy, keep it locally, or push it back (prevents deleted configs from "resurrecting")
- Asks about untracked new files in project repos one by one (no blanket commits)
- Offers clone options for newly discovered repos
- Confirms each cross-device task (HANDOFF) with you before handling it (see below)
- Analyzes and suggests fixes for merge conflicts

You only make decisions when Claude asks. Everything else is automatic.

### Device Management

Say to Claude:

- "list devices"
- "register new device MyLaptop" (pick a unique name)
- "remove device OldPC"

### Module Management

Say to Claude:

- "list installed modules"
- "check for updates"
- "update all modules"
- "install the pdf skill from anthropics/skills"
- "remove module xxx"
- "adopt the xxx directory" (register an existing directory in the manifest)
- "clean up untracked directories"
- "restore all modules" (new device setup)

Module updates follow a three-step "check → approve → install" flow: "check for updates" lists new upstream commits per module (with GitHub compare links); only after you approve does Claude lock in the new version, then install exactly that approved version. Modules never auto-follow upstream — every upgrade assumes you've seen the changes first.

### Cross-Device Tasks (HANDOFF)

HANDOFF is CC_Sync's mechanism for relaying tasks between devices. When you need device B to do something, you can leave a message from device A.

**Prerequisite: Each device needs a unique registered name.** In **Claude Code**, say:

- "register new device HomeMac"
- "register new device OfficePC"

> Device names can be any English name, but must be unique. Pick something that lets you instantly recognize which machine it is, like `HomeMac`, `OfficePC`, `MyLaptop`.

**Leaving a task:** On device A, in **Claude Code**, say:

- "leave a task for OfficePC: copy the config file from xxx project"
- "leave a task for HomeMac: run pip install requests"
- "task for all devices: update gh CLI" (writes to the ANY section, all devices will see it)

**Receiving tasks:** When you run /sync on device B in **Claude Code**, Claude automatically:

1. Detects pending tasks
2. Reports what needs to be done
3. Asks you how to handle each one: run it / skip this time / mark done without running / refuse and quarantine (for suspicious content)
4. Clears resolved tasks and pushes

> Task content arrives as git-synced text and is treated as untrusted input — Claude never runs any command from a task body without your confirmation. If hidden tasks are detected in the file, a security warning is shown first.

No need to manually edit any files — everything is done via natural language.

## CLI Reference (Advanced)

For direct terminal use (**Git Bash** or **Terminal**):

| Command | Description |
|---------|-------------|
| `bash sync.sh` | Full sync |
| `bash sync.sh --show-diff` | Full sync (conflict prompts include the full diff; metadata only by default) |
| `bash sync.sh device list` | List devices |
| `bash sync.sh device add <name>` | Register device |
| `bash sync.sh device remove <name>` | Remove device |
| `bash sync.sh repo-sync enable` | Enable repo sync |
| `bash sync.sh repo-sync unignore <name>` | Restore ignored repo |
| `bash module-manager.sh list` | List modules |
| `bash module-manager.sh check --all` | Check updates |
| `bash module-manager.sh bump <name\|--all> [--to <sha>\|--latest]` | Approve a new version (records only, no download) |
| `bash module-manager.sh update --all` | Install approved versions |
| `bash module-manager.sh install <source>` | Install module |
| `bash module-manager.sh remove <name>` | Remove module |
| `bash module-manager.sh adopt <name> <source>` | Track an existing directory |
| `bash module-manager.sh adopt --bulk [--dry-run] <owner/repo>` | Bulk-adopt directories |
| `bash module-manager.sh prune [--all \| --confirm <name>...]` | Clean up untracked directories |
| `bash module-manager.sh restore` | Restore on new device |

> `module-manager.sh check` exit codes are informational: `0` = all up to date, `10` = updates available, `1` = query errors. When scripting, don't treat `10` as a failure.
>
> Two more subcommands exist — `sync.sh prune-apply` and `sync.sh skill-import` — mechanical executors invoked by the /sync skill after you confirm a decision. You normally never run them by hand.
>
> To verify the scripts themselves are intact, run `bash tests/bounce_simulation.sh` — it executes in an isolated test mode and never touches your real repos or config.

## Configuration

After first run, a `.env` file is created in the project root (gitignored):

| Field | Description | Example |
|-------|-------------|---------|
| `DOTFILES_PATH` | Dotfiles repo path (required) | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | Enable repo syncing | `true` or `false` |
| `WORKSPACE_ROOTS` | Repo directories (`;` separated) | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic tag | `claude-code-workspace` |

The following machine-local state files are also generated in the project root at runtime (all gitignored except `.sync_ignore`, so they are never committed):

| File | Purpose |
|------|---------|
| `.machine-name` | This device's name (used by HANDOFF) |
| `.sync_state.json` | Sync-state ledger — records each config file's fingerprint at last sync, used to recognize deleted files and prevent "resurrection" |
| `.sync_ignore` | Permanently ignored repos (created on demand; users maintaining their own fork can commit it to share across devices) |
| `.skill_import_ignore` | Skill directories you declined to import; never asked again |
| `.repo_sync_hint_count` | Internal hint counter |

Module management additionally maintains two files under `~/.claude/skills/`: `modules.toml` (the module manifest, synced via dotfiles, the basis for new-device restore) and `.check_state.json` (machine-local cache for update checks, 24-hour freshness, not synced).

## Project Structure

```
CC_Sync/
├── sync.sh                  # Main script
├── module-manager.sh        # Module management
├── lib/
│   ├── common.sh            # Shared bash utilities
│   ├── handoff.py           # HANDOFF.md parser/writer
│   └── module_helper.py     # Module manager Python helper
├── tests/
│   └── bounce_simulation.sh # Self-check tests (isolated test mode, no real repos touched)
├── HANDOFF.md               # Cross-device task relay
├── CLAUDE.md                # Project instructions for Claude Code
├── .env                     # Local config (auto-generated, not committed)
├── .sync_state.json         # Sync-state ledger (auto-generated, not committed)
├── .sync_ignore             # Permanently ignored repos (created on demand)
└── .claude/
    ├── skills/              # Skill definitions (/sync, /module-manager)
    └── hooks/               # Session startup checks
```

## FAQ

### sync.sh says "please run in terminal"

`.env` doesn't exist. Run `bash sync.sh` once in an interactive terminal (**Git Bash** or **Terminal**) to complete setup. Claude Code's bash tool is non-interactive and cannot run the wizard.

### gh CLI connection timeout

gh CLI ignores system proxy. Set it manually in your terminal (**Git Bash** or **Terminal**):

```bash
export HTTPS_PROXY=http://127.0.0.1:<port>
```

### git diff shows many changes but nothing actually changed

CRLF phantom diff on Windows (LF vs CRLF). Not real content changes.

### Why does the first sync ask me whether to import settings.json?

`settings.json`, `keybindings.json`, `statusline.sh`, and `CLAUDE.md` directly control Claude's behavior. Their first import from dotfiles to this machine (including a new device's first sync) requires your confirmation, so unfamiliar config never takes effect silently. All other config files sync automatically as usual.

### Why am I asked what to do with a config file that was deleted?

CC_Sync keeps a machine-local ledger (`.sync_state.json`) recording each config file's state at last sync. When a file was deleted on another device but a copy still exists here, it asks you: remove the local copy (follow the deletion), keep it locally (never ask again, never push back), or push it back to the repo (undo the deletion). This prevents "a config deleted on device A gets pushed back by device B."

### Can the dotfiles repo be public?

No. Your dotfiles hold personal config; its GitHub visibility is checked before every sync, and a PUBLIC repo aborts the sync.

### Do repos cloned via SSH work too?

Yes. Remote URLs are normalized before comparison, so the SSH and HTTPS forms of the same repo are treated as identical.

### Setting up a new device

1. In **PowerShell** or **Git Bash**: `git clone https://github.com/koagaroon/CC_Sync.git`
2. Continue in the terminal, enter the directory and run (replace with your actual path): `cd /c/Projects/CC_Sync && bash sync.sh` (complete wizard)
3. Open **Claude Code**, navigate to CC_Sync, say "register new device xxx"
4. Continue in **Claude Code**: say "sync" to pull all configs and code (first-time imports of sensitive configs like settings.json will ask for your confirmation one by one)
5. Continue in **Claude Code**: say "restore all modules" (restores the exact versions pinned in the manifest)

## Author

VRPSPshinOvO

## License

[MIT License](./LICENSE)
