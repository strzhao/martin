#!/bin/bash
# kanban_card.sh — contrib 域建卡薄封装（T1 契约钉死，T3/T4/T5 复用地基）
#
# 用法:
#   kanban_card.sh create --kind <scan|mail|radar|deepcheck|digest>
#                 --title <t> --body-file <path> [--priority N] [--json-out <path>]
#
# 输出: stdout 一行归一化 JSON {"id":"...","status":"..."}（两键，jq -c 生成）；
#       --json-out <path> 同时落盘该行。失败 exit 1 + stderr 原因。
#
# 内部契约（设计钉死）:
#   - 一律 env -u 三个 ANTHROPIC_* 变量调 hermes（CC shell env 劫持防御）
#   - --assignee contrib --idempotency-key <kind>-<YYYYMMDD-HHMMSS> --max-retries 2 --json
#   - 上游 create --json 输出为 indent=2 全字段 dict → helper 归一化为 {id,status} 两键，
#     契约不建立在上游输出形态上
#   - 卡终态闭集锚定上游 VALID_STATUSES（done/blocked/...），本 helper 不产出也不消费 failed 字面量
# seam:
#   HERMES_BIN        缺省 hermes（PATH 前置 $HOME/.local/bin:/opt/homebrew/bin，launchd 极简 PATH 兼容）
#   CONTRIB_DATA_DIR  --json-out 相对路径的落盘基准感知由调用方负责；本脚本不写其他产物
set -euo pipefail

HERMES_BIN="${HERMES_BIN:-hermes}"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

fail() {
  echo "kanban_card: $1" >&2
  exit 1
}

create_card() {
  local kind="" title="" body_file="" priority="" json_out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --priority) priority="${2:-}"; shift 2 ;;
      --json-out) json_out="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "$kind" && -n "$title" && -n "$body_file" ]] || usage
  case "$kind" in
    scan|mail|radar|deepcheck|digest) : ;;
    *) fail "非法 --kind: ${kind}（闭集 scan|mail|radar|deepcheck|digest）" ;;
  esac
  [[ -f "$body_file" ]] || fail "body 文件不存在: $body_file"
  if [[ -n "$priority" ]] && ! printf '%s' "$priority" | grep -qE '^[0-9]+$'; then
    fail "--priority 须为非负整数: $priority"
  fi

  # launchd 极简 PATH 兼容（同 run-watch 探测口径）
  PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
  export PATH

  local idem_key resp rc=0 normalized
  idem_key="${kind}-$(date +%Y%m%d-%H%M%S)"
  resp="$(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
      "$HERMES_BIN" kanban create "$title" \
      --body "$(cat "$body_file")" \
      --assignee contrib \
      --idempotency-key "$idem_key" \
      --max-retries 2 \
      ${priority:+--priority "$priority"} \
      --json 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    fail "hermes kanban create 失败（exit=${rc}: ${resp:0:200}）"
  fi
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
    # T2 范围：hermes 健康探测（结构预留，本任务不实现）
    fail "healthcheck 子命令属 T2 范围，尚未实现"
    ;;
  *)
    usage
    ;;
esac
