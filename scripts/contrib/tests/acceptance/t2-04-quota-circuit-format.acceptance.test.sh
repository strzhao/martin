#!/usr/bin/env bash
# =============================================================================
# t2-04-quota-circuit-format.acceptance.test.sh — T2 验收矩阵④：quota_circuit.sh 零改动 + 格式 byte 级不变
#   ④a 静态：quota_circuit.sh 对 HEAD diff 为空（T2 只改调用方语义，本文件零改动）
#   ④b 行为：.quota-circuit epoch 单整数格式 + 四子命令行为不变（trip/check/clear/status）
#     - trip（429 签名）→ exit 0 + 旗标文件=单整数 epoch（>now）+ TRIPPED 输出
#     - check（开闸）→ exit 1 + stdout=剩余秒数单整数（0 < remain <= 缺省冷却 21600）
#     - check（闭合/无旗标）→ exit 0
#     - status（开）→ 含 OPEN；clear → 旗标删除 + check exit 0
#     - 旗标损坏 → check 自愈闭合 exit 0；到期 epoch → check 自动闭合 exit 0
# 依据：state.md「## 设计文档」§2（quota_circuit.sh 本身零改动，.quota-circuit epoch 格式
#   byte 级不变）+ 跨任务约束「quota_circuit.sh 文件格式（.quota-circuit epoch）T2 只改
#   调用方语义不改格式」+ 任务级契约「.quota-circuit 文件格式与四子命令行为不变」
# 红队纪律：黑盒；每断言硬失败；无 skip。Mutation 自检：改 epoch→结构化 JSON、
#   多行/带尾随空白 → ④b 红；动四子命令语义 → ④b 红；悄悄改 quota_circuit.sh → ④a 红。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

QC_REL="scripts/contrib/quota_circuit.sh"
FLAG_PATH_IN_SB() { printf '%s/contrib-data/.quota-circuit' "$SB_ROOT"; }

# =============================================================================
t_case "4.1 静态零改动：quota_circuit.sh 工作树对 HEAD diff 为空（含未跟踪改动）"
DIFF_OUT="$(git -C "$REPO_ROOT" diff HEAD -- "$QC_REL" 2>/dev/null || true)"
assert_eq "$DIFF_OUT" "" "4.1 git diff HEAD 对 quota_circuit.sh 为空"
PORCELAIN="$(git -C "$REPO_ROOT" status --porcelain -- "$QC_REL" 2>/dev/null || true)"
assert_eq "$PORCELAIN" "" "4.1 git status 对 quota_circuit.sh 为空（无 staged/unstaged/untracked 改动）"

# =============================================================================
t_case "4.2 trip（429 签名）→ 旗标=单整数 epoch：文件内容 byte 级断言"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
FAKELOG="$SB_ROOT/tmp/claude-fail.log"
printf 'x\nRequest rejected (429)\ny\n' > "$FAKELOG"
TRIP_OUT="$(sb_run "zsh \"\$MARTIN_DIR/scripts/contrib/quota_circuit.sh\" trip \"$FAKELOG\"")"; RC=$?
assert_exit 0 $RC "4.2 trip exit 0=已跳闸"
assert_contains "$TRIP_OUT" "TRIPPED" "4.2 trip 输出 TRIPPED 标记"
if [ -f "$(FLAG_PATH_IN_SB)" ]; then
  _pass "4.2 旗标文件已产出"
  RAW="$(cat "$(FLAG_PATH_IN_SB)")"
  # byte 级：恰一行十进制 epoch + 换行，无多余空白/结构化包装
  case "$RAW" in
    *[!0-9]*) _fail "4.2 旗标 byte 格式" "含非数字字节（epoch 单整数格式被改）：[$(printf '%s' "$RAW" | od -c | head -2 | tr '\n' ' ')]" ;;
    *) _pass "4.2 旗标内容为纯数字（单整数 epoch）" ;;
  esac
  VAL="$(printf '%s' "$RAW" | tr -d '[:space:]')"
  case "$VAL" in
    ''|*[!0-9]*) _fail "4.2 epoch 数值" "非整数 [$VAL]" ;;
    *) [ "$VAL" -gt "$(date +%s)" ] && _pass "4.2 epoch 为未来时间戳（$VAL > now）" || _fail "4.2 epoch 为未来时间戳" "实得 $VAL" ;;
  esac
  assert_eq "$(wc -l < "$(FLAG_PATH_IN_SB)" | tr -d ' ')" "1" "4.2 旗标恰 1 行（无多行结构）"
else
  _fail "4.2 旗标文件已产出" "$SB_ROOT/contrib-data/.quota-circuit 未写出"
fi
sb_cleanup

# =============================================================================
t_case "4.3 check 开闸 → exit 1 + stdout 剩余秒数单整数（<=缺省冷却 21600）；status 含 OPEN"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$(FLAG_PATH_IN_SB)"
CHECK_OUT="$(sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" check')"; RC=$?
assert_exit 1 $RC "4.3 check exit 1=打开"
case "$CHECK_OUT" in
  ''|*[!0-9]*) _fail "4.3 剩余秒数单整数" "stdout 非纯整数 [$CHECK_OUT]" ;;
  *) [ "$CHECK_OUT" -ge 1 ] && [ "$CHECK_OUT" -le 21600 ] && _pass "4.3 剩余秒数在 (0,21600]（${CHECK_OUT}）" || _fail "4.3 剩余秒数范围" "实得 ${CHECK_OUT}" ;;
esac
STATUS_OUT="$(sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" status')"
assert_contains "$STATUS_OUT" "OPEN" "4.3 status 含 OPEN（开闸态）"
sb_cleanup

# =============================================================================
t_case "4.4 check 闭合（无旗标/到期/损坏）→ exit 0 自愈；clear → 旗标删除"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
# 无旗标
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" check' >/dev/null; RC=$?
assert_exit 0 $RC "4.4 无旗标 → check exit 0（闭合）"
# 到期 epoch
printf '%s\n' "$(( $(date +%s) - 5 ))" > "$(FLAG_PATH_IN_SB)"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" check' >/dev/null; RC=$?
assert_exit 0 $RC "4.4 到期 epoch → check exit 0（自动闭合放一次尝试）"
[ -f "$(FLAG_PATH_IN_SB)" ] && _fail "4.4 到期旗标自清" "到期后旗标文件未删除" || _pass "4.4 到期旗标已自动删除"
# 损坏旗标（非整数）
printf 'garbage\n' > "$(FLAG_PATH_IN_SB)"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" check' >/dev/null; RC=$?
assert_exit 0 $RC "4.4 损坏旗标 → check exit 0（自愈闭合）"
# clear
printf '%s\n' "$(( $(date +%s) + 600 ))" > "$(FLAG_PATH_IN_SB)"
CLEAR_OUT="$(sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" clear')"; RC=$?
assert_exit 0 $RC "4.4 clear exit 0"
assert_contains "$CLEAR_OUT" "OK" "4.4 clear 输出 OK"
[ -f "$(FLAG_PATH_IN_SB)" ] && _fail "4.4 clear 删旗标" "clear 后旗标仍存在" || _pass "4.4 clear 后旗标已删除"
sb_cleanup

t_finish
