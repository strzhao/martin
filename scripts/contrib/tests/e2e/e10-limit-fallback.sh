#!/bin/bash
# e10-limit-fallback.sh — E10：告警限额 + 失败兜底（osascript 日幂等）
# 契约锚点：flush 防双发（当日 alerts>=max → 拒推 + osascript 兜底）；
# attempts>=3 → osascript 本地提示且同日至多一次（fallback_notice 幂等，场景12.P4）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e10-limit-fallback.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
TODAY="$(date +%F)"

t_case "E10a: 当日限额 3/3 → 拒推 + osascript 兜底 + 事件保留"
sb_notify event own-pr-activity --key e10-limit --summary "限额日的事件" >/dev/null
assert_exit 0 $?
# 时间闸门不 sleep：回拨 state 构造「当日已推 3 条」前置态
jq -c --arg d "$TODAY" '.alerts[$d] = 3' "$STATE_FILE" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
before_hermes="$(stub_count hermes)"
before_osascript="$(stub_count osascript)"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
rc=$?
assert_exit 0 $rc "限额拒绝属正常流程（exit 0）"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "拒推零 hermes 调用"
assert_eq "$(( $(stub_count osascript) - before_osascript ))" "1" "osascript 兜底恰一次"
assert_eq "$(jq -r 'select(.key == "e10-limit") | .pushed' "$EVENTS_FILE")" "false" "事件保留未标 pushed"
assert_eq "$(jq -r --arg d "$TODAY" '.alerts[$d]' "$STATE_FILE")" "3" "限额计数不被空推消耗"

t_case "E10b: attempts>=3 → osascript 本地提示 + fallback_notice 落账"
jq -c --arg d "$TODAY" '.alerts[$d] = 0' "$STATE_FILE" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
sb_seed_event "pipeline-failure" "e10-retry" "连续失败事件" contrib 3 false
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
rc=$?
assert_exit 1 $rc "发送失败向上传播 rc=1"
assert_eq "$(jq -r --arg d "$TODAY" '.fallback_notice[$d] // 0' "$STATE_FILE")" "1" "fallback_notice 落账"
assert_eq "$(jq -r 'select(.key == "e10-retry") | .attempts' "$EVENTS_FILE")" "4" "attempts 递增（3→4）"

t_case "E10c: 同日再次失败 → osascript 不再发（fallback_notice 日幂等，场景12.P4）"
sb_state_set '.last_flush_epoch = 0'
before_osascript="$(stub_count osascript)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
rc=$?
assert_exit 1 $rc
assert_eq "$(( $(stub_count osascript) - before_osascript ))" "0" "osascript 恰一次/日"
assert_eq "$(jq -r 'select(.key == "e10-retry") | .attempts' "$EVENTS_FILE")" "5" "attempts 继续递增（账面不丢）"

t_case "E10d: 审批推送限额——max_approval_pushes_per_day 用满后拒推并兜底"
sb_seed_queue_item "rq-20260905-011" 11 deep awaiting-approval 40
printf '# 草稿\n' >"$SB_ROOT/contrib-data/pending/rq-20260905-011.md"
sb_rq set-draft rq-20260905-011 "$SB_ROOT/contrib-data/pending/rq-20260905-011.md" >/dev/null
assert_exit 0 $?
jq -c --arg d "$TODAY" '.approvals[$d].count = 3' "$STATE_FILE" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
before_hermes="$(stub_count hermes)"
before_osascript="$(stub_count osascript)"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve rq-20260905-011' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "审批限额拒推零调用"
assert_eq "$(( $(stub_count osascript) - before_osascript ))" "1" "审批限额 osascript 兜底一次"

sb_cleanup
t_finish
