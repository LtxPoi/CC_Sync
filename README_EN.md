[中文](./README.md)

# CC_Sync

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE) [![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-blue.svg)](https://python.org) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/LtxPoi/CC_Sync/pulls)

Multi-repo sync, cross-device task handoff, and module management for Claude Code.

## Features

- **Batch repo sync** — Auto-discover GitHub repos by topic, one-command pull/commit/push
- **Cross-device config sync** — settings.json, skills, hooks, keybindings via dotfiles repo
- **Cross-device task handoff** — Relay pending tasks between machines via HANDOFF.md
- **Third-party module management** — Install/update/remove/restore skills from GitHub
- **First-run wizard** — Interactive .env setup, beginner-friendly
- **Multi-workspace support** — Repos spread across different directories? No problem

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
  Restart PowerShell, then verify: `python --version`
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
git clone https://github.com/LtxPoi/CC_Sync.git
```

### Step 2: Tag Your GitHub Repos

Continue in the same terminal. For each repo you want to sync:

```bash
gh repo edit <your-username>/<repo-name> --add-topic claude-code-workspace
```

> Don't know your username? Continue in the same terminal: `gh api user -q .login`

### Step 3: First-Time Setup (Interactive Terminal Required!)

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

**Q1: Dotfiles repo path** — Enter a path for storing Claude Code config as a git repo. Examples: `C:/dotfiles` (Windows), `~/dotfiles` (macOS/Linux)

> Windows paths are case-insensitive (`C:/Dotfiles` and `c:/dotfiles` are equivalent).

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
- Asks you to resolve config conflicts via multiple-choice
- Offers clone options for newly discovered repos
- Executes cross-device tasks (HANDOFF)
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
- "restore all modules" (new device setup)

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
3. Executes each task (commands run directly; manual steps are prompted)
4. Clears completed tasks

No need to manually edit any files — everything is done via natural language.

## CLI Reference (Advanced)

For direct terminal use (**Git Bash** or **Terminal**):

| Command | Description |
|---------|-------------|
| `bash sync.sh` | Full sync |
| `bash sync.sh device list` | List devices |
| `bash sync.sh device add <name>` | Register device |
| `bash sync.sh device remove <name>` | Remove device |
| `bash sync.sh repo-sync enable` | Enable repo sync |
| `bash sync.sh repo-sync unignore <name>` | Restore ignored repo |
| `bash module-manager.sh list` | List modules |
| `bash module-manager.sh check --all` | Check updates |
| `bash module-manager.sh update --all` | Update all |
| `bash module-manager.sh install <source>` | Install module |
| `bash module-manager.sh remove <name>` | Remove module |
| `bash module-manager.sh restore` | Restore on new device |

## Configuration

After first run, a `.env` file is created in the project root (gitignored):

| Field | Description | Example |
|-------|-------------|---------|
| `DOTFILES_PATH` | Dotfiles repo path (required) | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | Enable repo syncing | `true` or `false` |
| `WORKSPACE_ROOTS` | Repo directories (`;` separated) | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic tag | `claude-code-workspace` |

## Project Structure

```
CC_Sync/
├── sync.sh                  # Main script
├── module-manager.sh        # Module management
├── lib/
│   ├── common.sh            # Shared bash utilities
│   ├── handoff.py           # HANDOFF.md parser/writer
│   └── module_helper.py     # Module manager Python helper
├── HANDOFF.md               # Cross-device task relay
├── CLAUDE.md                # Project instructions for Claude Code
├── .env                     # Local config (auto-generated, not committed)
├── .sync_ignore             # Permanently ignored repos (shared)
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

### Setting up a new device

1. In **PowerShell** or **Git Bash**: `git clone https://github.com/LtxPoi/CC_Sync.git`
2. Continue in **Git Bash**: `cd CC_Sync && bash sync.sh` (complete wizard)
3. Open **Claude Code**, navigate to CC_Sync, say "register new device xxx"
4. Continue in **Claude Code**: say "sync" to pull all configs and code
5. Continue in **Claude Code**: say "restore all modules"

## Author

VRPSPshinOvO

## License

[MIT License](./LICENSE)
