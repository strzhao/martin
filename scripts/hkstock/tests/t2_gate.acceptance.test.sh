#!/bin/bash
# t2_gate.acceptance.test.sh — gate.sh ROOTS 扩展实跑验收（红队，det-machine）
# 覆盖谓词：EXTRA-gate
# 依据：设计契约 G2：scripts/contrib/tests/gate.sh 的 ROOTS 集合新增 scripts/hkstock；
#   改完实跑 exit ∈ {0,2}（0=全绿，2=依赖缺失合法，1=有发现）
# 用法：bash t2_gate.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
GATE="$MARTIN_ROOT/scripts/contrib/tests/gate.sh"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t2_gate: gate.sh ROOTS 扩展实跑验收 =="

if [[ ! -f "$GATE" ]]; then
  fail "EXTRA-gate" "gate.sh 不存在: $GATE"
  printf 'RESULT: FAIL=1\n'
  exit 1
fi

g_out="$(cd "$MARTIN_ROOT" && bash "$GATE" 2>&1)"
g_rc=$?

# EXTRA-gate: exit ∈ {0, 2}
if [[ "$g_rc" -eq 0 || "$g_rc" -eq 2 ]]; then
  pass "EXTRA-gate"
else
  fail "EXTRA-gate" "gate.sh 实跑 exit=${g_rc}（要求 ∈ {0,2}；1=有发现），输出尾部: $(printf '%s' "$g_out" | tail -5 | tr '\n' ' ')"
fi

# EXTRA-gate-covers-hkstock（2026-09-08 auto-fix，qa-reviewer：原断言对 ROOTS 变更无鉴别力）：
# gate 输出 COVERAGE 行必须含 scripts/hkstock，且 SCAN file 计数 ≥70（证明 hkstock 文件真被扫到）
if printf '%s' "$g_out" | grep -q 'scripts/hkstock'; then
  pass "EXTRA-gate-covers-hkstock"
else
  fail "EXTRA-gate-covers-hkstock" "gate 输出无 scripts/hkstock 覆盖行（ROOTS 扩展疑似失效）: $(printf '%s' "$g_out" | grep COVERAGE | head -1)"
fi
files_scanned="$(printf '%s' "$g_out" | grep -oE 'SCAN [a-z -]+: [0-9]+' | grep -oE '[0-9]+' | sort -rn | head -1)"
if [[ -n "$files_scanned" && "$files_scanned" -ge 70 ]]; then
  pass "EXTRA-gate-scan-count"
else
  fail "EXTRA-gate-scan-count" "gate 扫描文件数异常（要求 ≥70，got=${files_scanned:-none}）"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
