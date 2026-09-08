#!/bin/bash
# soul-contract.acceptance.test.sh — coder profile SOUL.md 文本契约（红队验收）
# 依据：设计文档「文本契约（SOUL/SKILL 必含元素）— coder SOUL.md」
# 用法：bash soul-contract.acceptance.test.sh
# 环境覆盖：HERMES_HOME（默认 ~/.hermes，供 fixture/沙箱复跑）
# 退出码：0 = 全绿；1 = 任一断言失败（立即 exit 1，无容错路径）
set -u

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
CODER_SOUL="$HERMES_ROOT/profiles/coder/SOUL.md"

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

echo "== coder SOUL.md 文本契约验收 =="

[[ -f "$CODER_SOUL" ]] || fail "coder SOUL.md 不存在: $CODER_SOUL"
[[ -s "$CODER_SOUL" ]] || fail "coder SOUL.md 为空文件"

# --- S1: 「只 commit」语义 + push 禁令 ---
grep -Eqi '只[[:space:]]*(允许[[:space:]]*)?commit' "$CODER_SOUL" ||
  fail "SOUL 缺「只 commit」提交边界语义"
ok "SOUL 含「只 commit」语义"
grep -Eiq '(禁止|不得|不允许|严禁|禁令|红线).*push|push.*(禁止|不得|不允许|严禁|禁令|红线)' "$CODER_SOUL" ||
  fail "SOUL 缺 push 禁令（push 与 禁止/不得/红线 类措辞须同现）"
ok "SOUL 含 push 禁令"

# --- S2: $HERMES_KANBAN_WORKSPACE 字面量 ---
grep -qF '$HERMES_KANBAN_WORKSPACE' "$CODER_SOUL" ||
  fail "SOUL 缺 \$HERMES_KANBAN_WORKSPACE 字面量"
ok "SOUL 含 \$HERMES_KANBAN_WORKSPACE"

# --- S3: 三段式结构（发生了什么 / 为何重要 / 建议动作） ---
grep -qF '发生了什么' "$CODER_SOUL" ||
  fail "SOUL 三段式缺「发生了什么」"
ok "SOUL 三段式含「发生了什么」"
grep -Eq '为何重要|为什么与我有关|为何与我有关' "$CODER_SOUL" ||
  fail "SOUL 三段式缺「为何重要/为什么与我有关」"
ok "SOUL 三段式含「为何重要」"
grep -qF '建议动作' "$CODER_SOUL" ||
  fail "SOUL 三段式缺「建议动作」"
ok "SOUL 三段式含「建议动作」"

# --- S4: 「最多 2 次」claude 启动语义 ---
grep -Eq '最多[[:space:]]*2[[:space:]]*次' "$CODER_SOUL" ||
  fail "SOUL 缺「最多 2 次」claude 启动上限语义"
ok "SOUL 含「最多 2 次」claude 启动语义"
grep -qi 'claude' "$CODER_SOUL" ||
  fail "SOUL 未提及 claude（启动语义缺主语）"
ok "SOUL 提及 claude"

# --- S5: kanban_request_review 工具 ---
grep -qF 'kanban_request_review' "$CODER_SOUL" ||
  fail "SOUL 缺 kanban_request_review"
ok "SOUL 含 kanban_request_review"

# --- S6: 长会话恢复锚点（process(action=list) + kanban_show()） ---
grep -Eq 'process[[:space:]]*\([[:space:]]*action[[:space:]]*=[[:space:]]*"?list' "$CODER_SOUL" ||
  fail "SOUL 恢复锚点缺 process(action=list)"
ok "SOUL 恢复锚点含 process(action=list)"
grep -qF 'kanban_show()' "$CODER_SOUL" ||
  fail "SOUL 恢复锚点缺 kanban_show()"
ok "SOUL 恢复锚点含 kanban_show()"

printf 'RESULT: PASS=%d FAIL=0 SKIP=0\n' "$PASS"
exit 0
