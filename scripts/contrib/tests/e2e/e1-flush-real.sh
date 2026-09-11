#!/bin/bash
# e1-flush-real.sh — E1：flush 真发全链（事件→聚合→stub 送达→账本/配额三同现）
# 契约锚点：真发成功判据（hermes rc==0 且 success:true 才标 pushed 并 bump 配额）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e1-flush-real.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"

t_case "E1: 叙事事件→digest 卡（T5 卡化：flight 四键+快照+零 send 零 claude+挂账 attempts 不增）"
sb_notify event pipeline-failure --key e1-narrative --summary "scan 研判 claude -p 失败 exit=1" >/dev/null
assert_exit 0 $?
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$out" "" "真发轮无 stdout 噪音（结果落账本/日志）"
# flight 四键 + 快照落盘（异步化主路：建卡而非内联发送）
DFLIGHT="$SB_ROOT/contrib-data/kanban-flight-digest.json"
assert_eq "$(jq -r '.kind // empty' "$DFLIGHT" 2>/dev/null)" "digest" "flight kind=digest"
SNAP="$(jq -r '.batch_file // empty' "$DFLIGHT" 2>/dev/null)"
[[ -n "$SNAP" && -f "$SNAP" ]] && _pass "batch_file=快照路径且落盘" || _fail "batch_file=快照路径" "actual=$SNAP"
assert_eq "$(jq -r '.created_epoch > 0' "$DFLIGHT" 2>/dev/null)" "true" "created_epoch 落值"
# 主路零发送零 LLM（发送移至 worker 卡内 send-digest）
send_calls="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
assert_eq "$send_calls" "0" "hermes send 零调用（异步化：发送在 worker 卡内）"
assert_stub_called claude 0 "主路零 claude"
# 事件保留未推、attempts 不增（在飞挂账）
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .pushed' "$EVENTS_FILE")" "false" "事件保留未推（等卡闭环）"
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .attempts' "$EVENTS_FILE")" "0" "attempts 不增（在飞非失败）"
# 卡 body 断言：含快照路径与三段式规范，无 raw 事件正文直推
body_file="$(stub_last_body hermes)"
[[ -n "$body_file" ]] && assert_file_contains "$body_file" "$SNAP" "卡 body 含快照路径"
[[ -n "$body_file" ]] && assert_file_contains "$body_file" "三段式" "卡 body 含三段式规范"
[[ -n "$body_file" ]] && assert_not_contains "$(cat "$body_file")" '"summary":"scan 研判' "无 raw JSON dump"

t_case "E1w: worker 收尾模拟——send-digest 发送 → 账本 pushed/配额 bump/批次 sent:true 三同现"
DIGEST="${SNAP%.json}.digest.md"
printf '🟠【contrib 告警】09-09\n\nscan 失败已挂账；无需动作。\n' >"$DIGEST"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIGEST' --batch '$SNAP'")"
assert_exit 0 $?
assert_eq "$out" "OK" "send-digest stdout 闭集 OK"
assert_file_contains "$SB_ROOT/stublog/hermes-send-last.json" '"success":true' "发送结果 success:true"
# ① 账本标 pushed=true + pushed_at 非空
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .pushed' "$EVENTS_FILE")" "true" "events 标 pushed"
assert_not_contains "$(jq -r 'select(.key == "e1-narrative") | .pushed_at' "$EVENTS_FILE")" "null" "pushed_at 落值"
# ② 配额 bump ③ 批次文件 sent:true（send_result 佐证）
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "1" "当日告警配额 bump 1"
assert_eq "$(jq -rs '[.[] | select(.sent == true)] | length' "$SNAP" 2>/dev/null)" "1" "批次回写 sent:true"
send_body="$(stub_last_body hermes)"
assert_contains "$(cat "$send_body")" "🟠【contrib 告警】" "外发内容为摘要（报头）"
assert_not_contains "$(cat "$send_body")" '"summary":"scan 研判' "外发无 raw JSON dump（永不 raw dump）"

t_case "E1c: 卡 done + 批次 sent:true 消费轮 → 零账本动作（双写禁止）+ 清登记清快照"
printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$(jq -r '.card_id' "$DFLIGHT")" \
  >"$SB_ROOT/stublog/kanban-cards.jsonl"
sb_state_set '.last_flush_epoch = 0'
sb_notify event pipeline-failure --key e1-next --summary "消费轮新攒叙事" >/dev/null
before_pushed="$(jq -s '[.[] | select(.pushed == true)] | length' "$EVENTS_FILE")"
before_alerts="$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(jq -s '[.[] | select(.pushed == true)] | length' "$EVENTS_FILE")" "$before_pushed" "零新增 pushed（账本双写禁止）"
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "$before_alerts" "配额不被重复消耗"
[[ ! -f "$DFLIGHT" ]] && _pass "登记已清" || _fail "登记已清" "残留"
[[ ! -f "$SNAP" ]] && _pass "快照消费即删" || _fail "快照消费即删" "残留"
send_calls="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
assert_eq "$send_calls" "1" "消费轮零发送（唯一 send 来自 worker 环节）"
assert_eq "$(jq -r 'select(.key == "e1-next") | .pushed' "$EVENTS_FILE")" "false" "新攒事件留待下小时轮（不丢）"

t_case "E1b: 纯机械批次→模板卡（零 LLM）+ ▪ 实质行"
# 前置态收口：消费轮新攒的 e1-next 留待下小时轮（卡路），此处拨账模拟其已被消费，
# 使本批为纯机械批（E1b 回归锚点）
jq 'if .key == "e1-next" then .pushed = true else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
rm -f "$SB_ROOT/contrib-data/kanban-flight-digest.json"   # E1b 建的卡在本用例语境外，清登记
sb_notify event probe-premise-dead --key e1-mech --summary "radar 2026-09-05 premise 复验：#102413 已被占坑出局" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
before_claude="$(stub_count claude)"
before_hermes="$(stub_count hermes)"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "纯机械批次零 claude 调用"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "1" "hermes 再发一次"
body_file="$(stub_last_body hermes)"
assert_contains "$(cat "$body_file")" "▪ 候选折损" "模板卡实质行（▪ 开头）"
assert_contains "$(cat "$body_file")" "↳ " "模板卡动作行"
assert_eq "$(jq -r 'select(.key == "e1-mech") | .pushed' "$EVENTS_FILE")" "true" "机械事件标 pushed"

t_case "E1f: 失败链（建卡失败 → fallback claude+send 也败）→ 事件保留 + attempts 递增"
sb_notify event pipeline-failure --key e1-fail --summary "会失败的事件" >/dev/null
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 1 $? "flush 上报失败"
assert_eq "$(jq -r 'select(.key == "e1-fail") | .pushed' "$EVENTS_FILE")" "false" "不得标 pushed"
assert_eq "$(jq -r 'select(.key == "e1-fail") | .attempts' "$EVENTS_FILE")" "1" "attempts 递增"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "建卡失败不写登记" \
  || _fail "建卡失败不写登记" "残留"

sb_cleanup
t_finish
