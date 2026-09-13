#!/bin/bash
# e8-idempotent.sh — E8：簿记幂等（同 key 事件一行；flush 防双发：min_interval + 无新事件零调用）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e8-idempotent.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"

t_case "E8a: 同 key 二次 event 不新增行（账本幂等唯一）"
sb_notify event own-pr-activity --key e8-k --summary "第一 graffiti" >/dev/null
assert_exit 0 $?
sb_notify event own-pr-activity --key e8-k --summary "第二 graffiti" >/dev/null
assert_exit 0 $?
assert_eq "$(grep -c '"key":"e8-k"' "$EVENTS_FILE" 2>/dev/null || true)" "1" "仍一行"

t_case "E8b: min_interval 防双发——紧凑两次 flush 只发一次"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_stub_called_times hermes 1 "第一次 flush 恰一次"
# 第二次 flush 紧跟其后（不回拨 last_flush_epoch）→ 必被 min_interval 拦截
before_hermes="$(stub_count hermes)"
out2="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
rc=$?
assert_exit 0 $rc "拦截属正常跳过（exit 0）"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "第二次 flush 零调用"
assert_eq "$out2" "" "拦截轮零输出"
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "1" "配额只 bump 一次"

t_case "E8c: 回拨时间闸门后，无未推事件 → flush 零调用（无事件不空发）"
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
out3="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
rc=$?
assert_exit 0 $rc
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "全部已推 → 零调用"
assert_eq "$out3" "" "空轮零输出"
assert_eq "$(jq -r '.last_flush_epoch' "$STATE_FILE")" "0" "last_flush_epoch 不被空轮推进"

sb_cleanup
t_finish
