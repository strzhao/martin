#!/bin/bash
# e7-happy-path.sh — E7：深检 happy path 全链（gate 命中 → claude 三轮审 → 草稿 → awaiting-approval → 审批卡）
# 同时固化 11.P5 黑洞契约：gate exit 0 与 gate exit 10 两种输入下 run-deepcheck.sh 恒 exit 0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e7-happy-path.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"

t_case "E7-pre: gate 无候选（exit 0）→ run-deepcheck 恒 0（黑洞契约固化 11.P5）"
sb_rq init >/dev/null
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
assert_exit 0 $?
assert_stub_not_called claude "无候选不唤 LLM"

t_case "E7: deep 车道全链 → awaiting-approval + 草稿 + 审批卡送达"
sb_seed_queue_item "rq-20260905-701" 701 deep queued 40
sb_run -e "NOTIFY_DRY_RUN=false" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "run-deepcheck 恒 0（黑洞契约 11.P5 第二输入）"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-701") | .state' "$QUEUE_FILE")" "awaiting-approval" "终态待批"
draft="$(jq -r '.items[] | select(.id == "rq-20260905-701") | .draft' "$QUEUE_FILE")"
assert_contains "$draft" "rq-20260905-701.md" "草稿路径已登记"
if [[ -f "$draft" ]]; then
  _pass "草稿文件存在"
else
  _fail "草稿文件存在" "actual=$draft"
fi
# deep 车道两阶段 = 两次独立 claude -p（preflight + redteam）
assert_stub_called_times claude 2 "preflight+redteam 各一次"
# 审批卡经 hermes 送达
assert_stub_called_times hermes 1 "审批卡恰一次"
card="$(stub_last_body hermes)"
assert_contains "$(cat "$card")" "🟡【L2 审批 #rq-20260905-701】" "审批卡报头含 id"
assert_contains "$(cat "$card")" "批 #rq-20260905-701" "审批卡含回复指令"
# 审批推送计账（dry-run=false 真发才计数）
assert_eq "$(jq -r --arg d "$(date +%F)" '.approvals[$d].ok["rq-20260905-701"] // false' "$SB_ROOT/contrib-data/notify-state.json")" "true" "approvals.ok 记账"

t_case "E7b: 幂等——同日重跑 run-deepcheck 不会重复深检/重复推卡"
before_claude="$(stub_count claude)"
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "非 queued 候选不再深检"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "不重复推卡"

t_case "E7c: 同 id 重复入队拒绝（幂等防线）"
sb_rq add --issue 701 --disposition review-evidence --score 12 >/dev/null 2>&1
assert_exit 2 $? "同 id 拒绝重复入队"

sb_cleanup
t_finish
