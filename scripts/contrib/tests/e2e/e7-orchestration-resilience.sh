#!/bin/bash
# e7-orchestration-resilience.sh — E7：编排层自愈三件套（09-06 深检挂死实证回归）
#   a) 阶段超时：stub 挂死 + DEEPCHECK_PHASE_TIMEOUT → run_phase 击杀 → fail 路径（state=failed，不进红队）
#   b) 整壳兜底：内层存活但超 DEEPCHECK_ORCH_TIMEOUT → 入口层击杀 + pipeline-failure 事件（响而不哑）
#   c) 陈旧锁自愈：>3h 锁被清掉重拿（对齐 gate 同款阈值），流水线不再靠人工 rmdir 解锁
#   d) 模型 pin：CLAUDE_MODEL_PIN → 每次 claude 调用显式带 --model（[1M] 后缀防线）
# 契约锚点：run-deepcheck 黑洞契约（exit 恒 0）在 a/b 下保持；死守候不再可能（无超时工具时退化为现状语义）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e7-orchestration-resilience.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
DC_LOG="$SB_ROOT/contrib-data/logs/deepcheck.log"
CALLS_LOG="$SB_STUBLOG/calls.log"

t_case "E7a: 阶段超时 → run_phase 击杀 → failed + 不进红队"
sb_seed_queue_item "rq-20260905-701" 701 deep queued 30
sb_run -e "STUB_CLAUDE_SLEEP=30" -e "DEEPCHECK_PHASE_TIMEOUT=2" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "run-deepcheck 黑洞契约保持"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-701") | .state' "$QUEUE_FILE")" "failed" "阶段超时置 failed"
assert_file_contains "$DC_LOG" "preflight 失败" "失败链日志留证"
assert_eq "$(grep -c '阶段2 redteam 启动' "$DC_LOG" 2>/dev/null || true)" "0" "preflight 击杀后不得进红队"
# 701 置终态，防 gate retry-failed 复活抢车道
sb_rq set rq-20260905-701 rejected --note "终态化让位" >/dev/null

t_case "E7b: 整壳兜底 → 入口层击杀 + pipeline-failure 事件"
sb_seed_queue_item "rq-20260905-702" 702 deep queued 30
sb_run -e "STUB_CLAUDE_SLEEP=30" -e "DEEPCHECK_PHASE_TIMEOUT=29" -e "DEEPCHECK_ORCH_TIMEOUT=2" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "黑洞契约保持（兜底击杀也不上抛）"
assert_file_contains "$DC_LOG" "超时被整壳兜底击杀" "整壳超时日志留证"
assert_file_contains "$EVENTS_FILE" "deepcheck-orch-timeout" "pipeline-failure 事件落账"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-702") | .state' "$QUEUE_FILE")" "deep-check" "击杀时项停留 deep-check（响而不哑，人工复核入口）"

t_case "E7c: 陈旧锁自愈 → 清掉重拿，流水线不靠人工解锁"
sb_seed_queue_item "rq-20260905-703" 703 deep queued 30
mkdir -p "$SB_ROOT/locks/deepcheck.lock"
touch -t 202601010000 "$SB_ROOT/locks/deepcheck.lock"   # 8 个月前的陈旧锁
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/deep-check.sh" rq-20260905-703 deep' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "deep-check 直调黑洞契约"
assert_file_contains "$DC_LOG" "陈旧锁" "锁自愈日志留证"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-703") | .state' "$QUEUE_FILE")" "awaiting-approval" "自愈后整链走通"

t_case "E7d: 模型 pin → 每次 claude 调用显式带 --model"
sb_seed_queue_item "rq-20260905-704" 704 deep queued 30
sb_run -e "CLAUDE_MODEL_PIN=glm-test-9" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "黑洞契约保持"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-704") | .state' "$QUEUE_FILE")" "awaiting-approval" "pin 不破坏正常链"
assert_eq "$(grep -c 'claude|.*--model glm-test-9' "$CALLS_LOG" 2>/dev/null || true)" "2" "preflight+redteam 两阶段都带 --model"
# 反向：未设 pin 且沙箱 HOME 无 settings.json → 不加 flag（现状语义，行为零改变）
assert_eq "$(grep -c 'claude|.*--model$' "$CALLS_LOG" 2>/dev/null || true)" "0" "空 pin 不产生悬空 flag"

sb_cleanup
t_finish
