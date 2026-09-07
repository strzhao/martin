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

# ---------------- scan_gate.sh ----------------
t_case "scan_gate: 路径/命令 seam"
seam_in scan_gate.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in scan_gate.sh 'DATA="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"'
seam_in scan_gate.sh 'CURSOR="$DATA/scan-cursor.json"'
seam_in scan_gate.sh 'PENDING="$DATA/pending-hits.json"'
seam_in scan_gate.sh 'GH_BIN="${GH_BIN:-gh}"'
seam_in scan_gate.sh '"$GH_BIN" api'

# ---------------- deep_check_gate.sh ----------------
t_case "deep_check_gate: 路径 seam"
seam_in deep_check_gate.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in deep_check_gate.sh 'CONFIG="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}/config.json"'
seam_in deep_check_gate.sh 'TARGET_FILE="${DEEPCHECK_TARGET_FILE:-/tmp/.deepcheck-target}"'
seam_in deep_check_gate.sh 'LOCK="${DEEPCHECK_LOCK:-/tmp/contrib-deepcheck.lock}"'
seam_in deep_check_gate.sh 'RQ="$MARTIN/scripts/contrib/rq.sh"'
seam_in deep_check_gate.sh 'LOG="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}/logs/deepcheck.log"'

# ---------------- deep-check.sh ----------------
t_case "deep-check: 路径 seam"
seam_in deep-check.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in deep-check.sh 'CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"'
seam_in deep-check.sh 'TARGET_FILE="${DEEPCHECK_TARGET_FILE:-/tmp/.deepcheck-target}"'
seam_in deep-check.sh 'LOCK="${DEEPCHECK_LOCK:-/tmp/contrib-deepcheck.lock}"'
seam_in deep-check.sh 'RQ="$MARTIN/scripts/contrib/rq.sh"'
seam_in deep-check.sh 'NOTIFY="$MARTIN/scripts/contrib/notify.sh"'

t_case "deep-check: claude seam（env 优先，空则现有两级探测）"
seam_in deep-check.sh 'CLAUDE_BIN="${CLAUDE_BIN:-}"'

t_case "deep-check: 模型 pin + 阶段超时 seam（09-06 深检挂死实证回归）"
seam_in deep-check.sh 'MODEL_PIN="${CLAUDE_MODEL_PIN:-}"'
seam_in deep-check.sh 'PHASE_TIMEOUT="${DEEPCHECK_PHASE_TIMEOUT:-3600}"'

# ---------------- run-deepcheck.sh ----------------
t_case "run-deepcheck: 路径 seam"
seam_in run-deepcheck.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in run-deepcheck.sh 'CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"'
seam_in run-deepcheck.sh 'LOG="$CONTRIB/logs/deepcheck.log"'
seam_in run-deepcheck.sh 'cd "$MARTIN" || exit 1'

t_case "run-deepcheck: 整壳超时 seam（09-06 失收尸永挂实证回归）"
seam_in run-deepcheck.sh 'orch_to="${DEEPCHECK_ORCH_TIMEOUT:-14400}"'

# ---------------- run-watch.sh ----------------
t_case "run-watch: 路径 seam"
seam_in run-watch.sh 'MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"'
seam_in run-watch.sh 'CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"'
seam_in run-watch.sh 'LOG="$CONTRIB/logs/launchd.log"'
seam_in run-watch.sh 'LOCK="${WATCH_LOCK:-/tmp/contrib-watch.lock}"'

t_case "run-watch: claude seam + maybe_radar 抽取"
seam_in run-watch.sh 'CLAUDE_BIN="${CLAUDE_BIN:-}"'
seam_in run-watch.sh 'maybe_radar() {'
seam_in run-watch.sh 'local hour="${1:-$(date +%H)}"'

t_case "run-watch: 模型 pin + 阶段超时 seam（09-06 同款挂死模式预防）"
seam_in run-watch.sh 'MODEL_PIN="${CLAUDE_MODEL_PIN:-}"'
seam_in run-watch.sh 'WATCH_PHASE_TIMEOUT="${WATCH_PHASE_TIMEOUT:-2700}"'

t_finish
