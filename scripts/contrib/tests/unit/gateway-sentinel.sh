#!/bin/bash
# gateway-sentinel.sh — Tier U：gateway 存活哨兵（T6）stub 测试矩阵
# 覆盖（T6 契约 3 钉死语义）：
#   ① pgrep 活（rc0） → 零动作（零 event 零账本写）
#   ② pgrep 死（rc1） → 唯一告警信号：notify event pipeline-failure --key <日期>-gateway-down
#      （日级幂等：同日重跑不重复入账）
#   ③ 探测自身异常（rc≥2）→ 只日志，绝不告警（防探针故障误报）
#   ④ 账本隔离：event 只落 CONTRIB_DATA_DIR/events.jsonl（notify event 本地渠道，零传输调用）
# 全部经 CONTRIB_DATA_DIR/GATEWAY_PROBE_BIN stub 沙箱隔离，零真实 pgrep/notify 副作用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "gateway-sentinel.sh"

[[ -f "$CONTRIB_TEST_TARGET/gateway_sentinel.sh" ]] || { echo "FATAL: 找不到 $CONTRIB_TEST_TARGET/gateway_sentinel.sh"; exit 1; }

run_sentinel() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    'bash "$MARTIN_DIR/scripts/contrib/gateway_sentinel.sh"'
}

events_count() {
  jq -s '[.[] | select(.class == "pipeline-failure")] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

t_case "哨兵: gateway 活（pgrep rc0）→ 零动作零 event（探测被记录）"
sb_new >/dev/null 2>&1
run_sentinel >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(events_count)" "0" "活 → 零告警入账"
[[ -s "$CONTRIB_TEST_STUB_LOG/probe.log" ]] && _pass "探测确实发生（stub probe.log 有记录）" \
  || _fail "探测确实发生（stub probe.log 有记录）" "probe.log 缺失——哨兵可能没跑探针"

t_case "哨兵: gateway 死（pgrep rc1）→ event 入账 + key 日级幂等"
sb_new >/dev/null 2>&1
run_sentinel "STUB_PGREP_DOWN=1" >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(events_count)" "1" "死 → pipeline-failure 恰 1 条"
key="$(jq -rs '[.[] | select(.class == "pipeline-failure")][0].key // ""' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null)"
if printf '%s' "$key" | grep -qE "$(date +%F)-gateway-down"; then
  _pass "event key=<日期>-gateway-down（日级幂等锚）"
else
  _fail "event key=<日期>-gateway-down（日级幂等锚）" "实得 key=[$key]"
fi
# 同日重跑：幂等不重复
run_sentinel "STUB_PGREP_DOWN=1" >/dev/null 2>&1
assert_eq "$(events_count)" "1" "同日重跑幂等（--key 去重，不重复入账）"

t_case "哨兵: 探测自身异常（pgrep rc3）→ 只日志零告警"
sb_new >/dev/null 2>&1
run_sentinel "STUB_PGREP_ERR=3" >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(events_count)" "0" "探针异常 → 零告警（防探针故障误报）"
assert_file_contains "$SB_ROOT/contrib-data/logs/sentinel.log" "探测异常" "异常落日志（可诊断）"

t_case "哨兵: 零传输调用（event 是本地账本动作，不触 hermes/tunnel/claude）"
sb_new >/dev/null 2>&1
run_sentinel "STUB_PGREP_DOWN=1" >/dev/null 2>&1
assert_stub_not_called hermes "零 hermes 调用"
assert_stub_not_called tunnel "零 tunnel 调用"
assert_stub_not_called claude "零 claude 调用"

t_finish
