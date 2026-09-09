#!/usr/bin/env bash
# =============================================================================
# t1-03-run-watch-flight.acceptance.test.sh — T1 验收矩阵③（+QC 顺延 + 零订阅隔离）
#   run-watch scan 段 flight 七态：无 flight 建卡成功 / 建卡失败→fallback+event /
#   done→清+本轮建卡 / blocked→清+fallback / running→跳过 / 非终态超 6h→清+fallback+event /
#   card_id 查无→清+fallback；QC_OPEN==1 顺延语义不变；主路不再直调 claude；零订阅零审批
# 依据：state.md「3. run-watch.sh scan 段重构」+ 契约 4（fallback）/契约 5（在飞登记）/
#   任务级契约「卡终态闭集：done=成功终态；blocked+outcome∈{gave_up,crashed,timed_out,
#   spawn_failed}=失败终态；"failed" 不是合法状态值（任何断言不引用该字面量）」
# 影子 stub 契约（tests/stubs/hermes 扩展能力，按设计 §5 声明的能力消费，黑盒实测）：
#  - `kanban list --json` 输出 $STUB_LOG_DIR/kanban-cards.jsonl 卡库（每行一卡 JSON 对象）
#    → 终态前置态经该文件播种（status: done/blocked/running/…）
#  - `kanban show <id> --json` 输出 {"task":{"id","status"},"runs":[{"outcome"}]}，
#    status/outcome 由 STUB_KANBAN_STATUS / STUB_KANBAN_OUTCOME env 控制
#  - 「card_id 查无（archived/异常）视同失败」→ 卡库清空表达「查无」
#  - 建卡失败 → STUB_HERMES_FAIL=1
# CONTRACT_AMBIGUOUS：
#  - 6h 陈旧守卫边界（>21600）秒级竞速不可稳定采样：以 ±5s 守卫窗覆盖
#    （21595s→必跳过；21605s→必 fallback），杀掉 6h→其他量级的 Boundary 突变
# 红队纪律：黑盒；每断言硬失败；无 skip。
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

mk_issues() {
  local out="$1" s="$2" e="$3" i
  {
    printf '['
    for ((i = s; i <= e; i++)); do
      [ "$i" -gt "$s" ] && printf ','
      printf '{"number":%d,"title":"gateway regression %d","labels":[{"name":"bug"}],"user":{"login":"alice"},"created_at":"2026-09-09T00:00:00Z","comments":0,"pull_request":null}' "$i" "$i"
    done
    printf ']\n'
  } > "$out"
}

seed_cursor() {
  jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' > "$SB_ROOT/contrib-data/scan-cursor.json"
}

seed_flight() { # <card_id> <created_epoch>
  jq -n --arg id "$1" --arg bf "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" --argjson ep "$2" \
    '{kind:"scan",card_id:$id,batch_file:$bf,created_epoch:$ep}' > "$SB_ROOT/contrib-data/kanban-flight-scan.json"
}

seed_card_store() { # <status>：在飞查询的前置态（卡库 1 张 t_old 卡）
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

seed_card_store_empty() { # 「card_id 查无」前置态
  : > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

hermes_lines()    { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_span()     { awk '/^hermes\|/{f=($0 ~ /kanban create/)} f' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls()    { hermes_lines | grep -c 'kanban create' || true; }
list_calls()      { hermes_lines | grep -c 'kanban list' || true; }
claude_scan_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'contrib-watch scan' || true; }

flight_card_id() { jq -r '.card_id // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null || echo ""; }
flight_exists()  { [ -s "$SB_ROOT/contrib-data/kanban-flight-scan.json" ]; }

pipeline_failure_count() {
  jq -s '[.[] | select(.class == "pipeline-failure")] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

GHF="" # STUB_GH_ISSUES_FILE 传参（common_setup 里随沙箱路径生成）

# common_setup：新沙箱 + 游标/gh 注入（1 条新命中 → scan_gate exit 10）
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mk_issues "$SB_ROOT/tmp/issues.json" 101 101
  seed_cursor 100
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}

# run_watch [-e K=V]...：黑盒跑 run-watch（始终注入 gh issues 文件）
run_watch() { sb_run -e "$GHF" "$@"; }

ge1() { # <n> <label>：≥1 硬断言（查询次数属实现细节，行为断言不受调用次数影响）
  case "${1:-}" in
    ''|*[!0-9]*) _fail "$2" "非数值 [$1]" ;;
    *) [ "$1" -ge 1 ] && _pass "$2" || _fail "$2" "实得 $1 < 1" ;;
  esac
}

# =============================================================================
t_case "3.1 无 flight → 建卡成功：主路建卡、零 claude、flight 登记、body 含批次路径+红线+收尾、零订阅零审批"
common_setup
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "3.1 run-watch exit"
assert_eq "$(create_calls)" "1" "3.1 恰 1 次 hermes kanban create（主路建卡）"
assert_ge "$(list_calls)" "1" "3.1 无 flight → ≥1 次 kanban list（T2 create 前置 healthcheck 探测，语义演进 09-09）"
assert_eq "$(claude_scan_calls)" "0" "3.1 主路不再直调 claude -p '/contrib-watch scan'（fallback 保留但不在主路触发）"
flight_exists && _pass "3.1 flight 登记存在" || _fail "3.1 flight 登记存在" "kanban-flight-scan.json 未产出（契约 5）"
CID="$(flight_card_id)"
case "$CID" in "") _fail "3.1 flight.card_id 非空" "card_id 为空（建卡 id 提取 No-op？）" ;; *) _pass "3.1 flight.card_id 非空（${CID}）" ;; esac
KIND="$(jq -r '.kind // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)"
assert_eq "$KIND" "scan" "3.1 flight.kind=scan"
BFEPOCH="$(jq -r '.created_epoch // 0' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)"
case "$BFEPOCH" in ''|*[!0-9]*) _fail "3.1 created_epoch 数值" "实得 [$BFEPOCH]" ;; *) [ "$BFEPOCH" -gt 0 ] && _pass "3.1 created_epoch>0" || _fail "3.1 created_epoch>0" "实得 $BFEPOCH" ;; esac
FBF="$(jq -r '.batch_file // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)"
if [ -n "$FBF" ] && [ -f "$FBF" ]; then
  _pass "3.1 flight.batch_file 指向真实批次文件"
  PTR="$(jq -r '.batch_file // ""' "$SB_ROOT/contrib-data/scan-latest-batch.json" 2>/dev/null)"
  assert_eq "$FBF" "$PTR" "3.1 flight.batch_file == scan-latest-batch 指针（同源）"
else
  _fail "3.1 flight.batch_file 指向真实批次文件" "实得 [$FBF]"
fi
BODYF="$(ls "$SB_ROOT"/contrib-data/pending-batches/*.body.md 2>/dev/null | head -1)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  _pass "3.1 卡 body 文件（batch-<TS>.body.md）已生成"
  assert_file_contains "$BODYF" "$FBF" "3.1 body 含批次文件绝对路径"
  assert_file_contains "$BODYF" "kanban_complete" "3.1 body 含收尾要求（kanban_complete）"
  assert_file_contains "$BODYF" "SKILL.md" "3.1 body 含 rubric 权威路径（SKILL.md 模式段）"
else
  _fail "3.1 卡 body 文件已生成" "$SB_ROOT/contrib-data/pending-batches/*.body.md 无产物"
fi
# 卡 body 多行 → calls.log 物理行被拆 → 用 create_span 取该调用完整行段断言
SPAN="$(create_span)"
assert_contains "$SPAN" "kanban create" "3.1 调用形态=hermes kanban create"
assert_contains "$SPAN" "--assignee contrib" "3.1 建卡经 kanban_card 契约参数（--assignee contrib）"
assert_contains "$SPAN" "--json" "3.1 建卡带 --json（解析卡 id 契约）"
assert_contains "$SPAN" "--max-retries 2" "3.1 建卡带 --max-retries 2"
assert_contains "$SPAN" "--idempotency-key scan-" "3.1 建卡带 scan 前缀幂等键"
assert_contains "$SPAN" "$FBF" "3.1 建卡 argv 携带批次文件路径（acceptance：body 含批次路径）"
assert_not_contains "$SPAN" "subscribe" "3.1 零订阅：scan 卡 create argv 禁 subscribe（终态零推送语义）"
assert_eq "$(pipeline_failure_count)" "0" "3.1 零 pipeline-failure 事件"
assert_eq "$(notify_approvals)" "0" "3.1 notify-state approvals 零新增（零订阅语义）"
sb_cleanup

# =============================================================================
t_case "3.2 建卡失败 → fallback：claude -p 旧路被调 + pipeline-failure event + 零 flight 登记"
common_setup
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_eq "$(claude_scan_calls)" "1" "3.2 建卡失败 → fallback claude -p '/contrib-watch scan' 被调"
assert_eq "$(create_calls)" "1" "3.2 前置：create 确实被尝试（stub 注毒生效）"
flight_exists && _fail "3.2 失败不写 flight" "建卡失败仍留下 kanban-flight-scan.json（会把下轮锁死在在飞态）" || _pass "3.2 失败不写 flight"
assert_eq "$(pipeline_failure_count)" "2" "3.2 pipeline-failure 事件入账（T2：hermes-down 首败 1 条 + fallback 1 条，语义演进 09-09）"
sb_cleanup

# =============================================================================
t_case "3.3 flight done → 清登记 + 本轮继续建新卡（终态闭集：done=成功终态）"
common_setup
seed_flight "t_old" "$(date +%s)"
seed_card_store "done"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "3.3 run-watch exit"
ge1 "$(list_calls)" "3.3 在飞查询 kanban list 被调"
assert_eq "$(create_calls)" "1" "3.3 done → 本轮继续走建卡支路"
CID="$(flight_card_id)"
assert_ne "$CID" "t_old" "3.3 旧登记已清、换新卡（实得 ${CID}）"
case "$CID" in "") _fail "3.3 新 card_id 非空" "为空" ;; *) _pass "3.3 新 card_id 非空" ;; esac
assert_eq "$(claude_scan_calls)" "0" "3.3 done 路不触发 fallback"
sb_cleanup

# =============================================================================
t_case "3.4 flight blocked+outcome=gave_up → 清登记 + fallback + event（blocked=outcome 闭集内的失败终态）"
common_setup
seed_flight "t_old" "$(date +%s)"
seed_card_store "blocked"
run_watch -e STUB_KANBAN_STATUS=blocked -e STUB_KANBAN_OUTCOME=gave_up 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
ge1 "$(list_calls)" "3.4 在飞查询被调"
assert_eq "$(create_calls)" "0" "3.4 失败终态不建新卡"
assert_eq "$(claude_scan_calls)" "1" "3.4 blocked → fallback claude 旧路被调"
if flight_exists; then
  assert_eq "$(flight_card_id)" "" "3.4 登记已清（card_id 空）"
else
  _pass "3.4 登记文件已清除"
fi
assert_eq "$(pipeline_failure_count)" "1" "3.4 pipeline-failure 事件入账"
sb_cleanup

# =============================================================================
t_case "3.5 flight running（非终态、未超时）→ 本轮跳过：不建卡、不 fallback、登记保留"
common_setup
seed_flight "t_old" "$(date +%s)"
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "3.5 run-watch exit"
ge1 "$(list_calls)" "3.5 在飞查询被调"
assert_eq "$(create_calls)" "0" "3.5 卡在飞 → 不建新卡（同 kind 单飞，契约 5）"
assert_eq "$(claude_scan_calls)" "0" "3.5 在飞 → 不触发 fallback"
assert_eq "$(flight_card_id)" "t_old" "3.5 登记保留"
assert_eq "$(pipeline_failure_count)" "0" "3.5 正常在飞零告警"
sb_cleanup

# =============================================================================
t_case "3.6a 非终态 <6h → 仍跳过（陈旧守卫下界守卫窗：21595s）"
common_setup
seed_flight "t_old" "$(( $(date +%s) - 21595 ))"
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(create_calls)" "0" "3.6a 未超 6h → 不建新卡"
assert_eq "$(claude_scan_calls)" "0" "3.6a 未超 6h → 不 fallback"
assert_eq "$(flight_card_id)" "t_old" "3.6a 登记保留"
sb_cleanup

t_case "3.6b 非终态 >6h → 清登记 + fallback + event（陈旧守卫防停摆放大）"
common_setup
seed_flight "t_old" "$(( $(date +%s) - 21605 ))"
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(create_calls)" "0" "3.6b 陈旧在飞不建新卡"
assert_eq "$(claude_scan_calls)" "1" "3.6b 陈旧守卫触发 fallback"
if flight_exists; then
  assert_eq "$(flight_card_id)" "" "3.6b 登记已清"
else
  _pass "3.6b 登记文件已清除"
fi
assert_eq "$(pipeline_failure_count)" "1" "3.6b pipeline-failure 事件入账"
sb_cleanup

# =============================================================================
t_case "3.7 card_id 查无（archived/异常视同失败）→ 清登记 + fallback + event"
common_setup
seed_flight "t_old" "$(date +%s)"
seed_card_store_empty
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
ge1 "$(list_calls)" "3.7 在飞查询被调"
assert_eq "$(create_calls)" "0" "3.7 查无 → 不建新卡（异常视同失败走兜底）"
assert_eq "$(claude_scan_calls)" "1" "3.7 查无 → fallback 被调"
if flight_exists; then
  assert_eq "$(flight_card_id)" "" "3.7 登记已清"
else
  _pass "3.7 登记文件已清除"
fi
assert_eq "$(pipeline_failure_count)" "1" "3.7 pipeline-failure 事件入账"
sb_cleanup

# =============================================================================
t_case "3.8 QC_OPEN==1 → 建卡照常发起（T2 新语义：QC 只挡 claude 兜底路，不挡 deepseek 卡路；旧顺延断言已由 t2-01 独立覆盖新契约）"
common_setup
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SB_ROOT/contrib-data/.quota-circuit"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(create_calls)" "1" "3.8 断路器开闸 → 建卡照常发起（T2 契约 1：建卡不受 QC 限）"
assert_eq "$(claude_scan_calls)" "0" "3.8 断路器开闸 → 零 claude"
flight_exists && _pass "3.8 开闸期 flight 正常登记" || _fail "3.8 开闸期 flight 正常登记" "建卡成功应写 flight"
sb_cleanup

t_finish
