#!/bin/bash
# skills-contract.acceptance.test.sh — claude-run / coder-delegate 两个 SKILL 文本契约 + 卡 body schema 模板（红队验收）
# 依据：设计文档「CLI 命令签名」「退出码契约」「卡 body schema」「文本契约 — 两个 SKILL」「错误契约」
# 用法：bash skills-contract.acceptance.test.sh
# 环境覆盖：HERMES_HOME（默认 ~/.hermes，供 fixture/沙箱复跑）
# 退出码：0 = 全绿；1 = 任一断言失败（立即 exit 1，无容错路径）
set -u

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
CR="$HERMES_ROOT/profiles/coder/skills/claude-run/SKILL.md"
DG="$HERMES_ROOT/skills/coder-delegate/SKILL.md"
SOUL="$HERMES_ROOT/profiles/coder/SOUL.md"

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
assert_grep() { # <ERE pattern> <契约点> <file>
  grep -qE "$1" "$3" || fail "${2}（pattern: $1, file: ${3}）"
  ok "$2"
}
assert_grep_f() { # <fixed string> <契约点> <file>
  grep -qF -- "$1" "$3" || fail "${2}（literal: $1, file: ${3}）"
  ok "$2"
}
assert_grep_any() { # <ERE pattern> <契约点> <file...>（union 命中即可）
  pat="$1"
  desc="$2"
  shift 2
  for f in "$@"; do
    if [[ -f "$f" ]] && grep -qE "$pat" "$f"; then
      ok "$desc"
      return 0
    fi
  done
  fail "$desc —— 候选文件均未命中 pattern: $pat"
}

echo "== claude-run SKILL 文本契约 =="

[[ -f "$CR" ]] || fail "claude-run SKILL 不存在: $CR"
[[ -s "$CR" ]] || fail "claude-run SKILL 为空文件"

# --- R1: CLI 命令签名 ---
assert_grep_f 'CLAUDE_BIN' "claude-run 含 CLAUDE_BIN 探测" "$CR"
assert_grep 'CLAUDE_MODEL_PIN' "claude-run 含 CLAUDE_MODEL_PIN（优先于 settings.json env.ANTHROPIC_MODEL）" "$CR"
assert_grep '\[1[mM]\]' "claude-run 含 [1m]/[1M] 剥后缀语义" "$CR"
assert_grep_f "perl -e 'alarm shift; exec @ARGV'" "claude-run 含内层 perl alarm 配方" "$CR"
assert_grep_f '--permission-mode' "claude-run 含 --permission-mode" "$CR"
assert_grep_f 'acceptEdits' "claude-run 含 --permission-mode acceptEdits 的 acceptEdits" "$CR"
assert_grep_f '--allowedTools' "claude-run 含 --allowedTools 白名单" "$CR"
assert_grep_f '--disallowedTools' "claude-run 含 --disallowedTools" "$CR"
assert_grep_f 'Bash(git push*)' "claude-run disallowedTools 含 Bash(git push*)" "$CR"
assert_grep '(^|[^A-Za-z-])--model([^A-Za-z-]|$)' "claude-run 含 --model <pinned>" "$CR"

# --- R2: 执行环境与日志 ---
assert_grep_f '$HERMES_KANBAN_WORKSPACE' "claude-run workdir 绑定 \$HERMES_KANBAN_WORKSPACE" "$CR"
assert_grep_f '.autopilot-coder.log' "claude-run 日志重定向 <worktree>/.autopilot-coder.log" "$CR"

# --- R3: 外层 process 等待 / 心跳 / 卡死判据 ---
assert_grep 'process[[:space:]]*\([[:space:]]*(action[[:space:]]*=[[:space:]]*)?"?wait' "claude-run 含外层 process(wait) 等待语义" "$CR"
assert_grep '(^|[^0-9])600([^0-9]|$)' "claude-run 含 600s 分片等待" "$CR"
assert_grep_f 'pgrep -f' "claude-run 含 pgrep -f 进程探测" "$CR"
assert_grep 'pgrep[[:space:]]+-f[[:space:]]+"?claude[[:space:]]+-p' "claude-run pgrep 目标为 claude -p" "$CR"
assert_grep_f 'kanban_heartbeat' "claude-run 含 kanban_heartbeat" "$CR"
assert_grep_f 'process(action=kill)' "claude-run 含 process(action=kill) 卡死处置（hermes 真实工具语法，process_registry.py:3228）" "$CR"
assert_grep '45([[:space:]]*min|分钟)' "claude-run 含 45min 日志 mtime 无增长卡死判据" "$CR"

# --- R4: 退出码契约 / 失败矩阵 / 重试 ---
assert_grep_f '重试' "claude-run 含退出码 != 0 重试语义" "$CR"
assert_grep '(^|[^0-9])142([^0-9]|$)' "claude-run 含 alarm 142 退出码语义" "$CR"
assert_grep_f 'claude_attempts' "claude-run 含 claude_attempts 计数（<= 2）" "$CR"
assert_grep '第[[:space:]]*3[[:space:]]*次' "claude-run 含第 3 次禁止启动语义" "$CR"
assert_grep_f 'kanban_request_review' "claude-run 重试耗尽后含 kanban_request_review" "$CR"
assert_grep '(^|[^0-9])200([^0-9]|$)' "claude-run 含日志尾 >= 200 行读取语义" "$CR"
assert_grep_f 'state.md' "claude-run 含 state.md phase 读取" "$CR"
assert_grep_f '状态文件' "claude-run 含「状态文件：」解析语义" "$CR"
assert_grep_f 'kanban_block' "claude-run 含 kanban_block（缺输入/缺 CLAUDE_BIN 等错误路）" "$CR"

# --- R5: 错误契约 — CLAUDE_BIN 三级探测 ---
assert_grep_any '三级' "含 CLAUDE_BIN 三级探测语义（claude-run/delegate union）" "$CR" "$DG"

# --- R6: timeout_budget 数值域（union：缺省 10800 / 合法域 600-14400 / max_runtime 关系） ---
assert_grep_any '(^|[^0-9])10800([^0-9]|$)' "含 timeout_budget 缺省 10800" "$CR" "$DG"
assert_grep_any '(^|[^0-9])14400([^0-9]|$)' "含 timeout_budget 合法域上界 14400" "$CR" "$DG"
assert_grep_any '(^|[^0-9])1800([^0-9]|$)' "含 max_runtime > timeout_budget + 1800s 关系" "$CR" "$DG"
assert_grep_any '(^|[^0-9])12600([^0-9]|$)' "含 max_runtime 下界 12600s（210m）" "$CR" "$DG"
assert_grep_any '(^|[^0-9])8192([^0-9]|$)' "含卡 body <= 8192 bytes 约束" "$CR" "$DG"
assert_grep_any '绝对路径' "含目标仓库必为以 / 开头的绝对路径语义" "$CR" "$DG"

echo "== coder-delegate SKILL 文本契约 =="

[[ -f "$DG" ]] || fail "coder-delegate SKILL 不存在: $DG"
[[ -s "$DG" ]] || fail "coder-delegate SKILL 为空文件"

# --- D1: AI 自判 + 不设硬闸 ---
assert_grep '自判|自行判断|自行评估' "coder-delegate 含 AI 自判语义" "$DG"
assert_grep_f '不设硬闸' "coder-delegate 含「不设硬闸」语义" "$DG"

# --- D2: 卡 body 五节模板（存在 + 顺序固定） ---
sec_order_check() {
  l1="$(grep -nE '^[[:space:]]*## 目标[[:space:]]*$' "$DG" | head -n 1 | cut -d: -f1)"
  l2="$(grep -nF '## 目标仓库' "$DG" | head -n 1 | cut -d: -f1)"
  l3="$(grep -nF '## 验收标准' "$DG" | head -n 1 | cut -d: -f1)"
  l4="$(grep -nF '## 约束' "$DG" | head -n 1 | cut -d: -f1)"
  l5="$(grep -nF '## 背景材料' "$DG" | head -n 1 | cut -d: -f1)"
  for v in "$l1" "$l2" "$l3" "$l4" "$l5"; do
    [[ -n "$v" ]] || fail "coder-delegate 卡 body 模板五节不齐（目标/目标仓库/验收标准/约束/背景材料）"
  done
  [[ "$l1" -lt "$l2" && "$l2" -lt "$l3" && "$l3" -lt "$l4" && "$l4" -lt "$l5" ]] ||
    fail "卡 body 五节顺序不固定（行号: 目标=${l1} 目标仓库=${l2} 验收标准=${l3} 约束=${l4} 背景材料=${l5}）"
  ok "卡 body 五节模板齐备且顺序固定"
}
sec_order_check

# --- D3: 卡 body 尾行 timeout_budget ---
assert_grep_f 'timeout_budget' "coder-delegate 模板含尾行 timeout_budget: <int>" "$DG"

# --- D4: 建卡参数 ---
assert_grep 'workspace_kind[^[:alnum:]]*.*worktree' "coder-delegate 含 workspace_kind=worktree" "$DG"
assert_grep 'assignee[^[:alnum:]]*.*coder' "coder-delegate 含 assignee=coder" "$DG"
assert_grep 'max_runtime[^[:alnum:]]*.*210|210[[:space:]]*m' "coder-delegate 含 max_runtime=210m" "$DG"

# --- D5: L2 边界 + 预期管理 ---
assert_grep_f 'L2' "coder-delegate 含 L2 不走 coder 语义" "$DG"
assert_grep '1-3[[:space:]]*小时' "coder-delegate 含建卡后预期管理「预计 1-3 小时」" "$DG"

# --- D6: 错误契约 — 审批门禁伪造 approve（union：SOUL + 两 SKILL） ---
assert_grep_any '伪造' "含禁止伪造 approve 语义（SOUL/claude-run/delegate union）" "$SOUL" "$CR" "$DG"

printf 'RESULT: PASS=%d FAIL=0 SKIP=0\n' "$PASS"
exit 0
