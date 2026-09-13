#!/bin/bash
# kanban_card.sh — contrib 域建卡薄封装（T1 契约钉死，T3/T4/T5 复用地基；T6 加 board seam）
#
# 用法:
#   kanban_card.sh create --kind <scan|mail|radar|deepcheck|digest|upstream>
#                 --title <t> --body-file <path> [--priority N] [--json-out <path>]
#                 [--idempotency-key <k>] [--board <slug>]
#   kanban_card.sh healthcheck
#
# 输出: stdout 一行归一化 JSON {"id":"...","status":"..."}（两键，jq -c 生成）；
#       --json-out <path> 同时落盘该行。失败 exit 1 + stderr 原因。
# healthcheck: stdout 一行 OK 或 FAIL <原因>；exit 0=健康 1=单次失败（emit -hermes-down
#       事件）3=连续>=2 次失败（调用方应跳过主路走 fallback）。down 计数=$CONTRIB/.hermes-down
#       （单整数，仅 healthcheck 读写；口径=「连续探测失败、中间无成功」——不设 TTL 不按天
#       衰减，唯一清零条件=任一次探测成功）。
#
# 内部契约（设计钉死）:
#   - 一律 env -u 三个 ANTHROPIC_* 变量调 hermes（CC shell env 劫持防御）
#   - --assignee contrib --idempotency-key <kind>-<YYYYMMDD-HHMMSS> --max-retries 2 --json
#   - 上游 create --json 输出为 indent=2 全字段 dict → helper 归一化为 {id,status} 两键，
#     契约不建立在上游输出形态上
#   - 卡终态闭集锚定上游 VALID_STATUSES（done/blocked/...），本 helper 不产出也不消费 failed 字面量
#   - hermes 调用统一经 hermes_call：stdout/stderr 分离（stderr 摘要进 fail 消息）+
#     超时包裹（HERMES_TIMEOUT 可注入，create 缺省 60s / healthcheck 缺省 10s；
#     command -v timeout → perl alarm → 直跑三级退化，双 shell 安全）
#   - create 前置 gate（读法 a）：先 healthcheck 探测（计数由探测驱动，create 自身失败
#     不写计数）——exit 0/1 继续建卡，exit 3 跳过（调用方走 fallback）；gate 的 stdout
#     一律路由 stderr，保住「create stdout 恒一行 {id,status}」契约
#   - board seam（T6）：--board 参数 > KANBAN_BOARD env > 空（不 pin）。非空时 --board
#     <slug> 插在 kanban 父级 flag 位置（hermes kanban --board X create …）——**必须**在
#     子命令前，尾部追加=上游 unrecognized arguments 硬失败。空=回落 current-board 解析
#     （=default board，回退态语义零变化）
# seam:
#   HERMES_BIN        缺省 hermes（PATH 前置 $HOME/.local/bin:/opt/homebrew/bin，launchd 极简 PATH 兼容）
#   HERMES_TIMEOUT    hermes 调用超时秒数（缺省 60；healthcheck 缺省 10）
#   KANBAN_BOARD      board pin（空=不 pin；入口 export 本 env 即完成 contrib board 切换，
#                     清空/删除即回退 default board——回退成本一个 env）
#   CONTRIB_DATA_DIR  --json-out 相对路径的落盘基准感知由调用方负责；healthcheck 的
#                     .hermes-down 计数文件与 -hermes-down 事件落在此目录
set -euo pipefail

HERMES_BIN="${HERMES_BIN:-hermes}"
KANBAN_BOARD="${KANBAN_BOARD:-}"
MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
DOWN_FILE="$CONTRIB/.hermes-down"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"

# launchd 极简 PATH 兼容（timeout/perl/jq 探测依赖此 PATH）
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export PATH

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

fail() {
  echo "kanban_card: $1" >&2
  exit 1
}

# hermes_call <secs> <args...> — env -u 三变量 + 统一超时包裹（三级退化）；
# stdout/stderr 分离由调用方负责（调用方以 2>file 捕获 stderr）
hermes_call() {
  local secs="$1"; shift
  local -a pre=()
  if command -v timeout >/dev/null 2>&1; then
    pre=(timeout "$secs")
  elif command -v perl >/dev/null 2>&1; then
    pre=(perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$secs")
  fi
  env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
    ${pre[@]+"${pre[@]}"} "$HERMES_BIN" "$@"
}

# board_args [<显式slug>] → 填充全局 BOARD_ARGS（kanban 父级 flag；参数优先于 env）。
# 空 slug（两处都空）=不 pin，BOARD_ARGS 为空数组。调用形态：kanban ${BOARD_ARGS[@]} <sub> …
BOARD_ARGS=()
board_args() {
  BOARD_ARGS=()
  local b="${1:-$KANBAN_BOARD}"
  if [[ -n "$b" ]]; then
    BOARD_ARGS=(--board "$b")
  fi
}

# down_count → $DOWN_FILE 中的整数（缺失/损坏按 0，自愈）
down_count() {
  local c
  c="$(cat "$DOWN_FILE" 2>/dev/null || true)"
  case "$c" in
    ''|*[!0-9]*) c=0 ;;
  esac
  printf '%s' "$c"
}

# emit_down_event — 首次探测失败告警（--key 日级幂等；notify 缺席不阻塞探测主流程）
emit_down_event() {
  [[ -x "$NOTIFY" ]] || return 0
  bash "$NOTIFY" event pipeline-failure \
    --key "$(date +%F)-hermes-down" \
    --summary "hermes 健康探测首次失败（kanban list 超时/非零）；连续 2 次将跳过建卡走 claude 兜底" \
    >/dev/null 2>&1 || true
}

# run_healthcheck — hermes 可用性探测：stdout 一行 OK | FAIL <原因>；exit 0/1/3（闭集）
run_healthcheck() {
  local secs="${HERMES_TIMEOUT:-10}"
  local resp rc=0 err_file reason=""
  err_file="$(mktemp "${TMPDIR:-/tmp}/kbc-hc.XXXXXX" 2>/dev/null)" || err_file="${TMPDIR:-/tmp}/kbc-hc.$$"
  board_args
  resp="$(hermes_call "$secs" kanban ${BOARD_ARGS[@]+"${BOARD_ARGS[@]}"} list --json 2>"$err_file")" || rc=$?
  reason="$(tail -c 160 "$err_file" 2>/dev/null | tr '\n' ' ')"
  rm -f "$err_file"
  # 热修 09-09：grep -q 提前退出 × pipefail → 大输出（>64KB 管道缓冲）时 printf SIGPIPE
  # 使整条管道 141 被误判失败（生产实锤：卡片列表涨过阈值后 healthcheck 连续误报 hermes
  # down、建卡全停）。改参数展开剥前导空白判首字符，零管道零竞速。
  local _first="" _healthy=1
  if [[ $rc -eq 0 ]]; then
    _first="${resp#"${resp%%[![:space:]]*}"}"   # 剥前导空白（bash 3.2 兼容）
    [[ ${_first:0:1} == "[" ]] && _healthy=0
  fi
  if [[ $_healthy -eq 0 ]]; then
    rm -f "$DOWN_FILE"   # 唯一清零点：任一次探测成功
    echo "OK"
    return 0
  fi
  if [[ $rc -eq 124 || $rc -eq 142 ]]; then
    reason="超时(${secs}s)"
  elif [[ $rc -ne 0 ]]; then
    reason="exit=${rc}${reason:+: ${reason}}"
  else
    reason="输出非 JSON 数组: ${resp:0:120}"
  fi
  mkdir -p "$CONTRIB" 2>/dev/null || true
  local count=$(( $(down_count) + 1 ))
  printf '%s\n' "$count" >"$DOWN_FILE"
  echo "FAIL $reason"
  if [[ $count -eq 1 ]]; then
    emit_down_event
    return 1
  fi
  return 3
}

create_card() {
  local kind="" title="" body_file="" priority="" json_out="" idem_override="" board=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --priority) priority="${2:-}"; shift 2 ;;
      --json-out) json_out="${2:-}"; shift 2 ;;
      # T4：可选覆盖（attempt 级 key，防同 rq-id 重试循环拿回既有卡死锁）；缺省现行为不变
      --idempotency-key) idem_override="${2:-}"; shift 2 ;;
      # T6：board pin（显式参数优先于 KANBAN_BOARD env）
      --board) board="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$kind" && -n "$title" && -n "$body_file" ]] || usage
  case "$kind" in
    scan|mail|radar|deepcheck|digest|upstream) : ;;
    *) fail "非法 --kind: ${kind}（闭集 scan|mail|radar|deepcheck|digest|upstream）" ;;
  esac
  [[ -f "$body_file" ]] || fail "body 文件不存在: $body_file"
  if [[ -n "$priority" ]] && ! printf '%s' "$priority" | grep -qE '^[0-9]+$'; then
    fail "--priority 须为非负整数: $priority"
  fi

  # 前置 gate（读法 a，T2）：healthcheck 探测驱动 down 计数——exit 0 正常建卡；
  # exit 1（首次失败，已 emit -hermes-down）仍继续尝试建卡；exit 3（连续>=2 败）跳过建卡，
  # 调用方走既有 fallback。gate 的 stdout/notify 输出全部路由 stderr。
  local hc_rc=0
  run_healthcheck >&2 || hc_rc=$?
  case "$hc_rc" in
    0) : ;;
    1) echo "kanban_card: hermes 首次探测失败（已告警），仍尝试建卡" >&2 ;;
    *) fail "hermes 连续不可用，跳过建卡（连续 $(down_count) 次探测失败）" ;;
  esac

  local idem_key resp rc=0 normalized err_file err_tail
  idem_key="${idem_override:-${kind}-$(date +%Y%m%d-%H%M%S)}"
  err_file="$(mktemp "${TMPDIR:-/tmp}/kbc-create.XXXXXX" 2>/dev/null)" || err_file="${TMPDIR:-/tmp}/kbc-create.$$"
  board_args "$board"   # --board 必须插在 kanban 与子命令之间（父级 flag 位置，重审 I1）
  resp="$(hermes_call "${HERMES_TIMEOUT:-60}" kanban ${BOARD_ARGS[@]+"${BOARD_ARGS[@]}"} create "$title" \
      --body "$(cat "$body_file")" \
      --assignee contrib \
      --idempotency-key "$idem_key" \
      --max-retries 2 \
      ${priority:+--priority "$priority"} \
      --json 2>"$err_file")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    err_tail="$(tail -c 200 "$err_file" 2>/dev/null | tr '\n' ' ')"
    rm -f "$err_file"
    fail "hermes kanban create 失败（exit=${rc}: ${resp:0:200}${err_tail:+ | stderr: ${err_tail}}）"
  fi
  rm -f "$err_file"
  # 输出归一化：无论上游 dict 形态如何，只吐 {id,status} 两键一行
  normalized="$(printf '%s' "$resp" | jq -c '{id,status}' 2>/dev/null || true)"
  [[ -n "$normalized" ]] || fail "hermes 输出不可解析为 JSON: ${resp:0:200}"
  if [[ "$(printf '%s' "$normalized" | jq -r '.id // empty' 2>/dev/null)" == "" ]]; then
    fail "hermes 输出缺 id 键: ${resp:0:200}"
  fi
  if [[ -n "$json_out" ]]; then
    printf '%s\n' "$normalized" >"$json_out" || fail "json-out 写盘失败: $json_out"
  fi
  printf '%s\n' "$normalized"
}

case "${1:-}" in
  create)
    shift
    create_card "$@"
    ;;
  healthcheck)
    run_healthcheck
    ;;
  *)
    usage
    ;;
esac
