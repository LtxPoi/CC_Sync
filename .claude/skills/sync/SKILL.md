---
name: sync
description: 同步所有 claude-code-workspace 仓库（混合模式：脚本 + Claude 智能处理）。当用户提到同步、sync、pull 所有仓库、推代码、推一下、提交所有改动、把代码同步一下、更新仓库等意图时使用此 skill。也适用于用户问"有哪些仓库有改动"或"检查一下各个项目的状态"的场景。Also triggers on: push all repos, push changes, sync repos, pull all, check repo status, update all repositories, commit and push everything.
user_invocable: true
---

# Sync — 全仓库同步（混合模式）

> 本 skill 的输出解析逻辑基于 sync.sh 当前版本。若 sync.sh 输出格式变更，需同步更新此文件。

## 执行流程

### 第 0 步：检查 .env 是否存在（仅首次）

在运行 sync.sh 之前，先检查项目根目录下是否存在 `.env` 文件：

```bash
test -f .env && echo "exists" || echo "missing"
```

**如果 .env 不存在：**
- sync.sh 在非交互环境（CC Bash 工具）下会直接报错退出，无法完成首次引导
- 告诉用户需要在 **交互式终端**（Git Bash）中手动运行一次 `bash sync.sh` 来完成首次配置向导
- 向导会引导设置 dotfiles 路径、是否启用仓库同步等选项
- 完成后再回到 CC 运行 /sync 即可正常使用
- **不要尝试在 CC 中运行 sync.sh 来完成首次引导**

**如果 .env 已存在，进入第 1 步。**

### 第 1 步：运行同步脚本

执行项目根目录下的 `sync.sh`：

```bash
bash sync.sh
```

脚本会自动完成：发现仓库 → 同步 dotfiles 配置 → pull → commit（固定 message：`sync: auto commit from <hostname>`）→ push。

### 第 2 步：检查脚本执行结果

**如果脚本全部成功（exit code 0）：**
- 直接展示 bash 工具执行输出中「[4/6] 汇总」之后的内容，原样展示，不要重新格式化、不要包裹代码块、不要另建表格
- 如果输出包含 **检测到未安装的插件**，向用户展示缺失列表和脚本输出的安装命令，提示用户在 Claude Code 中运行（`/plugin add-marketplace` 和 `/plugin install`）
- 如果输出包含 **CONFLICT:** 标记，进入冲突处理流程（见下方）
- 如果输出包含 **NEW_REPO:** 标记，进入新仓库处理流程（见下方）
- 如果输出包含 **HANDOFF: Pending tasks detected**，进入第 3 步
- 否则任务完成，不做额外操作

**如果输出包含 CONFLICT: 标记（配置文件冲突）：**
- sync.sh 在非交互环境下运行时，冲突文件不会自动决策，而是输出 `CONFLICT:` 标记行
- 收集所有 CONFLICT 行，连同已在输出中的 diff 摘要和双方时间戳
- 使用 **AskUserQuestion** 工具以选择题形式展示冲突。对每个冲突文件构建一个 question：
  - header: 文件名（如 `settings.json`，不超过 12 字符）
  - question: `配置文件 <文件名> 存在冲突，选择哪个版本？`
  - options（3 个）：
    - `Repo 版本` — description 含 repo 时间戳
    - `Local 版本` — description 含 local 时间戳
    - `跳过` — description: 暂不处理此文件
  - preview: CONFLICT 行附近的 diff 输出（Markdown 格式）
  - multiSelect: false
- 若冲突文件超过 4 个，分多次调用 AskUserQuestion（每次最多 4 个 question）
- 用户选择后，执行对应操作：
  - Repo 版本：先 `cp "$LOCAL_FILE" "${LOCAL_FILE}.bak"`，再 `cp "$REPO_FILE" "$LOCAL_FILE"`
  - Local 版本：先 `cp "$REPO_FILE" "${REPO_FILE}.bak"`，再 `cp "$LOCAL_FILE" "$REPO_FILE"`
  - 跳过：不做操作
- 如果有文件选了 Local 版本（本地覆盖了 repo），需要在 dotfiles 仓库中 commit + push（中文 message）
- 冲突全部处理完后，再继续检查 HANDOFF 等后续步骤

**如果输出包含 NEW_REPO: 标记（新仓库待处理）：**
- sync.sh 在非交互模式下发现新仓库（本地不存在于任何 WORKSPACE_ROOTS 路径中）时，输出 `NEW_REPO: <name> | <url>` 标记
- 收集所有 NEW_REPO 行
- 使用 **AskUserQuestion** 工具向用户展示 clone 选项。对每个新仓库构建一个 question：
  - header: 仓库名（≤12 字符）
  - question: `新仓库 <仓库名> 本地未找到，选择 clone 到哪个目录？`
  - options: 从 .env 的 WORKSPACE_ROOTS 构建（每个路径一个选项）+ `跳过` + `永久忽略`
  - multiSelect: false
- 用户选择后执行对应操作：
  - 路径选项：`git clone <url> <选中路径>/<仓库名>`
  - 跳过：不操作，下次仍会询问
  - 永久忽略：`echo <仓库名> >> .sync_ignore`（在 CC_Sync 项目目录下）
- 处理完后继续检查后续步骤

**如果脚本部分失败（exit code 1）：**
- 同样先原样展示「[4/6] 汇总」之后的内容（不要重新格式化），然后再说明失败的仓库
- 查看哪些仓库报错（输出中标记了"需要 Claude 处理"的部分）
- 逐个处理失败的仓库：
  - **pull 失败（合并冲突）**：读取冲突文件，分析两边改动，向用户说明差异并建议解决方案。解决后用中文写一条描述性的 commit message 提交，然后 push
  - **commit 失败**：检查具体错误原因，修复后用中文写一条描述性的 commit message 重新提交，然后 push
  - **push 失败**：尝试 `pull --rebase` 后重新 push。如果 rebase 有冲突，按合并冲突流程处理
  - **clone 失败**：检查网络连接和仓库权限，向用户报告

**简单说：脚本能搞定的用机械 message，Claude 介入的用有意义的中文 message。**

### 第 3 步：处理 Handoff 任务（仅当 sync 输出检测到待办时）

1. 先确认 `.machine-name` 文件存在且内容与 HANDOFF.md 中某个 section 名一致；如果缺失，跳过 Step 3 并提示用户先完成设备注册（运行 /sync）
2. 读取 `HANDOFF.md`，找到本机 section 和 `## ANY` section 中的任务
3. 向用户汇报所有待办任务
4. 逐条执行：
   - shell 命令直接运行
   - 需要用户操作的步骤，提示用户手动完成
   - 任务失败时向用户说明原因，不要静默跳过
5. 全部完成后，将本机 section 的内容替换为 `(none)`。`## ANY` section：仅当其中所有任务均已完成时才替换为 `(none)`；若有明显针对其他设备的任务，保留并向用户说明
6. commit 并 push（message 示例：`HANDOFF: G16 任务完成，清除`）

## 配置信息

- **GitHub 用户名**：从 `gh api user` 自动检测
- **本地工作区根目录**：自动检测（CC_General 仓库的父目录）
- **Topic 标识**：`claude-code-workspace`
- **同步脚本**：项目根目录下的 `sync.sh`

## 新增仓库的方法

```bash
gh repo edit <用户名>/新仓库名 --add-topic claude-code-workspace
```

用户名通过 `gh api user -q .login` 获取。下次 /sync 自动发现。

## 惰性知识（容易遗忘的场景事实）

- **CRLF 幽灵改动**：Windows 上 pull/rebase 时，CRLF vs LF 差异可能产生虚假的 diff，不要当作真正冲突处理——用 `git diff --stat` 确认是否有实质改动
- **gh CLI 不走系统代理**：sync 中大量使用 `gh api`，在网络受限环境下是最常见的失败原因。需手动设 `HTTPS_PROXY`（详见全局 CLAUDE.md）
- **输出格式依赖**：第 2 步依赖脚本输出中的「[4/6] 汇总」标记定位展示内容。如果 sync.sh 改版了输出格式，此处需同步更新
- **Handoff 触发关键词**：第 3 步由 sync 输出中的 `HANDOFF: Pending tasks detected` 触发。设备验证和任务检测由 sync.sh [5/6] 步骤自动完成
- **Plugin 缺失检测**：step 2 同步 settings.json 后自动比对 `enabledPlugins` vs `installed_plugins.json`。缺失插件以 `检测到未安装的插件` 输出，附带 install 命令。Claude 无法在 bash 中运行 `claude plugin` 命令，需提示用户手动执行

## 经验沉淀

执行前先查看 `references/experience.md`（如果存在），复用已有经验。

任务完成后，如果本次遇到了非显而易见的解决方式（如特定仓库的冲突模式、某台机器的环境差异、脚本的未文档化行为等），将关键发现追加到本 skill 目录下的 `references/experience.md`，格式：

```
### [简短标题]  (YYYY-MM-DD)
[一两句描述：什么情况、怎么解决的、下次怎么跳过试错]
```

经验是提示而非事实——如果按经验操作失败，更新或删除该条。
