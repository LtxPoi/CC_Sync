#!/bin/bash
# lib/common.sh — 三脚本共享的基础函数和常量
# 使用前必须设置 SCRIPT_DIR 变量

# --- 防重复 source ---
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# --- 前置检查 ---
if [ -z "$SCRIPT_DIR" ] || [ ! -d "$SCRIPT_DIR" ]; then
    echo "错误：SCRIPT_DIR 未设置或不是有效目录（当前值：'${SCRIPT_DIR:-}'）" >&2
    return 1
fi

# --- 颜色常量 ---
# GREEN/YELLOW/GRAY are this lib's public API — used by the scripts that source
# common.sh, not within this file — so SC2034 "unused" is a false positive here.
# (RED / NC are used directly below and in helpers, so they aren't flagged.)
RED='\033[0;31m'
# shellcheck disable=SC2034
GREEN='\033[0;32m'
# shellcheck disable=SC2034
YELLOW='\033[1;33m'
NC='\033[0m'
# shellcheck disable=SC2034
GRAY='\033[90m'

# --- 工作区根目录（脚本所在目录的父目录）---
# shellcheck disable=SC2034  # consumed by sync.sh / new-project.sh that source this lib
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- GitHub topic 常量 ---
TOPIC="${TOPIC:-claude-code-workspace}"

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
        # Call cygpath directly (not echo "$(cygpath …)"): the command-sub
        # wrapper discarded cygpath's exit status, so a failure returned rc 0 +
        # empty path silently.
        cygpath -m "$1"
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
# CC 将路径中的 : \ _ / 全部替换为 -，如 D:\workspace\my-project → D--workspace-my-project
# WARNING: Must match Claude Code's internal path hashing. If CC changes its scheme,
# update this function and verify with: ls ~/.claude/projects/
# 已知碰撞：含下划线和斜杠的不同路径会哈希到同一字符串（例：D:/foo_bar/baz 与
# D-/foo/bar/baz 都 → D--foo-bar-baz）。无法在不破坏 CC 兼容的前提下规避；
# sync_memory_dir 的 [ ! -d "$CC_PROJECT_DIR" ] 守卫使错配只表现为静默跳过，
# 而非误写 —— 但理论上若两个 CC 项目同时 hash 到一致目录，memory 会互相覆盖。
compute_cc_hash() {
    local p
    p=$(normalize_path "${1%/}")
    # normalize_path 输出 / 分隔符路径（cygpath -m 模式或手动 /X/... 转换）；
    # 这里替换 ':', '/', '_' 三种字符为 '-'，与 CC 内部哈希算法一致
    echo "$p" | tr ':/_' '-'
}

# --- 自动检测 GitHub 用户名，设置全局变量 GITHUB_USER ---
# 依赖 detect_gh，调用前必须先调用 detect_gh
detect_github_user() {
    if [ -n "${GITHUB_USER:-}" ]; then
        return 0
    fi
    if [ -z "${GH:-}" ]; then
        echo -e "${RED}内部错误：detect_github_user 前必须先调用 detect_gh${NC}" >&2
        return 1
    fi
    GITHUB_USER=$("$GH" api user -q .login 2>/dev/null)
    if [ -z "$GITHUB_USER" ]; then
        echo -e "${RED}错误：无法获取 GitHub 用户名。请运行 gh auth login。${NC}" >&2
        return 1
    fi
}

# --- 跨平台 mktemp -d（兼容 GNU 和 BSD）---
safe_mktemp() {
    mktemp -d 2>/dev/null || mktemp -d -t 'cc-tmp.XXXXXX'
}

# --- 跨平台 stat（兼容 GNU coreutils 和 BSD/macOS）---
_stat_field() {
    stat -c"$1" "$3" 2>/dev/null || stat -f"$2" "$3" 2>/dev/null || return 1
}

# file_mtime <path> — 输出文件修改时间（Unix epoch 秒）
file_mtime() { _stat_field %Y %m "$1"; }

# file_size <path> — 输出文件大小（字节）
file_size()  { _stat_field %s %z "$1"; }

# --- Safe backup helpers ---
# _safe_bak_path computes a non-clobbering .bak path WITHOUT performing I/O.
# Prefers $1.bak; on collision, falls back to $1.bak.<epoch-seconds>; if THAT
# fallback is also occupied (rare same-second collision, OR an adversary with
# write access to the directory pre-placed a symlink at the predicted epoch
# path to misdirect downstream cp/mv), refuses with rc 1 + stderr message.
#
# Use this when the caller needs to DISPLACE $1 (mv) rather than snapshot it.
# _safe_bak below uses it internally for the snapshot (cp) case. Lives in
# common.sh so module-manager.sh's cmd_update can share the same path-
# computation logic as sync.sh's prune-apply / CONFLICT-resolve sites.
_safe_bak_path() {
    local target="$1"
    local bak="${target}.bak"
    if [ -e "$bak" ] || [ -L "$bak" ]; then
        bak="${target}.bak.$(date +%s 2>/dev/null || echo $$)"
        # Re-check at the timestamp fallback path. The fallback is
        # predictable (epoch seconds + target), so an attacker with write
        # access to this directory (e.g., teammate push to the dotfiles
        # repo) can pre-place a symlink at <target>.bak.<predicted-epoch>
        # to misdirect cp/mv. Refuse rather than allowing the downstream
        # I/O to follow the symlink.
        if [ -e "$bak" ] || [ -L "$bak" ]; then
            echo "_safe_bak_path: 备份回退路径已被占用（疑似预置符号链接），无法分配：$bak" >&2
            return 1
        fi
    fi
    printf '%s' "$bak"
}

# _safe_bak creates a sibling .bak COPY of $1 via cp -p. Path is computed by
# _safe_bak_path (.bak primary, .bak.<epoch> fallback with collision refusal).
# Prints the bak path that was created on stdout. Returns rc 0 on success,
# rc 1 on failure (no safe path OR cp failed).
#
# NOTE: when $1 does NOT exist this returns rc 0 with EMPTY stdout
# (nothing to back up). A caller doing `bak=$(_safe_bak x) && mv … "$bak"` would
# then operate on an empty path with a success rc — callers MUST guard for empty
# output, not just the return code, before using the result.
#
# Use when you need a snapshot of $1 before destructive in-place overwrite.
# Callers that need to displace $1 (mv) should call _safe_bak_path directly
# and perform their own mv with the returned path.
_safe_bak() {
    local target="$1"
    [ -e "$target" ] || return 0
    local bak
    bak=$(_safe_bak_path "$target") || return 1
    # `--` defends against $target whose name starts with `-` being parsed
    # as a cp option.
    if cp -p -- "$target" "$bak"; then
        printf '%s' "$bak"
        return 0
    fi
    return 1
}
