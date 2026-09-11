#!/usr/bin/env bash
# =============================================================================
# t6-04-run-watch-slim-five-states.acceptance.test.sh — T6 验收④：run-watch 瘦身后五态行为
#   矩阵回归 + QC 断路器行为面保留 + QC_OPEN 死变量静态锚
#   W1  无命中（gate exit 0）→ 零建卡零 claude 零告警零 flight
#   W2  有命中（gate exit 10）→ scan 卡建 + flight 登记（batch_file==指针同源）+ 零 claude
#   W3  在飞（running 未超时）→ 本轮跳过：不建卡不 fallback、登记保留
#   W4  失败（blocked+outcome 闭集）→ fallback claude + 告警 + 登记清
#   W5  建卡失败（hermes 不可用）→ fallback claude + 告警 + 零 flight
#   W6  错过 radar（非 08 窗口 + 补跑旗标）→ radar 卡照建（补跑）、旗标保留、radar flight 登记
#   W7  QC 开 + 有命中 → 建卡照常发起 + 零 claude（QC 只挡兜底路，T2 语义收窄保持）
#   W8  QC 开 + radar 补跑 + 建卡失败 → radar fallback 被 QC 挡（零 claude + -radar-fallback-
#       skipped 告警 + 旗标保留）——「保留 QC check 本身」的行为锚（deep_check_gate 同依赖）
#   W9  静态锚：run-watch.sh 零 QC_OPEN token（死变量+陈旧注释清理；行为面由 W7/W8 钉死防
#       QC check 一并被清的 No-op 突变）
# 依据：state.md 输出契约 2「run-watch 瘦身：五段骨架（scan gate→建卡/flight、mail gate→建卡、
#   radar、notify flush、快车道 deepcheck）保留；QC_OPEN 死变量与陈旧注释清理（保留 QC check
#   本身）」+ 验收标准 5「五态行为矩阵回归」+ 契约 4「rq.sh/deep_check_gate/…核心语义零变化」
# 说明：run_phase 超时包裹的收窄（只裹 fallback claude 路+flight 查询）属实现内部形态，行为面
#   由本矩阵覆盖；五段骨架逐一存活在本矩阵各态中隐式自证（scan/mail/radar/flush/deepcheck 段
#   全部跑过且互不干扰）。
# CONTRACT_AMBIGUOUS：无
# 红队纪律：黑盒；每断言硬失败；无 skip。
# Mental Mutation：瘦身误删五段之一→对应态红；QC check 本体被连同死变量一起删→W8 红；
#   QC 语义回退成「挡建卡」→W7 红；radar 补跑旗标语义丢→W6 红；QC_OPEN 只改注释没删→W9 红。
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

SCRIPTS_DIR="$(tests_scripts_dir "$REPO_ROOT/scripts/contrib")"

# ---- 本文件专用工具（镜像 t1-03 范式）----

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

seed_cursor() { jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' > "$SB_ROOT/contrib-data/scan-cursor.json"; }

seed_flight() { # <card_id> <created_epoch>
  jq -n --arg id "$1" --arg bf "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" --argjson ep "$2" \
    '{kind:"scan",card_id:$id,batch_file:$bf,created_epoch:$ep}' > "$SB_ROOT/contrib-data/kanban-flight-scan.json"
}

seed_card_store() { printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" > "$SB_ROOT/stublog/kanban-cards.jsonl"; }

hermes_lines()      { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls()      { hermes_lines | grep -c 'kanban create' || true; }
scan_create_calls() { hermes_lines | grep -c 'kanban create.*idempotency-key scan-' || true; }
radar_create_calls(){ hermes_lines | grep -c 'contrib radar' || true; }
claude_scan_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'contrib-watch scan' || true; }
claude_radar_calls(){ grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'contrib-watch radar' || true; }
claude_any_calls()  { grep -c '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }

flight_card_id() { jq -r '.card_id // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null || echo ""; }
flight_exists()  { [ -s "$SB_ROOT/contrib-data/kanban-flight-scan.json" ]; }

pipeline_failure_count() {
  jq -s '[.[] | select(.class == "pipeline-failure")] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

event_key_count() { # <key 后缀> → 匹配 event 条数
  jq -s --arg k "$1" '[.[] | select(((.key // "") | endswith($k)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

GHF=""
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mkdir -p "$SB_ROOT/tmp"
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}
run_watch() { sb_run -e "$GHF" "$@"; }

# =============================================================================
t_case "W1 无命中 → 零建卡零 claude 零告警零 flight（scan 段骨架存活且安静）"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 90 99    # 全部 <= 游标
seed_cursor 100
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "4.1 run-watch exit"
assert_eq "$(create_calls)" "0" "4.1 零建卡"
assert_eq "$(claude_any_calls)" "0" "4.1 零 claude（任何模式）"
assert_eq "$(pipeline_failure_count)" "0" "4.1 零告警入账"
flight_exists && _fail "4.1 零 flight" "无命中却留下 kanban-flight-scan.json" || _pass "4.1 零 flight"
sb_cleanup

# =============================================================================
t_case "W2 有命中 → scan 卡建 + flight 登记（batch_file==指针同源）+ 零 claude"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "4.2 run-watch exit"
assert_eq "$(scan_create_calls)" "1" "4.2 恰 1 张 scan 卡"
assert_eq "$(claude_any_calls)" "0" "4.2 主路零 claude"
flight_exists && _pass "4.2 flight 登记存在" || _fail "4.2 flight 登记存在" "kanban-flight-scan.json 未产出"
assert_eq "$(jq -r '.kind // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json")" "scan" "4.2 flight.kind=scan"
case "$(flight_card_id)" in "") _fail "4.2 card_id 非空" "为空" ;; *) _pass "4.2 card_id 非空（$(flight_card_id)）" ;; esac
FBF="$(jq -r '.batch_file // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)"
PTR="$(jq -r '.batch_file // ""' "$SB_ROOT/contrib-data/scan-latest-batch.json" 2>/dev/null)"
assert_eq "$FBF" "$PTR" "4.2 flight.batch_file == scan-latest-batch 指针（批次文件唯一数据源，骨架未瘦掉）"
sb_cleanup

# =============================================================================
t_case "W3 在飞（running 未超时）→ 跳过：不建卡不 fallback、登记保留、零告警"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
seed_flight "t_old" "$(date +%s)"
seed_card_store "running"
run_watch -e STUB_KANBAN_CARD_STATUS=running 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "4.3 run-watch exit"
assert_eq "$(scan_create_calls)" "0" "4.3 卡在飞不建新卡（同 kind 单飞）"
assert_eq "$(claude_any_calls)" "0" "4.3 在飞零 fallback"
assert_eq "$(flight_card_id)" "t_old" "4.3 登记保留"
assert_eq "$(pipeline_failure_count)" "0" "4.3 正常在飞零告警"
sb_cleanup

# =============================================================================
t_case "W4 失败（blocked+outcome=gave_up）→ fallback claude + 告警入账 + 登记清"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
seed_flight "t_old" "$(date +%s)"
seed_card_store "blocked"
run_watch -e STUB_KANBAN_CARD_STATUS=blocked -e STUB_KANBAN_RUN_OUTCOME=gave_up \
  'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(scan_create_calls)" "0" "4.4 失败终态不建新 scan 卡"
assert_eq "$(claude_scan_calls)" "1" "4.4 blocked → fallback claude 被调"
if flight_exists; then
  assert_eq "$(flight_card_id)" "" "4.4 登记已清"
else
  _pass "4.4 登记文件已清除"
fi
[ "$(pipeline_failure_count)" -ge 1 ] && _pass "4.4 告警入账（$(pipeline_failure_count) 条）" || _fail "4.4 告警入账" "零 pipeline-failure 事件"
sb_cleanup

# =============================================================================
t_case "W5 建卡失败（hermes 不可用）→ fallback claude + 告警 + 零 flight"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(claude_scan_calls)" "1" "4.5 建卡失败 → fallback claude 被调"
flight_exists && _fail "4.5 失败不写 flight" "建卡失败仍留下 flight（下轮锁死在飞态）" || _pass "4.5 失败不写 flight"
PC="$(pipeline_failure_count)"
case "$PC" in
  ''|*[!0-9]*) _fail "4.5 告警计数" "非数值 [$PC]" ;;
  *) [ "$PC" -ge 2 ] && _pass "4.5 hermes-down+card-fallback 告警入账（$PC 条）" || _fail "4.5 告警入账" "实得 $PC < 2（首败告警+卡路 fallback 告警）" ;;
esac
sb_cleanup

# =============================================================================
t_case "W6 错过 radar（非 08 窗口 + 补跑旗标）→ radar 卡照建、旗标保留、radar flight 登记"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 90 90    # scan 段安静，隔离 radar 行为
seed_cursor 100
printf '%s\n' "$(date +%F)" > "$SB_ROOT/contrib-data/pending-radar.flag"
run_watch -e RADAR_HOUR=14 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "4.6 run-watch exit"
[ "$(radar_create_calls)" -ge 1 ] && _pass "4.6 radar 卡已补建（$(radar_create_calls) 张）" || _fail "4.6 radar 卡已补建" "错过窗口+旗标未触发建卡（补跑旗标语义丢失）"
[ -f "$SB_ROOT/contrib-data/pending-radar.flag" ] && _pass "4.6 旗标保留（删除条件=研判完成）" || _fail "4.6 旗标保留" "建卡即删旗标"
RADAR_FLIGHT="$SB_ROOT/contrib-data/kanban-flight-radar.json"
if [ -s "$RADAR_FLIGHT" ]; then
  assert_eq "$(jq -r '.kind // ""' "$RADAR_FLIGHT")" "radar" "4.6 radar flight 登记 kind=radar"
  case "$(jq -r '.card_id // ""' "$RADAR_FLIGHT")" in "") _fail "4.6 radar card_id 非空" "为空" ;; *) _pass "4.6 radar card_id 非空" ;; esac
else
  _fail "4.6 radar flight 登记" "kanban-flight-radar.json 未产出"
fi
sb_cleanup

# =============================================================================
t_case "W7 QC 开 + 有命中 → 建卡照常发起 + 零 claude（QC 只挡兜底路）"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SB_ROOT/contrib-data/.quota-circuit"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(scan_create_calls)" "1" "4.7 断路器开闸建卡照常（QC_OPEN 清理后 T2 语义不得回退）"
assert_eq "$(claude_any_calls)" "0" "4.7 零 claude"
flight_exists && _pass "4.7 flight 正常登记" || _fail "4.7 flight 正常登记" "建卡成功应写 flight"
sb_cleanup

# =============================================================================
t_case "W8 QC 开 + radar 补跑 + 建卡失败 → radar fallback 被 QC 挡（零 claude + 幂等告警 + 旗标保留）"
common_setup
mk_issues "$SB_ROOT/tmp/issues.json" 90 90
seed_cursor 100
printf '%s\n' "$(date +%F)" > "$SB_ROOT/contrib-data/pending-radar.flag"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SB_ROOT/contrib-data/.quota-circuit"
run_watch -e RADAR_HOUR=14 -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
# 注：hermes 全挂时 flush 尾部 digest fallback 也会调 claude（合法独立路径），
# 故此处按模式精确计数 radar fallback 的 claude，而非断言 claude 全零
assert_eq "$(claude_radar_calls)" "0" "4.8 QC 挡下 radar fallback（QC check 本体保留的行为锚）"
assert_eq "$(event_key_count "-radar-fallback-skipped")" "1" "4.8 -radar-fallback-skipped 告警恰 1 条"
[ -f "$SB_ROOT/contrib-data/pending-radar.flag" ] && _pass "4.8 旗标保留（fallback 被挡≠研判完成）" || _fail "4.8 旗标保留" "QC 挡下却删旗标"
sb_cleanup

# =============================================================================
t_case "W9 静态锚：run-watch.sh 零 QC_OPEN token（死变量+陈旧注释清理）"
if [ ! -f "$SCRIPTS_DIR/run-watch.sh" ]; then
  _fail "4.9 run-watch.sh 存在" "$SCRIPTS_DIR/run-watch.sh 缺失"
else
  N="$(grep -c 'QC_OPEN' "$SCRIPTS_DIR/run-watch.sh" 2>/dev/null || true)"
  assert_eq "$N" "0" "4.9 run-watch.sh 零 QC_OPEN 引用（保留 QC check 行为面已由 4.7/4.8 钉死）"
fi

t_finish
