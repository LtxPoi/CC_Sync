#!/bin/bash
# sync.sh — Claude Code 工作区自动同步脚本
# 发现所有 claude-code-workspace 仓库，pull + 检测改动 + commit + push
# 冲突和错误会输出到 stderr，交给 Claude 处理

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE="${SCRIPT_DIR}/.env"

# 非交互模式检测：stdin 不是终端时启用（如通过 Claude Code Bash 工具运行）
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# --- 首次配置向导 ---
run_first_run_wizard() {
    detect_gh || true  # best-effort: 向导内可能需要 $GH 执行 gh repo create
    echo ""
    echo "========================================"
    echo " CC_Sync 首次配置"
    echo "========================================"
    echo ""

    # 【第 1 步】DOTFILES_PATH
    echo "【第 1 步】请指定 dotfiles 仓库的存放路径"
    echo ""
    echo "  CC_Sync 需要一个 git 仓库来存放你的 Claude Code 配置文件"
    echo "  （settings、skills、hooks、keybindings 等），以便在多台设备间"
    echo "  保持一致的工作环境。这个仓库叫做 dotfiles 仓库。"
    echo ""
    echo "  请输入你希望存放该仓库的路径，例如："
    echo "    C:/dotfiles"
    echo "    E:/config/my-dotfiles"
    echo "  Windows 路径不区分大小写（C:/Dotfiles 和 c:/dotfiles 等效）"
    echo ""

    local dotfiles_path=""
    while true; do
        read -p "路径：" dotfiles_path
        dotfiles_path=$(echo "$dotfiles_path" | tr -d '\r\n')

        # Reject empty
        if [ -z "$dotfiles_path" ]; then
            echo "路径不能为空，请重新输入。"
            continue
        fi

        # Check parent dir exists
        local parent_dir
        parent_dir=$(dirname "$dotfiles_path")
        # Fix drive-letter edge: dirname "C:/foo" → "C:" → "C:/"
        [[ "$parent_dir" =~ ^[A-Za-z]:$ ]] && parent_dir="${parent_dir}/"
        if [ ! -d "$parent_dir" ]; then
            echo ""
            echo "路径无效——父目录不存在，请检查是否拼写有误。"
            echo "  示例：C:/dotfiles、E:/config/my-dotfiles"
            echo ""
            continue
        fi

        # If path exists and has content
        if [ -d "$dotfiles_path" ]; then
            if [ -d "$dotfiles_path/claude-code-config" ] || [ -d "$dotfiles_path/claude" ]; then
                echo ""
                echo "检测到该路径下已有 dotfiles 仓库。"
                read -p "是否使用这个仓库？(y/n) " reuse_choice
                if [[ "$reuse_choice" =~ ^[Yy] ]]; then
                    break
                else
                    echo "请输入其他路径。"
                    echo ""
                    continue
                fi
            fi
            # Path exists but empty or no dotfiles structure — treat as valid
            break
        fi

        # Path doesn't exist: confirm creation
        echo ""
        echo "该路径不存在，将为你创建："
        echo "  - git init $dotfiles_path"
        echo "  - mkdir -p $dotfiles_path/claude"
        echo "  - 尝试在 GitHub 上创建同名仓库"
        echo ""
        read -p "确认创建？(y/n) " create_choice
        if [[ "$create_choice" =~ ^[Yy] ]]; then
            git init "$dotfiles_path"
            mkdir -p "$dotfiles_path/claude"
            # Attempt gh repo create (best-effort)
            local repo_name
            repo_name=$(basename "$dotfiles_path")
            if command -v "$GH" >/dev/null 2>&1; then
                echo "尝试在 GitHub 创建仓库 $repo_name..."
                "$GH" repo create "$repo_name" --private --source "$dotfiles_path" 2>&1 || echo -e "${YELLOW}GitHub 仓库创建失败，请稍后手动创建。${NC}"
            fi
            break
        else
            echo "请输入其他路径。"
            echo ""
            continue
        fi
    done

    # 【第 2 步】ENABLE_REPO_SYNC
    echo ""
    echo "【第 2 步】是否启用项目仓库批量同步？"
    echo ""
    echo "  除了配置同步，CC_Sync 还可以帮你一键同步所有 GitHub 项目仓库。"
    echo "  如果你的项目已经通过 GitHub 管理，不需要批量同步，可以选择不启用。"
    echo "  以后随时可以开启。"
    echo ""

    local enable_repo="false"
    local ws_roots=""
    local topic=""
    read -p "是否启用？(y/n)：" enable_choice
    if [[ "$enable_choice" =~ ^[Yy] ]]; then
        enable_repo="true"

        # 【第 2a 步】WORKSPACE_ROOTS
        echo ""
        echo "【第 2a 步】你的项目仓库存放在电脑上的哪个文件夹？"
        echo ""
        echo "  例如："
        echo "    D:/Projects"
        echo "    E:/Work;F:/Personal（多个文件夹用英文分号 ; 隔开）"
        echo "  Windows 路径不区分大小写（C:/Dotfiles 和 c:/dotfiles 等效）"
        echo ""
        read -p "请输入路径：" ws_roots

        # 【第 2b 步】TOPIC
        echo ""
        echo "【第 2b 步】你给 GitHub 仓库贴的标签（topic）叫什么？"
        echo ""
        echo "  sync 通过这个标签来发现你想同步的仓库。"
        echo "  如果你还没贴过标签，建议用默认值，直接回车即可。"
        echo ""
        read -p "请输入标签名（回车使用默认值 claude-code-workspace）：" topic
        topic="${topic:-claude-code-workspace}"
    fi

    # Write .env via Python (UTF-8 safe)
    python -c "
import sys
path = sys.argv[1]
with open(path, 'w', encoding='utf-8', newline='\n') as f:
    f.write('# .env — CC_Sync local config (auto-generated, do not commit)\n')
    for i in range(2, len(sys.argv), 2):
        f.write(sys.argv[i] + '=\"' + sys.argv[i+1] + '\"\n')
" "$(normalize_path "$ENV_FILE")" \
    "DOTFILES_PATH" "$dotfiles_path" \
    "ENABLE_REPO_SYNC" "$enable_repo" \
    "WORKSPACE_ROOTS" "${ws_roots:-}" \
    "TOPIC" "${topic:-claude-code-workspace}"

    echo ""
    echo "========================================"
    echo " 配置已保存到 .env"
    echo "========================================"
    echo ""
    echo "CC_Sync 会同步 settings.json 中的 MCP Server 配置（server 地址、"
    echo "启动参数等），但 MCP Server 本身的运行环境（代码、依赖、运行时）"
    echo "需要你在每台设备上自行安装和管理。"
    echo ""

    # Set runtime variables
    DOTFILES_PATH="$dotfiles_path"
    DOTFILES_DIR="$dotfiles_path"
    DOTFILES_REPO=$(basename "$dotfiles_path")
    ENABLE_REPO_SYNC="$enable_repo"
    WORKSPACE_ROOTS="${ws_roots:-}"
    TOPIC="${topic:-claude-code-workspace}"
}

# --- .env 加载或首次引导 ---
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    DOTFILES_DIR="$DOTFILES_PATH"
    DOTFILES_REPO=$(basename "$DOTFILES_PATH")
else
    if [ "$INTERACTIVE" = false ]; then
        echo -e "${RED}错误：.env 配置文件不存在。请在终端中运行 bash sync.sh 完成首次配置。${NC}" >&2
        exit 1
    fi
    run_first_run_wizard
fi

# Fallback: 未通过 .env 配置时使用旧的硬编码值
if [ -z "${DOTFILES_DIR:-}" ]; then
    DOTFILES_REPO="dotfiles"
    DOTFILES_DIR="${WORKSPACE_ROOT}/${DOTFILES_REPO}"
fi

CC_HOME="${HOME}/.claude"

# 配置文件映射：dotfiles 子路径 | 本地目标 | 显示名
CONFIG_MAP=(
    "claude-code-config/CLAUDE.md|${CC_HOME}/CLAUDE.md|CLAUDE.md"
    "claude-code-config/settings.json|${CC_HOME}/settings.json|settings.json"
    "claude-code-config/modules.toml|${CC_HOME}/skills/modules.toml|modules.toml"
    "claude-code-config/keybindings.json|${CC_HOME}/keybindings.json|keybindings.json"
    "claude-code-config/statusline.sh|${CC_HOME}/statusline.sh|statusline.sh"
)

# 多路径解析
declare -a WS_ROOTS=()
if [ -n "${WORKSPACE_ROOTS:-}" ]; then
    IFS=';' read -ra WS_ROOTS <<< "$WORKSPACE_ROOTS"
fi
if [ ${#WS_ROOTS[@]} -eq 0 ] && [ -n "${WORKSPACE_ROOT:-}" ]; then
    WS_ROOTS=("$WORKSPACE_ROOT")
fi

detect_gh || exit 1
detect_github_user || exit 1

HANDOFF_FILE="${SCRIPT_DIR}/HANDOFF.md"
HANDOFF_PY=$(normalize_path "${SCRIPT_DIR}/lib/handoff.py")
HANDOFF_FILE_PY=$(normalize_path "$HANDOFF_FILE")

# --- HANDOFF.md 辅助函数（委托给 lib/handoff.py）---

_handoff() { PYTHONIOENCODING=utf-8 python "$HANDOFF_PY" "$1" "$HANDOFF_FILE_PY" "${@:2}"; }
handoff_section_exists() { _handoff section_exists "$1"; }
handoff_add_section()    { _handoff add_section "$1"; }
handoff_remove_section() { _handoff remove_section "$1"; }
handoff_list_devices()   { _handoff list_devices; }
handoff_get_pending()    { _handoff get_pending "$@"; }

# 注册新设备到 HANDOFF.md 并提交推送
register_handoff_device() {
    local device_name="$1"
    handoff_add_section "$device_name"
    if ! (cd "$SCRIPT_DIR" && git add HANDOFF.md && git commit -m "HANDOFF: 新增设备 $device_name" && git push) 2>&1; then
        echo -e "${RED}注册设备 $device_name 时 git 操作失败${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}设备 $device_name 已注册到 HANDOFF.md${NC}"
}

# 从 HANDOFF.md 移除设备并提交推送
unregister_handoff_device() {
    local device_name="$1"
    handoff_remove_section "$device_name"
    if ! (cd "$SCRIPT_DIR" && git add HANDOFF.md && git commit -m "HANDOFF: 移除设备 $device_name" && git push) 2>&1; then
        echo -e "${RED}移除设备 $device_name 时 git 操作失败${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}设备 $device_name 已从 HANDOFF.md 移除${NC}"
}

# --- device 子命令 ---
if [ "${1:-}" = "device" ]; then
    subcmd="${2:-}"
    name="${3:-}"

    if [ ! -f "$HANDOFF_FILE" ]; then
        echo -e "${RED}HANDOFF.md 不存在${NC}" >&2
        exit 1
    fi

    require_device_arg() {
        if [ -z "${1:-}" ]; then
            echo "用法: sync.sh device $2 <name>" >&2
            exit 1
        fi
    }

    case "$subcmd" in
        list)
            echo "已注册的设备："
            handoff_list_devices | while read -r dev; do
                if get_machine_name && [ "$MACHINE_NAME" = "$dev" ]; then
                    echo "  $dev  ← 本机"
                else
                    echo "  $dev"
                fi
            done
            ;;
        add)
            require_device_arg "$name" "add"
            if [ "$(handoff_section_exists "$name")" = "yes" ]; then
                echo "设备 $name 已存在于 HANDOFF.md" >&2
                exit 1
            fi
            register_handoff_device "$name" || exit 1
            ;;
        remove)
            require_device_arg "$name" "remove"
            if [ "$(handoff_section_exists "$name")" = "no" ]; then
                echo "设备 $name 不在 HANDOFF.md 中" >&2
                exit 1
            fi
            PENDING=$(handoff_get_pending "$name")
            if [ -n "$PENDING" ]; then
                echo -e "${YELLOW}警告：设备 $name 有未完成的 handoff 任务：${NC}"
                echo "$PENDING"
                read -p "确认移除？(y/n) " CONFIRM
                if [[ ! "$CONFIRM" =~ ^[Yy] ]]; then
                    echo "已取消。"
                    exit 0
                fi
            fi
            unregister_handoff_device "$name" || exit 1
            ;;
        *)
            echo "用法: sync.sh device <list|add|remove> [name]"
            exit 1
            ;;
    esac
    exit 0
fi

# --- repo-sync 子命令 ---
if [ "${1:-}" = "repo-sync" ]; then
    subcmd="${2:-}"
    name="${3:-}"

    IGNORE_FILE="${SCRIPT_DIR}/.sync_ignore"

    case "$subcmd" in
        unignore)
            if [ -z "$name" ]; then
                echo "用法: sync.sh repo-sync unignore <repo-name>" >&2
                exit 1
            fi
            if [ ! -f "$IGNORE_FILE" ]; then
                echo ".sync_ignore 文件不存在，没有被忽略的仓库" >&2
                exit 1
            fi
            if ! grep -qx "$name" "$IGNORE_FILE" 2>/dev/null; then
                echo "仓库 $name 不在 .sync_ignore 中" >&2
                exit 1
            fi
            grep -vx "$name" "$IGNORE_FILE" > "${IGNORE_FILE}.tmp"
            mv "${IGNORE_FILE}.tmp" "$IGNORE_FILE"
            echo -e "${GREEN}已从 .sync_ignore 中移除 $name${NC}"
            ;;
        enable)
            if [ ! -f "$ENV_FILE" ]; then
                echo ".env 文件不存在，请先运行 bash sync.sh 完成首次配置" >&2
                exit 1
            fi
            source "$ENV_FILE"
            if [ "${ENABLE_REPO_SYNC:-false}" = "true" ]; then
                echo "项目仓库同步已启用，无需操作"
                exit 0
            fi
            echo ""
            echo "启用项目仓库批量同步"
            echo ""
            read -p "$(printf '你的项目仓库存放在电脑上的哪个文件夹？\n\n  例如：\n    D:/Projects\n    E:/Work;F:/Personal（多个文件夹用英文分号 ; 隔开）\n\n请输入路径：')" ws_roots
            if [ -z "$ws_roots" ]; then
                echo "路径不能为空" >&2
                exit 1
            fi
            read -p "$(printf '你给 GitHub 仓库贴的标签（topic）叫什么？\n（回车使用默认值 claude-code-workspace）：')" topic
            topic="${topic:-claude-code-workspace}"
            # Update .env via Python
            python -c "
import sys
env_path = sys.argv[1]
ws = sys.argv[2]
tp = sys.argv[3]
lines = []
with open(env_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
ws_found = False
tp_found = False
with open(env_path, 'w', encoding='utf-8', newline='\n') as f:
    for line in lines:
        if line.startswith('ENABLE_REPO_SYNC='):
            f.write('ENABLE_REPO_SYNC=\"true\"\n')
        elif line.startswith('WORKSPACE_ROOTS='):
            f.write('WORKSPACE_ROOTS=\"' + ws + '\"\n')
            ws_found = True
        elif line.startswith('TOPIC='):
            f.write('TOPIC=\"' + tp + '\"\n')
            tp_found = True
        else:
            f.write(line)
    if not ws_found:
        f.write('WORKSPACE_ROOTS=\"' + ws + '\"\n')
    if not tp_found:
        f.write('TOPIC=\"' + tp + '\"\n')
" "$(normalize_path "$ENV_FILE")" "$ws_roots" "$topic"
            # Reset hint counter
            rm -f "${SCRIPT_DIR}/.repo_sync_hint_count"
            echo -e "${GREEN}已启用项目仓库同步！下次运行 sync 时将自动发现并同步仓库。${NC}"
            ;;
        *)
            echo "用法: sync.sh repo-sync <enable|unignore> <repo-name>"
            exit 1
            ;;
    esac
    exit 0
fi

# 在多个 workspace root 中查找仓库目录（step 2 memory 同步 + step 3 均需要）
_find_repo_dir() {
    local repo_name="$1"
    local root
    for root in "${WS_ROOTS[@]}"; do
        if [ -d "${root}/${repo_name}" ]; then
            echo "${root}/${repo_name}"
            return 0
        fi
    done
    return 1
}

# 结果记录
declare -a RESULTS
HAS_ERROR=0

# 并行处理用的临时目录
SYNC_TMPDIR=$(safe_mktemp)
trap 'rm -rf "$SYNC_TMPDIR"' EXIT

echo "========================================="
echo " Claude Code Workspace Sync"
echo "========================================="

# --- 第 1 步：发现仓库 ---
echo ""
echo "[1/6] 发现仓库..."

if [ "${ENABLE_REPO_SYNC:-true}" = "false" ]; then
    # Config-only mode: only find dotfiles repo
    if ! REPOS_JSON=$("$GH" repo list "$GITHUB_USER" --json name,url --limit 100 2>/dev/null); then
        echo -e "${RED}错误：无法获取仓库列表。${NC}" >&2
        exit 1
    fi
    REPOS=$(python -c "
import json, sys
name = sys.argv[1]
data = json.loads(sys.stdin.read())
for repo in data:
    if repo['name'] == name:
        print(repo['name'] + '|' + repo['url'])
        break
" "$DOTFILES_REPO" <<< "$REPOS_JSON" | tr -d '\r')

    if [ -z "$REPOS" ]; then
        echo -e "${YELLOW}未找到 dotfiles 仓库 ($DOTFILES_REPO)。${NC}"
    else
        echo "已定位 dotfiles 仓库"
    fi
    declare -A KNOWN_REPOS
    declare -A REPO_URLS
    while IFS='|' read -r name url; do
        [ -z "$name" ] && continue
        KNOWN_REPOS["$name"]=1
        REPO_URLS["$name"]="$url"
    done <<< "$REPOS"
else
    # Full mode: discover all repos with topic
    if ! REPOS_JSON=$("$GH" repo list "$GITHUB_USER" --json name,url,repositoryTopics --limit 100 2>/dev/null); then
        echo -e "${RED}错误：无法获取仓库列表。请检查 gh auth 状态。${NC}" >&2
        exit 1
    fi

    # 读取 .sync_ignore（永久忽略的仓库列表）
    IGNORE_FILE="${SCRIPT_DIR}/.sync_ignore"
    IGNORED_LIST=""
    N_IGNORED=0
    if [ -f "$IGNORE_FILE" ]; then
        IGNORED_LIST=$(grep -v '^\s*#' "$IGNORE_FILE" | grep -v '^\s*$' | tr -d '\r' || true)
        if [ -n "$IGNORED_LIST" ]; then
            N_IGNORED=$(echo "$IGNORED_LIST" | wc -l | tr -d ' ')
        fi
    fi

    # 筛选带有指定 topic 的仓库（用 python 解析 JSON，因为 Git Bash 没有 jq）
    REPOS=$(TOPIC="$TOPIC" IGNORED_REPOS="$IGNORED_LIST" python -c "
import json, os, sys
topic = os.environ['TOPIC']
ignored = set(line for line in os.environ.get('IGNORED_REPOS', '').split('\n') if line)
data = json.loads(sys.stdin.read())
for repo in data:
    if repo['name'] in ignored:
        continue
    topics = [t['name'] for t in (repo.get('repositoryTopics') or [])]
    if topic in topics:
        print(repo['name'] + '|' + repo['url'])
" <<< "$REPOS_JSON" | tr -d '\r')

    if [ "$N_IGNORED" -gt 0 ]; then
        echo "  （已跳过 ${N_IGNORED} 个被忽略的仓库，见 .sync_ignore）"
    fi

    if [ -z "$REPOS" ]; then
        echo -e "${YELLOW}未发现任何带有 ${TOPIC} topic 的仓库。${NC}"
        exit 0
    fi

    REPO_COUNT=$(echo "$REPOS" | wc -l)
    echo "发现 ${REPO_COUNT} 个仓库"

    # --- 孤儿目录检测：找出本地存在但未纳入 GitHub 同步的目录 ---
    declare -A KNOWN_REPOS
    declare -A REPO_URLS
    while IFS='|' read -r name url; do
        KNOWN_REPOS["$name"]=1
        REPO_URLS["$name"]="$url"
    done <<< "$REPOS"

    ORPHAN_FOUND=0
    for ws_root in "${WS_ROOTS[@]}"; do
    for DIR in "${ws_root}"/*/; do
        [ ! -d "$DIR" ] && continue
        DIR_NAME=$(basename "$DIR")
        [[ "$DIR_NAME" == .* ]] && continue
        [ "${KNOWN_REPOS[$DIR_NAME]+_}" ] && continue

        if [ $ORPHAN_FOUND -eq 0 ]; then
            echo ""
            echo -e "${YELLOW}⚠ 检测到未纳入同步的本地目录：${NC}"
            ORPHAN_FOUND=1
        fi

        if [ -d "$DIR/.git" ]; then
            echo -e "${YELLOW}  - ${DIR_NAME}/ （在 ${ws_root}，是 git 仓库，但 GitHub 仓库缺少 ${TOPIC} topic）${NC}"
            echo -e "${YELLOW}    → gh repo edit ${GITHUB_USER}/${DIR_NAME} --add-topic ${TOPIC}${NC}"
        else
            echo -e "${YELLOW}  - ${DIR_NAME}/ （在 ${ws_root}，不是 git 仓库）${NC}"
            echo -e "${YELLOW}    → 需要 git init + 创建 GitHub 仓库 + 添加 ${TOPIC} topic${NC}"
        fi
    done
    done

    if [ $ORPHAN_FOUND -eq 1 ]; then
        echo ""
    fi
fi

# --- add + commit + push 统一函数 ---
# 用法: sync_commit_push <label>
# 前提: 当前目录已是目标仓库
# 注意: HAS_ERROR 赋值仅在主进程中生效，子进程中请用 touch .error 文件
sync_commit_push() {
    local label="$1"
    git add -A
    if ! git commit -m "sync: auto commit from $(hostname)"; then
        echo -e "${RED}${label} commit 失败${NC}" >&2
        HAS_ERROR=1
        return 1
    fi
    if ! git push 2>&1; then
        echo -e "${RED}${label} push 失败${NC}" >&2
        HAS_ERROR=1
        return 1
    fi
    return 0
}

# --- 单向同步辅助函数 ---
_sync_one_way() {
    local src="$1" dst="$2" label="$3" arrow="$4"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo -e "  ${arrow} ${label}"
}

# --- 智能同步函数：比较内容 + 时间戳定方向 ---
# 用法: sync_config_file <仓库文件> <本地文件> <显示名>
sync_config_file() {
    local REPO_FILE="$1"
    local LOCAL_FILE="$2"
    local LABEL="$3"

    # 只有一边存在：复制到另一边
    if [ ! -f "$REPO_FILE" ] && [ ! -f "$LOCAL_FILE" ]; then return; fi
    if [ ! -f "$REPO_FILE" ] && [ -f "$LOCAL_FILE" ]; then
        _sync_one_way "$LOCAL_FILE" "$REPO_FILE" "$LABEL: 本地新增，同步到仓库" "${GREEN}→${NC}"
        CFG_SYNCED=$((CFG_SYNCED+1))
        return
    fi
    if [ -f "$REPO_FILE" ] && [ ! -f "$LOCAL_FILE" ]; then
        _sync_one_way "$REPO_FILE" "$LOCAL_FILE" "$LABEL: 仓库新增，同步到本地" "${GREEN}←${NC}"
        CFG_SYNCED=$((CFG_SYNCED+1))
        return
    fi

    # 两边都存在：比较内容
    if cmp -s "$REPO_FILE" "$LOCAL_FILE"; then
        echo "  = $LABEL: 无差异"
        CFG_SKIPPED=$((CFG_SKIPPED+1))
        return
    fi

    # Content differs — show summary and ask user
    echo -e "  ${YELLOW}!${NC} $LABEL: repo 和本地内容不同"
    diff --unified=1 "$REPO_FILE" "$LOCAL_FILE" 2>/dev/null | head -20 || true
    echo ""

    local REPO_TIME LOCAL_TIME
    REPO_TIME=$(date -r "$REPO_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
    LOCAL_TIME=$(date -r "$LOCAL_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
    echo "    Repo:  $REPO_TIME"
    echo "    Local: $LOCAL_TIME"
    echo ""
    if [ "$INTERACTIVE" = true ]; then
        read -p "    选择: (r)epo 优先 / (l)ocal 优先 / (s)kip [s]: " CHOICE
    else
        echo "    CONFLICT: $LABEL | repo=$REPO_FILE | local=$LOCAL_FILE"
        CHOICE="s"
    fi
    case "$CHOICE" in
        r|R)
            cp "$LOCAL_FILE" "${LOCAL_FILE}.bak"
            cp "$REPO_FILE" "$LOCAL_FILE"
            echo -e "  ${GREEN}←${NC} $LABEL: 使用 repo 版本 (本地已备份 .bak)"
            CFG_SYNCED=$((CFG_SYNCED+1))
            ;;
        l|L)
            cp "$REPO_FILE" "${REPO_FILE}.bak"
            cp "$LOCAL_FILE" "$REPO_FILE"
            echo -e "  ${GREEN}→${NC} $LABEL: 使用本地版本 (repo 已备份 .bak)"
            CFG_SYNCED=$((CFG_SYNCED+1))
            ;;
        *)
            echo -e "  ${NC}  $LABEL: 已跳过 (无修改)"
            CFG_CONFLICT=$((CFG_CONFLICT+1))
            ;;
    esac
}

# --- Memory 目录同步：CC hash 路径 ↔ dotfiles/claude-code-config/projects/<仓库名>/memory/ ---
sync_memory_dir() {
    local REPO_DIR="$1"
    local REPO_NAME="$2"

    local CC_HASH
    CC_HASH=$(compute_cc_hash "$REPO_DIR")

    local CC_PROJECT_DIR="${HOME}/.claude/projects/${CC_HASH}"
    [ ! -d "$CC_PROJECT_DIR" ] && return 1

    local DOTFILES_MEMORY="${DOTFILES_DIR}/claude-code-config/projects/${REPO_NAME}/memory"
    local CC_MEMORY="${CC_PROJECT_DIR}/memory"

    # find 对不存在的目录直接跳过，无需预检查
    local ALL_FILES
    ALL_FILES=$(
        find "$DOTFILES_MEMORY" "$CC_MEMORY" -maxdepth 1 -name "*.md" -exec basename {} \; 2>/dev/null
    )
    ALL_FILES=$(echo "$ALL_FILES" | sort -u)

    [ -z "$ALL_FILES" ] && return 1

    mkdir -p "$DOTFILES_MEMORY" "$CC_MEMORY"
    echo "  ${REPO_NAME}:"

    while IFS= read -r filename; do
        [ -z "$filename" ] && continue
        sync_config_file "${DOTFILES_MEMORY}/${filename}" "${CC_MEMORY}/${filename}" "    ${filename}"
    done <<< "$ALL_FILES"
    return 0
}

# --- 自制全局 skill 同步：modules.toml 外的 skill ↔ dotfiles ---
sync_custom_skills() {
    local DOTFILES_SKILLS="${DOTFILES_DIR}/claude-code-config/skills"
    local LOCAL_SKILLS="${HOME}/.claude/skills"
    local MANIFEST="${LOCAL_SKILLS}/modules.toml"
    local MANIFEST_PY
    MANIFEST_PY=$(normalize_path "$MANIFEST")

    # Step A: 从 modules.toml 提取第三方 skill 名列表
    local MANAGED_SKILLS=""
    if [ -f "$MANIFEST" ]; then
        MANAGED_SKILLS=$(python -c "
import sys, re
with open(sys.argv[1], encoding='utf-8') as f:
    text = f.read()
for m in re.findall(r'\[modules\.([^\]]+)\]', text):
    if '.' not in m:
        print(m)
" "$MANIFEST_PY" 2>/dev/null || true)
    fi

    # Step B: 收集双方的自制 skill 名（排除第三方 + modules.toml 文件本身）
    local ALL_CUSTOM=""

    # 本地侧：~/.claude/skills/ 中不在 modules.toml 里的目录
    if [ -d "$LOCAL_SKILLS" ]; then
        for d in "$LOCAL_SKILLS"/*/; do
            [ ! -d "$d" ] && continue
            local name
            name=$(basename "$d")
            if ! echo "$MANAGED_SKILLS" | grep -qx "$name"; then
                ALL_CUSTOM=$(printf '%s\n%s' "$ALL_CUSTOM" "$name")
            fi
        done
    fi

    # dotfiles 侧：dotfiles/claude-code-config/skills/ 中的目录
    if [ -d "$DOTFILES_SKILLS" ]; then
        for d in "$DOTFILES_SKILLS"/*/; do
            [ ! -d "$d" ] && continue
            local name
            name=$(basename "$d")
            ALL_CUSTOM=$(printf '%s\n%s' "$ALL_CUSTOM" "$name")
        done
    fi

    # 去重排序
    ALL_CUSTOM=$(echo "$ALL_CUSTOM" | sort -u | sed '/^$/d')
    [ -z "$ALL_CUSTOM" ] && return

    mkdir -p "$DOTFILES_SKILLS"

    # Step C: 对每个自制 skill，双向逐文件同步
    while IFS= read -r skill_name; do
        [ -z "$skill_name" ] && continue
        local dotfiles_skill="${DOTFILES_SKILLS}/${skill_name}"
        local local_skill="${LOCAL_SKILLS}/${skill_name}"

        echo "  ${skill_name}/:"

        # 合并两侧文件列表（排除 __pycache__、.pyc）
        local ALL_FILES=""
        if [ -d "$dotfiles_skill" ]; then
            ALL_FILES=$(cd "$dotfiles_skill" && find . -type f \
                ! -path '*/__pycache__/*' ! -name '*.pyc' | sed 's|^\./||')
        fi
        if [ -d "$local_skill" ]; then
            local LOCAL_FILES
            LOCAL_FILES=$(cd "$local_skill" && find . -type f \
                ! -path '*/__pycache__/*' ! -name '*.pyc' | sed 's|^\./||')
            ALL_FILES=$(printf '%s\n%s' "$ALL_FILES" "$LOCAL_FILES")
        fi
        ALL_FILES=$(echo "$ALL_FILES" | sort -u | sed '/^$/d')

        [ -z "$ALL_FILES" ] && continue

        while IFS= read -r rel_path; do
            [ -z "$rel_path" ] && continue
            sync_config_file "${dotfiles_skill}/${rel_path}" "${local_skill}/${rel_path}" "    ${rel_path}"
        done <<< "$ALL_FILES"
    done <<< "$ALL_CUSTOM"
}

# --- Plugin 缺失检测：settings.json enabledPlugins vs installed_plugins.json ---
check_missing_plugins() {
    local SETTINGS_FILE="${HOME}/.claude/settings.json"
    local INSTALLED_FILE="${HOME}/.claude/plugins/installed_plugins.json"
    local SETTINGS_PY INSTALLED_PY
    SETTINGS_PY=$(normalize_path "$SETTINGS_FILE")
    INSTALLED_PY=$(normalize_path "$INSTALLED_FILE")

    [ ! -f "$SETTINGS_FILE" ] && return 0

    local MISSING
    MISSING=$(PYTHONIOENCODING=utf-8 python -c "
import json, sys

settings_path = sys.argv[1]
installed_path = sys.argv[2]

try:
    with open(settings_path, encoding='utf-8') as f:
        settings = json.load(f)
except Exception:
    sys.exit(0)

enabled = settings.get('enabledPlugins') or {}
marketplaces = settings.get('extraKnownMarketplaces') or {}

try:
    with open(installed_path, encoding='utf-8') as f:
        installed = json.load(f)
    installed_keys = set((installed.get('plugins') or {}).keys())
except Exception:
    installed_keys = set()

missing = []
for plugin_id, is_enabled in enabled.items():
    if not is_enabled:
        continue
    if plugin_id in installed_keys:
        continue
    # plugin_id format: name@marketplace
    parts = plugin_id.split('@', 1)
    if len(parts) != 2:
        continue
    name, mkt = parts
    mkt_info = marketplaces.get(mkt, {})
    source = mkt_info.get('source', {})
    repo = source.get('repo', '')
    missing.append(f'{plugin_id}|{repo}')

for m in missing:
    print(m)
" "$SETTINGS_PY" "$INSTALLED_PY" 2>/dev/null)

    [ -z "$MISSING" ] && return 0

    echo ""
    echo -e "${YELLOW}检测到未安装的插件：${NC}"
    local INSTALL_CMDS=""
    while IFS='|' read -r plugin_id mkt_repo; do
        [ -z "$plugin_id" ] && continue
        local mkt="${plugin_id#*@}"
        if [ -n "$mkt_repo" ]; then
            echo -e "  ${YELLOW}!${NC} ${plugin_id}  (marketplace: ${mkt_repo})"
        else
            echo -e "  ${YELLOW}!${NC} ${plugin_id}"
        fi
        # 收集安装命令
        if [ ! -d "${HOME}/.claude/plugins/marketplaces/${mkt}" ] && [ -n "$mkt_repo" ]; then
            INSTALL_CMDS+="  claude plugin add-marketplace ${mkt} --url ${mkt_repo}"$'\n'
        fi
        INSTALL_CMDS+="  claude plugin install ${plugin_id}"$'\n'
    done <<< "$MISSING"
    echo -e "${YELLOW}运行以下命令安装：${NC}"
    printf '%s' "$INSTALL_CMDS"
    echo ""
}

# --- 第 2 步：先拉取 dotfiles 并同步全局配置（智能双向） ---
echo ""
echo "[2/6] 同步全局配置..."

if [ "${KNOWN_REPOS[$DOTFILES_REPO]+_}" ]; then
    DOTFILES_URL="${REPO_URLS[$DOTFILES_REPO]}"

    # 如果 dotfiles 本地不存在，先克隆
    if [ ! -d "$DOTFILES_DIR" ]; then
        echo "dotfiles 本地不存在，正在克隆..."
        if ! git clone "$DOTFILES_URL" "$DOTFILES_DIR" 2>&1; then
            echo -e "${RED}dotfiles 克隆失败${NC}" >&2
            HAS_ERROR=1
        fi
    fi

    if [ -d "$DOTFILES_DIR" ] && cd "$DOTFILES_DIR"; then
        echo "拉取 dotfiles 远程更新..."
        DOTFILES_PULL_OUTPUT=$(git pull --rebase 2>&1)
        DOTFILES_PULL_EXIT=$?
        echo "$DOTFILES_PULL_OUTPUT"

        if [ $DOTFILES_PULL_EXIT -ne 0 ]; then
            echo -e "${RED}dotfiles pull 失败，跳过配置同步（避免用旧文件覆盖本地）${NC}" >&2
            HAS_ERROR=1
            touch "${SYNC_TMPDIR}/dotfiles_pull_failed"
        else
            # 逐文件智能同步：基于 CONFIG_MAP 声明式映射
            CFG_SYNCED=0; CFG_SKIPPED=0; CFG_CONFLICT=0
            for entry in "${CONFIG_MAP[@]}"; do
                IFS='|' read -r _repo_sub _local _label <<< "$entry"
                sync_config_file "${DOTFILES_DIR}/${_repo_sub}" "$_local" "$_label"
            done
            echo ""
            if [ $CFG_CONFLICT -gt 0 ]; then
                echo -e "配置同步：${GREEN}${CFG_SYNCED} 已同步${NC} · ${CFG_SKIPPED} 跳过 · ${YELLOW}${CFG_CONFLICT} 冲突待处理${NC}"
            else
                echo -e "配置同步：${GREEN}${CFG_SYNCED} 已同步${NC} · ${CFG_SKIPPED} 跳过"
            fi

            # 自制全局 skill 同步（modules.toml 外的 skill ↔ dotfiles）
            echo ""
            echo "同步自制 Skills..."
            sync_custom_skills

            # Plugin 缺失检测（settings.json 的 enabledPlugins vs 本地已安装）
            check_missing_plugins

            # （_find_repo_dir 已在脚本顶部定义，见上方）

            # Memory 文件同步（CC hash 路径 ↔ dotfiles）
            echo ""
            echo "同步 Memory 文件..."
            MEM_SYNCED=0
            for name in "${!KNOWN_REPOS[@]}"; do
                MEM_REPO_DIR=$(_find_repo_dir "$name") || continue
                if sync_memory_dir "$MEM_REPO_DIR" "$name"; then
                    MEM_SYNCED=$((MEM_SYNCED + 1))
                fi
            done
            if [ $MEM_SYNCED -eq 0 ]; then
                echo "  (无项目有 memory 需要同步)"
            fi
        fi
    elif [ -d "$DOTFILES_DIR" ]; then
        echo -e "${RED}无法进入 dotfiles 目录${NC}" >&2
        HAS_ERROR=1
    fi
else
    echo "仓库列表中无 dotfiles，跳过"
fi

# --- 第 3 步：并行处理仓库 ---
if [ "${ENABLE_REPO_SYNC:-true}" = "false" ]; then
    echo ""
    echo "[3/6] 项目仓库同步已禁用，跳过"
else
echo ""
echo "[3/6] 处理仓库..."
echo ""

# --- 仓库处理结果辅助函数 ---
_repo_fail() {
    local name="$1" msg="$2"
    echo "${name}|${msg}" > "${SYNC_TMPDIR}/${name}.result"
    touch "${SYNC_TMPDIR}/${name}.error"
    echo -e "${RED}${msg}${NC}"
}

_repo_ok() {
    local name="$1" msg="$2"
    echo "${name}|${msg}" > "${SYNC_TMPDIR}/${name}.result"
    echo -e "${GREEN}✓${NC} ${msg}"
}

# 交互式 clone 菜单：新仓库选择 clone 目标
# 返回值：0=已 clone, 1=跳过, 2=忽略
_interactive_clone_menu() {
    local repo_name="$1"
    local repo_url="$2"

    echo ""
    echo "发现新仓库 ${repo_name}，本地未找到。"
    echo "请选择 clone 到哪个目录："

    local i=1
    for root in "${WS_ROOTS[@]}"; do
        echo "  [$i] $root"
        i=$((i + 1))
    done
    echo "  [n] 输入新路径"
    echo "  [s] 跳过（下次仍会询问）"
    echo "  [i] 忽略（以后不再询问）"
    echo ""
    read -p "> " choice < /dev/tty
    choice=$(echo "$choice" | tr -d '\r\n')

    # Handle numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local idx=$((choice - 1))
        if [ $idx -ge 0 ] && [ $idx -lt ${#WS_ROOTS[@]} ]; then
            local target_dir="${WS_ROOTS[$idx]}/${repo_name}"
            echo "正在 clone 到 ${target_dir}..."
            if git clone "$repo_url" "$target_dir" 2>&1; then
                echo -e "${GREEN}克隆完成${NC}"
                CLONE_RESULT_DIR="$target_dir"
                return 0
            else
                echo -e "${RED}克隆失败${NC}"
                return 3
            fi
        else
            echo "无效选择，跳过"
            return 1
        fi
    fi

    case "$choice" in
        n|N)
            echo ""
            read -p "$(printf '请输入完整路径（例如 D:/MyProjects 或 C:/Users/你的用户名/Documents/Code）：\n> ')" new_path < /dev/tty
            new_path=$(echo "$new_path" | tr -d '\r\n')
            if [ -z "$new_path" ]; then
                echo "路径为空，跳过"
                return 1
            fi
            if [ ! -d "$new_path" ]; then
                read -p "路径 $new_path 不存在，是否创建？(y/n) " create_confirm < /dev/tty
                if [[ "$create_confirm" =~ ^[Yy] ]]; then
                    mkdir -p "$new_path" || { echo -e "${RED}创建失败${NC}"; return 1; }
                else
                    echo "已跳过"
                    return 1
                fi
            fi
            local target_dir="${new_path}/${repo_name}"
            echo "正在 clone 到 ${target_dir}..."
            if git clone "$repo_url" "$target_dir" 2>&1; then
                echo -e "${GREEN}克隆完成${NC}"
                # 自动追加新路径到 .env 的 WORKSPACE_ROOTS
                _append_workspace_root "$new_path"
                WS_ROOTS+=("$new_path")
                CLONE_RESULT_DIR="$target_dir"
                return 0
            else
                echo -e "${RED}克隆失败${NC}"
                return 3
            fi
            ;;
        s|S)
            echo "已跳过 ${repo_name}"
            return 1
            ;;
        i|I)
            local ignore_file="${SCRIPT_DIR}/.sync_ignore"
            echo "$repo_name" >> "$ignore_file"
            echo "已将 ${repo_name} 添加到 .sync_ignore"
            return 2
            ;;
        *)
            echo "无效选择，跳过"
            return 1
            ;;
    esac
}

# 追加新路径到 .env 的 WORKSPACE_ROOTS
_append_workspace_root() {
    local new_root="$1"
    if [ ! -f "$ENV_FILE" ]; then return; fi
    python -c "
import sys
env_path = sys.argv[1]
new_root = sys.argv[2]
lines = []
found = False
with open(env_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()
with open(env_path, 'w', encoding='utf-8', newline='\n') as f:
    for line in lines:
        if line.startswith('WORKSPACE_ROOTS='):
            old_val = line.strip().split('=', 1)[1].strip('\"')
            if old_val:
                f.write('WORKSPACE_ROOTS=\"' + old_val + ';' + new_root + '\"\n')
            else:
                f.write('WORKSPACE_ROOTS=\"' + new_root + '\"\n')
            found = True
        else:
            f.write(line)
    if not found:
        f.write('WORKSPACE_ROOTS=\"' + new_root + '\"\n')
" "$(normalize_path "$ENV_FILE")" "$new_root"
}

# 单个仓库的处理函数（在子进程中运行）
# 输出写入 SYNC_TMPDIR/<name>.out，结果写入 .result，错误标记 .error
_process_repo() {
    local REPO_NAME="$1"
    local REPO_URL="$2"
    local REPO_DIR="$3"

    echo "----- ${REPO_NAME} -----"

    # 情况 A：本地不存在，克隆
    if [ ! -d "$REPO_DIR" ]; then
        echo "本地不存在，正在克隆..."
        if git clone "$REPO_URL" "$REPO_DIR" 2>&1; then
            echo "${REPO_NAME}|新克隆" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo -e "${GREEN}克隆完成${NC}"
        else
            _repo_fail "$REPO_NAME" "克隆失败"
        fi
        echo ""
        return
    fi

    cd "$REPO_DIR" || return

    # Pull
    echo "拉取远程更新..."
    local PULL_OUTPUT PULL_EXIT
    PULL_OUTPUT=$(git pull --rebase 2>&1)
    PULL_EXIT=$?
    if [ $PULL_EXIT -ne 0 ]; then
        echo "${REPO_NAME}|pull 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        echo -e "${RED}pull 失败：${PULL_OUTPUT}${NC}"
        touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        echo ""
        return
    fi

    # 检查改动
    local STATUS
    STATUS=$(git status --porcelain)
    if [ -z "$STATUS" ]; then
        local UNPUSHED
        UNPUSHED=$(git log @{u}..HEAD --oneline 2>/dev/null)
        if [ -n "$UNPUSHED" ]; then
            echo "有未推送的 commit，正在 push..."
            if git push 2>&1; then
                echo "${REPO_NAME}|已推送未同步的 commit" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo -e "${GREEN}push 完成${NC}"
            else
                echo "${REPO_NAME}|push 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            fi
        else
            if echo "$PULL_OUTPUT" | grep -q "Already up to date"; then
                echo "${REPO_NAME}|无改动" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo "无改动，跳过"
            else
                echo "${REPO_NAME}|已拉取远程更新" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
                echo "已拉取远程更新"
            fi
        fi
        echo ""
        return
    fi

    # 有改动：add + commit + push
    echo "检测到改动，正在提交..."
    git add -A
    if ! git commit -m "sync: auto commit from $(hostname)"; then
        echo "${REPO_NAME}|commit 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        echo -e "${RED}${REPO_NAME} commit 失败${NC}"
        touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        echo ""
        return
    fi
    if ! git push 2>&1; then
        echo "${REPO_NAME}|push 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        echo -e "${RED}${REPO_NAME} push 失败${NC}"
        touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        echo ""
        return
    fi
    echo "${REPO_NAME}|已提交并推送" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
    echo -e "${GREEN}完成${NC}"
    echo ""
}

# 并行启动所有仓库处理
declare -a REPO_ORDER=()
while IFS='|' read -r REPO_NAME REPO_URL; do
    REPO_ORDER+=("$REPO_NAME")

    # dotfiles 已在第 2 步处理
    if [ "$REPO_NAME" = "$DOTFILES_REPO" ]; then
        if [ -f "${SYNC_TMPDIR}/dotfiles_pull_failed" ]; then
            echo "${REPO_NAME}|pull 失败 - 需要 Claude 处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"; echo "第 2 步 pull 失败，需要处理"; echo ""; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        else
            echo "${REPO_NAME}|已在第 2 步同步" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"; echo "已在第 2 步处理，跳过"; echo ""; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
        fi
        continue
    fi

    # 在所有 workspace root 中查找
    FOUND_DIR=""
    if FOUND_DIR=$(_find_repo_dir "$REPO_NAME"); then
        # 校验 remote URL 是否匹配（防止多路径下同名仓库误操作）
        _actual_url=$(git -C "$FOUND_DIR" remote get-url origin 2>/dev/null || true)
        _expect_clean="${REPO_URL%.git}"
        _actual_clean="${_actual_url%.git}"
        if [ -n "$_actual_url" ] && [ "$_actual_clean" != "$_expect_clean" ]; then
            echo "${REPO_NAME}|remote URL 不匹配，已跳过" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            { echo "----- ${REPO_NAME} -----"
              echo "警告：本地 ${FOUND_DIR} 的 origin URL 与 GitHub 不匹配"
              echo "  期望: ${REPO_URL}"
              echo "  实际: ${_actual_url}"
              echo "已跳过，请手动检查"; } > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
            continue
        fi
        # 已存在且 URL 匹配：后台处理（保持并行）
        _process_repo "$REPO_NAME" "$REPO_URL" "$FOUND_DIR" > "${SYNC_TMPDIR}/${REPO_NAME}.out" 2>&1 &
    elif [ "$INTERACTIVE" = true ]; then
        # 新仓库 + 交互模式：前台运行 clone 菜单（不重定向，保持终端交互）
        CLONE_RESULT_DIR=""
        _interactive_clone_menu "$REPO_NAME" "$REPO_URL"
        menu_rc=$?
        if [ $menu_rc -eq 0 ] && [ -n "$CLONE_RESULT_DIR" ]; then
            echo "${REPO_NAME}|新克隆" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo "----- ${REPO_NAME} -----" > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            echo "新克隆到 ${CLONE_RESULT_DIR}" >> "${SYNC_TMPDIR}/${REPO_NAME}.out"
        elif [ $menu_rc -eq 2 ]; then
            echo "${REPO_NAME}|已忽略" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo "----- ${REPO_NAME} -----" > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            echo "已添加到 .sync_ignore" >> "${SYNC_TMPDIR}/${REPO_NAME}.out"
        elif [ $menu_rc -eq 3 ]; then
            echo "${REPO_NAME}|克隆失败" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo "----- ${REPO_NAME} -----" > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            echo "克隆失败" >> "${SYNC_TMPDIR}/${REPO_NAME}.out"
            touch "${SYNC_TMPDIR}/${REPO_NAME}.error"
        else
            echo "${REPO_NAME}|已跳过" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
            echo "----- ${REPO_NAME} -----" > "${SYNC_TMPDIR}/${REPO_NAME}.out"
            echo "用户跳过" >> "${SYNC_TMPDIR}/${REPO_NAME}.out"
        fi
    else
        # 新仓库 + 非交互模式：输出标记
        {
            echo "NEW_REPO: ${REPO_NAME} | ${REPO_URL}"
            echo "${REPO_NAME}|新仓库待处理" > "${SYNC_TMPDIR}/${REPO_NAME}.result"
        } > "${SYNC_TMPDIR}/${REPO_NAME}.out" 2>&1
    fi
done <<< "$REPOS"

wait

# 按原始顺序收集输出和结果
for name in "${REPO_ORDER[@]}"; do
    [ -f "${SYNC_TMPDIR}/${name}.out" ] && cat "${SYNC_TMPDIR}/${name}.out"
    [ -f "${SYNC_TMPDIR}/${name}.result" ] && RESULTS+=("$(cat "${SYNC_TMPDIR}/${name}.result")")
    [ -f "${SYNC_TMPDIR}/${name}.error" ] && HAS_ERROR=1
done

fi  # ENABLE_REPO_SYNC gate (step 3)

# --- 第 4 步：汇总 ---
if [ "${ENABLE_REPO_SYNC:-true}" = "false" ]; then
    echo "========================================="
    echo "[4/6] 汇总"
    echo "========================================="
    echo ""
    if [ "${CFG_CONFLICT:-0}" -gt 0 ]; then
        echo -e "配置同步：${GREEN}${CFG_SYNCED:-0} 已同步${NC} · ${CFG_SKIPPED:-0} 跳过 · ${YELLOW}${CFG_CONFLICT:-0} 冲突待处理${NC}"
    else
        echo -e "配置同步：${GREEN}${CFG_SYNCED:-0} 已同步${NC} · ${CFG_SKIPPED:-0} 跳过"
    fi
else
    echo "========================================="
    echo "[4/6] 汇总"
    echo "========================================="

    # 分类
    declare -a FAIL_ITEMS=()
    declare -a ACTION_ITEMS=()
    declare -a NOOP_ITEMS=()

    for RESULT in "${RESULTS[@]}"; do
        IFS='|' read -r NAME REPO_STATUS <<< "$RESULT"
        if [ -f "${SYNC_TMPDIR}/${NAME}.error" ]; then
            FAIL_ITEMS+=("$NAME|$REPO_STATUS")
        elif [ "$REPO_STATUS" = "无改动" ] || [ "$REPO_STATUS" = "已在第 2 步同步" ]; then
            NOOP_ITEMS+=("$NAME|$REPO_STATUS")
        else
            ACTION_ITEMS+=("$NAME|$REPO_STATUS")
        fi
    done

    # 显示一组仓库
    print_group() {
        local SYMBOL="$1"
        local COLOR="$2"
        local LABEL="$3"
        shift 3
        local ITEMS=("$@")

        [ ${#ITEMS[@]} -eq 0 ] && return

        echo ""
        echo -e "${COLOR}${LABEL}${NC}"
        for ITEM in "${ITEMS[@]}"; do
            IFS='|' read -r NAME REPO_STATUS <<< "$ITEM"
            REPO_STATUS="${REPO_STATUS% - 需要 Claude 处理}"
            echo -e "  ${COLOR}${SYMBOL}${NC} ${NAME}  ${COLOR}${REPO_STATUS}${NC}"
        done
    }

    # 按优先级输出：失败 → 已同步 → 无变化
    print_group "✗" "$RED"   "失败 (${#FAIL_ITEMS[@]})"     "${FAIL_ITEMS[@]}"
    print_group "✓" "$GREEN" "已同步 (${#ACTION_ITEMS[@]})" "${ACTION_ITEMS[@]}"
    print_group "·" "$GRAY"   "无变化 (${#NOOP_ITEMS[@]})"   "${NOOP_ITEMS[@]}"

    # 统计摘要
    TOTAL=${#RESULTS[@]}
    N_FAIL=${#FAIL_ITEMS[@]}
    N_ACTION=${#ACTION_ITEMS[@]}
    N_NOOP=${#NOOP_ITEMS[@]}

    echo ""
    if [ $N_FAIL -gt 0 ]; then
        echo -e "合计 ${TOTAL} 个仓库：${GREEN}${N_ACTION} 成功${NC} · ${RED}${N_FAIL} 失败${NC} · ${N_NOOP} 无变化"
    else
        echo -e "合计 ${TOTAL} 个仓库：${GREEN}${N_ACTION} 成功${NC} · ${N_NOOP} 无变化"
    fi
fi

# --- Handoff banner 辅助函数 ---
print_handoff_banner() {
    local title="$1" content="$2"
    echo ""
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW} HANDOFF: ${title}${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    echo "$content"
    echo -e "${YELLOW}=========================================${NC}"
}

# --- 第 5 步：Handoff 检测 ---
echo ""
echo "[5/6] Handoff 检测..."

    # Auto-migrate HANDOFF.md to registry format (idempotent)
    if [ -f "$HANDOFF_FILE" ]; then
        python "$HANDOFF_PY" migrate "$HANDOFF_FILE_PY" >/dev/null 2>&1 || true
    fi

if [ ! -f "$HANDOFF_FILE" ]; then
    echo -e "${RED}警告：HANDOFF.md 不存在（pull 失败或文件损坏？）${NC}"
else
    HANDOFF_READY=0

    if ! get_machine_name; then
        # Case 1: .machine-name 不存在
        echo -e "${YELLOW}未找到 .machine-name，需要设置设备名称。${NC}"

        while true; do
            read -p "请输入本设备的名称（如 G16、X1C），留空跳过：" INPUT_NAME
            INPUT_NAME=$(echo "$INPUT_NAME" | tr -d '\r\n')

            if [ -z "$INPUT_NAME" ]; then
                echo "已跳过，下次 sync 会再次询问。"
                break
            fi

            if [ "$(handoff_section_exists "$INPUT_NAME")" = "no" ]; then
                # Case 1A: 新名字，不存在于 HANDOFF.md
                read -p "新设备 [$INPUT_NAME]，是否添加到 HANDOFF.md？(y/n) " CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy] ]]; then
                    echo "$INPUT_NAME" > "${SCRIPT_DIR}/.machine-name"
                    register_handoff_device "$INPUT_NAME"
                    MACHINE_NAME="$INPUT_NAME"
                    HANDOFF_READY=1
                else
                    echo "已跳过，下次 sync 会再次询问。"
                fi
                break
            else
                # Case 1B: 名字已被注册 — 拒绝重复，防止身份冲突
                echo -e "${RED}✗ [$INPUT_NAME] 已被其他设备注册，请选择其他名称。${NC}"
                continue
            fi
        done
    else
        # Case 2: .machine-name 存在
        if [ "$(handoff_section_exists "$MACHINE_NAME")" = "yes" ]; then
            # Case 2A: 正常流程
            HANDOFF_READY=1
        else
            # Case 2B: 文件存在但 section 不在 HANDOFF.md 中
            echo -e "${YELLOW}设备 [$MACHINE_NAME] 未在 HANDOFF.md 中注册。${NC}"
            read -p "是否添加？(y/n) " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy] ]]; then
                register_handoff_device "$MACHINE_NAME"
                HANDOFF_READY=1
            else
                echo -e "${YELLOW}设备 [$MACHINE_NAME] 未在 handoff 设备列表中，handoff 功能不可用。${NC}"
            fi
        fi
    fi

    # Check ANY tasks (always, regardless of registration)
    ANY_PENDING=$(handoff_get_pending "ANY" 2>/dev/null)
    if [ -n "$ANY_PENDING" ]; then
        print_handoff_banner "全局任务 (ANY)" "$ANY_PENDING"
    fi

    # Check device-specific tasks (only when registered)
    if [ $HANDOFF_READY -eq 1 ]; then
        DEVICE_PENDING=$(handoff_get_pending "$MACHINE_NAME" 2>/dev/null)
        if [ -n "$DEVICE_PENDING" ]; then
            print_handoff_banner "$MACHINE_NAME 专属任务" "$DEVICE_PENDING"
        fi
    fi

    # --- sync skill 触发信号：有待办任务时输出标准关键词 ---
    if [ -n "$ANY_PENDING" ] || [ -n "${DEVICE_PENDING:-}" ]; then
        echo "HANDOFF: Pending tasks detected"
    fi

    # Summary
    if [ -z "$ANY_PENDING" ] && { [ $HANDOFF_READY -eq 0 ] || [ -z "$DEVICE_PENDING" ]; }; then
        echo "无待办 handoff 任务。"
    fi
fi

# --- 第 6 步：提交并推送 dotfiles（如果有改动）---
echo ""
echo "[6/6] 检查 dotfiles 是否需要推送..."

if [ -d "$DOTFILES_DIR" ]; then
    if cd "$DOTFILES_DIR"; then
        DOTFILES_STATUS=$(git status --porcelain)
        if [ -n "$DOTFILES_STATUS" ]; then
            if sync_commit_push "dotfiles"; then
                echo -e "${GREEN}dotfiles 已提交并推送${NC}"
            fi
        else
            echo "dotfiles 无改动"
        fi
    else
        echo -e "${RED}无法进入 dotfiles 目录（step 6）${NC}" >&2
        HAS_ERROR=1
    fi
fi

if [ $HAS_ERROR -ne 0 ]; then
    echo ""
    echo -e "${YELLOW}有仓库处理失败，建议使用 Claude Code /sync 处理。${NC}"
    exit 1
fi

# --- Repo sync disabled hint ---
if [ "${ENABLE_REPO_SYNC:-true}" = "false" ]; then
    HINT_FILE="${SCRIPT_DIR}/.repo_sync_hint_count"
    hint_count=0
    if [ -f "$HINT_FILE" ]; then
        hint_count=$(tr -d '\r\n' < "$HINT_FILE")
        if ! [[ "$hint_count" =~ ^[0-9]+$ ]]; then hint_count=0; fi
    fi
    if [ "$hint_count" -lt 3 ]; then
        echo ""
        echo "[Tip] Project repo sync is disabled. Run 'bash sync.sh repo-sync enable' to turn it on."
        hint_count=$((hint_count + 1))
        echo "$hint_count" > "$HINT_FILE"
    fi
fi

echo ""
echo "全部完成！"
exit 0
