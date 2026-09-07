#!/bin/bash
# e11-approval-card-retry.sh — E11：审批卡重试 + claude 模型 [1m] 后缀剥离（09-07 双修回归）
# 契约锚点：
#   ①rc==1 失败原地退避重试（NOTIFY_CARD_ATTEMPTS/BACKOFF seam），耗尽才记账 fail+=attempts
#   ②rc==3（网关不可达）不重试，osascript 兜底
#   ③_ai_digest --model 剥 [1m]/[1M] 后缀（settings.json env 优先于运行时 env；CLAUDE_MODEL_PIN 覆盖）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e11-approval-card-retry.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
TODAY="$(date +%F)"

seed_item() { # <id> — 造一个 awaiting-approval + 草稿 + set-draft 的最小审批项
  local id="$1"
  sb_seed_queue_item "$id" 104693 deep awaiting-approval 40
  printf '# 草稿 %s\n' "$id" >"$SB_ROOT/contrib-data/pending/$id.md"
  sb_rq set-draft "$id" "$SB_ROOT/contrib-data/pending/$id.md" >/dev/null
}

t_case "E11a: 失败 2 次第 3 次成功 → ok 落账 + 恰 3 次 hermes 调用"
seed_item "rq-20260907-011"
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL_FIRST=2" -e "NOTIFY_CARD_BACKOFF=0" \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve rq-20260907-011' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "3" "重试恰 3 次尝试（2 败 1 成）"
assert_eq "$(jq -r --arg d "$TODAY" '.approvals[$d].ok["rq-20260907-011"] // false' "$STATE_FILE")" "true" "第 3 次成功 → ok 落账"
assert_eq "$(jq -r --arg d "$TODAY" '.approvals[$d].count // 0' "$STATE_FILE")" "1" "count 恰一次（重试不重复计数）"
assert_eq "$(jq -r --arg d "$TODAY" '.approvals[$d].fail["rq-20260907-011"] // 0' "$STATE_FILE")" "0" "成功后无 fail 记录"

t_case "E11b: 恒败 → 3 次尝试耗尽 → fail 累计 3 + osascript 兜底一次"
seed_item "rq-20260907-012"
before_hermes="$(stub_count hermes)"
before_osascript="$(stub_count osascript)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" -e "NOTIFY_CARD_BACKOFF=0" \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve rq-20260907-012' >/dev/null 2>&1
assert_exit 0 $? "approve 吞掉发送失败（记账后返回 0，跨轮 sweep 兜底）"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "3" "耗尽=恰 3 次尝试"
assert_eq "$(jq -r --arg d "$TODAY" '.approvals[$d].fail["rq-20260907-012"] // 0' "$STATE_FILE")" "3" "fail 累计 attempts（0+3）"
assert_eq "$(jq -r --arg d "$TODAY" '.approvals[$d].ok["rq-20260907-012"] // false' "$STATE_FILE")" "false" "恒败无 ok 记录"
assert_eq "$(( $(stub_count osascript) - before_osascript ))" "1" "连续 3 败 osascript 本地提示"

t_case "E11c: 单次失败（attempt<上限）→ fail 只记 1，不到 3 不触发 osascript"
seed_item "rq-20260907-013"
before_osascript="$(stub_count osascript)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL_FIRST=1" -e "STUB_HERMES_FAIL=1" -e "NOTIFY_CARD_ATTEMPTS=1" -e "NOTIFY_CARD_BACKOFF=0" \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve rq-20260907-013' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(jq -r --arg d "$TODAY" '.approvals[$d].fail["rq-20260907-013"] // 0' "$STATE_FILE")" "1" "上限=1 时 fail 只累计 1"
assert_eq "$(( $(stub_count osascript) - before_osascript ))" "0" "累计不足 3 不触发 osascript"

t_case "E11d: _ai_digest --model 剥 [1m]（settings.json env 优先于运行时 env）"
mkdir -p "$SB_HOME/.claude"
cat >"$SB_HOME/.claude/settings.json" <<'EOF'
{ "env": { "ANTHROPIC_MODEL": "glm-5.3-flash[1m]" } }
EOF
sb_state_set '.last_flush_epoch = 0'
sb_notify event pipeline-failure --key e11-digest --summary "模型后缀剥离用例" >/dev/null
assert_exit 0 $?
sb_run -e "NOTIFY_DRY_RUN=false" -e "ANTHROPIC_MODEL=kimi-k3[1M]" \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
claude_calls="$(grep 'claude|' "$SB_STUBLOG/calls.log" 2>/dev/null || true)"
assert_contains "$claude_calls" "--model glm-5.3-flash" "settings.json env 剥后缀后作 --model"
assert_not_contains "$claude_calls" "[1m]" "调用参数零 [1m] 残留"
assert_not_contains "$claude_calls" "kimi-k3" "运行时 env 不越过 settings.json 优先级"

t_case "E11e: 无 settings env 时回落运行时 env 剥后缀"
rm -f "$SB_HOME/.claude/settings.json"
sb_state_set '.last_flush_epoch = 0'
sb_notify event pipeline-failure --key e11-digest-2 --summary "运行时 env 回落用例" >/dev/null
assert_exit 0 $?
sb_run -e "NOTIFY_DRY_RUN=false" -e "ANTHROPIC_MODEL=glm-5.3-flash[1m]" \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
claude_calls="$(grep 'claude|' "$SB_STUBLOG/calls.log" 2>/dev/null | tail -1)"
assert_contains "$claude_calls" "--model glm-5.3-flash" "运行时 env 剥后缀回落生效"
assert_not_contains "$claude_calls" "[1m]" "回落路径同样零后缀"

t_case "E11f: 正常模型名不被误伤（无 ] 后缀原样传递）"
printf '{ "env": { "ANTHROPIC_MODEL": "kimi-k3" } }' >"$SB_HOME/.claude/settings.json"
sb_state_set '.last_flush_epoch = 0'
sb_notify event pipeline-failure --key e11-digest-3 --summary "正常模型名用例" >/dev/null
assert_exit 0 $?
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
claude_calls="$(grep 'claude|' "$SB_STUBLOG/calls.log" 2>/dev/null | tail -1)"
assert_contains "$claude_calls" "--model kimi-k3" "无后缀模型名原样作 --model"

sb_cleanup
t_finish
