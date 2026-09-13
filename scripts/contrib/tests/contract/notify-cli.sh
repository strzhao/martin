#!/bin/bash
# notify-cli.sh — Tier C：notify.sh 对外 API 契约（hermes 侧 SKILL.md receipt 唯一生产调用方）
# 覆盖契约规约：子命令闭集 / events.jsonl 行 schema / key 幂等 / notify-state schema（场景11.P4）/
# DRY_RUN 否定变体（场景11.P3）/ 渠道隔离（场景12.P1）/ 空卡守卫排除集对齐（场景12.P3 契约面）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=contract

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "notify-cli.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"

# ---------------- 子命令闭集 ----------------
t_case "子命令闭集：6 个入口全部在实现中"
for sub in "event)" "flush)" "approve)" "receipt)" "fallback)" "help"; do
  if grep -qF -- "$sub" "$SB_ROOT/scripts/contrib/notify.sh"; then
    _pass "子命令 ${sub)}"
  else
    _fail "子命令 ${sub)}" "case 分支缺失（对外 API 静默破坏）"
  fi
done
if grep -qF -- '--channel) channel="$2"' "$SB_ROOT/scripts/contrib/notify.sh"; then
  _pass "event --channel 选项"
else
  _fail "event --channel 选项" "渠道隔离入口缺失"
fi

# ---------------- event：schema + key 幂等 ----------------
t_case "event：events.jsonl 行 schema 八键齐备"
sb_notify event own-pr-activity --key c-key-1 --summary "契约测试事件" >/dev/null
assert_exit 0 $?
keys="$(jq -S 'keys | join(",")' "$EVENTS_FILE" 2>/dev/null)"
for k in attempts channel class key pushed pushed_at summary ts; do
  assert_contains "$keys" "$k" "键 $k"
done
types="$(jq -r '.pushed | type' "$EVENTS_FILE")|$(jq -r '.attempts | type' "$EVENTS_FILE")|$(jq -r '.pushed_at | type' "$EVENTS_FILE")"
assert_eq "$types" "boolean|number|null" "类型：pushed=bool attempts=int pushed_at=null"
assert_eq "$(jq -r '.channel' "$EVENTS_FILE")" "contrib" "channel 缺省 contrib"

t_case "event：同 key 二次入账不新增行（幂等唯一）"
sb_notify event own-pr-activity --key c-key-1 --summary "重复事件" >/dev/null
assert_exit 0 $?
assert_eq "$(wc -l <"$EVENTS_FILE" | tr -d ' ')" "1" "仍为 1 行"

t_case "event：缺 class/key → exit 2"
sb_notify event >/dev/null 2>&1
assert_exit 2 $? "无参用法错误"

# ---------------- 渠道隔离（场景12.P1 契约面）----------------
t_case "channel 隔离：非 contrib 事件入账但 channel 字段正确"
sb_notify event pipeline-failure --key c-foo-1 --summary "另一渠道" --channel foo-ops >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "c-foo-1") | .channel' "$EVENTS_FILE")" "foo-ops" "channel 落账"

t_case "flush 批次只含 contrib：foo 事件不推送、不标 pushed、不占限额"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
foo_pushed="$(jq -r 'select(.key == "c-foo-1") | .pushed' "$EVENTS_FILE")"
assert_eq "$foo_pushed" "false" "foo 事件未标 pushed"
hermes_args="$(stub_count hermes)"
assert_eq "$hermes_args" "1" "hermes 恰一次（只发 contrib 批次）"
body_file="$(stub_last_body hermes)"
if [[ -n "$body_file" ]]; then
  assert_not_contains "$(cat "$body_file")" "另一渠道" "foo 内容不进消息体"
else
  _fail "消息体副本" "hermes stub 未捕获消息体"
fi
alerts="$(jq -r '.alerts | length' "$STATE_FILE")"
assert_eq "$alerts" "1" "alerts 只 bump 一次（非 contrib 不占限额）"

# ---------------- DRY_RUN 否定变体（场景11.P3）----------------
# T5 卡化语义更新：叙事批 flush 在 dry-run 下仍走 digest 卡路（建卡=编排写非传输发送，
# 干跑只盖发送不盖盖编排——「dry-run 只盖发送不盖账本」同款口径）；dry-run 的消息体打印
# 移至 worker 侧 send-digest 环节，flush stdout 不再含 [dry-run]。
t_case "DRY_RUN=true：flush 叙事批建 digest 卡（零 send/tunnel）+ 事件挂账不消费"
sb_notify event pipeline-failure --key c-dry-1 --summary "dry-run 批次" >/dev/null
before_tunnel="$(stub_count tunnel)"
before_send="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)"
# 时间闸门不 sleep：回拨 last_flush_epoch 构造「可立即 flush」前置态
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=true" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
rc=$?
assert_exit 0 $rc
assert_eq "$(( $(stub_count tunnel) - before_tunnel ))" "0" "tunnel 零调用"
send_calls="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)"
assert_eq "$(( send_calls - before_send ))" "0" "hermes send 零调用（dry-run 只盖发送；kanban 建卡属编排写）"
assert_file_contains "$SB_ROOT/contrib-data/kanban-flight-digest.json" '"digest"' "digest 卡已建并登记"
# 卡化后 dry-run 叙事批挂账不消费（旧内联摘要路的 dry-run pushed 语义随卡化废止）：
# pushed 留 false 由卡闭环（worker send-digest）驱动，下轮 done+sent 消费收敛
dry_pushed="$(jq -r 'select(.key == "c-dry-1") | .pushed' "$EVENTS_FILE")"
assert_eq "$dry_pushed" "false" "卡化语义：dry-run 叙事批挂账不消费（等卡闭环）"

# ---------------- 真发 + notify-state schema（场景11.P4）----------------
t_case "真发 flush 后 notify-state schema（fallback_notice 允许缺失=契约）"
# 构造机械批前置态：c-dry-1 已由卡闭环消费（拨账模拟）+ 清 flight + 补一条机械事件
jq 'if .key == "c-dry-1" then .pushed = true else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
rm -f "$SB_ROOT/contrib-data/kanban-flight-digest.json"
sb_notify event own-pr-activity --key c-real-1 --summary "真发机械事件" >/dev/null
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
rc=$?
assert_exit 0 $rc
chk="$(jq -e '
  (.last_flush_epoch | type == "number" and . > 0)
  and (.alerts | type == "object")
  and ((.alerts | to_entries | map(.value | type == "number") | all)
       or (.alerts | length == 0))
  and (.approvals | type == "object")
  and (.receipts | type == "object")
  and ((.fallback_notice | type == "object") or (.fallback_notice == null) or (.fallback_notice == null and has("fallback_notice") | not))
' "$STATE_FILE" 2>&1)"
assert_eq "$chk" "true" "schema 校验（last_flush_epoch/alerts/approvals/receipts 必备，fallback_notice 可惰性缺省）"
today_alerts="$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")"
if [[ "$today_alerts" -ge 1 ]]; then
  _pass "alerts.<today> >= 1"
else
  _fail "alerts.<today> >= 1" "actual=$today_alerts"
fi
# 渠道隔离收尾核验：foo-ops 渠道事件至终未被标 pushed（真发轮也只标 contrib 批次）
foo_final="$(jq -r 'select(.key == "c-foo-1") | .pushed' "$EVENTS_FILE")"
assert_eq "$foo_final" "false" "非 contrib 事件跨轮保持未推"

t_case "空卡守卫排除集：渲染剔除集与实现措辞对齐"
# 契约措辞：剔除 ^🟠 / ^（明细 / 空行 / ^── 后实质行计数为零 → 不发送
guard_line="$(grep -F "grep -v -e '^🟠'" "$SB_ROOT/scripts/contrib/notify.sh")"
assert_contains "$guard_line" "'^🟠'" "排除报头"
assert_contains "$guard_line" "'^（明细'" "排除明细尾注"
assert_contains "$guard_line" "'^$'" "排除空行"

# ---------------- receipt：独立计数（回执不占告警限额）----------------
t_case "receipt：成功后 receipts 计数 +1，不触发 flush 限额"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" receipt rq-20260905-999 --summary "已完成"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc
receipts="$(jq -r --arg d "$(date +%F)" '.receipts[$d] // 0' "$STATE_FILE")"
assert_eq "$receipts" "1" "receipts 计 1"

# ---------------- fallback ----------------
t_case "fallback：osascript 本地提示被调"
before_osascript="$(stub_count osascript)"
sb_notify fallback "人工兜底文案" >/dev/null
assert_exit 0 $?
assert_eq "$(( $(stub_count osascript) - before_osascript ))" "1" "osascript 恰一次"

sb_cleanup
t_finish
