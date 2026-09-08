#!/bin/bash
# docs-contract.acceptance.test.sh — martin 仓文档契约（红队验收）
# 依据：设计文档「文档契约」：hermes-lane-protocol.md 新增 §10（coder lane 链路 / worktree 归属决策 / L2 引用）；
#       martin CLAUDE.md 多域 COO 节含 coder 说明
# 用法：bash docs-contract.acceptance.test.sh
# 环境覆盖：MARTIN_ROOT（默认 /Users/stringzhao/workspace/martin）
# 退出码：0 = 全绿；1 = 任一断言失败（立即 exit 1，无容错路径）
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
LANE_DOC="$MARTIN_ROOT/hermes-lane-protocol.md"
PROJECT_MD="$MARTIN_ROOT/CLAUDE.md"

PASS=0

fail() {
  printf 'FAIL: %s\n' "$1"
  printf 'RESULT: PASS=%d FAIL=1 SKIP=0\n' "$PASS"
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$1"
}

echo "== 文档契约验收 =="

[[ -f "$LANE_DOC" ]] || fail "hermes-lane-protocol.md 不存在: $LANE_DOC"
[[ -f "$PROJECT_MD" ]] || fail "martin CLAUDE.md 不存在: $PROJECT_MD"

# --- DOC1: lane 协议文档新增 §10（标题行匹配 '## 10.' / '## §10' 等形态） ---
sec_start="$(grep -nE '^#{2,3}[[:space:]]*§?10([.:：、）)]?[[:space:]]|$)' "$LANE_DOC" | head -n 1 | cut -d: -f1)"
[[ -n "$sec_start" ]] || fail "hermes-lane-protocol.md 缺 §10 标题（形态: ## 10. / ## §10 …）"
ok "hermes-lane-protocol.md 存在 §10 标题（L${sec_start}）"

# 提取 §10 节正文（自标题下一行到下一个 '## ' 顶级标题）
sec10="$(sed -n "${sec_start},\$p" "$LANE_DOC" | tail -n +2 | sed -n '1,/^## /p')"
[[ -n "$sec10" ]] || fail "§10 节正文为空"

# --- DOC2: §10 含 coder lane 链路 ---
printf '%s\n' "$sec10" | grep -q 'coder' ||
  fail "§10 缺 coder lane 链路内容"
ok "§10 含 coder lane 链路"
printf '%s\n' "$sec10" | grep -q 'claude' ||
  fail "§10 缺 claude -p / autopilot 无头进程链路内容"
ok "§10 含 claude 无头进程链路"

# --- DOC3: §10 含 worktree 归属决策 ---
printf '%s\n' "$sec10" | grep -q 'worktree' ||
  fail "§10 缺 worktree 归属决策内容"
ok "§10 含 worktree"
printf '%s\n' "$sec10" | grep -q '归属' ||
  fail "§10 缺「归属」决策表述"
ok "§10 含归属决策表述"

# --- DOC4: §10 引用 L2 ---
printf '%s\n' "$sec10" | grep -q 'L2' ||
  fail "§10 缺 L2 审批闸门引用"
ok "§10 引用 L2"

# --- DOC5: martin CLAUDE.md 多域 COO 节含 coder 说明 ---
coo_start="$(grep -nE '^## .*多域 COO' "$PROJECT_MD" | head -n 1 | cut -d: -f1)"
[[ -n "$coo_start" ]] || fail "martin CLAUDE.md 缺「多域 COO」节"
coo_sec="$(sed -n "${coo_start},\$p" "$PROJECT_MD" | tail -n +2 | sed -n '1,/^## /p')"
[[ -n "$coo_sec" ]] || fail "多域 COO 节正文为空"
printf '%s\n' "$coo_sec" | grep -q 'coder' ||
  fail "martin CLAUDE.md 多域 COO 节缺 coder 说明"
ok "martin CLAUDE.md 多域 COO 节含 coder 说明"

printf 'RESULT: PASS=%d FAIL=0 SKIP=0\n' "$PASS"
exit 0
