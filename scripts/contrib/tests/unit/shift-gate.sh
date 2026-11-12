#!/bin/bash
# shift-gate.sh — Tier U：班次空班守卫①尾行读取契约（s0525 班实证系列锁死）
#
# 缺口史（本文件锁死的三个事故面）：
#   A. 非法 UTF-8 行（bash3.2 heredoc $VAR 紧邻全角标点吞多字节字节所产）→ BSD grep 行内
#      假阴 + cut Illegal byte sequence（UTF-8 locale 下）→ 守卫①静默聋
#   B. panel-truth */5 岗哨班每 5 分钟自记一行 → 续命判据必须排除岗哨行、只认 operator 班活动
#   C. gate③④ 看板行含中文 → grep/cut 管道须 locale 无关（LC_ALL=C 加固）
#
# 覆盖：
#   ① 毒行容忍×locale 矩阵：末行=非法 UTF-8 的 operator 行，LANG=UTF-8 与无 LANG 两态都读到其时刻
#      （python3 utf-8 replace 读取，locale 无关；毒行不带岗哨标记——带标记会被②的排除条件滤掉）
#   ② 岗哨排除：operator 行新鲜（<60min）+ 新鲜岗哨行 → 触发；operator 行陈旧 + 新鲜岗哨行 → 不触发；
#      理由栏提到 panel-truth 的 operator 行不被误排除
#   ③ gate③④：CJK 看板行 triage/ready 计数 + due 到期唤醒 + due 未到期零唤醒
#   ④ gate②：rq 活跃项（seeded ready-queue）→ rq_active 触发
#   ⑤ x 形时刻容错（HH:Mx 上界归一，t_a49fa51e 班实证）：09:0x/23:5x 尾行必须被听到
#      （上界归一 0x→09/5x→59；[0-5]x 之外的 6x-9x 垃圾仍拒）；well-formed 行为零回归
# 沙箱：每用例 sb_new 全新沙箱；journal/gate_state/rq 全在沙箱内；date stub 透传 date -j -f；
#   hermes stub 经 STUB_KANBAN_LIST_RAW 注入中文看板文本。生产零触达。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "shift-gate.sh"

GATE='bash "$MARTIN_DIR/scripts/contrib/shift-gate.sh"'

# add_row <line...> —— 逐行写入沙箱 journal（UTF-8 文本）
add_row() {
  mkdir -p "$SB_HOME/workspace/martin/contrib-data"
  python3 - "$SB_HOME/workspace/martin/contrib-data/ops-journal.md" "$@" <<'PYEOF'
import sys
path, lines = sys.argv[1], sys.argv[2:]
with open(path, 'wb') as f:
    for l in lines:
        f.write(l.encode('utf-8') + b'\n')
PYEOF
}

# add_poison_operator_row <YYYY-MM-DD HH:MM> —— 追加非法 UTF-8 的 operator 行
#   （模拟 bash3.2 变量展开紧邻全角分号吞 EF 后残迹：archived=<BC 9B>t_... 中段毒字节）
add_poison_operator_row() {
  mkdir -p "$SB_HOME/workspace/martin/contrib-data"
  python3 - "$SB_HOME/workspace/martin/contrib-data/ops-journal.md" "$1" <<'PYEOF'
import sys
path, ts = sys.argv[1], sys.argv[2]
head = ('| %s | operator 班（修复验证班） | 对象 | 理由前段 archived=' % ts).encode('utf-8')
poison = b'\xbc\x9bt_x'
tail = (' 后段中文续写。' * 60) + ' | 高 | <!-- s0525-poison --> |'
with open(path, 'ab') as f:
    f.write(head + poison + tail.encode('utf-8') + b'\n')
PYEOF
}

ts_minus() { # <分钟数> → 现在减 N 分钟的时刻串
  date -v-"${1}"M '+%Y-%m-%d %H:%M'
}

# ---------- ① 毒行容忍 × locale 矩阵 ----------
t_case "poison-row LANG=UTF8: fresh poisoned operator row is heard"
sb_new >/dev/null 2>&1
add_row "| $(ts_minus 120) | operator 班（早班） | 对象 | 理由 | 高 | <!-- s0400-shift --> |"
add_poison_operator_row "$(date '+%Y-%m-%d %H:%M')"
OUT=$(sb_run -e "LANG=zh_CN.UTF-8" "$GATE")
RC=$?
assert_exit 0 "$RC" "rc"
assert_contains "$OUT" "journal_tail_recent" "poison fresh row → fires (LANG=UTF-8)"

t_case "poison-row no-LANG: same fixture, bare launchd-like env"
sb_new >/dev/null 2>&1
add_row "| $(ts_minus 120) | operator 班（早班） | 对象 | 理由 | 高 | <!-- s0400-shift --> |"
add_poison_operator_row "$(date '+%Y-%m-%d %H:%M')"
OUT=$(sb_run "$GATE")
RC=$?
assert_exit 0 "$RC" "rc"
assert_contains "$OUT" "journal_tail_recent" "poison fresh row → fires (no LANG)"

# ---------- ② 岗哨排除 ----------
t_case "sentinel: fresh operator row + fresh sentry row → fires (operator heard under sentry)"
sb_new >/dev/null 2>&1
add_row "| $(ts_minus 10) | operator 班 | 对象 | 理由 | 高 | <!-- s0500-shift --> |" \
       "| $(date '+%Y-%m-%d %H:%M') | panel-truth */5 岗哨班（now 计划班） | 对象 | 理由 | 高 | <!-- s0555-paneltruth --> |"
OUT=$(sb_run "$GATE")
assert_contains "$OUT" "journal_tail_recent" "operator <60min → fires"

t_case "sentinel: stale operator row + fresh sentry row → none (sentry must not trigger)"
sb_new >/dev/null 2>&1
add_row "| $(ts_minus 120) | operator 班 | 对象 | 理由 | 高 | <!-- s0400-shift --> |" \
       "| $(date '+%Y-%m-%d %H:%M') | panel-truth */5 岗哨班（now 计划班） | 对象 | 理由 | 高 | <!-- s0555-paneltruth --> |"
OUT=$(sb_run "$GATE")
assert_eq "$OUT" "none" "stale operator + fresh sentry → none"

t_case "operator row mentioning panel-truth in rationale is NOT excluded"
sb_new >/dev/null 2>&1
add_row "| $(ts_minus 10) | operator 班 | 对象 | 理由提到 panel-truth 岗哨面但决策栏是 operator 班 | 高 | <!-- s0500-shift --> |"
OUT=$(sb_run "$GATE")
assert_contains "$OUT" "journal_tail_recent" "marker in rationale must not exclude"

# ---------- ③ gate③④ CJK 看板行 ----------
t_case "gate③: CJK triage/ready lines counted"
sb_new >/dev/null 2>&1
KB=$'  t_11111111  ready    [forge] 中文标题卡一 due 2026-11-24\n  t_22222222  blocked  [watch] 中文标题卡二 due 2026-11-08 08:00'
OUT=$(sb_run -e "STUB_KANBAN_LIST_RAW=$KB" "$GATE")
assert_contains "$OUT" "board_triage_ready=1" "CJK ready line counted"

t_case "gate④: due ≤ today fires on CJK line"
sb_new >/dev/null 2>&1
KB=$'t_22222222  blocked  [watch] 中文标题卡二 due 2026-11-06 08:00'
OUT=$(sb_run -e "STUB_KANBAN_LIST_RAW=$KB" -e "STUB_DATE_TODAY=2026-11-07" "$GATE")
assert_contains "$OUT" "watch_due=2026-11-06" "overdue fires"

t_case "gate④: due > today → no wake (falls through to none)"
sb_new >/dev/null 2>&1
KB=$'t_22222222  blocked  [watch] 中文标题卡二 due 2026-11-08 08:00'
OUT=$(sb_run -e "STUB_KANBAN_LIST_RAW=$KB" -e "STUB_DATE_TODAY=2026-11-07" "$GATE")
assert_eq "$OUT" "none" "future due → none"

t_case "gate④: done card's historical due does NOT fire (s0630 stale-due fix)"
sb_new >/dev/null 2>&1
KB=$'✓ t_fe25a004  done      [watch] 已收口卡 due 2026-09-26\n✓ t_9ab4b52a  done      [watch] 岗哨载体 due 2026-09-23'
OUT=$(sb_run -e "STUB_KANBAN_LIST_RAW=$KB" -e "STUB_DATE_TODAY=2026-11-07" "$GATE")
assert_eq "$OUT" "none" "done-card due → none"

t_case "gate④: live scheduled card with overdue due still fires"
sb_new >/dev/null 2>&1
KB=$'✓ t_oldddddd  done      [watch] 已收口 due 2026-09-26\n⏱ t_44444444  scheduled  [watch] 活跃守候 due 2026-11-06'
OUT=$(sb_run -e "STUB_KANBAN_LIST_RAW=$KB" -e "STUB_DATE_TODAY=2026-11-07" "$GATE")
assert_contains "$OUT" "watch_due=2026-11-06" "live overdue fires while done ignored"

# ---------- ④ gate② rq 活跃项 ----------
t_case "gate②: seeded awaiting-approval rq item fires rq_active"
sb_new >/dev/null 2>&1
sb_seed_queue_item "rq-sb-1" 12345 "deep" "awaiting-approval" 50
OUT=$(sb_run "$GATE")
assert_contains "$OUT" "rq_active=1" "awaiting-approval fires"

t_case "gate②: release-gate item does NOT fire rq_active (s0630 misroute fix)"
sb_new >/dev/null 2>&1
sb_seed_queue_item "rq-sb-2" 812574 "deep" "approved" 90 "release-gate"
OUT=$(sb_run "$GATE")
assert_eq "$OUT" "none" "approved release-gate → none (flashcards domain, not contrib)"

t_case "gate②: mixed queue — release-gate excluded, others still counted"
sb_new >/dev/null 2>&1
sb_seed_queue_item "rq-sb-3" 812574 "deep" "approved" 90 "release-gate"
sb_seed_queue_item "rq-sb-4" 12346 "deep" "awaiting-approval" 50
OUT=$(sb_run "$GATE")
assert_contains "$OUT" "rq_active=1" "release-gate filtered, awaiting-approval still counts"

# ---------- ⑤ x 形时刻容错（HH:Mx 上界归一，t_a49fa51e） ----------
# xrow_at <T> <hour-shift> —— 产 x 形时刻串 "YYYY-MM-DD HH:MTx"（末位分钟数字被 x 掩蔽）。
#   墙钟无关确定性：归一上报 R=HH:MT9，AGE=now-R；
#   shift=0 时若本小时 T9 已成未来（mm < 10T+9）自动退一小时 ⇒ AGE 恒 ∈ [0,59min]（必触发）；
#   shift≥1 时退两小时 ⇒ AGE 恒 ≥ 60min（恒不触发；退 1 小时 AGE=mm+1 可低至 1min 会误触发）。
xrow_at() {
  local T="$1" S="$2" mm off
  mm=$(( 10#$(date '+%M') ))
  if (( S == 0 )); then
    off=$(( (10#$T * 10 + 9 > mm) ? 1 : 0 ))
  else
    off=2
  fi
  printf '%s:%sx' "$(date -v-"$off"H '+%Y-%m-%d %H')" "$T"
}

t_case "x-form 0x: fresh 0x row is heard via upper-bound normalization"
sb_new >/dev/null 2>&1
add_row "| $(xrow_at 0 0) | operator 班（0x 形遗留行） | 对象 | 理由 | 高 | <!-- s0400-shift --> |"
OUT=$(sb_run "$GATE")
assert_contains "$OUT" "journal_tail_recent" "0x-style fresh row fires"

t_case "x-form 5x: fresh 5x row is heard (5x→59 normalization)"
sb_new >/dev/null 2>&1
add_row "| $(xrow_at 5 0) | operator 班（5x 形遗留行） | 对象 | 理由 | 高 | <!-- s0400-shift --> |"
OUT=$(sb_run "$GATE")
assert_contains "$OUT" "journal_tail_recent" "5x-style fresh row fires"

t_case "x-form stale: normalized age ≥60min stays silent (window not loosened)"
sb_new >/dev/null 2>&1
add_row "| $(xrow_at 5 1) | operator 班（x 形陈旧行） | 对象 | 理由 | 高 | <!-- s0400-shift --> |"
OUT=$(sb_run "$GATE")
assert_eq "$OUT" "none" "stale x row does not fire"

t_case "x-form garbage: 6x outside [0-5]x remains rejected → none"
sb_new >/dev/null 2>&1
add_row "| $(xrow_at 6 0) | operator 班（6x 垃圾形） | 对象 | 理由 | 高 | <!-- s0400-shift --> |"
OUT=$(sb_run "$GATE")
assert_eq "$OUT" "none" "6x garbage stays rejected"

# stderr 卫生：末个用例 stderr 不允许出现 Illegal byte sequence（locale 炸管道的 smoke 探针）
t_case "stderr hygiene: no Illegal byte sequence in last run's stderr"
if [ -f "$SB_OUT_FILE" ] && grep -q "Illegal byte sequence" "$SB_OUT_FILE" 2>/dev/null; then
  _fail "stderr" "BSD cut/grep 仍在炸 locale"
else
  _pass "stderr"
fi

t_finish
