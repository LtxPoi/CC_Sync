[English](./README_EN.md)

# CC_Sync

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE) [![GitHub release](https://img.shields.io/github/v/release/koagaroon/CC_Sync)](https://github.com/koagaroon/CC_Sync/releases) ![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)

Claude Code 多仓库同步、跨设备任务传递、模块管理工具。

## 功能特性

- **多仓库批量同步**——通过 GitHub topic 自动发现仓库，一键 pull/commit/push
- **跨设备配置同步**——settings.json、skills、hooks、keybindings 等通过 dotfiles 仓库同步
- **跨设备任务传递**——通过 HANDOFF.md 在设备间传递待办任务
- **第三方模块管理**——从 GitHub 安装/更新/删除/恢复 skills
- **首次引导向导**——交互式 .env 配置，小白也能完成
- **多 workspace 路径支持**——仓库分散在不同目录也能统一管理
- **删除防复活**——本机账本记录每个配置文件的同步历史，在一台设备上删除的配置不会被其他设备悄悄推回来
- **模块按版本锁定**——模块更新走“检查 → 批准 → 安装”流程，升级前先看变更，不会自动跟随上游最新代码
- **确认优先的安全模型**——敏感配置导入、跨设备任务执行、新技能目录同步都先征求你的同意，不做静默动作

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
git clone https://github.com/koagaroon/CC_Sync.git
```

### 第 2 步：给你的 GitHub 仓库添加标签

继续在同一个终端中，对每个想同步的仓库运行：

```bash
gh repo edit <你的用户名>/<仓库名> --add-topic claude-code-workspace
```

> 不知道用户名？继续在同一个终端中运行 `gh api user -q .login` 查看。

### 第 3 步：首次配置

> ⚠️ **这一步必须在交互式终端中运行**（不是在 Claude Code 里）。Windows 用户请打开 **Git Bash**，macOS/Linux 用户用 **Terminal**。

在终端中进入你克隆下来的 CC_Sync 目录并运行（路径根据你实际情况修改）：

```bash
# Windows 示例（请替换为你的实际路径）
cd /c/Projects/CC_Sync

# macOS/Linux 示例
cd ~/Projects/CC_Sync
```

然后运行：

```bash
bash sync.sh
```

首次运行会启动配置向导，依次询问：

**问题 1：dotfiles 仓库路径**

输入你想用来存放 Claude Code 配置文件的 git 仓库路径。如果还没有，填一个新路径——脚本会自动创建目录并初始化 git 仓库，还可以帮你在 GitHub 上创建同名的私有仓库。

示例：
- Windows: `C:/dotfiles` 或 `D:/config/dotfiles`
- macOS/Linux: `~/dotfiles`

> Windows 路径不区分大小写（`C:/Dotfiles` 和 `c:/dotfiles` 等效）。

> ⚠️ dotfiles 仓库必须保持**私有**。每次同步前都会检查它在 GitHub 上的可见性，公开（PUBLIC）状态会直接中止同步，防止个人配置泄露。

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
- 如果有配置文件冲突，会用选择题问你“保留哪个版本”（默认只展示时间、行数等元信息，你选“查看完整差异”后才展示具体改动）
- 如果是首次从 dotfiles 导入 `settings.json`、`keybindings.json`、`statusline.sh`、`CLAUDE.md` 这类影响 Claude 行为的敏感配置，会先征求你的同意
- 如果 dotfiles 里出现了新的技能目录，会问你要不要导入本机
- 如果发现某个配置文件曾在别的设备上被删除，会问你是删除本机副本、保留在本机、还是推回仓库（防止删掉的配置“复活”）
- 如果项目仓库里有未跟踪的新文件，会逐个问你要不要提交（不会一股脑全部提交）
- 如果有新仓库，会问你“克隆到哪个目录”
- 如果有跨设备任务（HANDOFF），会逐条向你确认后再处理（见下文）
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
- “纳管 xxx 目录”（把手动放进去的已有目录登记到清单里）
- “清理未纳管的目录”
- “新设备恢复所有模块”

模块更新走“检查 → 批准 → 安装”三步：“检查更新”列出每个模块上游的新提交（附 GitHub 变更对比链接），你点头后 Claude 才把新版本标记为“已批准”，最后按已批准的版本安装。模块不会自动跟随上游最新代码——每次升级都以你看过变更为前提。

### 跨设备任务（HANDOFF）

HANDOFF 是 CC_Sync 的跨设备任务传递机制。当你在 A 设备上需要 B 设备做某件事时，可以通过它留言。

**前提：每台设备需要先注册一个唯一名称。** 在 **Claude Code** 中说：

- “注册新设备 HomeMac”
- “注册新设备 OfficePC”

> 设备名可以是任何英文名称，但必须唯一。建议用能让你一眼认出是哪台电脑的名字，比如 `HomeMac`、`OfficePC`、`MyLaptop`。

**留任务：** 在 A 设备的 **Claude Code** 中说：

- “给 OfficePC 留个任务：把 xxx 项目的配置文件复制过来”
- “给 HomeMac 留个任务：运行 pip install requests”
- “所有设备都要做：更新 gh CLI”（写入 ANY section，所有设备都会看到）

**接收任务：** 在 B 设备的 **Claude Code** 中运行 /sync 时，Claude 会自动：

1. 检测到待办任务
2. 向你报告任务内容
3. 逐条问你怎么处理：直接执行 / 本次跳过 / 不执行但标记完成 / 拒绝并隔离（内容可疑时）
4. 处理完毕后清除任务并推送

> 任务内容来自 git 同步过来的文本，被视为不可信输入——Claude 不会不经你确认就执行任务里的任何命令。如果检测到藏在文件里的隐藏任务，会先显示安全警告。

不需要手动编辑任何文件，全部通过自然语言完成。

## 命令行参考（高级用户）

如果你喜欢直接在终端中操作，以下是完整命令参考。在终端（**Git Bash** 或 **Terminal**）中运行：

| 命令 | 说明 |
|------|------|
| `bash sync.sh` | 完整同步 |
| `bash sync.sh --show-diff` | 完整同步（冲突提示附带完整 diff，默认只有元信息） |
| `bash sync.sh device list` | 查看设备 |
| `bash sync.sh device add <名称>` | 注册设备 |
| `bash sync.sh device remove <名称>` | 移除设备 |
| `bash sync.sh repo-sync enable` | 开启仓库同步 |
| `bash sync.sh repo-sync unignore <名称>` | 恢复忽略的仓库 |
| `bash module-manager.sh list` | 查看模块 |
| `bash module-manager.sh check --all` | 检查更新 |
| `bash module-manager.sh bump <名称\|--all> [--to <sha>\|--latest]` | 批准新版本（只记录、不下载） |
| `bash module-manager.sh update --all` | 安装已批准的版本 |
| `bash module-manager.sh install <source>` | 安装模块 |
| `bash module-manager.sh remove <名称>` | 删除模块 |
| `bash module-manager.sh adopt <名称> <source>` | 纳管已有目录 |
| `bash module-manager.sh adopt --bulk [--dry-run] <owner/repo>` | 批量纳管 |
| `bash module-manager.sh prune [--all \| --confirm <名称>...]` | 清理未纳管的目录 |
| `bash module-manager.sh restore` | 新设备恢复 |

> `module-manager.sh check` 的退出码是信息性的：`0` = 全部最新，`10` = 有可用更新，`1` = 查询出错。写脚本调用时不要把 `10` 当作失败。
>
> 另有 `sync.sh prune-apply` 和 `sync.sh skill-import` 两个机械执行子命令，由 /sync 技能在你确认后调用，一般不需要手动使用。
>
> 想验证脚本本身是否完好，可运行 `bash tests/bounce_simulation.sh`——它在隔离的测试模式下执行，不会碰你的真实仓库和配置。

## 配置说明

首次运行后会在项目根目录生成 `.env` 文件（已加入 .gitignore，不会被提交）：

| 字段 | 说明 | 示例 |
|------|------|------|
| `DOTFILES_PATH` | dotfiles 仓库路径（必填） | `C:/dotfiles` |
| `ENABLE_REPO_SYNC` | 是否启用仓库同步 | `true` 或 `false` |
| `WORKSPACE_ROOTS` | 仓库存放路径（多个用 `;` 分隔） | `D:/Projects;E:/Work` |
| `TOPIC` | GitHub topic 标签 | `claude-code-workspace` |

运行过程中还会在项目根目录生成以下本机状态文件（除 `.sync_ignore` 外都已加入 .gitignore，不会被提交）：

| 文件 | 用途 |
|------|------|
| `.machine-name` | 本机的设备名（HANDOFF 用） |
| `.sync_state.json` | 同步状态账本——记录每个配置文件最后同步时的指纹，用于识别被删除过的文件、防止“复活” |
| `.sync_ignore` | 永久忽略的仓库列表（按需生成；维护自己 fork 的用户可以提交它，在多台设备间共享） |
| `.skill_import_ignore` | 拒绝导入过的技能目录，之后不再询问 |
| `.repo_sync_hint_count` | 内部提示计数器 |

模块管理另外在 `~/.claude/skills/` 下维护两个文件：`modules.toml`（模块清单，随 dotfiles 同步，新设备恢复的依据）和 `.check_state.json`（“检查更新”的本机缓存，24 小时时效，不同步）。

## 项目结构

```
CC_Sync/
├── sync.sh                  # 主脚本
├── module-manager.sh        # 模块管理
├── lib/
│   ├── common.sh            # 共享 bash 工具
│   ├── handoff.py           # HANDOFF.md 解析/写入
│   └── module_helper.py     # 模块管理 Python helper
├── tests/
│   └── bounce_simulation.sh # 自检测试（隔离测试模式，不碰真实仓库）
├── HANDOFF.md               # 跨设备任务传递
├── CLAUDE.md                # Claude Code 项目级指令
├── .env                     # 本机配置（自动生成，不提交）
├── .sync_state.json         # 同步状态账本（自动生成，不提交）
├── .sync_ignore             # 永久忽略的仓库列表（按需生成）
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

### 为什么第一次同步会问我要不要导入 settings.json？

`settings.json`、`keybindings.json`、`statusline.sh`、`CLAUDE.md` 这几个文件会直接影响 Claude 的行为，从 dotfiles 首次导入到本机时（包括新设备的第一次同步）需要你确认，防止来路不明的配置静默生效。其他配置文件照常自动同步。

### 删除过的配置文件为什么会问我怎么处理？

CC_Sync 在本机维护一份同步账本（`.sync_state.json`），记录每个配置文件最后同步时的状态。当发现某个文件在别的设备上被删除、但本机还留有副本时，会问你：删除本机副本（跟随删除）、保留在本机（以后不再询问、也不推回）、还是推回仓库（撤销删除）。这样就不会出现“在 A 设备上删掉的配置被 B 设备又推了回来”。

### dotfiles 仓库可以是公开的吗？

不可以。dotfiles 里存的是你的个人配置，每次同步前都会检查它的 GitHub 可见性，公开（PUBLIC）状态会直接中止同步。

### 仓库是用 SSH 克隆的也能同步吗？

可以。比较远程地址时会做归一化处理，同一个仓库的 SSH 和 HTTPS 地址视为一致。

### 新设备怎么恢复

1. 在终端（**PowerShell** 或 **Git Bash**）中克隆：`git clone https://github.com/koagaroon/CC_Sync.git`
2. 继续在终端中进入目录并运行（路径替换为你的实际位置）：`cd /c/Projects/CC_Sync && bash sync.sh`（完成向导）
3. 打开 **Claude Code**，进入 CC_Sync 目录，说“注册新设备 xxx”
4. 继续在 **Claude Code** 中说“同步”拉取所有配置和代码（首次导入 settings.json 等敏感配置时会逐个向你确认）
5. 继续在 **Claude Code** 中说“恢复所有模块”（按清单中锁定的版本恢复）

## 作者

VRPSPshinOvO

## 许可证

[MIT License](./LICENSE)
