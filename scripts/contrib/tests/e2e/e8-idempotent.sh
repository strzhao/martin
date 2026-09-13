#!/bin/bash
# e8-idempotent.sh — E8：簿记幂等（同 key 事件一行；flush 防双发：min_interval + 无新事件零调用）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e8-idempotent.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"

t_case "E8a: 同 key 二次 event 不新增行（账本幂等唯一；更新语义收编旧幂等跳过）"
sb_notify event own-pr-activity --key e8-k --summary "第一 graffiti" >/dev/null
assert_exit 0 $?
sb_notify event own-pr-activity --key e8-k --summary "第二 graffiti" >/dev/null
assert_exit 0 $?
assert_eq "$(grep -c '"key":"e8-k"' "$EVENTS_FILE" 2>/dev/null || true)" "1" "仍一行"
assert_eq "$(jq -r 'select(.key == "e8-k") | .occurrences' "$EVENTS_FILE")" "2" "同 key 第二次 = 原位更新（occurrences 累计 2）"
assert_eq "$(jq -r 'select(.key == "e8-k") | .summary' "$EVENTS_FILE")" "第二 graffiti" "最新摘要落原行"

t_case "E8b: min_interval 防双发——紧凑两次 flush 只发一次"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_stub_called_times hermes 1 "第一次 flush 恰一次"
# 第二次 flush 紧跟其后（不回拨 last_flush_epoch）→ 必被 min_interval 拦截
before_hermes="$(stub_count hermes)"
out2="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
rc=$?
assert_exit 0 $rc "拦截属正常跳过（exit 0）"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "第二次 flush 零调用"
assert_eq "$out2" "" "拦截轮零输出"
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "1" "配额只 bump 一次"

t_case "E8c: 回拨时间闸门后，无未推事件 → flush 零调用（无事件不空发）"
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
out3="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
rc=$?
assert_exit 0 $rc
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "全部已推 → 零调用"
assert_eq "$out3" "" "空轮零输出"
assert_eq "$(jq -r '.last_flush_epoch' "$STATE_FILE")" "0" "last_flush_epoch 不被空轮推进"

# =============================================================================
t_case "E8d: 同簇不同 key（date 后缀）→ 原位更新首行（不追加、key 不变、occurrences 累计）"
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_notify event visual-run-done --key "e8-stale-2026-09-13" --summary "首报" >/dev/null
sb_notify event visual-run-done --key "e8-stale-2026-09-14" --summary "复发" >/dev/null
assert_exit 0 $?
assert_eq "$(wc -l <"$EVENTS_FILE" | tr -d ' ')" "1" "同簇不追加新行（仍一行）"
assert_eq "$(jq -r '.occurrences' "$EVENTS_FILE")" "2" "同簇第二次 = 原位更新（occurrences 累计 2）"
assert_eq "$(jq -r '.key' "$EVENTS_FILE")" "e8-stale-2026-09-13" "告警 id 保持首行 key（可追踪性）"
assert_eq "$(jq -r '.summary' "$EVENTS_FILE")" "复发" "最新摘要落原行"
assert_eq "$(jq -r '.cluster' "$EVENTS_FILE")" "e8-stale-" "簇键=剥离日期 token"

t_case "E8e: 静默窗内复发（pushed=true + 双格式 pushed_at）→ 保持 pushed=true 不重推"
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
# 格式一：cmd_event 路 date +%z（+0800）
sb_seed_event "probe-premise-dead" "e8-win-z" "首报" contrib 0 true
jq -c --arg p "$(date +%Y-%m-%dT%H:%M:%S%z)" 'if .key == "e8-win-z" then .pushed_at = $p else . end' \
  "$EVENTS_FILE" >"$EVENTS_FILE.tmp" && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
sb_notify event probe-premise-dead --key e8-win-z --summary "窗口内复发" >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r '.pushed' "$EVENTS_FILE")" "true" "窗内保持 pushed=true（只记账不重推）"
assert_eq "$(jq -r '.occurrences' "$EVENTS_FILE")" "2" "复发次数累计（窗内仍记账）"
# 格式二：flush 标记路 python isoformat（+08:00）
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_seed_event "probe-premise-dead" "e8-win-p" "首报" contrib 0 true
jq -c --arg p "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" 'if .key == "e8-win-p" then .pushed_at = $p else . end' \
  "$EVENTS_FILE" >"$EVENTS_FILE.tmp" && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
sb_notify event probe-premise-dead --key e8-win-p --summary "窗口内复发" >/dev/null
assert_eq "$(jq -r '.pushed' "$EVENTS_FILE")" "true" "带冒号偏移格式同样抑制（时钟归一化）"

t_case "E8f: 静默窗过期（pushed_at 早于 86400s）→ 置 pushed=false 进下轮 flush"
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_seed_event "probe-premise-dead" "e8-old" "首报" contrib 0 true
jq -c --arg p "$(date -u -v-2d +%Y-%m-%dT%H:%M:%S+00:00)" 'if .key == "e8-old" then .pushed_at = $p else . end' \
  "$EVENTS_FILE" >"$EVENTS_FILE.tmp" && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
sb_notify event probe-premise-dead --key e8-old --summary "窗口外复发" >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r '.pushed' "$EVENTS_FILE")" "false" "窗口外 → 重推（pushed=false）"
assert_eq "$(jq -r '.occurrences' "$EVENTS_FILE")" "2" "复发次数累计"

t_case "E8g: 已 resolved 根因复发 → 重开为活跃态（resolved=false 且 pushed=false）"
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_seed_event "probe-premise-dead" "e8-reopen" "首报" contrib 1 true
jq -c 'if .key == "e8-reopen" then (.resolved = true | .resolved_at = "2026-09-13T10:00:00+0800" | .resolution = "已手工处置") else . end' \
  "$EVENTS_FILE" >"$EVENTS_FILE.tmp" && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
sb_notify event probe-premise-dead --key e8-reopen --summary "处置后复发" >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r '.resolved' "$EVENTS_FILE")" "false" "resolved 历史不构成静默：重开"
assert_eq "$(jq -r '.pushed' "$EVENTS_FILE")" "false" "重开必重推（pushed=false）"
assert_eq "$(jq -r '.occurrences' "$EVENTS_FILE")" "2" "重开计数累计"

sb_cleanup
t_finish
