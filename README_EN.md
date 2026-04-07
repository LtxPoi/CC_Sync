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
- **macOS**: Open terminal and run: `brew install git`
- **Linux**: Open terminal and run: `sudo apt install git`

### 2. Python 3.10+

- **Windows**: Continue in **PowerShell**:
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  Restart PowerShell, then verify: `python --version`
- **macOS**: Continue in terminal: `brew install python`
- **Linux**: Continue in terminal: `sudo apt install python3`

### 3. GitHub CLI (gh)

- **Windows**: Continue in **PowerShell**:
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**: Continue in terminal: `brew install gh`
- **Linux**: See [GitHub CLI docs](https://cli.github.com/)

Then authenticate (continue in the same terminal):

```bash
gh auth login
```

Follow prompts: GitHub.com > HTTPS > Login with a web browser, then authorize in your browser.

### 4. Claude Code

You need a working Claude Code CLI. See [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code) if not installed.

## Quick Start

### Step 1: Clone This Repo

Open a terminal (Windows: **PowerShell** or **Git Bash**; macOS/Linux: regular terminal):

```bash
git clone https://github.com/LtxPoi/CC_Sync.git
```

### Step 2: Tag Your GitHub Repos

Continue in the same terminal. For each repo you want to sync:

```bash
gh repo edit <your-username>/<repo-name> --add-topic claude-code-workspace
```

> Don't know your username? Run `gh api user -q .login`.

### Step 3: First-Time Setup (Interactive Terminal Required!)

> **This step MUST run in an interactive terminal** (not inside Claude Code). Windows: open **Git Bash**. macOS/Linux: regular terminal.

Enter the CC_Sync directory and run:

```bash
cd CC_Sync
bash sync.sh
```

The wizard will ask:

**Question 1: Dotfiles repo path**

Enter a path for storing Claude Code config as a git repo. If you don't have one, enter a new path (the script creates it).

Examples:
- Windows: `C:/dotfiles` or `D:/config/dotfiles`
- macOS/Linux: `~/dotfiles`

**Question 2: Enable repo sync?**

Type `y` to enable. Then:

- **Repo directory**: Where your code repos live. Multiple paths separated by `;` (e.g., `D:/Projects;E:/Work`)
- **GitHub topic**: Press Enter for the default (`claude-code-workspace`)

After setup, the script runs a full sync immediately.

### Step 4: Daily Use (In Claude Code)

From now on, all syncing happens in **Claude Code**:

1. Open the CC_Sync directory in Claude Code
2. Type `/sync` or just say "sync", "pull all repos", "push everything", etc.

Claude handles syncing, conflict resolution, reporting, and cross-device tasks automatically.

> Other features (device management, module management) also work via natural language in Claude Code.

## Usage

All operations below are done in **Claude Code** using natural language or slash commands.

### Sync

In Claude Code, say:

- "sync" or "pull all repos" or "push everything"
- Or type `/sync`

Claude runs sync.sh, handles conflicts, and shows results.

### Device Management

- "list devices"
- "register new device xxx"
- "remove device xxx"

### Repo Sync Management

- "enable repo sync" (if you chose no during setup)
- "restore ignored repo xxx"

### Module Management

- "list installed modules"
- "check for updates"
- "update all modules"
- "install the pdf skill from anthropics/skills"
- "remove module xxx"
- "restore all modules" (new device setup)

### CLI Reference (Advanced)

For direct terminal use:

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

`.env` doesn't exist. Run `bash sync.sh` once in an interactive terminal (Git Bash / regular terminal) to complete setup. Claude Code's bash tool is non-interactive and cannot run the wizard.

### gh CLI connection timeout

gh CLI ignores system proxy. Set it manually in your terminal:

```bash
export HTTPS_PROXY=http://127.0.0.1:<port>
```

### git diff shows many changes but nothing actually changed

CRLF phantom diff on Windows (LF vs CRLF). Not real content changes.

### Setting up a new device

1. In terminal: `git clone https://github.com/LtxPoi/CC_Sync.git`
2. Continue in terminal: `cd CC_Sync && bash sync.sh` (complete wizard)
3. In Claude Code: "register new device xxx"
4. In Claude Code: "sync" to pull all configs and code
5. In Claude Code: "restore all modules"

## Author

VRPSPshinOvO

## License

[MIT License](./LICENSE)
