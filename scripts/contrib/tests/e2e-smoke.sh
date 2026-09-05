#!/bin/bash
# e2e-smoke.sh — e2e 冒烟独立入口：mktemp 沙箱 + 影子 stub 全链路（闸门→队列→推送→账本）
#
# 末行 JSON：{"transport_calls":N,"ledger_appends":N,"queue_transitions":N,
#            "prefix_preserved":bool,"all_lines_valid_json":bool,"stub_log":"<path>"[,"sandbox":"<path>"]}
# 旋钮：
#   E2E_STUB_FAIL=<cmd>  令指定 stub（hermes/claude/tunnel/osascript/gh）非零退出 → 冒烟必须非零退出
#                        且账本零新增成功记录（场景3.P2 / 场景7.P3）
#   E2E_KEEP=1           保留沙箱并在 JSON 报 sandbox 路径（场景3.P3 防伪对照 / 7.P3 账本计数）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$HERE"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

FAIL_REASON=""
smoke_fail() { FAIL_REASON="${1:-unknown}"; }

sb_new >/dev/null 2>&1 || { echo '{"error":"sandbox-fail"}'; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"
TODAY="$(date +%F)"

# ---- 前置：既有已推行（字节级前缀锚点，python3 重序列化格式——与 flush 的账本重写格式一致）----
PREFIX_LINE="$(python3 -c 'import json; print(json.dumps({"ts": "2026-01-01T00:00:00+08:00", "class": "probe-premise-dead", "key": "smoke-prefix", "channel": "contrib", "summary": "既有已推行（前缀锚点）", "pushed": True, "attempts": 0, "pushed_at": None}, ensure_ascii=False))')"
printf '%s\n' "$PREFIX_LINE" >>"$EVENTS_FILE"

# ---- 链路：队列种子 → run-deepcheck（gate→深检→审批卡）→ 事件+flush（告警链）----
sb_seed_queue_item "rq-$(date +%Y%m%d)-7001" 7001 probe queued 40
sb_notify event own-pr-activity --key smoke-alert --summary "radar：自有 PR 收到维护者评论" >/dev/null 2>&1

STUB_FAIL_KNOB=""
if [[ -n "${E2E_STUB_FAIL:-}" ]]; then
  case "$E2E_STUB_FAIL" in
    hermes|claude|tunnel|osascript|gh) STUB_FAIL_KNOB="STUB_$(printf '%s' "$E2E_STUB_FAIL" | tr '[:lower:]' '[:upper:]')_FAIL=1" ;;
    *) smoke_fail "E2E_STUB_FAIL 非法值: $E2E_STUB_FAIL" ;;
  esac
fi

# 传输链（deep-check 审批卡 + flush 告警），STUB_FAIL 注入到整条链
if [[ -z "$FAIL_REASON" ]]; then
  sb_run -e "NOTIFY_DRY_RUN=false" ${STUB_FAIL_KNOB:+"-e"} ${STUB_FAIL_KNOB:+"$STUB_FAIL_KNOB"} \
    'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"
bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
fi

# ---- 计数器 ----
transport_calls="$(awk -F'|' 'NF >= 1 && $1 != "" { c++ } END { printf "%d", c + 0 }' "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
ledger_lines="$(grep -c . "$EVENTS_FILE" 2>/dev/null || true)"
ledger_appends=$(( ledger_lines - 1 ))   # 减去前缀锚点行
queue_transitions="$(jq -r '[.items[].history | length] | add // 0' "$QUEUE_FILE" 2>/dev/null || echo 0)"

# prefix_preserved：既有行字节级不变（未被 flush 重写破坏/丢失）
if grep -qF -- "$PREFIX_LINE" "$EVENTS_FILE"; then
  prefix_preserved=true
else
  prefix_preserved=false
  [[ -z "$FAIL_REASON" ]] && smoke_fail "前缀行被破坏（账本重写伤及未批次行）"
fi

# all_lines_valid_json：events 每行 + 队列 + 状态文件全部可解析
all_lines_valid_json=true
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || all_lines_valid_json=false
done <"$EVENTS_FILE"
jq -e . "$QUEUE_FILE" >/dev/null 2>&1 || all_lines_valid_json=false
jq -e . "$STATE_FILE" >/dev/null 2>&1 || all_lines_valid_json=false

# ---- 成功/失败账本判据（场景3.P2：stub 失败 → 冒烟非零退出且零新增成功记录）----
ok_count="$(jq -r --arg d "$TODAY" '[.approvals[$d].ok | to_entries[] | select(.value == true)] | length' "$STATE_FILE" 2>/dev/null || echo 0)"
pushed_count="$(jq -s '[.[] | select(.pushed == true)] | length - 1' "$EVENTS_FILE" 2>/dev/null || echo 0)"  # 减前缀行
fail_count="$(jq -r --arg d "$TODAY" '([.approvals[$d].fail | to_entries[] | select(.value >= 1)] | length)
  + ([inputs | select(.pushed == false and .attempts >= 1)] | length)' "$STATE_FILE" "$EVENTS_FILE" 2>/dev/null || echo 0)"

if [[ -z "$FAIL_REASON" ]]; then
  if [[ -n "${E2E_STUB_FAIL:-}" ]]; then
    # 注毒轮：交付未达成 → 冒烟判失败（场景3.P2：exit!=0）
    smoke_fail "传输 stub $E2E_STUB_FAIL 非零退出 → 交付未达成"
    # 附加账实核验：零新增成功记录 + 至少一条失败记录（场景7.P3 账本按类型计数的数据基础）
    if [[ "$ok_count" != "0" || "$pushed_count" != "0" ]]; then
      smoke_fail "stub $E2E_STUB_FAIL 失败但账本出现成功记录（账面≠送达）"
    fi
    if [[ "$fail_count" -lt 1 ]]; then
      smoke_fail "stub $E2E_STUB_FAIL 失败但账本无失败记录"
    fi
  else
    # 正常轮：≥1 传输、≥1 账本追加、≥1 队列迁移、≥1 成功记录
    [[ "$transport_calls" -ge 1 ]] || smoke_fail "transport_calls=$transport_calls < 1"
    [[ "$ledger_appends" -ge 1 ]] || smoke_fail "ledger_appends=$ledger_appends < 1"
    [[ "$queue_transitions" -ge 1 ]] || smoke_fail "queue_transitions=$queue_transitions < 1"
    [[ "$ok_count" -ge 1 || "$pushed_count" -ge 1 ]] || smoke_fail "零成功记录（审批卡/告警均未送达）"
  fi
fi

# ---- 汇总 JSON（末行）----
sb_json_path="$SB_ROOT/stublog"
sandbox_key=""
if [[ "${E2E_KEEP:-}" == "1" ]]; then
  sandbox_key=",\"sandbox\":\"$SB_ROOT\""
  echo "e2e-smoke: 沙箱保留于 $SB_ROOT" >&2
else
  sb_cleanup
fi

if [[ -z "$FAIL_REASON" && "$all_lines_valid_json" == "true" && "$prefix_preserved" == "true" ]]; then
  exit_code=0
else
  exit_code=1
fi

printf '{"transport_calls":%d,"ledger_appends":%d,"queue_transitions":%d,"prefix_preserved":%s,"all_lines_valid_json":%s,"stub_log":"%s"%s}\n' \
  "$transport_calls" "$ledger_appends" "$queue_transitions" "$prefix_preserved" "$all_lines_valid_json" \
  "$sb_json_path" "$sandbox_key"
if [[ -n "$FAIL_REASON" ]]; then
  echo "e2e-smoke FAIL: $FAIL_REASON" >&2
fi
exit "$exit_code"
