#!/usr/bin/env bash
# =============================================================================
# t1-01-kanban-card-create.acceptance.test.sh — T1 验收矩阵①
#   kanban_card.sh create 参数断言：--assignee contrib / --idempotency-key 秒级 /
#   --max-retries 2 / --json / 输出两键归一化 / env -u 三变量剥离 / 失败 exit≠0+stderr /
#   --json-out 落盘 / 零订阅（create argv 禁 subscribe）
# 依据：state.md 契约「1. kanban_card.sh 设计（契约钉死）」+ 任务级契约
#   「kanban_card.sh 输出闭集：成功=一行 JSON（id/status 两键，helper 自行归一化），失败=exit≠0」
#   「零订阅语义：scan 卡 CLI 建卡默认零微信订阅」
# 影子 stub 契约（tests/stubs/hermes 扩展能力，本测试仅按设计 §5 声明的能力消费）：
#  - `kanban create` 输出上游形态多键 dict（含 id/status 之外字段）→ 支撑归一化断言
#  - ANTHROPIC_* env 存在性记录 → $STUB_LOG_DIR/anthropic-env.log，行形如
#    `hermes|base_url=<present|absent>|auth_token=<present|absent>|api_key=<present|absent>`
# CONTRACT_AMBIGUOUS：
#  - [--json-out <path>] 语义未细述 → 断言「文件存在 + 合法 JSON + .id 与 stdout 一致」
# 红队纪律：黑盒（未读任何实现代码）；每断言硬失败；无 skip。
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

# ---- 本文件专用工具 ----

# run_card <args...>：黑盒调用沙箱内 kanban_card.sh（stdout 捕获、rc 走 $?）
run_card() {
  local a snippet=""
  for a in "$@"; do snippet+="$(printf '%q ' "$a")"; done
  sb_run "bash \"\$MARTIN_DIR/scripts/contrib/kanban_card.sh\" $snippet"
}

hermes_lines() { cat "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_line()  { hermes_lines | grep '^hermes|' | grep 'kanban create' | tail -1; }

# =============================================================================
t_case "1.1 create 成功：stdout=单行 JSON，键闭集恰为 {id,status}（输出归一化反 No-op：stub 原始输出 4 键，透传必红）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf '批次路径与红线段占位 ACC-BODY-MARKER-9f2c\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title "T1 验收卡" --body-file "$SB_ROOT/tmp/body.md")"
RC=$?
assert_exit 0 $RC "1.1 exit"
NLINES="$(printf '%s\n' "$OUT" | grep -c . )"
assert_eq "$NLINES" 1 "1.1 stdout 恰一行"
KEYS="$(printf '%s' "$OUT" | jq -cr 'keys | sort | join(",")' 2>/dev/null)"
assert_eq "$KEYS" "id,status" "1.1 键闭集恰 {id,status}（上游多余键 assignee/priority 必须被剥掉）"
CID="$(printf '%s' "$OUT" | jq -r '.id // ""' 2>/dev/null)"
case "$CID" in "") _fail "1.1 卡 id 非空" "id 为空/缺失" ;; *) _pass "1.1 卡 id 非空" ;; esac
ST="$(printf '%s' "$OUT" | jq -r '.status // ""' 2>/dev/null)"
case "$ST" in "") _fail "1.1 status 非空" "status 为空/缺失" ;; *) _pass "1.1 status 非空（${ST}）" ;; esac
sb_cleanup

# =============================================================================
t_case "1.2 create 必带参数：kanban create/--assignee contrib/--idempotency-key 秒级/--max-retries 2/--json/--body 内容透传/--priority 透传；零订阅"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf 'ACC-BODY-MARKER-9f2c 批次文件绝对路径占位\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title "T1 验收卡" --body-file "$SB_ROOT/tmp/body.md" --priority 2)"
RC=$?
assert_exit 0 $RC "1.2 exit"
LINE="$(create_line)"
assert_contains "$LINE" "kanban create" "1.2 调用形态=hermes kanban create"
assert_contains "$LINE" "--assignee contrib" "1.2 --assignee contrib"
assert_contains "$LINE" "--json" "1.2 --json"
assert_contains "$LINE" "--max-retries 2" "1.2 --max-retries 2"
assert_contains "$LINE" "ACC-BODY-MARKER-9f2c" "1.2 --body 透传 body-file 内容"
KEYARG="$(printf '%s' "$LINE" | grep -oE -- '--idempotency-key [^ ]+' | awk '{print $2}')"
case "$KEYARG" in
  scan-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
    _pass "1.2 idempotency-key=<kind>-<YYYYMMDD-HHMMSS> 秒级（实得 $KEYARG)" ;;
  *) _fail "1.2 idempotency-key 秒级格式" "实得 [$KEYARG]，期望 scan-<YYYYMMDD-HHMMSS>" ;;
esac
assert_contains "$LINE" "--priority 2" "1.2 --priority 透传"
assert_not_contains "$LINE" "subscribe" "1.2 零订阅：create argv 禁含 subscribe"
sb_cleanup

# =============================================================================
t_case "1.3 env -u 三变量剥离：父 env 携带 ANTHROPIC_* 时 hermes 子进程 env 记录必须三者皆 absent（反 No-op：删 env -u 必红）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(sb_run -e ANTHROPIC_BASE_URL=https://evil.example -e ANTHROPIC_AUTH_TOKEN=sk-test-1 -e ANTHROPIC_API_KEY=sk-test-2 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/tmp/body.md"')"
RC=$?
assert_exit 0 $RC "1.3 exit"
ENVLOG="$SB_ROOT/stublog/anthropic-env.log"
if [ ! -s "$ENVLOG" ]; then
  _fail "1.3 env 观测记录" "$ENVLOG 缺失/空（hermes 未被调用或 stub 未记录 env）"
else
  PRESENT_N="$(grep -c '=present' "$ENVLOG" || true)"
  CLEAN_N="$(grep -c 'base_url=absent|auth_token=absent|api_key=absent' "$ENVLOG" || true)"
  assert_eq "$PRESENT_N" "0" "1.3 子进程 env 记录 present 计数（必须 0）"
  case "$CLEAN_N" in
    ''|*[!0-9]*) _fail "1.3 全 absent 行数" "非数值 [$CLEAN_N]" ;;
    *) [ "$CLEAN_N" -ge 1 ] && _pass "1.3 三变量全 absent 记录存在（$CLEAN_N 行）" || _fail "1.3 全 absent 行数" "无 base_url/auth_token/api_key 全 absent 记录" ;;
  esac
fi
sb_cleanup

# =============================================================================
t_case "1.4 --json-out 落盘：文件存在、合法 JSON、.id 与 stdout 一致"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t --body-file "$SB_ROOT/tmp/body.md" --json-out "$SB_ROOT/tmp/card.json")"
RC=$?
assert_exit 0 $RC "1.4 exit"
if [ -f "$SB_ROOT/tmp/card.json" ]; then
  _pass "1.4 json-out 文件存在"
  FILE_ID="$(jq -r '.id // ""' "$SB_ROOT/tmp/card.json" 2>/dev/null)"
  OUT_ID="$(printf '%s' "$OUT" | jq -r '.id // ""' 2>/dev/null)"
  assert_eq "$FILE_ID" "$OUT_ID" "1.4 json-out 文件与 stdout 卡 id 一致且为合法 JSON"
else
  _fail "1.4 json-out 文件存在" "$SB_ROOT/tmp/card.json 未产出"
fi
sb_cleanup

# =============================================================================
t_case "1.5 建卡失败：exit≠0 + stderr 原因（输出闭集：失败=exit≠0）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(sb_run -e STUB_HERMES_FAIL=1 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/tmp/body.md"')"
RC=$?
case "$RC" in 0) _fail "1.5 失败 exit" "STUB_HERMES_FAIL=1 下仍 exit 0（无失败面=假成功）";; *) _pass "1.5 失败 exit≠0（rc=${RC}）";; esac
ERR="$(sb_out 40 | tr -d '[:space:]')"
case "$RC" in
  0) : ;;
  *) if [ -n "$ERR" ]; then _pass "1.5 stderr 非空（含原因）"; else _fail "1.5 stderr 非空" "stderr 为空，无失败原因"; fi ;;
esac
sb_cleanup

# =============================================================================
t_case "1.6 幂等键 kind 前缀随 --kind 变化（scan-/mail-）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf 'x\n' > "$SB_ROOT/tmp/body.md"
run_card create --kind mail --title t --body-file "$SB_ROOT/tmp/body.md" >/dev/null
LINE="$(create_line)"
KEYARG="$(printf '%s' "$LINE" | grep -oE -- '--idempotency-key [^ ]+' | awk '{print $2}')"
case "$KEYARG" in
  mail-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
    _pass "1.6 kind=mail 前缀正确（${KEYARG}）" ;;
  *) _fail "1.6 kind 前缀" "实得 [$KEYARG]，期望 mail-<YYYYMMDD-HHMMSS>" ;;
esac
sb_cleanup

t_finish
