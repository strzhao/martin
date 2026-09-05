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

t_case "E2: config notify_dry_run=true → flush 零传输调用 + stdout 标注"
sb_config_set '.notify_dry_run = true'
sb_notify event pipeline-failure --key e2-dry --summary "dry-run 全链" >/dev/null
assert_exit 0 $?
# 关键：env 无 NOTIFY_DRY_RUN（验证 config 路径）
out="$(sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "[dry-run]" "stdout 含 [dry-run]"
assert_stub_not_called hermes "hermes 零调用"
assert_stub_not_called tunnel "tunnel 零调用"
assert_stub_not_called osascript "osascript 零调用"

t_case "E2b: env NOTIFY_DRY_RUN=false 可压过 config true（审批演练路径）"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve --all' 2>/dev/null)"
rc=$?
# 队列无 awaiting-approval 项 → 无可推，返回 0 且零调用
assert_exit 0 $rc
assert_stub_not_called hermes "无可推项零调用"

t_case "E2c: receipt 在 dry-run 下也零调用"
out="$(sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" receipt rq-x --summary "演练回执"')"
rc=$?
assert_exit 0 $rc
assert_contains "$out" "[dry-run]" "receipt 亦走 dry-run 打印"
assert_stub_not_called hermes "receipt dry-run 零调用"

sb_cleanup
t_finish
