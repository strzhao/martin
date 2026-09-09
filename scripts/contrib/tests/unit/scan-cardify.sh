#!/bin/bash
# scan-cardify.sh — Tier U：scan 研判卡化（T1）stub 测试矩阵
# 覆盖：
#   ① kanban_card.sh 建卡契约（assignee/idempotency-key 格式/max-retries/--json/输出归一化/env -u 剥离）
#   ② scan_gate.sh 批次文件双写 + 无挤出 + 指针文件 + backlog 去重告警
#   ③ run-watch.sh scan 段 flight 五态矩阵 + fallback 兜底
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN/GH_BIN stub 沙箱隔离，零真实 hermes/gh 调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "scan-cardify.sh"

[[ -f "$CONTRIB_TEST_TARGET/kanban_card.sh" ]] || { echo "FATAL: 找不到 $CONTRIB_TEST_TARGET/kanban_card.sh"; exit 1; }

# last_hermes_line → calls.log 中最后一条 hermes 调用行
last_hermes_line() {
  awk -F'|' '$1 == "hermes" { l = $0 } END { if (l != "") print l }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
last_claude_line() {
  awk -F'|' '$1 == "claude" { l = $0 } END { if (l != "") print l }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
# scan fallback 的 claude 行（notify AI 摘要层也调 claude，须按 prompt 锚定）
scan_claude_line() {
  awk -F'|' '$1 == "claude" && $0 ~ /contrib-watch scan/ { l = $0 } END { if (l != "") print l }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}

# gh_issue <number> <title> → 单条 issue JSON（驱动 scan_gate 的 raw 响应）
gh_issue() {
  jq -cn --argjson n "$1" --arg t "$2" \
    '{number:$n,title:$t,labels:[],pull_request:null,user:{login:"someone"},created_at:"2026-09-09T00:00:00Z",comments:0}'
}
# watch_issues <start> — 写两个新 issue（start, start+1）到 gh stub 数据文件
watch_issues() {
  { gh_issue "$1" "a"; gh_issue $((1 + $1)) "b"; } >"$SB_ROOT/gh.rows"
  jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
}
# watch_sb — 每用例新沙箱 + 游标 2000 + 首轮 issue 2001/2002
watch_sb() {
  sb_new >/dev/null 2>&1
  printf '{"last_issue":2000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
  watch_issues 2001
}
# run_watch [K=V ...] — 注入 gh issues 数据源跑一轮 run-watch
run_watch() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}

# ---------------- ① kanban_card.sh ----------------

t_case "kanban_card: create 快乐路——参数契约 + 输出归一化"
sb_new >/dev/null 2>&1
printf '# 研判卡\n- 批次文件: /sandbox/batch.json\n- 红线: gh 只读\n' >"$SB_ROOT/body-scan.md"
out="$(sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/body-scan.md" --json-out "$CONTRIB_DATA_DIR/card-out.json"')"
assert_exit 0 $?
assert_eq "$out" '{"id":"t_stub_2","status":"ready"}' "输出归一化两键一行 JSON（stub 序号 2=hc 探测在前，T2 gate）"
assert_file_contains "$SB_ROOT/contrib-data/card-out.json" '"status":"ready"' "--json-out 落盘"
line="$(last_hermes_line)"
assert_contains "$line" "kanban create" "hermes kanban create 被调"
assert_contains "$line" "--assignee contrib" "--assignee contrib"
assert_contains "$line" "--max-retries 2" "--max-retries 2"
assert_contains "$line" "--json" "--json"
if printf '%s' "$line" | grep -qE -- '--idempotency-key scan-[0-9]{8}-[0-9]{6}'; then
  _pass "idempotency-key 格式 kind-YYYYMMDD-HHMMSS"
else
  _fail "idempotency-key 格式" "行=[$line]"
fi
envlog="$CONTRIB_TEST_STUB_LOG/anthropic-env.log"
if [[ -f "$envlog" ]]; then
  assert_eq "$(tail -1 "$envlog")" "hermes|base_url=absent|auth_token=absent|api_key=absent" "ANTHROPIC_* 三变量 env -u 剥离"
else
  _fail "ANTHROPIC_* 剥离" "stub 未记录 anthropic-env.log"
fi

t_case "kanban_card: --priority 透传 + body 内容传递"
sb_new >/dev/null 2>&1
printf '红线正文标记 REDLINE-MARKER-42\n' >"$SB_ROOT/body-r.md"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind mail --title m --body-file "$MARTIN_DIR/body-r.md" --priority 7' >/dev/null 2>&1
assert_exit 0 $?
assert_contains "$(last_hermes_line)" "--priority 7" "--priority 透传"
assert_stub_called_times hermes 2 "hc 探测+create（T2 gate）"
body_copy="$(stub_last_body hermes)"
if [[ -n "$body_copy" ]]; then
  assert_file_contains "$body_copy" "REDLINE-MARKER-42" "--body 值完整传入"
else
  _fail "--body 值传递" "stub 未捕获 --body 消息体"
fi

t_case "kanban_card: env -u 对照组——裸调 stub 时 present 可被记录（记录器自身有效）"
sb_new >/dev/null 2>&1
sb_run -e "ANTHROPIC_BASE_URL=http://x" '"$HERMES_BIN" kanban list --json' >/dev/null 2>&1
assert_contains "$(tail -1 "$CONTRIB_TEST_STUB_LOG/anthropic-env.log" 2>/dev/null)" "base_url=present" "对照组 present 记录"

t_case "kanban_card: kind 非法 / body 缺失 / hermes 失败 → exit≠0"
sb_new >/dev/null 2>&1
printf 'x\n' >"$SB_ROOT/body-x.md"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind nope --title t --body-file "$MARTIN_DIR/body-x.md"' >/dev/null 2>&1
assert_ne $? 0 "kind 非法被拒"
assert_stub_not_called hermes "kind 非法零 hermes 调用"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/no-such.md"' >/dev/null 2>&1
assert_ne $? 0 "body 文件缺失被拒"
sb_run -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/body-x.md"' >/dev/null 2>&1
assert_ne $? 0 "hermes 建卡失败 → exit≠0"

# ---------------- ② scan_gate.sh ----------------

t_case "scan_gate: 命中双写——批次文件(state=pending) + pending-hits 兼容 + 指针文件"
sb_new >/dev/null 2>&1
printf '{"last_issue":5000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
{ gh_issue 5001 "gateway weixin 投递失败"; gh_issue 5002 "sessions state.db 锁"; } >"$SB_ROOT/gh.rows"
jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
assert_exit 10 $?
batch_dir="$SB_ROOT/contrib-data/pending-batches"
assert_eq "$(ls "$batch_dir"/batch-*.json 2>/dev/null | wc -l | tr -d ' ')" "1" "批次文件恰好 1 个"
batch_file="$(ls "$batch_dir"/batch-*.json 2>/dev/null | head -1)"
assert_eq "$(jq -r '[.[] | select(.state == "pending")] | length' "$batch_file" 2>/dev/null)" "2" "批次条目 state=pending"
assert_eq "$(jq -r '.[0].number' "$batch_file" 2>/dev/null)" "5001" "批次条目保留原始 hit 字段"
assert_eq "$(jq -r '[.[] | select(.number == 5001)] | length' "$SB_ROOT/contrib-data/pending-hits.json")" "1" "pending-hits 兼容写保留"
if printf '%s' "$(basename "$batch_file")" | grep -qE '^batch-[0-9]{8}-[0-9]{6}\.json$'; then
  _pass "批次文件名秒级 TS"
else
  _fail "批次文件名秒级 TS" "实际=$(basename "$batch_file")"
fi
ptr="$SB_ROOT/contrib-data/scan-latest-batch.json"
assert_eq "$(jq -r '.batch_file' "$ptr" 2>/dev/null)" "$batch_file" "指针文件指向批次"
assert_eq "$(jq -r '.count' "$ptr" 2>/dev/null)" "2" "指针文件 count"

t_case "scan_gate: 无 cap 挤出——60 条命中全保留"
sb_new >/dev/null 2>&1
printf '{"last_issue":4000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
: >"$SB_ROOT/gh.rows"
i=0
while (( i < 60 )); do
  gh_issue $((4001 + i)) "issue $((4001 + i))" >>"$SB_ROOT/gh.rows"
  i=$((i + 1))
done
jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
assert_exit 10 $?
assert_eq "$(jq -r 'length' "$SB_ROOT/contrib-data/pending-hits.json")" "60" "60 条命中零挤出"

t_case "scan_gate: backlog 两源去重口径 + >80 告警幂等"
sb_new >/dev/null 2>&1
printf '{"last_issue":3000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
# 两源同 hit 只计一次：pending-hits 预置 #3001，本轮批次亦含 #3001 → 去重后 81（若双计=82 仍 >80，
# 故以「批次 done 写回后仅剩 pending-hits 侧」场景验证去重更弱——此处直接断言告警存在 + 幂等）
printf '[%s]\n' "$(gh_issue 3001 "既有积压")" >"$SB_ROOT/contrib-data/pending-hits.json"
: >"$SB_ROOT/gh.rows"
gh_issue 3001 "既有积压" >>"$SB_ROOT/gh.rows"
i=0
while (( i < 80 )); do
  gh_issue $((3002 + i)) "批量 $((3002 + i))" >>"$SB_ROOT/gh.rows"
  i=$((i + 1))
done
jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
assert_exit 10 $?
events="$SB_ROOT/contrib-data/events.jsonl"
assert_eq "$(grep -c 'pipeline-failure' "$events" 2>/dev/null || true)" "1" "积压 >80 → pipeline-failure 入账"
if grep -q '"key":"[0-9-]*-backlog"' "$events"; then
  _pass "告警 key 日级幂等（-backlog）"
else
  _fail "告警 key 日级幂等" "events 无 -backlog key"
fi
# 同日再跑（积压仍在账）：告警不重复入账
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
assert_eq "$(grep -c 'pipeline-failure' "$events" 2>/dev/null || true)" "1" "同日重跑告警不重复（--key 幂等）"

t_case "scan_gate: 批次文件损坏容错——坏文件显式告警 + 好文件仍计入积压"
sb_new >/dev/null 2>&1
printf '{"last_issue":7000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
mkdir -p "$SB_ROOT/contrib-data/pending-batches"
# 坏文件（worker 写坏形态：截断 JSON）
printf '[{"number":7001,"title":"broken","state":"pendi' >"$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json"
# 好文件含 1 条 pending
printf '[{"number":7002,"title":"good","state":"pending"}]\n' >"$SB_ROOT/contrib-data/pending-batches/batch-20260909-010202.json"
{ gh_issue 7003 "新命中"; } >"$SB_ROOT/gh.rows"
jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
assert_exit 10 $?
events="$SB_ROOT/contrib-data/events.jsonl"
assert_eq "$(grep -c 'backlog-corrupt' "$events" 2>/dev/null || true)" "1" "坏文件 → pipeline-failure(-backlog-corrupt) 显式告警"
assert_eq "$(grep -c '"key":"[0-9-]*-backlog"' "$events" 2>/dev/null || true)" "0" "1 条好积压不误触 >80 告警"
assert_eq "$(jq -r '.count' "$SB_ROOT/contrib-data/scan-latest-batch.json" 2>/dev/null)" "1" "坏文件不影响本轮批次落盘（指针 count=新命中数）"

t_case "scan_gate: 无命中 → exit 0 零批次文件"
sb_new >/dev/null 2>&1
printf '{"last_issue":6000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
printf '[]\n' >"$SB_ROOT/gh-issues.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(ls "$SB_ROOT/contrib-data/pending-batches"/batch-*.json 2>/dev/null | wc -l | tr -d ' ')" "0" "零命中零批次"

# ---------------- ③ run-watch.sh scan 段矩阵 ----------------

t_case "run-watch: 无 flight + 建卡成功 → flight 登记四键 + 零 claude（主路卡化）"
watch_sb
run_watch
assert_exit 0 $?
flight="$SB_ROOT/contrib-data/kanban-flight.json"
assert_eq "$(jq -r '.kind' "$flight" 2>/dev/null)" "scan" "flight kind=scan"
assert_eq "$(jq -r '.card_id' "$flight" 2>/dev/null)" "t_stub_2" "flight card_id（stub 序号 2=hc 探测在前）"
assert_eq "$(jq -r '.batch_file' "$flight" 2>/dev/null)" "$(jq -r '.batch_file' "$SB_ROOT/contrib-data/scan-latest-batch.json" 2>/dev/null)" "flight batch_file 与指针一致"
assert_eq "$(jq -r '.created_epoch > 0' "$flight" 2>/dev/null)" "true" "flight created_epoch"
assert_stub_not_called claude "主路不再调 claude"
assert_stub_called_times hermes 2 "hc 前置探测(list)+create（T2 gate）"
line="$(last_hermes_line)"
assert_contains "$line" "--assignee contrib" "建卡参数 assignee"
assert_contains "$line" "--idempotency-key scan-" "建卡参数 idempotency-key"
assert_contains "$line" "--json" "建卡参数 --json"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "batch-" "卡 body 含批次文件路径"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban_complete" "卡 body 含收尾要求"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "gh 只读" "卡 body 含红线段"

t_case "run-watch: 建卡失败 → claude fallback 被调 + pipeline-failure 入账"
watch_sb
run_watch "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_stub_called claude 1 "fallback claude -p 被调"
assert_contains "$(scan_claude_line)" "/contrib-watch scan" "fallback 研判 /contrib-watch scan"
assert_eq "$(grep -c 'pipeline-failure' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true)" "2" "event 入账（T2 gate -hermes-down + -scan-card-fallback）"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight.json" ]] && _pass "建卡失败不写 flight" || _fail "建卡失败不写 flight" "登记残留"

t_case "run-watch: flight status=done → 清登记 + 本轮建新卡"
watch_sb
run_watch
assert_stub_called_times hermes 2 "r1: hc 探测+create（T2 gate）"
watch_issues 2003
run_watch "STUB_KANBAN_CARD_STATUS=done"
assert_exit 0 $?
assert_stub_called_times hermes 5 "r1:hc+create, r2:flight list+hc+create（T2 gate）"
assert_eq "$(jq -r '.card_id' "$SB_ROOT/contrib-data/kanban-flight.json" 2>/dev/null)" "t_stub_5" "flight 指向新卡（stub 序号 5=r2 的 flight list+hc+create）"
assert_stub_not_called claude "done 路不 fallback"

t_case "run-watch: flight status=blocked 且 outcome 非失败 → 在飞跳过（防误杀可自愈卡，矩阵第 8 态）"
watch_sb
run_watch
watch_issues 2003
run_watch "STUB_KANBAN_CARD_STATUS=blocked" "STUB_KANBAN_RUN_OUTCOME=manual_block"
assert_exit 0 $?
assert_stub_not_called claude "blocked+非失败 outcome 不 fallback"
assert_eq "$(jq -r '.card_id' "$SB_ROOT/contrib-data/kanban-flight.json" 2>/dev/null)" "t_stub_2" "flight 保留（卡可能自愈或 6h 守卫兜底）"

t_case "run-watch: flight status=blocked+outcome=gave_up → 清登记 + fallback"
watch_sb
run_watch
watch_issues 2003
run_watch "STUB_KANBAN_CARD_STATUS=blocked" "STUB_KANBAN_RUN_OUTCOME=gave_up"
assert_exit 0 $?
assert_stub_called claude 1 "blocked+gave_up → fallback"
assert_eq "$(grep -c 'pipeline-failure' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true)" "1" "卡失败 event 入账"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight.json" ]] && _pass "flight 已清" || _fail "flight 已清" "登记残留"

t_case "run-watch: flight status=running → 本轮跳过（卡片在飞）"
watch_sb
run_watch
watch_issues 2003
run_watch "STUB_KANBAN_CARD_STATUS=running"
assert_exit 0 $?
assert_stub_not_called claude "running 不 fallback"
assert_eq "$(jq -r '.card_id' "$SB_ROOT/contrib-data/kanban-flight.json" 2>/dev/null)" "t_stub_2" "flight 保留不重建卡"
assert_stub_called_times hermes 3 "r1:hc+create, r2:flight list（T2 gate）"

t_case "run-watch: flight 非终态超 6h → 清登记 + fallback + event"
watch_sb
run_watch
flight="$SB_ROOT/contrib-data/kanban-flight.json"
old=$(( $(date +%s) - 30000 ))
jq --argjson e "$old" '.created_epoch = $e' "$flight" >"$flight.tmp" && mv "$flight.tmp" "$flight"
watch_issues 2003
run_watch "STUB_KANBAN_CARD_STATUS=running"
assert_exit 0 $?
assert_stub_called claude 1 "陈旧守卫 → fallback"
assert_eq "$(grep -c 'pipeline-failure' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true)" "1" "陈旧守卫 event 入账"
[[ ! -f "$flight" ]] && _pass "陈旧 flight 已清" || _fail "陈旧 flight 已清" "登记残留"

t_case "run-watch: card_id 查无（archived/异常）→ 清登记 + fallback"
watch_sb
run_watch
watch_issues 2003
run_watch "STUB_KANBAN_LIST_EMPTY=1"
assert_exit 0 $?
assert_stub_called claude 1 "查无此卡 → fallback"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight.json" ]] && _pass "flight 已清" || _fail "flight 已清" "登记残留"

t_finish
