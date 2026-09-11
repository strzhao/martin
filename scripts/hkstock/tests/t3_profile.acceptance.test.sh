#!/bin/bash
# t3_profile.acceptance.test.sh — hkstock profile 指令与简报来源标识契约验收（红队）
# 覆盖谓词：10.P1 / 10.P2
# 依据：设计契约 D：
#   - 10.P1 ~/.hermes/profiles/hkstock/ 指令（SOUL.md / skills/**.md）含 mktd 用法标识
#   - 10.P2 取数切换后的简报产物含 mktd 来源标识（real-process，BRIEF_ARTIFACT 注入）
# 门控：10.P2 无 BRIEF_ARTIFACT 注入且 briefs/ 无可发现产物 → SKIP_REAL_PROCESS，该谓词跳过
# 说明：10.P1 是正向存在性断言（grep profile 指令文本），不属于红线 negate 扫描，不受 *.md 排除口径约束
# 用法：bash t3_profile.acceptance.test.sh
# 退出码：0 = 全绿（含 10.P2 跳过）；1 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
PROFILE_DIR="${HKSTOCK_PROFILE_DIR:-$HOME/.hermes/profiles/hkstock}"
BRIEFS_DIR="$MARTIN_ROOT/hkstock-data/briefs"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t3_profile: profile 指令与简报来源标识验收（场景 10）=="

# ============ 10.P1: profile 指令含 mktd ============
if [[ ! -d "$PROFILE_DIR" ]]; then
  fail "10.P1" "profile 目录不存在: $PROFILE_DIR"
else
  hits="$(find "$PROFILE_DIR" -type f -name '*.md' -not -path '*/.hub/*' -exec grep -lI 'mktd' {} + 2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    pass "10.P1"
    printf 'INFO 10.P1 命中文件: %s\n' "$(printf '%s' "$hits" | tr '\n' ' ' | cut -c1-200)"
  else
    fail "10.P1" "profile 指令（$PROFILE_DIR 下 SOUL.md / skills/**.md，排除 .hub 缓存）无任何 mktd 标识"
  fi
fi

# ============ 10.P2: 简报产物含 mktd 来源标识（real-process 门控）============
if [[ -n "${BRIEF_ARTIFACT:-}" ]]; then
  ARTIFACT="$BRIEF_ARTIFACT"
else
  ARTIFACT="$(ls -t "$BRIEFS_DIR"/*-brief.md 2>/dev/null | head -1 || true)"
fi

if [[ -z "$ARTIFACT" || ! -f "$ARTIFACT" ]]; then
  printf 'SKIP_REAL_PROCESS (10.P2)\n'
  printf 'INFO 10.P2 跳过: BRIEF_ARTIFACT 未注入且 %s 下无可发现 *-brief.md\n' "$BRIEFS_DIR"
else
  printf 'INFO 产物: %s\n' "$ARTIFACT"
  [[ -n "${KANBAN_TASK_ID:-}" ]] && printf 'INFO 关联卡: %s\n' "$KANBAN_TASK_ID"
  if grep -qi 'mktd' "$ARTIFACT"; then
    pass "10.P2"
  else
    fail "10.P2" "简报产物不含 mktd 来源标识（取数切换未生效或简报未走 mktd）"
  fi
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
