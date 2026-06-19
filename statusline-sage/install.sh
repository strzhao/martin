#!/usr/bin/env bash
# =============================================================================
# install.sh — statusline-sage 一键安装器
# -----------------------------------------------------------------------------
# 做三件事：
#   1. 检查依赖（bash / jq / git / curl）
#   2. 复制 statusline-sage.sh 到 ~/.claude/ 并赋可执行权限
#   3. 在 ~/.claude/settings.json 写入 statusLine 配置（自动备份原文件）
# 特性：幂等可重复运行；不动旧的 statusline-*.sh 脚本，仅切换引用。
# 兼容：macOS bash 3.2
# 用法：bash install.sh
# =============================================================================
set -euo pipefail

_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCRIPT_SRC="$_SRC_DIR/statusline-sage.sh"
_DEST="${HOME}/.claude/statusline-sage.sh"
_SETTINGS="${HOME}/.claude/settings.json"
_CLAUDE_DIR="${HOME}/.claude"

# 用 sage 色彩做提示（与 statusline 一致）
_green()  { printf '\033[38;2;58;125;104m%s\033[0m' "$1"; }
_amber()  { printf '\033[38;2;212;146;10m%s\033[0m' "$1"; }
_smoke()  { printf '\033[38;2;143;143;141m%s\033[0m' "$1"; }

echo "$(_green '▸ statusline-sage 安装器')"

# ---------- 1. 依赖检查 ----------
echo "$(_smoke '▸ 检查依赖...')"
_missing=()
for _dep in bash jq git curl; do
  command -v "$_dep" >/dev/null 2>&1 || _missing+=("$_dep")
done
if [ "${#_missing[@]}" -gt 0 ]; then
  echo "$(_amber '✗ 缺少依赖'): ${_missing[*]}"
  echo "  macOS 安装: brew install ${_missing[*]}"
  exit 1
fi
echo "  $(_green '✓') 依赖齐全 (bash/jq/git/curl)"

# ---------- 2. 复制脚本 ----------
echo "$(_smoke '▸ 安装脚本 → ')$_DEST"
[ -f "$_SCRIPT_SRC" ] || { echo "$(_amber '✗ 找不到') $_SCRIPT_SRC"; exit 1; }
mkdir -p "$_CLAUDE_DIR"
cp -f "$_SCRIPT_SRC" "$_DEST"
chmod +x "$_DEST"
echo "  $(_green '✓') 已安装"

# ---------- 3. 配置 settings.json ----------
echo "$(_smoke '▸ 配置 ')$_SETTINGS"
[ -f "$_SETTINGS" ] || printf '{}\n' > "$_SETTINGS"

# 备份原配置（幂等：每次安装都留一份带时间戳的备份）
_BACKUP="$_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp -f "$_SETTINGS" "$_BACKUP"
echo "  $(_smoke '备份') → $_BACKUP"

# 幂等写入 statusLine（padding:0 让状态栏更紧凑，可手动改为 1/2）
_CMD="bash $_DEST"
_tmp="$(mktemp)"
if jq --arg cmd "$_CMD" \
  '.statusLine = {"type":"command","command":$cmd,"padding":0}' \
  "$_SETTINGS" > "$_tmp" 2>/dev/null; then
  mv -f "$_tmp" "$_SETTINGS"
else
  rm -f "$_tmp"
  echo "$(_amber '✗ 写入 settings.json 失败，请检查 JSON 格式')"
  exit 1
fi
echo "  $(_green '✓') statusLine.command = $_CMD"

# ---------- 完成 ----------
echo ""
echo "$(_green '✓ 安装完成')"
echo ""
echo "$(_smoke '生效方式:')"
echo "  · 新开 Claude Code 会话即可生效"
echo "  · 当前会话可执行 /statusline 重载"
echo ""
echo "$(_smoke 'GLM token limit:')"
echo "  · 首次渲染同步获取（约 0.5-1s），之后 60s 缓存 + 后台静默刷新"
echo "  · 缓存文件: ${_CLAUDE_DIR}/.statusline-sage-quota.json"
echo "  · 强制刷新: rm ${_CLAUDE_DIR}/.statusline-sage-quota.json"
echo ""
echo "$(_smoke '卸载:') 删除 ${_DEST}，并从 ${_SETTINGS} 移除 .statusLine 字段"
echo "$(_smoke '旧脚本保留:') 原 ~/.claude/statusline-avit.sh / statusline-command.sh 未被删除，可自行清理"
