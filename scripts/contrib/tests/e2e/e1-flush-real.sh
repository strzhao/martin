#!/bin/bash
# e1-flush-real.sh — E1：flush 真发全链（事件→聚合→stub 送达→账本/配额三同现）
# 契约锚点：真发成功判据（hermes rc==0 且 success:true 才标 pushed 并 bump 配额）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e1-flush-real.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"

t_case "E1: 叙事事件→AI 摘要→hermes 送达→pushed/配额/时间戳三同现"
sb_notify event pipeline-failure --key e1-narrative --summary "scan 研判 claude -p 失败 exit=1" >/dev/null
assert_exit 0 $?
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$out" "" "真发轮无 stdout 噪音（结果落账本/日志）"
# ① stub 恰一次
assert_stub_called_times hermes 1 "hermes 恰一次"
# ② stub 输出 success:true（写进 NOTIFY_SEND_LAST 落点）
assert_file_contains "$SB_ROOT/stublog/hermes-send-last.json" '"success":true' "发送结果 success:true"
# ③ 账本标 pushed=true + pushed_at 非空
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .pushed' "$EVENTS_FILE")" "true" "events 标 pushed"
assert_not_contains "$(jq -r 'select(.key == "e1-narrative") | .pushed_at' "$EVENTS_FILE")" "null" "pushed_at 落值"
# 配额与时间戳
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "1" "当日告警配额 bump 1"
last="$(jq -r '.last_flush_epoch' "$STATE_FILE")"
if [[ "$last" =~ ^[0-9]+$ && "$last" -gt 0 ]]; then
  _pass "last_flush_epoch 落值"
else
  _fail "last_flush_epoch 落值" "actual=$last"
fi
# 消息体经 AI 摘要（claude 恰一次）且不含原始 JSON dump
assert_stub_called claude 1 "AI 摘要恰一次"
body_file="$(stub_last_body hermes)"
assert_contains "$(cat "$body_file")" "🟠【contrib 告警】" "AI 摘要报头"
assert_not_contains "$(cat "$body_file")" '"summary":"scan 研判' "无 raw JSON dump"

t_case "E1b: 纯机械批次→模板卡（零 LLM）+ ▪ 实质行"
sb_notify event probe-premise-dead --key e1-mech --summary "radar 2026-09-05 premise 复验：#102413 已被占坑出局" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
before_claude="$(stub_count claude)"
before_hermes="$(stub_count hermes)"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "纯机械批次零 claude 调用"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "1" "hermes 再发一次"
body_file="$(stub_last_body hermes)"
assert_contains "$(cat "$body_file")" "▪ 候选折损" "模板卡实质行（▪ 开头）"
assert_contains "$(cat "$body_file")" "↳ " "模板卡动作行"
assert_eq "$(jq -r 'select(.key == "e1-mech") | .pushed' "$EVENTS_FILE")" "true" "机械事件标 pushed"

t_case "E1c: 失败链（stub 报 success:false）→ 事件保留 + attempts 递增"
sb_notify event pipeline-failure --key e1-fail --summary "会失败的事件" >/dev/null
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_SUCCESS_FALSE=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 1 $? "flush 上报失败"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "1" "确实调用了 hermes（exit0 但 success≠true）"
assert_eq "$(jq -r 'select(.key == "e1-fail") | .pushed' "$EVENTS_FILE")" "false" "不得标 pushed"
assert_eq "$(jq -r 'select(.key == "e1-fail") | .attempts' "$EVENTS_FILE")" "1" "attempts 递增"

sb_cleanup
t_finish
