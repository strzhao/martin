#!/bin/bash
# seam-defaults.sh — 静态守卫：每个 seam 的默认值必须与现状硬编码**逐字符一致**（步骤 1 铁律）
# 本文件是「生产行为零改变」的第一道门：任何人改 seam 默认值都会在此 FAIL。
# 断言方式：grep -F 精确行匹配（逐字符），不做任何宽松归一化。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"

source "$TESTS_ROOT/lib/assert.sh"
TARGET="$(tests_scripts_dir "$TARGET_DEFAULT")"
t_init "seam-defaults.sh"

# seam_in <script> <精确行片段> [label] — 该片段必须逐字符出现在脚本中
seam_in() {
  local f="$TARGET/$1" needle="$2" label="${3:-$1}"
  if [[ ! -f "$f" ]]; then
    _fail "$label" "脚本缺失: $f"
    return 0
  fi
  if grep -qF -- "$needle" "$f"; then
    _pass "$label"
  else
    _fail "$label" "未找到逐字符 seam 行: $needle"
  fi
}

# seam_absent_in <script> <精确片段> [label] — 该片段必须不出现在脚本中（撤销/删除守卫）
seam_absent_in() {
  local f="$TARGET/$1" needle="$2" label="${3:-$1}"
  if [[ ! -f "$f" ]]; then
    _fail "$label" "脚本缺失: $f"
    return 0
  fi
  if grep -qF -- "$needle" "$f"; then
    _fail "$label" "已撤销的片段重新出现: $needle"
  else
    _pass "$label"
  fi
}

# ---------------- notify.sh ----------------
t_case "notify: 路径 seam"
seam_in notify.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in notify.sh 'CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"'
seam_in notify.sh 'LOCK="${NOTIFY_LOCK:-/tmp/contrib-notify.lock}"'
seam_in notify.sh 'RQ="$MARTIN/scripts/contrib/rq.sh"'

t_case "notify: 命令 seam"
seam_in notify.sh 'HERMES_BIN="${HERMES_BIN:-hermes}"'
seam_in notify.sh '"$HERMES_BIN" send'
seam_in notify.sh 'OSASCRIPT_BIN="${OSASCRIPT_BIN:-osascript}"'
seam_in notify.sh 'GATEWAY_PROBE_BIN="${GATEWAY_PROBE_BIN:-pgrep}"'

t_case "notify: /tmp 写点 seam"
seam_in notify.sh 'NOTIFY_SEND_LAST="${NOTIFY_SEND_LAST:-/tmp/contrib-send-last.json}"'

t_case "notify: claude seam（env 优先，空则现状探测）"
seam_in notify.sh 'CLAUDE_BIN="${CLAUDE_BIN:-}"'

t_case "notify: source guard"
seam_in notify.sh 'NOTIFY_SOURCE_ONLY'

# ---------------- rq.sh ----------------
t_case "rq: 路径 seam"
seam_in rq.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in rq.sh 'CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"'
seam_in rq.sh 'LOCKDIR="${RQ_LOCKDIR:-/tmp/contrib-rq.lock}"'
seam_in rq.sh 'QUEUE="$CONTRIB/ready-queue.json"'
seam_in rq.sh 'BUDGET="$CONTRIB/budget.json"'
seam_in rq.sh 'CONFIG="$CONTRIB/config.json"'

t_case "rq: 命令 seam"
seam_in rq.sh 'TUNNEL_BIN="${TUNNEL_BIN:-tunnel}"'

t_case "rq: source guard"
seam_in rq.sh 'RQ_SOURCE_ONLY'

t_finish
