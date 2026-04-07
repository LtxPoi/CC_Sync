---
name: sync
description: "Sync all claude-code-workspace repos (hybrid: script + Claude). Triggers: sync, pull all repos, push changes, commit and push, check repo status, update repositories. Also: 同步, pull 所有仓库, 推代码, 提交所有改动, 检查项目状态."
user_invocable: true
---

# Sync — Multi-Repo Sync (Hybrid Mode)

> This skill’s output parsing logic is based on the current sync.sh version. If sync.sh output format changes, update this file accordingly.

## Workflow

### Step 0: Check .env Exists (First Run Only)

Before running sync.sh, check if `.env` exists in the project root:

```bash
test -f .env && echo "exists" || echo "missing"
```

**If .env is missing:**
- sync.sh in non-interactive mode (CC Bash tool) exits with an error
- Tell the user to run `bash sync.sh` in an **interactive terminal** (e.g., Git Bash) to complete setup
- The wizard guides through dotfiles path, repo sync toggle, etc.
- After setup, /sync works normally in CC
- **Do NOT attempt to run sync.sh from CC to complete first-run setup**

**If .env exists, proceed to Step 1.**

### Step 1: Run Sync Script

```bash
bash sync.sh
```

Handles: discover repos → sync dotfiles config → pull → commit (fixed message: `sync: auto commit from <hostname>`) → push.

### Step 2: Check Script Results

**If script succeeded (exit code 0):**
- Display everything after the `[4/6]` summary marker verbatim — do not reformat, wrap in code blocks, or build a new table
- If output contains **missing plugins detected**, show list and install commands, prompt user to run in Claude Code
- If output contains **CONFLICT:** markers, enter conflict resolution flow (below)
- If output contains **NEW_REPO:** markers, enter new repo handling flow (below)
- If output contains **HANDOFF: Pending tasks detected**, proceed to Step 3
- Otherwise, task complete

**CONFLICT: markers (config file conflicts):**
- Collect all CONFLICT lines with diff summaries and timestamps
- Use **AskUserQuestion** to present each conflict:
  - header: filename (max 12 chars)
  - question: `Config file <name> has a conflict. Which version to keep?`
  - options: `Repo version` (with timestamp), `Local version` (with timestamp), `Skip`
  - preview: diff output (markdown)
  - multiSelect: false
- Max 4 questions per AskUserQuestion call; batch if more
- Execute user’s choice:
  - Repo: `cp "" ".bak"` then `cp "" ""`
  - Local: `cp "" ".bak"` then `cp "" ""`
  - Skip: no action
- If any Local version chosen, commit + push in dotfiles repo (descriptive message)
- Continue to HANDOFF and other steps after all resolved

**NEW_REPO: markers (new repos detected):**
- Collect all `NEW_REPO: <name> | <url>` lines
- Use **AskUserQuestion** per repo:
  - header: repo name
  - question: `New repo <name> not found locally. Clone to which directory?`
  - options: one per WORKSPACE_ROOTS path + `Skip` + `Ignore permanently`
- Execute:
  - Path: `git clone <url> <path>/<name>`
  - Skip: no action (asks again next time)
  - Ignore: `echo <name> >> .sync_ignore`

**If script partially failed (exit code 1):**
- Display `[4/6]` summary verbatim first, then explain failures
- Handle each failed repo:
  - **pull failed (merge conflict)**: Read conflicts, analyze both sides, explain and suggest resolution. Commit with descriptive message, push
  - **commit failed**: Diagnose, fix, recommit with descriptive message, push
  - **push failed**: `pull --rebase` then push. If rebase conflicts, follow merge flow
  - **clone failed**: Check network/permissions, report to user

**Rule: Script-automated steps use mechanical messages. Claude-intervened steps use descriptive commit messages.**

### Step 3: Handle Handoff Tasks (Only When Detected)

1. Verify `.machine-name` exists and matches a HANDOFF.md section. If missing, skip and prompt device registration
2. Read `HANDOFF.md` — find tasks in device section and `## ANY` section
3. Report all pending tasks to user
4. Execute each:
   - Shell commands: run directly
   - User-action steps: prompt user
   - On failure: explain, never skip silently
5. After completion: replace device section with `(none)`. `## ANY`: only clear if ALL tasks done; keep tasks for other devices
6. Commit and push (e.g., `HANDOFF: <device> tasks completed, cleared`)

## Configuration

- **GitHub username**: `gh api user` (auto-detected)
- **Workspace root**: Auto-detected (parent directory of this repo)
- **Topic tag**: `claude-code-workspace`
- **Sync script**: `sync.sh` in project root

## Adding New Repos

```bash
gh repo edit <username>/<repo> --add-topic claude-code-workspace
```

Username via `gh api user -q .login`. Next /sync auto-discovers.

## Gotchas

- **CRLF phantom diffs**: Windows pull/rebase may produce false diffs. Verify with `git diff --stat` before treating as real conflicts.
- **gh CLI ignores system proxy**: Most common failure in restricted networks. Set `HTTPS_PROXY` manually.
- **Output format dependency**: Step 2 relies on `[4/6]` marker. Update this file if sync.sh format changes.
- **Handoff trigger**: Step 3 triggered by `HANDOFF: Pending tasks detected`. Device checks done by sync.sh step [5/6].
- **Plugin detection**: After syncing settings.json, script compares `enabledPlugins` vs `installed_plugins.json`. Claude cannot run `claude plugin` from bash — prompt user.

## Experience Log

Before execution, check `references/experience.md` if it exists.

After completion, if a non-obvious solution was found, append to `references/experience.md`:

```
### [Short Title]  (YYYY-MM-DD)
[1-2 sentences: what happened, how resolved, how to avoid next time]
```

Experience is hints, not facts — update or delete if following one fails.
