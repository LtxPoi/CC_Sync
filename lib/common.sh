#!/bin/bash
# lib/common.sh — 三脚本共享的基础函数和常量
# 使用前必须设置 SCRIPT_DIR 变量

# --- 防重复 source ---
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# --- 前置检查 ---
if [ -z "$SCRIPT_DIR" ]; then
    echo "错误：source lib/common.sh 前必须设置 SCRIPT_DIR" >&2
    return 1
fi

# --- 颜色常量 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
GRAY='\033[90m'

# --- 工作区根目录（当前项目的父目录）---
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- GitHub topic 常量 ---
TOPIC="claude-code-workspace"

# --- cygpath 可用性缓存（脚本生命周期内不变）---
if command -v cygpath &>/dev/null; then
    _HAS_CYGPATH=1
else
    _HAS_CYGPATH=0
fi

# --- 路径标准化（Git Bash /c/... → C:/... 供 Python 和跨平台使用）---
normalize_path() {
    local p
    if [ "$_HAS_CYGPATH" -eq 1 ]; then
        echo "$(cygpath -m "$1")"
    else
        p="$1"
        if [[ "$p" =~ ^/([a-zA-Z])/ ]]; then
            p="${BASH_REMATCH[1]^^}:/${p:3}"
        fi
        echo "$p"
    fi
}

# --- 自动检测 gh CLI 路径，设置全局变量 GH ---
# 如果 GH 已设置且非空，跳过检测
detect_gh() {
    if [ -n "${GH:-}" ]; then
        return 0
    fi
    if command -v gh &>/dev/null; then
        GH="gh"
    elif [ -f "/c/Program Files/GitHub CLI/gh.exe" ]; then
        GH="/c/Program Files/GitHub CLI/gh.exe"
    else
        echo -e "${RED}错误：找不到 gh 命令。请安装 GitHub CLI。${NC}" >&2
        return 1
    fi
}

# --- 读取本机设备名（.machine-name），不 fallback ---
# 成功返回 0 并设置 MACHINE_NAME，失败返回 1
get_machine_name() {
    local name_file="${SCRIPT_DIR}/.machine-name"
    if [ ! -f "$name_file" ]; then
        return 1
    fi
    MACHINE_NAME=$(tr -d '\r\n' < "$name_file")
    if [ -z "$MACHINE_NAME" ]; then
        return 1
    fi
    return 0
}

# --- 计算 CC 项目哈希（绝对路径 → ~/.claude/projects/ 下的目录名）---
# CC 将路径中的 : \ _ / 全部替换为 -，如 D:\Claude_Code\CC_Sync → D--Claude-Code-CC-Sync
compute_cc_hash() {
    local p
    p=$(normalize_path "${1%/}")
    # normalize_path 已将 \ 转为 /，替换 : / _ 三种字符为 -
    echo "$p" | tr ':/_' '-'
}

# --- 自动检测 GitHub 用户名，设置全局变量 GITHUB_USER ---
# 依赖 detect_gh，调用前必须先调用 detect_gh
detect_github_user() {
    if [ -n "${GITHUB_USER:-}" ]; then
        return 0
    fi
    GITHUB_USER=$("$GH" api user -q .login 2>/dev/null)
    if [ -z "$GITHUB_USER" ]; then
        echo -e "${RED}错误：无法获取 GitHub 用户名。请运行 gh auth login。${NC}" >&2
        return 1
    fi
}

# --- 跨平台 mktemp -d（兼容 GNU 和 BSD）---
safe_mktemp() {
    mktemp -d 2>/dev/null || mktemp -d -t 'cc-tmp'
}

# --- 跨平台 stat（兼容 GNU coreutils 和 BSD/macOS）---
_stat_field() {
    stat -c"$1" "$3" 2>/dev/null || stat -f"$2" "$3" 2>/dev/null
}

# file_mtime <path> — 输出文件修改时间（Unix epoch 秒）
file_mtime() { _stat_field %Y %m "$1"; }

# file_size <path> — 输出文件大小（字节）
file_size()  { _stat_field %s %z "$1"; }
