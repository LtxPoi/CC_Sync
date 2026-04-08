---
name: sync
description: "Sync all claude-code-workspace repos (hybrid: script + Claude). Triggers: sync, pull all repos, push changes, commit and push, check repo status, update repositories. Also: 同步, pull 所有仓库, 推代码, 提交所有改动, 检查项目状态."
user_invocable: true
---

# Sync — Multi-Repo Sync (Hybrid Mode)

> This skill’s output parsing logic is based on the current sync.sh version. If sync.sh output format changes, update this file accordingly.

## Critical Rules

### AskUserQuestion is MANDATORY for interactive decisions

When sync.sh output contains `===CONFLICT_BEGIN===` blocks or `NEW_REPO:` markers, you MUST call the AskUserQuestion tool with structured options. This is non-negotiable.

**WRONG** (never do this):
- Printing conflict details as text and asking "你想保留哪个版本？" in conversation
- Silently skipping conflicts or choosing "skip" as default
- Summarizing "发现 2 个冲突" without presenting structured choices
- Asking "要我帮你处理吗？" instead of directly presenting the tool UI

**RIGHT**: For every `===CONFLICT_BEGIN===` block and `NEW_REPO:` marker, call AskUserQuestion immediately.

#### CONFLICT example call

When output contains a structured conflict block:

```
===CONFLICT_BEGIN===
LABEL: settings.json
REPO: /c/dotfiles/claude-code-config/settings.json
LOCAL: /c/Users/user/.claude/settings.json
REPO_TIME: 2025-04-07 14:32
LOCAL_TIME: 2025-04-08 09:15
DIFF:
        --- /c/dotfiles/claude-code-config/settings.json
        +++ /c/Users/user/.claude/settings.json
        @@ -3,2 +3,2 @@
        -  "theme": "dark"
        +  "theme": "light"
===CONFLICT_END===
```

Parse each field from the block, then call AskUserQuestion:

```
AskUserQuestion:
  questions:
    - header: "settings"
      question: "Config file settings.json has a conflict. Which version to keep?"
      multiSelect: false
      options:
        - label: "Repo version"
          description: "Use dotfiles repo copy (REPO_TIME from block)"
          preview: (DIFF lines from block, strip 8-space indent)
        - label: "Local version"
          description: "Use local machine copy (LOCAL_TIME from block)"
          preview: (same DIFF content)
        - label: "Skip"
          description: "Keep both as-is, resolve manually later"
```

Field mapping:
- `LABEL` → `question` text and `header` (trim whitespace, strip extension, truncate to 12 chars if needed)
- `REPO_TIME` / `LOCAL_TIME` → option `description` timestamps
- `DIFF` lines (strip 8-space indent) → option `preview` content
- `REPO` / `LOCAL` → used in post-resolution `cp` commands (see Workflow § CONFLICT)

#### NEW_REPO example call

When output contains: `NEW_REPO: my-project | https://github.com/user/my-project.git`

Read `WORKSPACE_ROOTS` from `.env` (semicolon-separated paths) to build options:

```
AskUserQuestion:
  questions:
    - header: "my-project"
      question: "New repo my-project not found locally. Clone to which directory?"
      multiSelect: false
      options:
        - label: "C:/Claude_code_cli"
          description: "Clone to workspace root C:/Claude_code_cli/my-project"
        - label: "Skip"
          description: "Do nothing now, will ask again on next sync"
        - label: "Ignore permanently"
          description: "Add to .sync_ignore, never ask again"
```

Adapt options count to actual WORKSPACE_ROOTS entries (max 4 options total including Skip/Ignore).

### Commit message rule

Script-automated commits use mechanical messages. Claude-intervened commits (conflict resolution, handoff) use descriptive commit messages.

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
- If output contains **===CONFLICT_BEGIN===** blocks, enter conflict resolution flow (below)
- If output contains **NEW_REPO:** markers, enter new repo handling flow (below)
- If output contains **HANDOFF: Pending tasks detected**, proceed to Step 3
- Otherwise, task complete

**===CONFLICT_BEGIN=== blocks** → Follow Critical Rules § CONFLICT example. Call AskUserQuestion (max 4 questions per call; batch if more). Then execute:
- Repo chosen: `cp "$LOCAL" "${LOCAL}.bak"` then `cp "$REPO" "$LOCAL"`
- Local chosen: `cp "$REPO" "${REPO}.bak"` then `cp "$LOCAL" "$REPO"`, then commit + push in dotfiles repo
- Skip: no action
- Continue to HANDOFF and other steps after all resolved

**NEW_REPO: markers** → Follow Critical Rules § NEW_REPO example. Call AskUserQuestion. Then execute:
- Path chosen: `git clone <url> <path>/<name>`
- Skip: no action (asks again next sync)
- Ignore permanently: `echo <name> >> .sync_ignore`

**If script partially failed (exit code 1):**
- Display `[4/6]` summary verbatim first, then explain failures
- Handle each failed repo:
  - **pull failed (merge conflict)**: Read conflicts, analyze both sides, explain and suggest resolution. Commit with descriptive message, push
  - **commit failed**: Diagnose, fix, recommit with descriptive message, push
  - **push failed**: `pull --rebase` then push. If rebase conflicts, follow merge flow
  - **clone failed**: Check network/permissions, report to user

**Commit messages**: See Critical Rules § Commit message rule.

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
