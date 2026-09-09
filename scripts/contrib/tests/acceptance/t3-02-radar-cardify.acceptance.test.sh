#!/usr/bin/env bash
# =============================================================================
# t3-02-radar-cardify.acceptance.test.sh — T3 验收矩阵②：radar 卡化 + 补跑旗标 + 终态每轮即查
#   R1  hour==08 → 建 radar 卡：body 含 SKILL 模式二权威 + 产出路径 radar/<F>.md；登记四键；
#       预置旗标存活（建卡成功不删）
#   R2  hour==08 + hermes down + 兜底 claude 失败 → 旗标落盘（内容=置旗日期）+ -radar-exit1 旧 key 不变
#   R3  有旗标+非 08 时段 → 补跑建卡 + 登记写盘 + 旗标存活（删除条件=研判实际完成）
#   R4  hour==08 + QC 开 → 仍建卡（卡路不受 QC 限；旧「断路器跳过」语义删除）
#   R5  登记卡 done+非 08 → 当轮观察终态：清登记+删旗标+零新卡零 fallback（非次日）
#   R6  登记卡 done+hour==08 → 清登记 + fall-through 建当日新卡（登记换新 id）
#   R7  登记卡 blocked+outcome=crashed（闭集失败终态）→ 清登记+fallback+-radar-card-fallback 恰 1
#       +旗标存活（兜底 claude 失败时，重审 B-2R）
#   R8  建卡失败但兜底 claude exit 0 → 旗标删除（fallback 成功=研判完成）
#   R9  QC 开+建卡失败 → -radar-fallback-skipped 恰 1 + 零 claude + 旗标存活
#   R10 非 08+无旗标+无登记 → 原样无动作（回归：radar 非 08 时段无行为变化）
#   R11a 登记 running 未超时 → 跳过；R11b 非终态超 6h → 清登记+fallback+事件+旗标存活
# 依据：state.md「## 设计文档」§3（radar 卡化+补跑旗标）+ 任务级契约：
#   「$CONTRIB/pending-radar.flag 内容=置旗日期；删除条件=radar 研判实际完成（卡终态 done 或
#     fallback claude exit 0），建卡成功不删；旗标存在时任意时段可补跑；radar 登记每轮即查终态」
#   「登记四键 {kind,card_id,batch_file,created_epoch}（per-kind 文件 schema 不变）」
#   「失败终态 = blocked + outcome∈{gave_up,crashed,timed_out,spawn_failed}，禁 failed 字面量」
#   「事件新族：<日期>-radar-card-fallback / <日期>-radar-fallback-skipped；旧 -radar-exit* 不变」
# hour 注入：沙箱 $HOME/.local/bin/date 影子 stub（黑盒，仅劫持裸 '+%H'，其余透传 /bin/date）。
# CONTRACT_AMBIGUOUS：
#   - hour==08 且旗标存在且前卡 done 的三元组合（设计注 I1『flag 情形 fall-through 会系统性双跑』
#     与主流程『若 hour==08 → fall-through』字面冲突）——R5/R6 各取单一因子组合，不覆盖三元态
#   - stale 分支『flag 保留，等下轮』与 fallback exit 0 删旗标的字面冲突——R11b 用兜底失败态
#     （两读一致：旗标存活）规避歧义
# 红队纪律：黑盒（未读 run-watch.sh 本次改动 / SKILL.md 新段）；每断言硬失败；无 skip；
#   Mental Mutation：删旗标写入→R2 红；建卡成功即删旗标→R1/R3 红；删补跑检查→R3 红；
#   恢复 QC 跳过建卡→R4 红；终态检查挪回窗口门控内→R5 红（done 滞留）；删 fall-through→R6 红；
#   flag 存活约束丢失→R7/R9 红；fallback 成功不删旗标→R8 红；事件 key 改后缀→R7/R9/R11b 红。
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

install_fake_date() { # 沙箱 $HOME/.local/bin/date：仅劫持裸 '+%H'（run-watch:9 PATH 前置首位），其余透传
  mkdir -p "$SB_HOME/.local/bin"
  cat > "$SB_HOME/.local/bin/date" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "+%H" && "$#" -eq 1 ]]; then
  printf '%s\n' "${STUB_DATE_HOUR:-14}"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$SB_HOME/.local/bin/date"
}

mk_issues() { # 无 scan 命中（游标 200 > issue 101 → scan_gate exit 0，radar 段聚焦）
  local out="$1"
  printf '[{"number":101,"title":"old issue","labels":[{"name":"bug"}],"user":{"login":"alice"},"created_at":"2026-09-01T00:00:00Z","comments":0,"pull_request":null}]\n' > "$out"
}

seed_scan_cursor() {
  jq -n --argjson n 200 --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' \
    > "$SB_ROOT/contrib-data/scan-cursor.json"
}

seed_flight_radar() { # <card_id> <created_epoch> — 四键登记
  jq -n --arg id "$1" --argjson ep "$2" \
    '{kind:"radar",card_id:$id,batch_file:"/tmp/radar-fixture.json",created_epoch:$ep}' \
    > "$SB_ROOT/contrib-data/kanban-flight-radar.json"
}

seed_card_store() { # <status>
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" \
    > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

seed_radar_flag() { printf '%s\n' "$(/bin/date +%F)" > "$SB_ROOT/contrib-data/pending-radar.flag"; }
flag_exists() { [ -e "$SB_ROOT/contrib-data/pending-radar.flag" ]; }
flag_content() { cat "$SB_ROOT/contrib-data/pending-radar.flag" 2>/dev/null || echo ""; }

flight_radar_card() { jq -r '.card_id // ""' "$SB_ROOT/contrib-data/kanban-flight-radar.json" 2>/dev/null || echo ""; }
flight_radar_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-radar.json" ]; }
flight_radar_keys() { jq -r 'keys | join(",")' "$SB_ROOT/contrib-data/kanban-flight-radar.json" 2>/dev/null || echo "?"; }

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls_kind() { hermes_lines | grep 'kanban create' | grep -c -- "--idempotency-key $1-" || true; }
claude_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c -- "$1" || true; }

radar_body_file() {
  grep -l "SKILL.md" "$SB_ROOT"/stublog/bodies/hermes-*.txt 2>/dev/null | head -1
}

ev_key_count() {
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

qcon_open() {
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SB_ROOT/contrib-data/.quota-circuit"
}

HOUR=14
GHF=""
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  install_fake_date
  mk_issues "$SB_ROOT/tmp/issues.json"
  seed_scan_cursor
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}

run_watch() { sb_run -e "$GHF" -e "STUB_DATE_HOUR=$HOUR" "$@"; }

ge1() {
  case "${1:-}" in
    ''|*[!0-9]*) _fail "$2" "非数值 [$1]" ;;
    *) [ "$1" -ge 1 ] && _pass "$2" || _fail "$2" "实得 $1 < 1" ;;
  esac
}

TODAY="$(/bin/date +%F)"

# =============================================================================
t_case "R1 hour==08 → 建 radar 卡：body 含 SKILL 模式二+产出路径、四键登记、预置旗标存活"
common_setup
HOUR=08
seed_radar_flag
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R1 run-watch exit"
assert_eq "$(create_calls_kind radar)" "1" "R1 恰 1 次 radar 建卡"
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R1 建卡路零 claude"
SPAN="$(hermes_lines | grep 'kanban create' | grep -- '--idempotency-key radar-')"
assert_contains "$SPAN" "--assignee contrib" "R1 建卡经 kanban_card 契约参数"
assert_contains "$SPAN" "--json" "R1 建卡带 --json"
assert_not_contains "$SPAN" "subscribe" "R1 零订阅：radar 卡 create argv 禁 subscribe"
BODYF="$(radar_body_file)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  _pass "R1 卡 body 副本已捕获"
  assert_file_contains "$BODYF" ".claude/skills/contrib-watch/SKILL.md" "R1 body 含 SKILL.md 权威路径"
  assert_file_contains "$BODYF" "模式二" "R1 body 引用 SKILL 模式二（radar rubric 权威）"
  assert_file_contains "$BODYF" "radar/$TODAY" "R1 body 含产出路径 radar/<F>.md（契约字面形态）"
else
  _fail "R1 卡 body 副本已捕获" "bodies/hermes-*.txt 无 radar 载荷"
fi
flight_radar_exists && _pass "R1 flight-radar 登记存在" || _fail "R1 flight-radar 登记存在" "建卡成功应写 kanban-flight-radar.json"
assert_eq "$(flight_radar_keys)" "batch_file,card_id,created_epoch,kind" "R1 登记四键精确键集（无 pending_max_id）"
assert_eq "$(jq -r '.kind' "$SB_ROOT/contrib-data/kanban-flight-radar.json")" "radar" "R1 登记 kind=radar"
case "$(flight_radar_card)" in "") _fail "R1 card_id 非空" "为空" ;; *) _pass "R1 card_id 非空" ;; esac
flag_exists && _pass "R1 建卡成功 → 旗标存活（删除条件=研判实际完成，不随建卡删）" \
  || _fail "R1 建卡成功旗标存活" "pending-radar.flag 被提前删除（删除条件突变）"
assert_eq "$(notify_approvals)" "0" "R1 notify-state approvals 零新增"
sb_cleanup

# =============================================================================
t_case "R2 hour==08 + hermes down + 兜底失败 → 旗标落盘（内容=置旗日期）+ 旧 -radar-exit key 不变"
common_setup
HOUR=08
run_watch -e STUB_HERMES_FAIL=1 -e STUB_CLAUDE_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R2 run-watch exit"
case "$(create_calls_kind radar)" in
  0) _fail "R2 前置自证" "radar create 零调用——注毒未生效" ;;
  *) _pass "R2 前置自证：建卡被尝试后失败" ;;
esac
ge1 "$(claude_calls 'contrib-watch radar')" "R2 兜底 claude radar 被调（QC 闭）"
flag_exists && _pass "R2 旗标落盘" || _fail "R2 旗标落盘" "窗口错过后 pending-radar.flag 未写（24h 空窗回归）"
assert_contains "$(flag_content)" "$TODAY" "R2 旗标内容=置旗日期（契约字面）"
assert_eq "$(ev_key_count -radar-card-fallback)" "1" "R2 建卡失败分支 emit -radar-card-fallback"
assert_eq "$(ev_key_count -radar-exit1)" "1" "R2 旧 <日期>-radar-exit* key 不变（兜底失败入账）"
if flight_radar_exists; then
  _fail "R2 失败不写登记" "建卡失败仍留 kanban-flight-radar.json（下轮锁死在飞态）"
else
  _pass "R2 失败不写登记"
fi
sb_cleanup

# =============================================================================
t_case "R3 有旗标+非 08 时段 → 补跑建卡 + 登记写盘 + 旗标存活"
common_setup
HOUR=14
seed_radar_flag
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R3 run-watch exit"
case "$(create_calls_kind radar)" in
  0) _fail "R3 补跑建卡" "有旗标非 08 时段零建卡（补跑机制缺失 = 窗口外旗标死信）" ;;
  *) _pass "R3 旗标驱动补跑建卡" ;;
esac
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R3 补跑走卡路零 claude"
flight_radar_exists && _pass "R3 登记写盘" || _fail "R3 登记写盘" "补跑建卡成功未写 kanban-flight-radar.json"
flag_exists && _pass "R3 建卡成功 → 旗标存活" || _fail "R3 旗标存活" "补跑建卡成功即删旗标（删除条件突变）"
sb_cleanup

# =============================================================================
t_case "R4 hour==08 + QC 开 → 仍建卡（卡路不受 QC 限；旧断路器跳过语义已删）"
common_setup
HOUR=08
qcon_open
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R4 run-watch exit"
case "$(create_calls_kind radar)" in
  0) _fail "R4 QC 开建卡" "断路器开闸下 radar 零建卡（旧『radar 窗口到但断路器打开，跳过』复活）" ;;
  *) _pass "R4 QC 开 → radar 建卡照常发起" ;;
esac
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R4 零 claude"
assert_eq "$(ev_key_count -radar-fallback-skipped)" "0" "R4 建卡成功 → 零 skipped 事件"
flight_radar_exists && _pass "R4 登记写盘" || _fail "R4 登记写盘" "QC 开闸建卡成功应写登记"
sb_cleanup

# =============================================================================
t_case "R5 登记卡 done+非 08 → 当轮观察终态：清登记+删旗标+零新卡（终态检查不受窗口门控）"
common_setup
HOUR=14
seed_radar_flag
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "done"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R5 run-watch exit"
assert_eq "$(create_calls_kind radar)" "0" "R5 非 08 done → 不 fall-through 建新卡（防系统性双跑）"
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R5 done 路零 fallback"
if flight_radar_exists; then
  _fail "R5 登记已清" "done 卡滞留到次日（终态检查被窗口门控 = 突变）"
else
  _pass "R5 登记已清（当轮观察，非次日）"
fi
if flag_exists; then
  _fail "R5 旗标已删" "研判实际完成（done）后 pending-radar.flag 未删"
else
  _pass "R5 旗标已删（done=删除条件命中）"
fi
assert_eq "$(ev_key_count -radar-card-fallback)" "0" "R5 零告警"
sb_cleanup

# =============================================================================
t_case "R6 登记卡 done+hour==08 → 清登记 + fall-through 建当日新卡（登记换新 id）"
common_setup
HOUR=08
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "done"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R6 run-watch exit"
case "$(create_calls_kind radar)" in
  0) _fail "R6 fall-through 建卡" "08 窗口轮首探到前卡 done 未 fall-through（当日窗口未消费）" ;;
  *) _pass "R6 fall-through 建新卡" ;;
esac
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R6 fall-through 走卡路"
assert_ne "$(flight_radar_card)" "t_old" "R6 登记已换新卡（实得 $(flight_radar_card)）"
case "$(flight_radar_card)" in "") _fail "R6 新 card_id 非空" "为空" ;; *) _pass "R6 新 card_id 非空" ;; esac
if flag_exists; then
  _fail "R6 旗标不产生" "正常窗口轮不应落旗标（旗标=错过补跑专用）"
else
  _pass "R6 旗标不产生"
fi
sb_cleanup

# =============================================================================
t_case "R7 登记卡 blocked+outcome=crashed（闭集失败终态）→ 清登记+fallback+事件+旗标存活（兜底失败态）"
common_setup
HOUR=14
seed_radar_flag
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "blocked"
run_watch -e STUB_KANBAN_RUN_OUTCOME=crashed -e STUB_CLAUDE_FAIL=1 \
  'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R7 run-watch exit"
assert_eq "$(create_calls_kind radar)" "0" "R7 失败终态不建新卡"
ge1 "$(claude_calls 'contrib-watch radar')" "R7 fallback claude radar 被调"
if flight_radar_exists; then
  _fail "R7 登记已清" "失败终态后 kanban-flight-radar.json 仍在"
else
  _pass "R7 登记已清"
fi
assert_eq "$(ev_key_count -radar-card-fallback)" "1" "R7 -radar-card-fallback 恰 1（与 scan 对称）"
flag_exists && _pass "R7 旗标存活（兜底失败时 B-2R：旗标必须存活待下轮）" \
  || _fail "R7 旗标存活" "兜底再败仍删旗标 → hermes 恢复后无补跑信号"
sb_cleanup

# =============================================================================
t_case "R8 建卡失败但兜底 claude exit 0 → 旗标删除（fallback 成功=研判完成）"
common_setup
HOUR=08
seed_radar_flag
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R8 run-watch exit"
case "$(create_calls_kind radar)" in
  0) _fail "R8 前置自证" "radar create 零调用——注毒未生效" ;;
  *) _pass "R8 前置自证：建卡被尝试后失败" ;;
esac
ge1 "$(claude_calls 'contrib-watch radar')" "R8 兜底 claude radar 被调（exit 0）"
if flag_exists; then
  _fail "R8 兜底成功删旗标" "fallback claude exit 0（研判完成）后 pending-radar.flag 未删"
else
  _pass "R8 旗标已删（fallback exit 0 = 删除条件命中）"
fi
if [ -e "$SB_ROOT/contrib-data/kanban-flight-radar.json" ]; then
  _fail "R8 失败不写登记" "建卡失败仍留登记"
else
  _pass "R8 失败不写登记"
fi
sb_cleanup

# =============================================================================
t_case "R9 QC 开+建卡失败 → -radar-fallback-skipped 恰 1 + 零 claude + 旗标存活"
common_setup
HOUR=08
qcon_open
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R9 run-watch exit"
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R9 QC 开 → 兜底跳过 claude"
assert_eq "$(ev_key_count -radar-fallback-skipped)" "1" "R9 -radar-fallback-skipped 恰 1"
assert_eq "$(ev_key_count -radar-card-fallback)" "1" "R9 建卡失败分支事件保留"
flag_exists && _pass "R9 旗标存活（QC 开跳过兜底 → 等恢复后补跑）" \
  || _fail "R9 旗标存活" "QC 挡下兜底仍删旗标 → 恢复后 24h 空窗"
sb_cleanup

# =============================================================================
t_case "R10 非 08+无旗标+无登记 → 原样无动作（radar 非 08 时段无行为变化回归）"
common_setup
HOUR=14
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "R10 run-watch exit"
assert_eq "$(create_calls_kind radar)" "0" "R10 非 08 零建卡"
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R10 非 08 零 claude radar"
if [ -e "$SB_ROOT/contrib-data/kanban-flight-radar.json" ] || flag_exists; then
  _fail "R10 零产物" "非 08 时段产出 flight/旗标"
else
  _pass "R10 零产物"
fi
sb_cleanup

# =============================================================================
t_case "R11a 登记 running 未超时 → 本轮跳过（登记保留零动作）"
common_setup
HOUR=14
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(create_calls_kind radar)" "0" "R11a 同 kind 单飞不建新卡"
assert_eq "$(claude_calls 'contrib-watch radar')" "0" "R11a 零 fallback"
assert_eq "$(flight_radar_card)" "t_old" "R11a 登记保留"
assert_eq "$(ev_key_count -radar-card-fallback)" "0" "R11a 零告警"
sb_cleanup

t_case "R11b 非终态超 6h → 清登记+fallback+事件（旗标存活，兜底失败态规避双读歧义）"
common_setup
HOUR=14
seed_radar_flag
seed_flight_radar "t_old" "$(( $(date +%s) - 21605 ))"
seed_card_store "running"
run_watch -e STUB_CLAUDE_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
ge1 "$(claude_calls 'contrib-watch radar')" "R11b 陈旧守卫触发 fallback"
if flight_radar_exists; then
  _fail "R11b 登记已清" "陈旧 flight 未清（停摆放大）"
else
  _pass "R11b 登记已清"
fi
assert_eq "$(ev_key_count -radar-card-fallback)" "1" "R11b -radar-card-fallback 恰 1"
flag_exists && _pass "R11b 旗标存活（stale 分支 flag 保留，等下轮）" \
  || _fail "R11b 旗标存活" "stale 兜底失败仍删旗标"
sb_cleanup

t_finish
