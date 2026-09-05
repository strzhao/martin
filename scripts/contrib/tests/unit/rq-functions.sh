#!/bin/bash
# rq-functions.sh — Tier U：rq.sh 纯函数表驱动（source 复用，不触子命令）
# 覆盖：transitions_for 状态闭集与迁移表 / assert_transition / calc_priority / assert_no_secret / week_key
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "rq-functions.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }

rq_fn() { # rq_fn <表达式> — 在子进程里 source rq.sh 后求值；输出 stdout，rc 为表达式 rc
  sb_run -e "RQ_SOURCE_ONLY=1" "source \"\$MARTIN_DIR/scripts/contrib/rq.sh\" >/dev/null 2>&1
$1"
}

# ---------------- transitions_for：10 态闭集 ----------------
ALL_STATES="queued deep-check awaiting-approval approved executed revise shelved rejected expired failed"

t_case "状态闭集：10 态全覆盖"
for s in $ALL_STATES; do
  rq_fn "transitions_for $s" >/dev/null
  assert_exit 0 $?
done

t_case "未知状态 → die exit 2"
rq_fn "transitions_for bogus-state" >/dev/null 2>&1
assert_exit 2 $? "transitions_for bogus-state"

t_case "迁移表与实现冻结值一致"
EXPECTED_queued="deep-check awaiting-approval expired shelved rejected failed"
EXPECTED_deepcheck="awaiting-approval failed queued"
EXPECTED_awaiting="approved revise expired shelved rejected failed"
EXPECTED_approved="executed failed"
EXPECTED_revise="queued rejected expired"
EXPECTED_failed="queued expired shelved rejected"
EXPECTED_shelved="queued rejected expired"
assert_eq "$(rq_fn 'transitions_for queued')" "$EXPECTED_queued" "queued →"
assert_eq "$(rq_fn 'transitions_for deep-check')" "$EXPECTED_deepcheck" "deep-check →"
assert_eq "$(rq_fn 'transitions_for awaiting-approval')" "$EXPECTED_awaiting" "awaiting-approval →"
assert_eq "$(rq_fn 'transitions_for approved')" "$EXPECTED_approved" "approved →"
assert_eq "$(rq_fn 'transitions_for revise')" "$EXPECTED_revise" "revise →"
assert_eq "$(rq_fn 'transitions_for failed')" "$EXPECTED_failed" "failed →"
assert_eq "$(rq_fn 'transitions_for shelved')" "$EXPECTED_shelved" "shelved →"
assert_eq "$(rq_fn 'transitions_for expired')" "" "expired →（终态）"
assert_eq "$(rq_fn 'transitions_for rejected')" "" "rejected →（终态）"
assert_eq "$(rq_fn 'transitions_for executed')" "" "executed →（终态）"

# 生产路径锚点：approved/revise 由 hermes 微信审批环驱动、shelved 由 sweep 产出（契约规约第 9 条）
t_case "生产路径锚点：approve/revise/shelved 三条活迁移"
assert_contains " $(rq_fn 'transitions_for awaiting-approval') " " approved " "awaiting-approval → approved（微信「批」）"
assert_contains " $(rq_fn 'transitions_for awaiting-approval') " " revise " "awaiting-approval → revise（微信「改」）"
assert_contains " $(rq_fn 'transitions_for failed') " " queued " "failed → queued（retry-failed 次日重试）"
assert_contains " $(rq_fn 'transitions_for queued') " " shelved " "queued → shelved（sweep 产出）"

# ---------------- assert_transition ----------------
t_case "assert_transition：合法迁移通过"
rq_fn "assert_transition queued deep-check" >/dev/null 2>&1
assert_exit 0 $? "queued → deep-check"
rq_fn "assert_transition awaiting-approval approved" >/dev/null 2>&1
assert_exit 0 $? "awaiting-approval → approved"
rq_fn "assert_transition revise queued" >/dev/null 2>&1
assert_exit 0 $? "revise → queued"

t_case "assert_transition：非法迁移 die exit 2"
rq_fn "assert_transition queued executed" >/dev/null 2>&1
assert_exit 2 $? "queued ↛ executed"
rq_fn "assert_transition awaiting-approval deep-check" >/dev/null 2>&1
assert_exit 2 $? "awaiting-approval ↛ deep-check"
rq_fn "assert_transition expired queued" >/dev/null 2>&1
assert_exit 2 $? "expired ↛ queued（终态）"

t_case "assert_transition：空迁移拒绝"
rq_fn "assert_transition queued queued" >/dev/null 2>&1
assert_exit 2 $? "queued → queued"

# ---------------- calc_priority ----------------
t_case "calc_priority：表驱动"
assert_eq "$(rq_fn 'calc_priority 15 2 review-evidence')" "104" "15分+<6h+review-evidence"
assert_eq "$(rq_fn 'calc_priority 12 10 own-PR')" "82" "12分+<24h+own-PR"
assert_eq "$(rq_fn 'calc_priority 11 100 probe-salvage')" "66" "11分+陈旧+无加成"
assert_eq "$(rq_fn 'calc_priority 12 5.7 probe-salvage')" "84" "浮点 age 取整 5 → fresh12"
assert_eq "$(rq_fn 'calc_priority 12 abc own-PR')" "76" "非法 age 兜底 999 → fresh0+bonus4"

# ---------------- assert_no_secret ----------------
t_case "assert_no_secret：凭据模式拦截"
rq_fn "assert_no_secret 'token=ghp_1234567890abcdefghijklmn'" >/dev/null 2>&1
assert_exit 2 $? "ghp_ 模式"
rq_fn "assert_no_secret 'github_pat_1234567890abcdefghijklmn'" >/dev/null 2>&1
assert_exit 2 $? "github_pat_ 模式"
rq_fn "assert_no_secret 'key=sk-1234567890abcdefghijklmn'" >/dev/null 2>&1
assert_exit 2 $? "sk- 模式"
rq_fn "assert_no_secret '-----BEGIN RSA PRIVATE KEY-----'" >/dev/null 2>&1
assert_exit 2 $? "私钥块"

t_case "assert_no_secret：干净文本放行"
rq_fn "assert_no_secret '普通 review 意见，含 rq-20260905-123 引用'" >/dev/null 2>&1
assert_exit 0 $?

# ---------------- week_key ----------------
t_case "week_key：ISO 周格式"
wk="$(rq_fn 'week_key')"
assert_exit 0 $?
if [[ "$wk" =~ ^[0-9]{4}-W[0-9]{2}$ ]]; then
  _pass "格式 $wk"
else
  _fail "week_key 格式" "actual=[$wk]"
fi

# ---------------- next 契约（注释对齐实现：无候选输出空 + exit 0）----------------
t_case "rq next：无候选 → 空 + exit 0（契约固化）"
next_out="$(sb_rq next --lane deep)"
assert_exit 0 $?
assert_eq "$next_out" "" "无候选输出空"

t_case "rq next：有 queued 候选 → 输出 id"
sb_seed_queue_item "rq-20260905-201" 201 deep queued 40
out3="$(sb_rq next --lane deep)"
assert_exit 0 $?
assert_eq "$out3" "rq-20260905-201" "最高 priority 候选"

sb_cleanup
t_finish
