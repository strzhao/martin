#!/bin/bash
# watch-due-patrol.sh — Tier U：确定性 [watch] 到期巡检器（卡 t_cc4c9fcd 的落地件）
#
# 缺口：`scheduled`/`blocked` 两侧 kernel 都不自醒（schedule_task 是终态停放；dispatcher 只枚举
#   ready 列）⇒ 到期唤醒的唯一形态 = 某个 actor 调 unblock。心跳钳夹随宿主退役后该 actor 消失。
# 修法：把巡检挂进既有确定性调用面（cron job 3e5c6e23e260 的 script harness），本文件锁其判据。
#
# 覆盖（逐条对应卡面 Q3/Q4 契约）：
#   ① 候选面 = 状态 in ('scheduled','blocked') ∧ 评论表含到期机器行；ready/done/archived 绝不动
#   ② 逐卡判据 = max(该卡全部合法窗口) <= 今天（判据修订抬高日期后不得早醒）
#   ③ 形状守卫：窗口不过 YYYY-MM-DD ⇒ 落 parse SKIP、不判到期（散文命中不得触发唤醒）
#   ④ 读库失败（板库缺失）⇒ rc=0 + stdout 恰 1 行 read FAILED + 日志 `patrol read FAILED`
#   ⑤ stdout 契约：零唤醒零输出 / 有唤醒恰 1 行且含卡 id（它是注入班次 agent prompt 的上下文）
#   ⑥ 逐日模拟（对照卡面 Q2 的 10 张真实布局）——每天「非到期被唤醒数=0 ∧ 到期漏唤醒数=0」
# 沙箱：板库固定读 $HOME/.hermes/kanban/boards/contrib/kanban.db，HOME 已指向沙箱 ⇒ 生产零触达；
#   「今天」由 tests/stubs/date 的 STUB_DATE_TODAY 冻结；hermes CLI 走影子 stub（写不到真板）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "watch-due-patrol.sh"

patrol_db() { printf '%s/.hermes/kanban/boards/contrib/kanban.db' "$SB_HOME"; }
patrol_log() { printf '%s/contrib-data/logs/watch-due-patrol.log' "$SB_ROOT"; }

# seed_patrol_db <id> <status> <comment...>  —— 每三元组一卡；comment 为该卡的一条评论
# 形式：seed_patrol_db id status body  [id status body ...]（body 见下方分节调用）
seed_patrol_db() {
  local db; db="$(patrol_db)"
  mkdir -p "$(dirname "$db")"
  rm -f "$db"
  sqlite3 "$db" "create table tasks (id text, status text);
create table task_comments (id integer primary key autoincrement, task_id text, body text);" || return 1
  local id status body
  while (( $# >= 3 )); do
    id="$1"; status="$2"; body="$3"; shift 3
    sqlite3 "$db" "insert into tasks values ('$id','$status');
insert into task_comments (task_id, body) values ('$id','$body');" || return 1
  done
  return 0
}

add_comment() { # <id> <body> —— 追加一条评论（双窗口/判据修订用例）
  sqlite3 "$(patrol_db)" "insert into task_comments (task_id, body) values ('$1','$2');"
}

run_day() { # <YYYY-MM-DD> → stdout（rc 由 $? 透出）
  sb_run -e "STUB_DATE_TODAY=$1" 'bash "$MARTIN_DIR/scripts/contrib/watch-due-patrol.sh"'
}

calls_n() { # 沙箱 hermes stub 累计调用行数
  if [ -f "$SB_STUBLOG/calls.log" ]; then wc -l <"$SB_STUBLOG/calls.log" | tr -d ' '; else printf '0'; fi
}

wake_ids_since() { # <行偏移> → 该偏移之后 unblock 的卡 id（空格分隔，保留调用顺序）
  local off="${1:-0}" f="$SB_STUBLOG/calls.log"
  [ -f "$f" ] || { printf ''; return 0; }
  tail -n +"$(( off + 1 ))" "$f" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "unblock") print $(i + 1) }' \
    | tr '\n' ' ' | sed 's/ $//'
}

regrade_woken() { # <行偏移> —— 模拟 kernel unblock 后的状态迁移（unblock ⇒ ready；
  # 真板上被唤醒的卡随即离开候选面，这正是「同一卡不重复唤醒」的机制来源）
  local id
  for id in $(wake_ids_since "${1:-0}"); do
    sqlite3 "$(patrol_db)" "update tasks set status='ready' where id='$id';"
  done
}

# ================= ① 候选面 + ② max 判据 + ③ 形状守卫 + ⑤ stdout 契约 =================

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
seed_patrol_db \
  t_w1 blocked   'watch-due: 2026-09-15  本卡由 shift-18 物化' \
  t_w2 scheduled 'SCHEDULED: watch-due: 2026-09-15 | object=issue#1' \
  t_w3 blocked   'watch-due: 2026-09-16 | object=issue#2' \
  t_w4 blocked   'watch-due: 2026-09-16 判据初稿' \
  t_w5 blocked   'watch-due: TBD 待定（形状非法：非日期）' \
  t_w6 ready     'watch-due: 2026-09-15 已 re-gate 的卡' \
  t_w7 'done'    'watch-due: 2026-09-15 已完成卡' \
  t_w8 blocked   '本卡评论无到期机器行'
add_comment t_w4 '**判据修订（跨卡通知）**：watch-due: 2026-09-18（原判据日 2026-09-16 顺延）'

t_case "D=09-14：零唤醒、零 unblock 调用、stdout 空（未到期不动）"
OFF="$(calls_n)"
out="$(run_day 2026-09-14)"; rc=$?
assert_exit 0 "$rc" "rc=0"
assert_eq "$(wake_ids_since "$OFF")" "" "零唤醒"
assert_eq "$out" "" "stdout 零输出（无唤醒即无上下文行）"

t_case "D=09-15：只唤醒当日到期两张（t_w1 blocked + t_w2 scheduled）"
OFF="$(calls_n)"
out="$(run_day 2026-09-15)"
assert_eq "$(wake_ids_since "$OFF")" "t_w1 t_w2" "恰好两张、无重复"
assert_contains "$out" "t_w1" "stdout 携带本 tick 唤醒对象"
assert_contains "$out" "t_w2" "stdout 携带本 tick 唤醒对象"
assert_eq "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0" "stdout 恰 1 行（无换行符 = 单行）"
assert_file_contains "$(patrol_log)" "woke t_w1 due=2026-09-15 today=2026-09-15" "日志落 woke 行"
regrade_woken "$OFF"

t_case "D=09-16：t_w3 唤醒；t_w4 因 max(09-16,09-18)=09-18 不得唤醒（防早醒 2 天）"
OFF="$(calls_n)"
out="$(run_day 2026-09-16)"
assert_eq "$(wake_ids_since "$OFF")" "t_w3" "只唤醒 t_w3（t_w4 取 max 未到）"
assert_not_contains "$out" "t_w4" "t_w4 不进 stdout"
regrade_woken "$OFF"

t_case "D=09-17：零唤醒（t_w4 的 max 仍未到）"
OFF="$(calls_n)"
out="$(run_day 2026-09-17)"
assert_eq "$(wake_ids_since "$OFF")" "" "零唤醒"
assert_eq "$out" "" "stdout 零输出"

t_case "D=09-18：t_w4 唤醒（max 到点才唤醒）"
OFF="$(calls_n)"
out="$(run_day 2026-09-18)"
assert_eq "$(wake_ids_since "$OFF")" "t_w4" "t_w4 到 max 日唤醒"
assert_contains "$out" "t_w4" "stdout 携带 t_w4"
regrade_woken "$OFF"

t_case "候选面：ready/done 卡（t_w6/t_w7）与无 token 卡（t_w8）全程零调用"
assert_not_contains "$(cat "$SB_STUBLOG/calls.log")" "unblock t_w6" "ready 卡未被唤醒"
assert_not_contains "$(cat "$SB_STUBLOG/calls.log")" "unblock t_w7" "done 卡未被唤醒"
assert_not_contains "$(cat "$SB_STUBLOG/calls.log")" "unblock t_w8" "无 token 卡未被唤醒"

t_case "形状守卫：非法窗口落 parse SKIP、不判到期（散文命中不得触发唤醒）"
assert_file_contains "$(patrol_log)" "parse SKIP t_w5 win=[len=" "落 SKIP 漏账行（带形状元信息）"
assert_not_contains "$(cat "$SB_STUBLOG/calls.log")" "unblock t_w5" "非法窗口未触发唤醒"

t_case "唤醒调用形态：hermes kanban --board contrib unblock <id> --reason …"
assert_file_contains "$SB_STUBLOG/calls.log" "kanban --board contrib unblock t_w1 --reason" "board pin 在父级 flag 位"
assert_stub_not_called "gh" "巡检器零 gh 调用"

sb_cleanup

# ================= ④ 读库失败态 =================

t_case "板库缺失：rc=0 + stdout 恰 1 行 read FAILED + 日志 patrol read FAILED"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
out="$(run_day 2026-09-15)"; rc=$?
assert_exit 0 "$rc" "永远 exit 0（cron harness 契约）"
assert_contains "$out" "read FAILED" "stdout 明示读失败（不静默）"
assert_file_contains "$(patrol_log)" "patrol read FAILED" "日志四态可判"
assert_stub_not_called "hermes" "读失败时零唤醒调用"

t_case "板库非法（非数据库文件）：rc=0 + 日志 read FAILED + 零唤醒"
mkdir -p "$(dirname "$(patrol_db)")"
printf 'not a sqlite db\n' >"$(patrol_db)"
out="$(run_day 2026-09-15)"; rc=$?
assert_exit 0 "$rc" "rc=0"
assert_file_contains "$(patrol_log)" "patrol read FAILED" "非法库同样落 read FAILED"
assert_stub_not_called "hermes" "零唤醒调用"

sb_cleanup

# ================= ⑥ 逐日模拟（对照卡面 Q2 的 10 张真实布局）=================
# blocked  : t_1621971d 09-15 / t_db200d54 09-16 / t_03bc12f0 09-18(max) / t_50ff94bb 09-17 /
#            t_19c1f214 09-20
# scheduled: t_d61894dd 09-15 / t_48f8038b 09-16 / t_7948e8d5 09-16 / t_eb1bdde3 09-17 /
#            t_26d4c387 09-18
# 判据：每天「非到期被唤醒数=0 ∧ 到期卡漏唤醒数=0」——任一 >0 即 REBUT。

t_case "逐日模拟 09-14 → 09-20：唤醒集合逐日对齐（10 张真实布局）"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
seed_patrol_db \
  t_1621971d blocked   'operator shift-14 物化本卡 + 基线落此；watch-due: 2026-09-15' \
  t_db200d54 blocked   'watch-due: 2026-09-16  本卡由 shift-18 scan 物化' \
  t_50ff94bb blocked   'watch-due: 2026-09-17  ## 提前派发 → 按卡面处置' \
  t_19c1f214 blocked   'watch-due: 2026-09-20 | status=未到期' \
  t_d61894dd scheduled 'SCHEDULED: watch-due: 2026-09-15 | object=pr#110023' \
  t_48f8038b scheduled 'watch-due: 2026-09-16 | object=issue#109954' \
  t_7948e8d5 scheduled 'SCHEDULED: watch-due: 2026-09-16 | object=issue#109964' \
  t_eb1bdde3 scheduled 'watch-due: 2026-09-17 | status=未到期' \
  t_26d4c387 scheduled 'watch-due: 2026-09-18 | object=生产契合簇' \
  t_03bc12f0 blocked   'watch-due: 2026-09-16  本卡由 shift-18 scan 物化'
add_comment t_03bc12f0 '**出手裁定已出（跨卡通知）**：watch-due: 2026-09-18（原判据日 2026-09-16 修订）'

sim_day() { # <天> <期望唤醒集>（唤醒后模拟 kernel re-gate：unblock ⇒ ready，离开候选面）
  local d="$1" want="$2" off got
  off="$(calls_n)"
  run_day "$d" >/dev/null
  got="$(wake_ids_since "$off" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$got" "$want" "今日 $d 唤醒集合"
  regrade_woken "$off"
}

sim_day 2026-09-14 ""
sim_day 2026-09-15 "t_1621971d t_d61894dd"
sim_day 2026-09-16 "t_48f8038b t_7948e8d5 t_db200d54"
sim_day 2026-09-17 "t_50ff94bb t_eb1bdde3"
sim_day 2026-09-18 "t_03bc12f0 t_26d4c387"
sim_day 2026-09-19 ""
sim_day 2026-09-20 "t_19c1f214"
assert_eq "$(calls_n)" "10" "全程唤醒调用总数=10（10 张卡各一次，无重复无遗漏）"

sb_cleanup
t_finish
