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

在开始之前，请确保以下工具已安装：

### 1. Git

- **Windows**: 打开 PowerShell，运行：
  ```powershell
  winget install --id Git.Git -e
  ```
- **macOS**: `brew install git`
- **Linux**: `sudo apt install git`（Ubuntu/Debian）或 `sudo dnf install git`（Fedora）

### 2. Python 3.10 或更高版本

- **Windows**: 打开 PowerShell，运行：
  ```powershell
  winget install --id Python.Python.3.13 -e
  ```
  安装后重新打开终端，输入 `python --version` 确认版本号 ≥ 3.10
- **macOS**: `brew install python`
- **Linux**: `sudo apt install python3`

### 3. GitHub CLI (gh)

- **Windows**:
  ```powershell
  winget install --id GitHub.cli -e
  ```
- **macOS**: `brew install gh`
- **Linux**: 参考 [GitHub CLI 官方文档](https://cli.github.com/)

安装后需要登录：

```bash
gh auth login
```

按提示选择 GitHub.com → HTTPS → Login with a web browser，然后在浏览器中完成授权。

### 4. Claude Code

需要已安装并可正常使用的 Claude Code CLI。如果你还没有安装，请参考 [Claude Code 官方文档](https://docs.anthropic.com/en/docs/claude-code)

## 快速开始

### 第 1 步：克隆本仓库

打开终端（Windows 用户打开 **Git Bash** 或 **PowerShell**），运行：

```bash
git clone https://github.com/LtxPoi/CC_Sync.git
cd CC_Sync
```

### 第 2 步：给你的 GitHub 仓库添加标签

CC_Sync 通过 GitHub topic 来发现你想同步的仓库。默认标签是 `claude-code-workspace`。

对每个你想同步的仓库，运行：

```bash
gh repo edit <你的用户名>/<仓库名> --add-topic claude-code-workspace
```

> 不知道用户名？运行 `gh api user -q .login` 查看。

### 第 3 步：首次配置（重要！必须在交互式终端中运行）

> ⚠️ **这一步必须在交互式终端中运行**（不是在 Claude Code 里）。Windows 用户请打开 **Git Bash**，macOS/Linux 用户打开普通终端。

在 CC_Sync 目录下运行：

```bash
bash sync.sh
```

首次运行会启动配置向导，会依次询问：

**问题 1：dotfiles 仓库路径**

```
【第 1 步】请指定 dotfiles 仓库的存放路径
路径：
```

输入你想用来存放配置文件的 git 仓库路径。如果你还没有 dotfiles 仓库，可以填一个新路径（脚本会自动创建）。例如：
- Windows: `C:/dotfiles` 或 `D:/config/dotfiles`
- macOS/Linux: `~/dotfiles`

**问题 2：是否启用仓库同步**

```
【第 2 步】是否启用项目仓库批量同步？
是否启用？(y/n)：
```

输入 `y` 启用。启用后会继续询问：

**问题 2a：仓库存放路径**

```
你的项目仓库存放在电脑上的哪个文件夹？
请输入路径：
```

输入你平时存放代码仓库的目录。多个目录用英文分号 `;` 分隔，例如：`D:/Projects;E:/Work`

**问题 2b：GitHub topic 标签**

```
请输入标签名（回车使用默认值 claude-code-workspace）：
```

直接按回车使用默认值即可。

配置完成后，脚本会立即执行一次完整同步。

### 第 4 步：日常使用

配置完成后，以后只需要：

1. 在 Claude Code 中打开 CC_Sync 目录
2. 输入 `/sync` 或用自然语言说“同步”

Claude 会自动执行同步、处理冲突、报告结果。

## 使用方法

### 同步

| 命令 | 说明 |
|------|------|
| `bash sync.sh` | 执行完整同步（6 步：发现→配置→pull→汇总→handoff→dotfiles） |

### 设备管理

| 命令 | 说明 |
|------|------|
| `bash sync.sh device list` | 查看已注册的设备 |
| `bash sync.sh device add <名称>` | 注册新设备（名称必须唯一） |
| `bash sync.sh device remove <名称>` | 移除设备 |

### 仓库同步管理

| 命令 | 说明 |
|------|------|
| `bash sync.sh repo-sync enable` | 开启仓库同步（首次配置时选了 no 的话） |
| `bash sync.sh repo-sync unignore <名称>` | 恢复之前忽略的仓库 |

### 模块管理

| 命令 | 说明 |
|------|------|
| `bash module-manager.sh list` | 查看已安装的模块 |
| `bash module-manager.sh check --all` | 检查所有模块是否有更新 |
| `bash module-manager.sh update --all` | 更新所有模块 |
| `bash module-manager.sh install <source>` | 安装新模块（如 `anthropics/skills:skills/pdf`） |
| `bash module-manager.sh remove <名称>` | 删除模块 |
| `bash module-manager.sh restore` | 新设备一键恢复所有模块 |

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
├── sync.sh                  # 主脚本：仓库发现、配置同步、pull/push、handoff
├── module-manager.sh        # 第三方模块管理
├── lib/
│   ├── common.sh            # 共享 bash 工具函数
│   ├── handoff.py           # HANDOFF.md 解析/写入
│   └── module_helper.py     # module-manager 的 Python helper
├── HANDOFF.md               # 跨设备任务传递
├── CLAUDE.md                # Claude Code 项目级指令
├── .env                     # 本机配置（自动生成，不提交）
├── .sync_ignore             # 永久忽略的仓库列表（跨设备共享）
├── .gitignore
├── LICENSE
└── .claude/
    ├── skills/
    │   ├── sync/SKILL.md        # /sync 技能定义
    │   └── module-manager/SKILL.md  # /module-manager 技能定义
    └── hooks/
        └── preflight.py         # 会话启动检查
```

## 常见问题

### sync.sh 报错“请在终端中运行”

原因：`.env` 配置文件不存在。首次使用必须在交互式终端（Git Bash 或普通终端）中运行 `bash sync.sh` 完成配置向导。Claude Code 的 bash 工具是非交互的，无法完成向导。

### gh CLI 连接超时

gh CLI 不走系统代理。如果你在受限网络环境下，需要手动设置代理：

```bash
export HTTPS_PROXY=http://127.0.0.1:端口号
```

### git diff 显示大量改动但内容没变

这是 Windows 上的 CRLF 幻影改动（行尾符 LF vs CRLF 差异），不是真正的内容变更。用 `git diff --stat` 确认是否有实质改动。

### 新设备怎么恢复环境

1. 克隆 CC_Sync 仓库
2. 在交互式终端运行 `bash sync.sh` 完成首次配置
3. 注册设备：`bash sync.sh device add <设备名>`
4. 运行一次 `/sync` 拉取所有配置和代码
5. 恢复模块：`bash module-manager.sh restore`

## 作者

VRPSPshinOvO

## 许可证

[MIT License](./LICENSE)
