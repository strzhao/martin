#!/bin/bash
# t1_docs.acceptance.test.sh — hkstock 三处文档登记契约验收（红队，黑盒）
# 覆盖谓词：4.P1 / 4.P2
# 依据：设计文档「登记契约」：
#   - ~/.hermes/SOUL.md 派单路由表含 hkstock 行且既有 life 行保留
#   - martin hermes-lane-protocol.md 与 CLAUDE.md 均含 hkstock 登记
# 用法：bash t1_docs.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
DEFAULT_SOUL="$HERMES_ROOT/SOUL.md"
MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
LANE_PROTOCOL="$MARTIN_ROOT/hermes-lane-protocol.md"
PROJECT_CLAUDE="$MARTIN_ROOT/CLAUDE.md"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t1_docs: hkstock 文档登记契约验收 =="

# --- 4.P1: default SOUL.md contains hkstock ∧ contains life ---
if [[ ! -f "$DEFAULT_SOUL" ]]; then
  fail "4.P1" "default SOUL.md 不存在: $DEFAULT_SOUL"
else
  soul="$(cat "$DEFAULT_SOUL")"
  if printf '%s' "$soul" | grep -q 'hkstock'; then
    :
  else
    fail "4.P1" "default SOUL.md 不含 hkstock 行"
  fi
  if printf '%s' "$soul" | grep -q 'life'; then
    :
  else
    fail "4.P1" "default SOUL.md 不含 life 行（既有路由行被删除）"
  fi
  if [[ $FAIL_COUNT -eq 0 ]]; then
    pass "4.P1"
  fi
fi

# --- 4.P2: lane-protocol.md ∧ CLAUDE.md 均 contains hkstock ---
for doc in "$LANE_PROTOCOL" "$PROJECT_CLAUDE"; do
  if [[ ! -f "$doc" ]]; then
    fail "4.P2" "登记文档不存在: $doc"
  elif grep -q 'hkstock' "$doc"; then
    :
  else
    fail "4.P2" "文档不含 hkstock 登记: $doc"
  fi
done
if [[ $FAIL_COUNT -eq 0 ]]; then
  pass "4.P2"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
