#!/bin/bash
# e9-illegal-after-chain.sh — E9：状态机非法迁移（真实链路产物上的守卫）
# 契约锚点：非法迁移/非法状态 → exit 2 且 ready-queue.json 字节级零改动
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e9-illegal-after-chain.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"

t_case "E9a: 真实链路到 awaiting-approval 后，非法迁移被拒且零写入"
sb_seed_queue_item "rq-20260905-901" 901 deep queued 40
sb_run -e "NOTIFY_DRY_RUN=false" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
assert_exit 0 $?
state="$(jq -r '.items[] | select(.id == "rq-20260905-901") | .state' "$QUEUE_FILE")"
assert_eq "$state" "awaiting-approval" "前置：链路推进到待批"
before="$(shasum -q "$QUEUE_FILE")"
sb_rq set rq-20260905-901 queued >/dev/null 2>&1 # awaiting-approval ↛ queued
assert_exit 2 $?
after="$(shasum -q "$QUEUE_FILE")"
assert_eq "$before" "$after" "字节级零改动"

t_case "E9b: 待批件的合法审批迁移（微信「批」路径）→ executed"
sb_rq set rq-20260905-901 approved --note "用户微信批" >/dev/null
assert_exit 0 $?
sb_rq set rq-20260905-901 executed --note "SKILL.md 执行完成" >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-901") | .state' "$QUEUE_FILE")" "executed" "终态 executed"
history="$(jq -r '.items[] | select(.id == "rq-20260905-901") | .history | map(.event) | join("→")' "$QUEUE_FILE")"
assert_contains "$history" "approved" "history 含 approved（微信「批」留痕）"
assert_contains "$history" "executed" "history 含 executed（SKILL.md 执行留痕）"

t_case "E9c: 终态 executed 不可再迁移"
before="$(shasum -q "$QUEUE_FILE")"
sb_rq set rq-20260905-901 queued >/dev/null 2>&1
assert_exit 2 $?
assert_eq "$before" "$(shasum -q "$QUEUE_FILE")" "终态零改动"

t_case "E9d: 微信「改」路径 revise → queued（下轮重写）"
sb_seed_queue_item "rq-20260905-902" 902 probe queued 35
sb_rq set rq-20260905-902 awaiting-approval --note "进入待批" >/dev/null
assert_exit 0 $?
sb_rq set rq-20260905-902 revise --note "用户改：意见 A" >/dev/null
assert_exit 0 $?
sb_rq set rq-20260905-902 queued --note "下轮重写" >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-902") | .state' "$QUEUE_FILE")" "queued" "revise→queued 回队"

t_case "E9e: 微信「否」路径 → rejected 终态"
sb_rq set rq-20260905-902 awaiting-approval --note "重新待批" >/dev/null
assert_exit 0 $?
sb_rq set rq-20260905-902 rejected --note "用户否决" >/dev/null
assert_exit 0 $?
before="$(shasum -q "$QUEUE_FILE")"
sb_rq set rq-20260905-902 queued >/dev/null 2>&1
assert_exit 2 $?
assert_eq "$before" "$(shasum -q "$QUEUE_FILE")" "rejected 终态零改动"

sb_cleanup
t_finish
