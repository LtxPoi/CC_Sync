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

Make sure you have these tools installed before starting:

### 1. Git

- **Windows** (open PowerShell):
  ```powershell
  winget install --id Git.Git -e
  ```
- **macOS**: `brew install git`
- **Linux**: `sudo apt install git` (Ubuntu/Debian) or `sudo dnf install git` (Fedora)

### 2. Python 3.10+

- **Windows** (open PowerShell):
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  After installing, restart your terminal and run `python --version` to verify.
- **macOS**: `brew install python`
- **Linux**: `sudo apt install python3`

### 3. GitHub CLI (gh)

- **Windows**:
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**: `brew install gh`
- **Linux**: See [GitHub CLI docs](https://cli.github.com/)

After installing, authenticate:

```bash
gh auth login
```

Follow the prompts: GitHub.com > HTTPS > Login with a web browser, then authorize in your browser.

### 4. Claude Code

You need a working Claude Code CLI installation. If you haven't installed it yet, see the [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code).

## Quick Start

### Step 1: Clone This Repo

Open a terminal (Windows users: open **Git Bash** or **PowerShell**):

```bash
git clone https://github.com/LtxPoi/CC_Sync.git
cd CC_Sync
```

### Step 2: Tag Your GitHub Repos

CC_Sync discovers repos to sync via a GitHub topic. The default is `claude-code-workspace`.

For each repo you want to sync:

```bash
gh repo edit <your-username>/<repo-name> --add-topic claude-code-workspace
```

> Don't know your username? Run `gh api user -q .login`.

### Step 3: First-Time Setup (Must Run in Interactive Terminal!)

> **This step MUST be run in an interactive terminal** (not inside Claude Code). Windows users: open **Git Bash**. macOS/Linux: use your regular terminal.

In the CC_Sync directory, run:

```bash
bash sync.sh
```

The first-run wizard will ask:

**Question 1: Dotfiles repo path**

Enter the path where you want to store your Claude Code config files as a git repo. If you don't have one yet, enter a new path (the script will create it). Examples:
- Windows: `C:/dotfiles` or `D:/config/dotfiles`
- macOS/Linux: `~/dotfiles`

**Question 2: Enable repo sync?**

Type `y` to enable batch repo syncing.

**Question 2a: Where are your repos stored?**

Enter the directory where your code repos live. Separate multiple directories with `;`, e.g.: `D:/Projects;E:/Work`

**Question 2b: GitHub topic tag**

Press Enter to use the default (`claude-code-workspace`).

After setup, the script immediately runs a full sync.

### Step 4: Daily Use

From now on, just:

1. Open the CC_Sync directory in Claude Code
2. Type `/sync` or say "sync"

Claude handles the rest: syncing, conflict resolution, reporting.

## Usage

### Sync

| Command | Description |
|---------|-------------|
| `bash sync.sh` | Full sync (6 steps: discover > config > pull > summary > handoff > dotfiles) |

### Device Management

| Command | Description |
|---------|-------------|
| `bash sync.sh device list` | List registered devices |
| `bash sync.sh device add <name>` | Register a new device (name must be unique) |
| `bash sync.sh device remove <name>` | Unregister a device |

### Repo Sync Management

| Command | Description |
|---------|-------------|
| `bash sync.sh repo-sync enable` | Enable repo syncing (if you chose no during setup) |
| `bash sync.sh repo-sync unignore <name>` | Restore a previously ignored repo |

### Module Management

| Command | Description |
|---------|-------------|
| `bash module-manager.sh list` | List installed modules |
| `bash module-manager.sh check --all` | Check all modules for updates |
| `bash module-manager.sh update --all` | Update all modules |
| `bash module-manager.sh install <source>` | Install a module (e.g., `anthropics/skills:skills/pdf`) |
| `bash module-manager.sh remove <name>` | Remove a module |
| `bash module-manager.sh restore` | Restore all modules on a new device |

## Configuration

After first run, a `.env` file is created in the project root (gitignored, not committed):

| Field | Description | Example |
|-------|-------------|---------|
| `DOTFILES_PATH` | Path to dotfiles repo (required) | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | Enable repo syncing | `true` or `false` |
| `WORKSPACE_ROOTS` | Repo directories (semicolon-separated) | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic tag | `claude-code-workspace` |

## Project Structure

```
CC_Sync/
├── sync.sh                  # Main script: repo discovery, config sync, pull/push, handoff
├── module-manager.sh        # Third-party module management
├── lib/
│   ├── common.sh            # Shared bash utilities
│   ├── handoff.py           # HANDOFF.md parser/writer
│   └── module_helper.py     # Python helper for module-manager
├── HANDOFF.md               # Cross-device task relay
├── CLAUDE.md                # Project-level instructions for Claude Code
├── .env                     # Local config (auto-generated, not committed)
├── .sync_ignore             # Permanently ignored repos (shared across devices)
├── .gitignore
├── LICENSE
└── .claude/
    ├── skills/
    │   ├── sync/SKILL.md        # /sync skill definition
    │   └── module-manager/SKILL.md  # /module-manager skill definition
    └── hooks/
        └── preflight.py         # Session startup checks
```

## FAQ

### sync.sh says "please run in terminal"

The `.env` config file doesn't exist yet. You need to run `bash sync.sh` once in an interactive terminal (Git Bash or regular terminal) to complete the setup wizard. Claude Code's bash tool is non-interactive and cannot run the wizard.

### gh CLI connection timeout

gh CLI does not use your system proxy. If you're behind a firewall or in a restricted network, set the proxy manually:

```bash
export HTTPS_PROXY=http://127.0.0.1:<port>
```

### git diff shows many changes but nothing actually changed

This is a CRLF phantom diff on Windows (LF vs CRLF line ending differences). Use `git diff --stat` to check for real changes.

### How to set up a new device

1. Clone the CC_Sync repo
2. Run `bash sync.sh` in an interactive terminal to complete setup
3. Register the device: `bash sync.sh device add <device-name>`
4. Run `/sync` in Claude Code to pull all configs and code
5. Restore modules: `bash module-manager.sh restore`

## Author

VRPSPshinOvO

## License

[MIT License](./LICENSE)
