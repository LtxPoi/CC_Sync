---
name: module-manager
description: Manage third-party Claude Code modules (skills, plugins, MCP servers) — install from GitHub, check for updates, update, remove, adopt, restore, and track via modules.toml. Triggers on: 模块管理, 安装/更新/删除/恢复技能, 检查更新, skill版本, 纳管, 装了哪些skill, 新设备恢复. Also: managing modules, installing/updating/removing/uninstalling a skill, listing installed modules, syncing skills across devices, third-party skill management, "are my skills up to date", "install this skill from GitHub", "what skills do I have", "set up modules on new machine", "adopt this directory", 卸载, 第三方skill.
---

# Module Manager — 第三方模块管理

管理 `~/.claude/skills/` 下所有来自外部的模块（skill / plugin / MCP server）。
不涉及用户自己在项目 `.claude/skills/` 里编写的 skill。

## 核心概念

- **Manifest**（`~/.claude/skills/modules.toml`）：记录每个模块的来源、版本、安装时间
- **脚本**（`module-manager.sh`）：处理所有机械操作
- **跨设备同步**：manifest 通过 dotfiles 同步，新设备用 `restore` 恢复

## 执行流程

### 列出模块：`list`

```bash
bash module-manager.sh list
```

脚本输出已管理模块的表格和未纳管目录的列表。原样展示脚本输出，不重新格式化。

如果有未纳管的目录，询问用户是否要纳入管理（adopt）。

### 检查更新：`check`

```bash
bash module-manager.sh check --all
```

或检查单个模块：

```bash
bash module-manager.sh check <name>
```

脚本输出每个模块的更新状态。原样展示脚本输出，不重新格式化、不另建表格。

### 更新模块：`update`

```bash
bash module-manager.sh update --all
```

或更新单个模块：

```bash
bash module-manager.sh update <name>
```

脚本会从上游拉取最新版本并更新 manifest。原样展示脚本输出。

### 安装新模块：`install`

```bash
bash module-manager.sh install <source> [--name <name>]
```

**source 格式：**

| 格式 | 含义 | 示例 |
|------|------|------|
| `owner/repo:path/to/skill` | GitHub 仓库子目录 | `anthropics/skills:skills/pdf` |
| `owner/repo` | 整个 GitHub 仓库 | `someuser/my-cool-skill` |
| `https://...` | 直接下载 URL | `https://example.com/skill.zip` |

当用户描述不够精确时（如"帮我装 anthropic 的 pdf skill"），不要自行推断 source 格式。向用户确认完整的 owner/repo 和路径后再调用脚本。

**安装冲突处理：** 如果脚本报告目标目录已存在（exit code 2），向用户提供三个选项：
1. 覆盖现有目录
2. 用 `--name` 指定不同名称
3. 放弃安装

### 删除模块：`remove`

```bash
bash module-manager.sh remove <name>
```

脚本会删除目录和 manifest 条目。执行前必须向用户确认。

### 纳入管理：`adopt`

将已存在但未被 manifest 追踪的目录纳入管理：

```bash
bash module-manager.sh adopt <name> <source>
```

批量纳入（用于初始化）：

```bash
bash module-manager.sh adopt --bulk anthropics/skills
```

`--bulk` 会扫描 `~/.claude/skills/` 下所有目录，与指定仓库的内容匹配。脚本输出匹配结果后，向用户展示将要纳入的目录列表，确认后再写入 manifest。

### 恢复模块（新设备）：`restore`

```bash
bash module-manager.sh restore
```

按 manifest 中的记录下载安装所有模块。用于新设备首次设置。

如果部分模块下载失败（网络问题），脚本会报告失败列表。原样展示脚本的错误输出，列出可能的原因（代理配置、API 限额、仓库不存在等）供用户判断，不要替用户下结论。

## 异常处理

**网络错误：** 分析 stderr 输出，检查代理配置（用户在中国，网络延迟高）。建议设置 `HTTPS_PROXY` 或重试。

**GitHub API 限额：** 提示用户稍后重试，或建议用 `gh auth status` 检查认证状态。

**仓库不存在 / 路径错误：** 展示脚本报错，提示用户检查 source 格式（owner/repo 和路径是否正确），由用户提供修正后的值。

**manifest 损坏：** 如果 `modules.toml` 解析失败，建议从 dotfiles 仓库恢复，或重新运行 `adopt --bulk` 重建。

## 注意事项

- 所有输出原样展示，不重新格式化、不包裹代码块、不另建表格
- 安装或删除操作前必须确认
- manifest 更新后提醒用户运行 `/sync` 同步到其他设备
- 脚本路径是相对于项目根目录的 `module-manager.sh`，直接执行，不改写路径

## 经验沉淀

执行前先查看 `references/experience.md`（如果存在），复用已有经验。

任务完成后，如果本次遇到了非显而易见的解决方式（如特定仓库的目录结构特征、GitHub API 的未文档化行为、安装/更新中的边界情况等），将关键发现追加到本 skill 目录下的 `references/experience.md`，格式：

```
### [简短标题]  (YYYY-MM-DD)
[一两句描述：什么情况、怎么解决的、下次怎么跳过试错]
```

经验是提示而非事实——如果按经验操作失败，更新或删除该条。
