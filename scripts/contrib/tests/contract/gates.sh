#!/bin/bash
# gates.sh — Tier C：两个无 LLM 闸门的 exit 契约 + target 文件契约
# 覆盖契约规约：deep_check_gate 0/10 + target `^rq-[0-9]{8}-[0-9]+ (deep|probe)$`（场景11.P2）、
# scan_gate 0/10、渠道隔离的 gate 侧（deep-budget 告警事件落账）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=contract

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "gates.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
TARGET_FILE="$SB_ROOT/locks/deepcheck-target"

# ---------------- deep_check_gate ----------------
t_case "deep gate：空队列 → exit 0 且无 target 文件"
sb_rq init >/dev/null
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/deep_check_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
if [[ -e "$TARGET_FILE" ]]; then
  _fail "无 target 文件" "空队列不应写 target"
else
  _pass "无 target 文件"
fi

t_case "deep gate：probe 候选 → exit 10 + target 格式契约"
sb_seed_queue_item "rq-20260905-401" 401 probe queued 40
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/deep_check_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 10 $rc
assert_file_contains "$TARGET_FILE" "rq-20260905-401 probe" "target 内容"
if grep -qE '^rq-[0-9]{8}-[0-9]+ (deep|probe)$' "$TARGET_FILE"; then
  _pass "target 格式 ^rq-YYYYMMDD-N (deep|probe)$"
else
  _fail "target 格式" "actual=[$(cat "$TARGET_FILE" 2>/dev/null)]"
fi

t_case "deep gate：probe 车道预算耗尽 → 深检 deep 候选"
sb_config_set '.probe_per_day = 1'
sb_rq budget reserve rq-20260905-401-drill --lane probe >/dev/null 2>&1 # drill 不计额，改用真件
sb_rq budget reserve rq-20260905-402 --lane probe >/dev/null 2>&1 || true
sb_seed_queue_item "rq-20260905-403" 403 deep queued 30
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/deep_check_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 10 $rc
assert_file_contains "$TARGET_FILE" "rq-20260905-403 deep" "落到 deep 车道"

t_case "deep gate：deep 预算不足 → exit 0 + deep-budget-exhausted 事件落账"
sb_config_set '.deep_check_per_day = 1'
sb_rq budget reserve rq-20260905-403 --lane deep >/dev/null 2>&1 # 占满当日 deep 额度
# 回拨 flush 闸门，防 min_interval 拦截告警推送链（事件落账本身不受影响）
: >"$SB_ROOT/contrib-data/events.jsonl"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/deep_check_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
n="$(grep -c "deep-budget-exhausted" "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true)"
if [[ "${n:-0}" -ge 1 ]]; then
  _pass "deep-budget-exhausted 事件已入账"
else
  _fail "deep-budget-exhausted 事件已入账" "events.jsonl 无该事件"
fi

# ---------------- scan_gate ----------------
make_issue() { # make_issue <number> <title> <label> → 一行 issue JSON
  jq -cn --argjson n "$1" --arg t "$2" --arg l "$3" \
    '{number: $n, title: $t, labels: (if $l == "" then [] else [{name: $l}] end),
      user: {login: "someone"}, created_at: "2026-09-05T00:00:00Z", comments: 0}'
}

t_case "scan gate：无新命中 → exit 0"
printf '{"last_issue": 5000}' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
printf '%s\n' "$(make_issue 5000 "old issue" "")" | jq -s '.' >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
assert_eq "$(jq -r '.last_issue' "$SB_ROOT/contrib-data/scan-cursor.json")" "5000" "游标推进"

t_case "scan gate：域内新命中 → exit 10 + pending-hits 落盘"
printf '{"last_issue": 5000}' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '%s\n' "$(make_issue 5001 "gateway weixin 消息投递失败" "")" | jq -s '.' >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 10 $rc
assert_file_contains "$SB_ROOT/contrib-data/pending-hits.json" "gateway weixin 消息投递失败" "命中落盘"

t_case "scan gate：黑名单域（desktop/kanban/dashboard）→ exit 0"
printf '{"last_issue": 5000}' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '%s\n%s\n' "$(make_issue 5002 "desktop UI 改版" "comp/desktop")" "$(make_issue 5003 "Kanban board improvements" "")" | jq -s '.' >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "黑名单命中被滤除"

t_case "scan gate：PR（pull_request 非空）与 duplicate 标签不计命中"
printf '{"last_issue": 5000}' >"$SB_ROOT/contrib-data/scan-cursor.json"
{ jq -cn '{number: 5003, title: "fix something", labels: [{name: "duplicate"}], user: {login: "x"}, created_at: "2026-09-05T00:00:00Z", comments: 0}';
  jq -cn '{number: 5004, title: "a pr not issue", pull_request: {url: "x"}, labels: [], user: {login: "x"}, created_at: "2026-09-05T00:00:00Z", comments: 0}'; } | jq -s '.' >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "duplicate/PR 不命中"

t_case "scan gate：--drain 清空 pending"
printf '[{"number": 5001}]' >"$SB_ROOT/contrib-data/pending-hits.json"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh" --drain' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
assert_eq "$(cat "$SB_ROOT/contrib-data/pending-hits.json")" "[]" "pending 清空"

sb_cleanup
t_finish
