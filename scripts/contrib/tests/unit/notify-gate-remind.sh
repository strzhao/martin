#!/bin/bash
# notify-gate-remind.sh — Tier U：人门提醒（gate-remind）机械检测（09-14 缺口根治）
# 缺口：blocked 的 `[draft]`/`[fix]` 卡在用户侧无送达面（contrib 板零微信订阅 + 简报不看卡
#       + 班次 job deliver=local）⇒ 只能靠人主动开板。修法 = flush 内机械检测 + 账本 key 幂等。
# 覆盖：
#   ① config 缺 gate_remind_hours ⇒ 0=关闭（不静默上线）
#   ② 命中面（status=blocked ∧ 标题含 [draft]/[fix] ∧ 超时）与四类反例（[watch] / done /
#      running / archived）
#   ③ 阈值边界（3h01m 落账 / 2h59m 不落账，严格大于）
#   ④ 账本 key 幂等（两轮 flush 单行、occurrences 累计）
#   ⑤ 同轮送达链（一次 flush 内 event → 批快照 → send-digest 后 pushed=true）
#   ⑥ 读板失败两态（板库缺失 / 板库非法）只记日志、不中断 flush
# 沙箱：板库固定读 $HOME/.hermes/kanban/boards/contrib/kanban.db（HOME 已指向沙箱 ⇒ 生产零触达）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "notify-gate-remind.sh"

EVENTS_FILE=""

gate_db() { printf '%s/.hermes/kanban/boards/contrib/kanban.db' "$SB_HOME"; }

# seed_gate_db <id> <title> <status> <age_secs> [<id> <title> <status> <age_secs> ...]
#   板库 fixture：created_at = now - age_secs（四元组序列；title 禁单引号）
seed_gate_db() {
  local db; db="$(gate_db)"
  mkdir -p "$(dirname "$db")"
  rm -f "$db"
  sqlite3 "$db" "create table tasks (id text, title text, status text, created_at integer);" || return 1
  local now; now="$(date +%s)"
  while (( $# >= 4 )); do
    sqlite3 "$db" "insert into tasks values ('$1', '$2', '$3', $(( now - $4 )));" || return 1
    shift 4
  done
  return 0
}

# gate_rows → human-gate 事件行数；gate_key_field <task_id> <字段> → 该 key 行的字段值
gate_rows() { grep -c '"class":"human-gate"' "$EVENTS_FILE" 2>/dev/null || true; }
gate_key_field() {
  jq -r --arg k "gate-$1" --arg f "$2" 'select(.key == $k) | .[$f]' "$EVENTS_FILE" 2>/dev/null || true
}

# ================= ① 缺配置 ⇒ 关闭 =================

t_case "config 缺 gate_remind_hours → 0=关闭（缺配置不静默上线）"
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
assert_eq "$(jq -r '.gate_remind_hours // "absent"' "$SB_ROOT/contrib-data/config.json")" "absent" "沙箱基线无该键"
seed_gate_db t_off "[draft] 超时人门卡" blocked 20000
sb_notify flush >/dev/null
assert_exit 0 $?
assert_eq "$(gate_rows)" "0" "缺键 ⇒ 零 human-gate 事件"

# ================= ② 命中面 =================

t_case "hours=3 + blocked [draft] 超时 → 落 human-gate 行（key/class/channel 三键）"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
seed_gate_db t_hit "[draft] 编排层缺口：示例" blocked 20000
sb_notify flush >/dev/null
assert_exit 0 $?
assert_eq "$(gate_rows)" "1" "落一行 human-gate"
assert_eq "$(gate_key_field t_hit class)" "human-gate" "class=human-gate"
assert_eq "$(gate_key_field t_hit channel)" "contrib" "channel=contrib"
assert_eq "$(gate_key_field t_hit pushed)" "false" "未推（等本轮批送）"
assert_eq "$(gate_key_field t_hit route)" "push" "route=push（不进简报降级）"
assert_contains "$(gate_key_field t_hit summary)" "t_hit" "summary 带卡 id 锚点"
assert_contains "$(gate_key_field t_hit summary)" "等你裁决或放行" "summary 自带动作行（不依赖黑话对照表）"

t_case "同轮带走：一次 flush 的 digest 批快照里已含该 human-gate 事件"
SNAP="$(jq -r '.batch_file // empty' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)"
if [[ -n "$SNAP" && -f "$SNAP" ]]; then
  _pass "flush 建了 digest 批快照"
else
  _fail "flush 建了 digest 批快照" "flight/snapshot 缺失: ${SNAP:-<空>}"
fi
assert_contains "$(cat "$SNAP" 2>/dev/null)" '"key":"gate-t_hit"' "快照含 gate-t_hit（同轮携带，非下一轮）"

t_case "命中面反例：[watch] / done / running / archived 一律不落账"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
seed_gate_db t_r1 "[watch] 普通观察卡" blocked 20000 \
             t_r2 "[draft] 已完成" "done" 20000 \
             t_r3 "[fix] 在跑" running 20000 \
             t_r4 "[draft] 归档" archived 20000
sb_notify flush >/dev/null
assert_exit 0 $?
assert_eq "$(gate_rows)" "0" "四类反例零命中"

# ================= ③ 阈值边界 =================

t_case "阈值边界：3h01m 落账 / 2h59m 不落账（now-created_at > hours 严格大于）"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
seed_gate_db t_b1 "[fix] 刚过线" blocked $(( 3 * 3600 + 60 )) \
             t_b2 "[fix] 未过线" blocked $(( 3 * 3600 - 60 ))
sb_notify flush >/dev/null
assert_exit 0 $?
assert_eq "$(gate_rows)" "1" "只落过线那张"
assert_eq "$(gate_key_field t_b1 class)" "human-gate" "过线的落账"
assert_eq "$(gate_key_field t_b2 class)" "" "未过线的零行"

# ================= ④ 账本 key 幂等 =================

t_case "账本 key 幂等：两轮 flush 同 key 仍单行、occurrences 累计（不重复成行）"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
seed_gate_db t_idem "[draft] 幂等用例" blocked 20000
sb_notify flush >/dev/null
sb_notify flush >/dev/null
assert_exit 0 $?
assert_eq "$(grep -c '"key":"gate-t_idem"' "$EVENTS_FILE")" "1" "同 key 恒单行"
assert_eq "$(gate_key_field t_idem occurrences)" "2" "occurrences 累计到 2"
assert_eq "$(gate_rows)" "1" "行数不随轮次增长"

# ================= ⑤ 送达判据（真送出 = 账本 pushed=true） =================

t_case "送达判据：同轮 flush → send-digest 后账本 pushed=true（不是「跑过 flush」）"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
seed_gate_db t_send "[draft] 送达用例" blocked 20000
sb_notify flush >/dev/null
assert_exit 0 $?
SNAP="$(jq -r '.batch_file // empty' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)"
if [[ -z "$SNAP" ]]; then
  _fail "flush 建了 digest 批快照（send-digest 前置）" "flight.batch_file 为空"
  SNAP="$SB_ROOT/contrib-data/pending/digest-fallback.json"
fi
DIGEST="${SNAP%.json}.digest.md"
printf '🟠【contrib 告警】09-14\n\n人门卡 t_send 停在 blocked 超 3h，微信与简报均未送达：等你裁决或放行。\n' >"$DIGEST"
out="$(sb_notify send-digest --digest "$DIGEST" --batch "$SNAP")"
assert_exit 0 $?
assert_eq "$out" "OK" "send-digest stdout 闭集 OK"
assert_eq "$(gate_key_field t_send pushed)" "true" "真送出判据：账本 pushed=true"
assert_not_contains "$(gate_key_field t_send pushed_at)" "null" "pushed_at 落值"
assert_file_contains "$SB_ROOT/stublog/hermes-send-last.json" '"success":true' "影子通道 success:true"

# ================= ⑥ 读板失败两态 =================

t_case "板库缺失 → 零事件、只记日志、flush 正常返回"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
sb_notify event pipeline-failure --key gr-pf --summary "无关叙事事件" >/dev/null
rm -rf "$SB_HOME/.hermes"
sb_notify flush >/dev/null
assert_exit 0 $? "flush 不被读板失败中断"
assert_eq "$(gate_rows)" "0" "零 human-gate 事件"
assert_file_contains "$SB_ROOT/contrib-data/logs/notify.log" "gate-remind: 板库不存在" "缺失态落日志"

t_case "板库非法（非数据库文件）→ 零事件、rc 落日志"
sb_new >/dev/null 2>&1
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
sb_config_set '.gate_remind_hours = 3'
mkdir -p "$(dirname "$(gate_db)")"
printf 'not a sqlite db\n' >"$(gate_db)"
sb_notify flush >/dev/null
assert_exit 0 $?
assert_eq "$(gate_rows)" "0" "零 human-gate 事件"
assert_file_contains "$SB_ROOT/contrib-data/logs/notify.log" "gate-remind: 板读取失败" "失败态落日志"

sb_cleanup
t_finish
