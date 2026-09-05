#!/bin/bash
# e6-preflight-fail.sh — E6：preflight 失败链（claude exit1 → state=failed + event + 预算按配置处置）
# 契约锚点：失败置 failed；预算按 config.refund_failed_deep_check 决定（默认不返还；probe 轻量必返还）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e6-preflight-fail.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
BUDGET_FILE="$SB_ROOT/contrib-data/budget.json"

t_case "E6a: probe 车道 preflight 失败 → failed + 事件 + 预算返还"
sb_seed_queue_item "rq-20260905-601" 601 probe queued 40
sb_run -e "STUB_CLAUDE_FAIL=1" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "run-deepcheck 黑洞契约"
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-601") | .state' "$QUEUE_FILE")" "failed" "state=failed"
assert_eq "$(jq -r '.probes | to_entries[0].value.used // 0' "$BUDGET_FILE")" "0" "probe 预算已返还"
assert_eq "$(grep -c 'pipeline-failure' "$EVENTS_FILE" 2>/dev/null || true)" "1" "pipeline-failure 事件落账"
assert_file_contains "$SB_ROOT/contrib-data/logs/deepcheck.log" "preflight 失败" "失败日志留证"

t_case "E6b: deep 车道 preflight 失败 → failed + 预算默认不返还"
# 把 601 置终态：gate 的 retry-failed 只复活 failed 件，rejected 不会被抢车道
sb_rq set rq-20260905-601 rejected --note "终态化，让出 probe 车道" >/dev/null
assert_exit 0 $?
sb_seed_queue_item "rq-20260905-602" 602 deep queued 30
sb_config_set '.refund_failed_deep_check = false'
sb_run -e "STUB_CLAUDE_FAIL=1" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-602") | .state' "$QUEUE_FILE")" "failed" "state=failed"
deep_used="$(jq -r '[.days[].used] | add // 0' "$BUDGET_FILE")"
assert_eq "$deep_used" "1" "deep 预算不返还（默认配置）"

t_case "E6c: refund_failed_deep_check=true → 失败后预算返还"
sb_rq retry-failed >/dev/null # failed → queued（次日重试链路顺带验证）
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-602") | .state' "$QUEUE_FILE")" "queued" "retry-failed 晋升"
sb_config_set '.refund_failed_deep_check = true'
deep_used_before="$(jq -r '[.days[].used] | add // 0' "$BUDGET_FILE")"
sb_run -e "STUB_CLAUDE_FAIL=1" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-602") | .state' "$QUEUE_FILE")" "failed" "state=failed"
deep_used="$(jq -r '[.days[].used] | add // 0' "$BUDGET_FILE")"
assert_eq "$deep_used" "$deep_used_before" "本轮 consume→refund 净零（预算已返还）"

t_case "E6d: preflight 成功但不产草稿 → 走「草稿未产出」失败链"
sb_rq retry-failed >/dev/null
sb_run -e "STUB_CLAUDE_NO_DRAFT=1" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
assert_eq "$(jq -r '.items[] | select(.id == "rq-20260905-602") | .state' "$QUEUE_FILE")" "failed" "state=failed"
assert_file_contains "$SB_ROOT/contrib-data/logs/deepcheck.log" "草稿未产出" "草稿缺失失败留证"

sb_cleanup
t_finish
