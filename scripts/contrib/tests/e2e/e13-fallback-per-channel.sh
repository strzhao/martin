#!/bin/bash
# e13-fallback-per-channel.sh — E13：3 败本地兜底的渠道分立（过滤 / 日幂等键 / 文案 / 标题）
#
# 缺口（2026-09-14，卡 t_6457f433）：`_flush_attempts_bump` 原先把渠道写死成 contrib——
#   ① `:501` 过滤条件 `(.channel // "contrib") == "contrib"` ⇒ flashcards 渠道 3 败**结构性永不**弹本地提示；
#   ② `:502` 日幂等键 = 全局单键 `fallback_notice` ⇒ 任一渠道先弹即吃掉另一渠道当日提示；
#   ③ 文案/标题写死 contrib ⇒ 即使触发也报错渠道。
# 契约（本文件冻结）：
#   - 每渠道各自计数（过滤按本渠道）、各自日幂等键（contrib 沿用历史键名 `fallback_notice`，
#     其余渠道 `fallback_notice_<ch>`）、各自文案与通知标题（`<ch>-watch`）。
#   - contrib 路径**逐字不变**（回归锚：与修前生产文案字节相同，见 E13a）。
# 驱动方式：seam 沙箱（tests/lib/sandbox.sh），hermes 影子置失败以构造 attempts+1 前路，
#   生产 contrib-data 零触碰。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e13-fallback-per-channel.sh"

TODAY="$(date +%F)"
STATE_FILE=""   # 每用例 sb_new 后重指

# 修前生产文案（逐字，来自 2026-09-14 改动前沙箱实测 calls.log）——回归锚
GOLDEN_CONTRIB='display notification "contrib 1 条告警多次推送未成（AI 摘要/通道失败），已挂账下轮重试——明细 contrib-data/events.jsonl" with title "contrib-watch" sound name "Ping"'

os_body() { # <n> → 第 n 次 osascript 通知脚本原文（stub bodies 副本）
  cat "$CONTRIB_TEST_STUB_LOG/bodies/osascript-$1.txt" 2>/dev/null
}
do_flush() { # 构造「发送失败」前路：hermes 影子置失败 ⇒ rc=1，事件保留挂账
  sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" \
    'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
}
state_of() { # <jq 参数...> → 作用于当前沙箱 notify-state.json
  jq -r "$@" "$STATE_FILE" 2>/dev/null
}

t_case "E13a: contrib-only + 3 败 → 文案/标题与修前逐字相同（回归锚）"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_seed_event pipeline-failure "e13-contrib-1" "E13a 连续失败事件" contrib 3 false
do_flush
rc=$?
assert_exit 1 $rc "发送失败向上传播 rc=1"
assert_stub_called_times osascript 1 "osascript 恰一次"
assert_contains "$(os_body 1)" "$GOLDEN_CONTRIB" "contrib 通知文案+标题逐字不变（回归锚）"
assert_eq "$(state_of --arg d "$TODAY" '.fallback_notice[$d] // 0')" "1" "contrib 日幂等键仍为历史键名 fallback_notice"
sb_cleanup >/dev/null

t_case "E13b: flashcards-only + 3 败 → 修前结构性不可达，现在必弹（本渠道文案/键/标题）"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_seed_event build-failure "e13-flash-1" "E13b 连续失败事件" flashcards 3 false
do_flush
rc=$?
assert_exit 1 $rc "发送失败向上传播 rc=1"
assert_stub_called_times osascript 1 "flashcards 3 败必弹本地提示（修前恒 0 次）"
assert_contains "$(os_body 1)" 'flashcards 1 条告警多次推送未成' "flashcards 文案取本渠道"
assert_contains "$(os_body 1)" 'title "flashcards-watch"' "通知标题取本渠道"
assert_eq "$(state_of --arg d "$TODAY" '.fallback_notice_flashcards[$d] // 0')" "1" "flashcards 日幂等键落盘"
assert_eq "$(state_of --arg d "$TODAY" '.fallback_notice[$d] // 0')" "0" "不误写 contrib 键"
sb_cleanup >/dev/null

t_case "E13c: 两渠道同日各 3 败 → 各弹一条、计数按渠道过滤、互不吃"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_seed_event build-failure "e13-flash-2" "E13c flashcards 事件一" flashcards 3 false
sb_seed_event agc-crash-spike "e13-flash-3" "E13c flashcards 事件二" flashcards 3 false
sb_seed_event pipeline-failure "e13-contrib-2" "E13c contrib 事件" contrib 3 false
do_flush
rc=$?
assert_exit 1 $rc "发送失败向上传播 rc=1"
assert_stub_called_times osascript 2 "两渠道同日各弹一条（不互吃）"
assert_contains "$(os_body 1)" 'contrib 1 条告警多次推送未成' "contrib 计数不含 flashcards 事件（1，非 3）"
assert_contains "$(os_body 2)" 'flashcards 2 条告警多次推送未成' "flashcards 计数不含 contrib 事件（2，非 3）"
assert_eq "$(state_of --arg d "$TODAY" '.fallback_notice[$d] // 0')" "1" "contrib 键落盘"
assert_eq "$(state_of --arg d "$TODAY" '.fallback_notice_flashcards[$d] // 0')" "1" "flashcards 键落盘"

t_case "E13d: 同日再次失败 flush → 每渠日幂等各自成立（不再弹）"
sb_state_set '.last_flush_epoch = 0'
before="$(stub_count osascript)"
do_flush
rc=$?
assert_exit 1 $rc "第二次失败仍 rc=1"
assert_eq "$(stub_count osascript)" "$before" "日幂等：两渠道均不再弹"
sb_cleanup >/dev/null

t_case "E13e: 限额耗尽分支 → 分渠各弹一条（不把两渠道合计数写成 contrib 单条）"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_config_set '.max_alert_pushes_per_day = 3'
sb_state_set ".alerts[\"$TODAY\"] = 3"
sb_seed_event probe-premise-dead "e13-lim-contrib" "E13e contrib 挂账事件" contrib 0 false
sb_seed_event build-failure "e13-lim-flash" "E13e flashcards 挂账事件" flashcards 0 false
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "限额拒绝属正常流程（exit 0）"
assert_stub_called_times osascript 2 "限额兜底分渠各一条"
assert_contains "$(os_body 1)" 'contrib 告警 1 条今日未推（限额 3 已满），明日 09:17 对账补推' "contrib 限额文案逐字（单渠道挂账时与历史相同）"
assert_contains "$(os_body 2)" 'flashcards 告警 1 条今日未推（限额 3 已满），明日 09:17 对账补推' "flashcards 限额文案取本渠道"
assert_eq "$(state_of --arg d "$TODAY" '.alerts[$d]')" "3" "限额计数不被空推消耗"
sb_cleanup >/dev/null

t_finish
