[English](./README_EN.md)

# CC_Sync

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE) [![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-blue.svg)](https://python.org) [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/LtxPoi/CC_Sync/pulls)

Claude Code 多仓库同步、跨设备任务传递、模块管理工具。

## 功能特性

- **多仓库批量同步**——通过 GitHub topic 自动发现仓库，一键 pull/commit/push
- **跨设备配置同步**——settings.json、skills、hooks、keybindings 等通过 dotfiles 仓库同步
- **跨设备任务传递**——通过 HANDOFF.md 在设备间传递待办任务
- **第三方模块管理**——从 GitHub 安装/更新/删除/恢复 skills
- **首次引导向导**——交互式 .env 配置，小白也能完成
- **多 workspace 路径支持**——仓库分散在不同目录也能统一管理

## 前提条件

### 1. Git

- **Windows**：打开 **PowerShell**，运行：
  ```powershell
  winget install --id Git.Git -e
  ```
- **macOS**：打开终端（**Terminal**），运行：`brew install git`
- **Linux**：打开终端（**Terminal**），运行：`sudo apt install git`

### 2. Python 3.10+

- **Windows**：继续在 **PowerShell** 中运行：
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  安装后重新打开 PowerShell，输入 `python --version` 确认版本号 >= 3.10
- **macOS**：继续在 **Terminal** 中运行：`brew install python`
- **Linux**：继续在 **Terminal** 中运行：`sudo apt install python3`

### 3. GitHub CLI (gh)

- **Windows**：继续在 **PowerShell** 中运行：
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**：继续在 **Terminal** 中运行：`brew install gh`
- **Linux**：参考 [GitHub CLI 官方文档](https://cli.github.com/)

安装完成后，继续在同一个 **PowerShell**（或 **Terminal**）中运行：

```bash
gh auth login
```

按提示选择：GitHub.com → HTTPS → Login with a web browser，然后在浏览器中完成授权。

### 4. Claude Code

需要已安装并可正常使用的 Claude Code CLI。如果还没安装，请参考 [Claude Code 官方文档](https://docs.anthropic.com/en/docs/claude-code)。

## 快速开始

### 第 1 步：克隆本仓库

打开终端（Windows 用 **PowerShell** 或 **Git Bash**，macOS/Linux 用 **Terminal**），运行：

```bash
git clone https://github.com/LtxPoi/CC_Sync.git
```

### 第 2 步：给你的 GitHub 仓库添加标签

继续在同一个终端中，对每个想同步的仓库运行：

```bash
gh repo edit <你的用户名>/<仓库名> --add-topic claude-code-workspace
```

> 不知道用户名？继续在同一个终端中运行 `gh api user -q .login` 查看。

### 第 3 步：首次配置

> ⚠️ **这一步必须在交互式终端中运行**（不是在 Claude Code 里）。Windows 用户请打开 **Git Bash**，macOS/Linux 用户用 **Terminal**。

在终端中进入 CC_Sync 目录并运行：

```bash
cd CC_Sync
bash sync.sh
```

首次运行会启动配置向导，依次询问：

**问题 1：dotfiles 仓库路径**

输入你想用来存放 Claude Code 配置文件的 git 仓库路径。如果还没有，填一个新路径（脚本会自动创建）。

示例：
- Windows: `C:/dotfiles` 或 `D:/config/dotfiles`
- macOS/Linux: `~/dotfiles`

**问题 2：是否启用仓库同步？**

输入 `y` 启用。启用后会继续询问：

- **仓库存放路径**：输入你平时存代码的目录，多个用 `;` 分隔（如 `D:/Projects;E:/Work`）
- **GitHub topic 标签**：直接按回车使用默认值 `claude-code-workspace`

配置完成后，脚本会立即执行一次完整同步。

## 日常使用（在 Claude Code 中）

配置完成后，以后的所有操作都在 **Claude Code** 中完成。

### 启动方式

1. 打开 Claude Code
2. 进入 CC_Sync 目录（如果 CC 不在这个目录，用 `cd` 切换）

### 同步仓库

直接对 Claude 说：

- “同步”
- “推一下”
- “pull 所有仓库”
- “检查一下各个项目的状态”

或者输入：`/sync`

Claude 会自动执行同步脚本，然后：

- 展示同步结果汇总（哪些成功、哪些失败、哪些无变化）
- 如果有配置文件冲突，会用选择题问你“保留哪个版本”
- 如果有新仓库，会问你“克隆到哪个目录”
- 如果有跨设备任务（HANDOFF），会自动执行或提示你手动完成
- 如果某个仓库 pull 冲突，会分析差异并建议解决方案

你只需要在 Claude 提问时做决定，其余全自动。

### 设备管理

对 Claude 说：

- “查看设备列表”
- “注册新设备 MyLaptop”（名称你自己取，必须唯一）
- “移除设备 OldPC”

### 模块管理

对 Claude 说：

- “查看已安装的模块”
- “检查更新”
- “更新所有模块”
- “安装 anthropics/skills 里的 pdf skill”
- “删除 xxx 模块”
- “新设备恢复所有模块”

### 跨设备任务（HANDOFF）

当你在 A 设备上需要 B 设备做某件事时，对 Claude 说：

- “给 MyDesktop 留个任务：装一下 xxx”

下次在 B 设备运行 /sync 时，Claude 会自动提示并执行待办任务。

## 命令行参考（高级用户）

如果你喜欢直接在终端中操作，以下是完整命令参考。在终端（**Git Bash** 或 **Terminal**）中运行：

| 命令 | 说明 |
|------|------|
| `bash sync.sh` | 完整同步 |
| `bash sync.sh device list` | 查看设备 |
| `bash sync.sh device add <名称>` | 注册设备 |
| `bash sync.sh device remove <名称>` | 移除设备 |
| `bash sync.sh repo-sync enable` | 开启仓库同步 |
| `bash sync.sh repo-sync unignore <名称>` | 恢复忽略的仓库 |
| `bash module-manager.sh list` | 查看模块 |
| `bash module-manager.sh check --all` | 检查更新 |
| `bash module-manager.sh update --all` | 更新所有 |
| `bash module-manager.sh install <source>` | 安装模块 |
| `bash module-manager.sh remove <名称>` | 删除模块 |
| `bash module-manager.sh restore` | 新设备恢复 |

## 配置说明

首次运行后会在项目根目录生成 `.env` 文件（已加入 .gitignore，不会被提交）：

| 字段 | 说明 | 示例 |
|------|------|------|
| `DOTFILES_PATH` | dotfiles 仓库路径（必填） | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | 是否启用仓库同步 | `true` 或 `false` |
| `WORKSPACE_ROOTS` | 仓库存放路径（多个用 `;` 分隔） | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic 标签 | `claude-code-workspace` |

## 项目结构

```
CC_Sync/
├── sync.sh                  # 主脚本
├── module-manager.sh        # 模块管理
├── lib/
│   ├── common.sh            # 共享 bash 工具
│   ├── handoff.py           # HANDOFF.md 解析/写入
│   └── module_helper.py     # 模块管理 Python helper
├── HANDOFF.md               # 跨设备任务传递
├── CLAUDE.md                # Claude Code 项目级指令
├── .env                     # 本机配置（自动生成，不提交）
├── .sync_ignore             # 永久忽略的仓库列表
└── .claude/
    ├── skills/              # 技能定义（/sync、/module-manager）
    └── hooks/               # 会话启动检查
```

## 常见问题

### sync.sh 报错“请在终端中运行”

`.env` 不存在。请在交互式终端（**Git Bash** 或 **Terminal**）中运行 `bash sync.sh` 完成首次配置。Claude Code 的 bash 工具是非交互的，无法运行向导。

### gh CLI 连接超时

gh CLI 不走系统代理。在受限网络环境下，需要在终端（**Git Bash** 或 **Terminal**）中手动设置：

```bash
export HTTPS_PROXY=http://127.0.0.1:<端口号>
```

### git diff 显示大量改动但内容没变

Windows 上的 CRLF 幻影改动（行尾符差异），不是真正的内容变更。

### 新设备怎么恢复

1. 在终端（**PowerShell** 或 **Git Bash**）中克隆：`git clone https://github.com/LtxPoi/CC_Sync.git`
2. 继续在终端中进入目录并运行：`cd CC_Sync && bash sync.sh`（完成向导）
3. 打开 **Claude Code**，进入 CC_Sync 目录，说“注册新设备 xxx”
4. 继续在 **Claude Code** 中说“同步”拉取所有配置和代码
5. 继续在 **Claude Code** 中说“恢复所有模块”

## 作者

VRPSPshinOvO

## 许可证

[MIT License](./LICENSE)
