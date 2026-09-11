#!/bin/bash
# e2-dry-run-config.sh — E2：dry-run 模式（negate：传输 stub 零调用），走 config 旋钮而非 env
# 契约锚点：DRY_RUN 解析优先级（env > config > "true"）+ 场景11.P3 否定变体
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e2-dry-run-config.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"

t_case "E2: config notify_dry_run=true → flush 叙事批建卡（零 send/tunnel/osascript；打印移至 send-digest 环节）"
sb_config_set '.notify_dry_run = true'
sb_notify event pipeline-failure --key e2-dry --summary "dry-run 全链" >/dev/null
assert_exit 0 $?
# 关键：env 无 NOTIFY_DRY_RUN（验证 config 路径）
out="$(sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
rc=$?
assert_exit 0 $rc
# T5 卡化语义：建卡属编排写（dry-run 只盖发送不盖编排），kanban 调用允许、send 零调用；
# dry-run 消息体打印移至 worker 侧 send-digest，flush stdout 不再含 [dry-run]
send_calls="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
assert_eq "$send_calls" "0" "hermes send 零调用"
assert_stub_not_called tunnel "tunnel 零调用"
assert_stub_not_called osascript "osascript 零调用"
assert_eq "$(jq -r 'select(.key == "e2-dry") | .pushed' "$EVENTS_FILE")" "false" "dry-run 叙事批挂账不消费（等卡闭环）"

t_case "E2b: env NOTIFY_DRY_RUN=false 可压过 config true（审批演练路径）"
before_hermes="$(stub_count hermes)"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve --all' 2>/dev/null)"
rc=$?
# 队列无 awaiting-approval 项 → 无可推，返回 0 且零新增调用（E2 建卡的 kanban 调用不计入）
assert_exit 0 $rc
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "无可推项零新增调用"

t_case "E2c: receipt 在 dry-run 下也零调用"
before_hermes="$(stub_count hermes)"
out="$(sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" receipt rq-x --summary "演练回执"')"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "[dry-run]" "receipt 亦走 dry-run 打印"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "receipt dry-run 零新增调用"

sb_cleanup
t_finish
