#!/bin/bash
# e7-happy-path.sh — E7：深检 happy path 全链（T4 卡化重锁）
#   主路（卡化）：gate 命中 → 建 preflight 卡（flight-deepcheck 登记，零 claude，状态推进交 worker）
#   fallback（注毒）：建卡失败 → claude 编排壳（deep-check.sh）两阶段 → awaiting-approval + 审批卡送达
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
DC_FLIGHT="$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"

t_case "E7-pre: gate 无候选（exit 0）→ run-deepcheck 恒 0（黑洞契约固化 11.P5）"
sb_rq init >/dev/null
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
assert_exit 0 $?
assert_stub_not_called claude "无候选不唤 LLM"

t_case "E7: gate 命中 → 建 preflight 卡主路（flight-deepcheck 登记，零 claude，状态交 worker）"
sb_seed_queue_item "rq-20260905-701" 701 deep queued 40
sb_run -e "NOTIFY_DRY_RUN=false" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "run-deepcheck 恒 0（黑洞契约 11.P5 第二输入）"
assert_eq "$(jq -r '.kind // empty' "$DC_FLIGHT" 2>/dev/null)" "deepcheck" "flight-deepcheck 登记"
assert_eq "$(jq -r '.rq_id // empty' "$DC_FLIGHT" 2>/dev/null)" "rq-20260905-701" "flight rq_id"
assert_eq "$(jq -r '.batch_file' "$DC_FLIGHT" 2>/dev/null)" "" "batch_file 空串占位（六键契约）"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-701") | .state' "$QUEUE_FILE")" "queued" "状态推进交 worker 卡内"
assert_stub_not_called claude "主路零 claude（claude 降格兜底）"
assert_contains "$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$SB_ROOT/stublog/calls.log" 2>/dev/null)" \
  "--idempotency-key deepcheck-rq-20260905-701-" "attempt 级幂等键"
body="$(stub_last_body hermes)"
[[ -n "$body" ]] && assert_file_contains "$body" "--parent" "body 含 redteam 自建子卡模板"
[[ -n "$body" ]] && assert_file_contains "$body" "verdict.json" "body 含 verdict 契约"

t_case "E7b: 幂等——同日重跑 run-deepcheck（在飞）不重复建卡/零 fallback"
before_claude="$(stub_count claude)"
before_create="$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { c++ } END { printf "%d", c + 0 }' "$SB_ROOT/stublog/calls.log")"
sb_run -e "NOTIFY_DRY_RUN=false" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "在飞零 fallback claude（10=绝不 fallback）"
after_create="$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { c++ } END { printf "%d", c + 0 }' "$SB_ROOT/stublog/calls.log")"
assert_eq "$(( after_create - before_create ))" "0" "在飞不重复建卡（全局单深检）"

t_case "E7c: fallback 注毒（建卡失败）→ claude 编排壳全链 → awaiting-approval + 审批卡送达"
# 新沙箱（stub 调用序号从 1 重计）：healthcheck(第1调)失败→count1，create(第2调)失败→建卡路
# 失败，fallback deep-check.sh 编排壳接管；notify approve(第3调起)恢复成功 → 审批卡可达
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
sb_seed_queue_item "rq-20260905-701" 701 deep queued 40
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"   # sb_new 换沙箱后重算（SB_ROOT 已变）
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL_FIRST=2" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "run-deepcheck 恒 0（fallback 路黑洞契约）"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-701") | .state' "$QUEUE_FILE")" "awaiting-approval" "fallback 终态待批"
draft="$(jq -r '.items[] | select(.id == "rq-20260905-701") | .draft' "$QUEUE_FILE")"
assert_contains "$draft" "rq-20260905-701.md" "草稿路径已登记"
[[ -f "$draft" ]] && _pass "草稿文件存在" || _fail "草稿文件存在" "actual=$draft"
# deep 车道两阶段 = 两次独立 claude -p（preflight + redteam）
assert_stub_called_times claude 2 "preflight+redteam 各一次"
assert_eq "$(awk -F'|' '$1 == "hermes" && $0 ~ / send/ { c++ } END { printf "%d", c + 0 }' "$SB_ROOT/stublog/calls.log" 2>/dev/null)" \
  "1" "审批卡送达恰一次（send 口径）"
card="$(stub_last_body hermes)"
assert_contains "$(cat "$card")" "🟡【L2 审批 #rq-20260905-701】" "审批卡报头含 id"
assert_contains "$(cat "$card")" "批 #rq-20260905-701" "审批卡含回复指令"
assert_eq "$(jq -r --arg d "$(date +%F)" '.approvals[$d].ok["rq-20260905-701"] // false' "$SB_ROOT/contrib-data/notify-state.json")" "true" "approvals.ok 记账"

t_case "E7d: fallback 后同日重跑——非 queued 候选不再深检/重复推卡"
before_claude="$(stub_count claude)"
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "非 queued 候选不再深检"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "不重复推卡"

t_case "E7e: 同 id 重复入队拒绝（幂等防线）"
sb_rq add --issue 701 --disposition review-evidence --score 12 >/dev/null 2>&1
assert_exit 2 $? "同 id 拒绝重复入队"

sb_cleanup
t_finish
