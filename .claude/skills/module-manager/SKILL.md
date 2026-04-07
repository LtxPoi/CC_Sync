---
name: module-manager
description: "Manage third-party Claude Code modules (skills, plugins, MCP servers) — install, update, remove, restore, and track via modules.toml. Triggers: managing modules, install/update/remove skill, list installed modules, sync skills across devices, new machine setup. Also: 模块管理, 安装/更新/删除/恢复技能, 检查更新, 纳管, 新设备恢复."
---

# Module Manager — Third-Party Module Management

Manages all externally-sourced modules (skills / plugins / MCP servers) under `~/.claude/skills/`.
Does not manage user-authored skills in project `.claude/skills/` directories.

## Core Concepts

- **Manifest** (`~/.claude/skills/modules.toml`): Records each module’s source, version, install time
- **Script** (`module-manager.sh`): Handles all mechanical operations
- **Cross-device sync**: Manifest syncs via dotfiles; new devices use `restore` to reinstall

## Workflow

### List Modules: `list`

```bash
bash module-manager.sh list
```

Displays managed modules table and untracked directories. Show script output verbatim — do not reformat.

If untracked directories exist, ask user whether to adopt them.

### Check Updates: `check`

```bash
bash module-manager.sh check --all
```

Or single module:

```bash
bash module-manager.sh check <name>
```

Show output verbatim.

### Update Modules: `update`

```bash
bash module-manager.sh update --all
```

Or single module:

```bash
bash module-manager.sh update <name>
```

Script pulls latest version and updates manifest. Show output verbatim.

### Install New Module: `install`

```bash
bash module-manager.sh install <source> [--name <name>]
```

**Source formats:**

| Format | Meaning | Example |
|--------|---------|---------|
| `owner/repo:path/to/skill` | GitHub repo subdirectory | `anthropics/skills:skills/pdf` |
| `owner/repo` | Entire GitHub repo | `someuser/my-cool-skill` |
| `https://...` | Direct download URL | `https://example.com/skill.zip` |

When user description is imprecise (e.g., "install the pdf skill"), do NOT guess the source format. Confirm the full owner/repo and path with the user before calling the script.

### Remove Module: `remove`

```bash
bash module-manager.sh remove <name>
```

Deletes directory and manifest entry. **Must confirm with user before executing.**

### Adopt Existing Directory: `adopt`

Track an existing but unmanaged directory:

```bash
bash module-manager.sh adopt <name> <source>
```

Bulk adopt (for initial setup):

```bash
bash module-manager.sh adopt --bulk anthropics/skills
```

`--bulk` scans `~/.claude/skills/` and matches against the specified repo. Show matched results to user, confirm before writing manifest.

### Restore Modules (New Device): `restore`

```bash
bash module-manager.sh restore
```

Downloads and installs all modules from manifest. Used for new device setup.

If some modules fail (network issues), show the script’s error output verbatim. List possible causes (proxy config, API rate limit, repo not found) for user to judge — do not diagnose on their behalf.

## Error Handling

**Network errors:** Check stderr, consider proxy configuration. Suggest setting `HTTPS_PROXY` or retrying.

**GitHub API rate limit:** Suggest retrying later, or check auth with `gh auth status`.

**Repo not found / wrong path:** Show script error, prompt user to verify source format (owner/repo and path). Let user provide corrected value.

**Manifest corrupted:** Suggest restoring from dotfiles repo, or rebuilding via `adopt --bulk`.

## Notes

- Show all output verbatim — do not reformat, wrap in code blocks, or build tables
- Confirm before install or remove operations
- After manifest changes, remind user to run /sync to propagate to other devices
- Script path is `module-manager.sh` relative to project root — execute as-is, do not rewrite paths

## Experience Log

Before execution, check `references/experience.md` if it exists.

After completion, if a non-obvious solution was found (e.g., specific repo directory structure, GitHub API quirks, install/update edge cases), append to `references/experience.md`:

```
### [Short Title]  (YYYY-MM-DD)
[1-2 sentences: what happened, how resolved, how to avoid next time]
```

Experience is hints, not facts — update or delete if following one fails.
