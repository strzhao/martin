#!/bin/bash
# radar-mail-cardify.sh — Tier U：radar 卡化 + mail 卡化 + cursor 快照守卫 + flight per-kind 迁移（T3）
# 覆盖：
#   ① flight per-kind 迁移：旧单对象 kanban-flight.json → kanban-flight-scan.json 一次性 mv
#   ② mail 段卡化：exit 10 → 建 mail 卡（五键登记含 pending_max_id 快照）/ 在飞跳过 /
#     done+快照一致 → commit-cursor / done+快照有增长 → 零 commit 只清登记 /
#     done+当前<快照 → 归不 commit 分支 / blocked+失败 outcome → fallback / 建卡失败+QC 开 →
#     -mail-fallback-skipped / 陈旧守卫
#   ③ radar 段卡化：08 窗口建卡 / 建卡失败置补跑旗标（fallback 成功才删）/ 有旗标非 08 补跑 /
#     卡 done 删旗标（fall-through 仅 hour==08）/ 在飞跳过 / 失败终态旗标保留（QC 挡兜底）
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN/HIMALAYA_BIN stub 沙箱隔离，零真实 hermes/claude/himalaya 调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "radar-mail-cardify.sh"

TODAY="$(date +%F)"

# ---- 通用工具 ----
last_claude_line() { # <prompt 子串>
  awk -F'|' -v s="$1" '$1 == "claude" && index($0, s) { l = $0 } END { if (l != "") print l }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_claude_prompt() { # <prompt 子串>
  awk -F'|' -v s="$1" '$1 == "claude" && index($0, s) { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_create() {
  awk -F'|' '$1 == "hermes" && index($0, "kanban create") { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
ev_key_count() { # <key 后缀>（endswith 口径，日期段不钉死）
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

# ---- mail 种子工具 ----
mail_env_row() { # <id> → 上游 GitHub 通知 envelope 行（to 双分流命中）
  jq -cn --arg id "$1" \
    '{id:$id,flags:[],subject:("Re: [NousResearch/hermes-agent] pr" + $id),
      from:{name:"Teknium",addr:"notifications@github.com"},
      to:{name:"x",addr:"hermes-agent@noreply.github.com"},
      date:"2026-09-09 05:00-07:00",has_attachment:false}'
}
mail_seed() { # <cursor_last> <id...> → 游标 + envelopes + read 正文（驱动 mail_gate exit 10）
  mkdir -p "$SB_ROOT/mailstub"
  printf '{"last_id":%s,"initialized":"t"}\n' "$1" >"$SB_ROOT/contrib-data/mail-cursor.json"
  : >"$SB_ROOT/mailstub/rows"
  local first=1 id
  shift
  for id in "$@"; do
    if [[ $first -eq 0 ]]; then printf ',' >>"$SB_ROOT/mailstub/rows"; fi
    first=0
    mail_env_row "$id" >>"$SB_ROOT/mailstub/rows"
    printf 'From: Teknium <notifications@github.com>\nSubject: s\n\n正文 %s。\n\nMessage ID: <m%s@github.com>\n' "$id" "$id" \
      >"$SB_ROOT/mailstub/read-$id.txt"
  done
  printf '[%s]\n' "$(cat "$SB_ROOT/mailstub/rows")" >"$SB_ROOT/mailstub/envelopes.json"
}
mail_pending_seed() { # <id...> → 直接写 pending（构造在飞期间增长/drain 前置态）
  : >"$SB_ROOT/pending.rows"
  local first=1 id
  for id in "$@"; do
    if [[ $first -eq 0 ]]; then printf ',' >>"$SB_ROOT/pending.rows"; fi
    first=0
    jq -cn --arg id "$id" --arg mid "m$id@github.com" \
      '{id:$id,subject:"s",message_id:$mid,preview:"p"}' >>"$SB_ROOT/pending.rows"
  done
  printf '[%s]\n' "$(cat "$SB_ROOT/pending.rows")" >"$SB_ROOT/contrib-data/mail-pending.json"
}

# ---- 沙箱预备 ----
quiet_sb() { # 新沙箱 + scan 静默（零命中）+ mail 采集静默（空 envelopes）
  sb_new >/dev/null 2>&1
  mkdir -p "$SB_ROOT/mailstub"
  printf '[]\n' >"$SB_ROOT/mailstub/envelopes.json"
  printf '[]\n' >"$SB_ROOT/gh-issues.json"
  printf '{"last_issue":9000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
}
run_watch() { # [K=V ...] — 注入 mail stub 数据源跑一轮 run-watch
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" \
    -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}
seed_card_store() { # <card_id> <status> — 在飞查询前置态
  printf '{"id":"%s","status":"%s","assignee":"contrib","priority":0}\n' "$1" "$2" \
    >"$SB_ROOT/stublog/kanban-cards.jsonl"
}
seed_flight_mail() { # <card_id> <epoch> <pending_max_id>
  jq -n --arg id "$1" --argjson ep "$2" --argjson p "${3:-0}" \
    '{kind:"mail",card_id:$id,batch_file:"",created_epoch:$ep,pending_max_id:$p}' \
    >"$SB_ROOT/contrib-data/kanban-flight-mail.json"
}
seed_flight_radar() { # <card_id> <epoch>
  jq -n --arg id "$1" --argjson ep "$2" \
    '{kind:"radar",card_id:$id,batch_file:"",created_epoch:$ep}' \
    >"$SB_ROOT/contrib-data/kanban-flight-radar.json"
}
seed_flight_scan_old() { # <card_id> <epoch> — 旧单对象 flight（迁移用例）
  jq -n --arg id "$1" --argjson ep "$2" \
    '{kind:"scan",card_id:$id,batch_file:"",created_epoch:$ep}' \
    >"$SB_ROOT/contrib-data/kanban-flight.json"
}
qopen() { printf '%s\n' "$(( $(date +%s) + 3600 ))" >"$SB_ROOT/contrib-data/.quota-circuit"; }

# ================= ① flight per-kind 迁移 =================

t_case "flight 迁移: 旧单对象 kanban-flight.json → 一次性 mv 为 kanban-flight-scan.json"
quiet_sb
seed_flight_scan_old "t_old" "$(date +%s)"
seed_card_store "t_old" "running"   # 非终态 → 迁移后走「在飞跳过」，-scan 文件可观测
run_watch
assert_exit 0 $?
[[ -f "$SB_ROOT/contrib-data/kanban-flight-scan.json" ]] && _pass "新路径 -scan 登记存在" \
  || _fail "新路径 -scan 登记存在" "旧文件未迁移"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight.json" ]] && _pass "旧单对象文件已消失" \
  || _fail "旧单对象文件已消失" "kanban-flight.json 残留"
assert_eq "$(jq -r '.card_id // empty' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)" "t_old" "登记内容延续（card_id）"

# ================= ② mail 段卡化 =================

t_case "mail: exit10+无登记 → 建 mail 卡（五键登记含 pending_max_id 快照）+ cursor 不动 + 零 claude"
quiet_sb
mail_seed 8000 8001 8002
run_watch
assert_exit 0 $?
MAILF="$SB_ROOT/contrib-data/kanban-flight-mail.json"
assert_eq "$(jq -r '.kind // empty' "$MAILF" 2>/dev/null)" "mail" "flight kind=mail"
case "$(jq -r '.card_id // empty' "$MAILF" 2>/dev/null)" in t_stub_*) _pass "flight card_id 登记" ;; *) _fail "flight card_id 登记" "实得 $(jq -r '.card_id' "$MAILF" 2>/dev/null)" ;; esac
assert_eq "$(jq -r '.pending_max_id // 0' "$MAILF" 2>/dev/null)" "8002" "第五键 pending_max_id=当前最大 id 快照"
assert_eq "$(jq -r '.created_epoch > 0' "$MAILF" 2>/dev/null)" "true" "created_epoch"
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8000" "cursor 本轮不动（异步推进）"
assert_eq "$(count_claude_prompt 'contrib-watch mail')" "0" "主路零 claude"
assert_contains "$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)" \
  "--idempotency-key mail-" "建卡 idempotency-key mail- 前缀"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "mail-pending.json" "卡 body 含 mail-pending.json 路径"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "SKILL.md" "卡 body 含 SKILL.md 权威路径"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "himalaya" "卡 body 含禁碰 himalaya 写操作红线"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "commit-cursor" "卡 body 含不自行 commit-cursor 红线"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban_complete" "卡 body 含收尾双传要求"

t_case "mail: 在飞 running → 本轮跳过（不建新卡、cursor 不动、登记保留）"
quiet_sb
mail_pending_seed 8001 8002   # leftover pending → mail_gate exit 10
printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
seed_flight_mail "t_old" "$(date +%s)" 8002
seed_card_store "t_old" "running"
run_watch
assert_exit 0 $?
assert_eq "$(count_create)" "0" "在飞不建新卡（同 kind 单飞）"
assert_eq "$(count_claude_prompt 'contrib-watch mail')" "0" "在飞不 fallback"
assert_eq "$(jq -r '.card_id // empty' "$SB_ROOT/contrib-data/kanban-flight-mail.json" 2>/dev/null)" "t_old" "登记保留"
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8000" "cursor 不动"

t_case "mail: 卡 done+快照一致 → commit-cursor 被调（cursor 拨 max+pending 清）+ 登记清"
quiet_sb
mail_pending_seed 8001 8002
printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
seed_flight_mail "t_old" "$(date +%s)" 8002
seed_card_store "t_old" "done"
run_watch
assert_exit 0 $?
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8002" "cursor 拨到 pending max（守卫通过才 commit）"
assert_eq "$(jq 'length' "$SB_ROOT/contrib-data/mail-pending.json" 2>/dev/null)" "0" "pending 已清（消费闭环）"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "登记已清" || _fail "登记已清" "flight-mail 残留"
assert_eq "$(count_claude_prompt 'contrib-watch mail')" "0" "done 路不 fallback"

t_case "mail: 卡 done+pending 有增长（快照 8002 → 当前 8003）→ 零 commit 只清登记 + pending 保留"
quiet_sb
mail_pending_seed 8001 8002 8003
printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
seed_flight_mail "t_old" "$(date +%s)" 8002
seed_card_store "t_old" "done"
run_watch
assert_exit 0 $?
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8000" "飞行窗口内新到邮件绝不被静默消费（cursor 不动）"
assert_eq "$(jq 'length' "$SB_ROOT/contrib-data/mail-pending.json" 2>/dev/null)" "3" "pending 保留驱动下轮新卡"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "登记已清（不 commit 分支）" || _fail "登记已清" "flight-mail 残留"

t_case "mail: 卡 done+当前<快照（在飞期间人工 drain）→ 归不 commit 分支（cursor 不动）+ 登记清"
quiet_sb
mail_pending_seed 8001
printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
seed_flight_mail "t_old" "$(date +%s)" 8002
seed_card_store "t_old" "done"
run_watch
assert_exit 0 $?
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8000" "当前<快照 → 零 commit"
assert_eq "$(jq 'length' "$SB_ROOT/contrib-data/mail-pending.json" 2>/dev/null)" "1" "pending 保留"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "登记已清" || _fail "登记已清" "flight-mail 残留"

t_case "mail: 卡 blocked+outcome=gave_up → 清登记 + fallback claude mail + -mail-card-fallback 事件"
quiet_sb
mail_pending_seed 8001 8002
printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
seed_flight_mail "t_old" "$(date +%s)" 8002
seed_card_store "t_old" "blocked"
run_watch "STUB_KANBAN_RUN_OUTCOME=gave_up"
assert_exit 0 $?
assert_eq "$(count_claude_prompt 'contrib-watch mail')" "1" "失败终态 → fallback claude 被调"
assert_eq "$(ev_key_count '-mail-card-fallback')" "1" "-mail-card-fallback 入账"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "登记已清" || _fail "登记已清" "flight-mail 残留"
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8002" "fallback 旧同步语义：exit 0 后 commit-cursor"

t_case "mail: 建卡失败+QC 开 → fallback 被 QC 挡（零 claude）+ -mail-fallback-skipped + -mail-card-fallback 各 1"
quiet_sb
mail_seed 8000 8001
qopen
run_watch "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(count_claude_prompt 'contrib-watch mail')" "0" "QC 开 → claude 零调用"
assert_eq "$(ev_key_count '-mail-fallback-skipped')" "1" "-mail-fallback-skipped 入账"
assert_eq "$(ev_key_count '-mail-card-fallback')" "1" "-mail-card-fallback 入账（建卡失败分支）"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "建卡失败不写登记" || _fail "建卡失败不写登记" "残留"
assert_eq "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" "8000" "cursor 不动"

t_case "mail: 非终态超 6h → 清登记 + fallback + event（陈旧守卫）"
quiet_sb
mail_pending_seed 8001
printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
seed_flight_mail "t_old" "$(( $(date +%s) - 30000 ))" 8001
seed_card_store "t_old" "running"
run_watch
assert_exit 0 $?
assert_eq "$(count_claude_prompt 'contrib-watch mail')" "1" "陈旧守卫 → fallback"
assert_eq "$(ev_key_count '-mail-card-fallback')" "1" "event 入账"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "陈旧登记已清" || _fail "陈旧登记已清" "残留"

t_case "mail: mrc==0（无新邮件）→ 零建卡零查询（卡化不越 mrc==10 门）"
quiet_sb
run_watch
assert_exit 0 $?
assert_eq "$(count_create)" "0" "无新邮件零建卡"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]] && _pass "零登记" || _fail "零登记" "残留"

# ================= ③ radar 段卡化 =================

t_case "radar: 08 窗口+无登记 → 建 radar 卡 + flight-radar 登记 + 旗标不落盘（建卡成功不置旗）"
quiet_sb
run_watch "RADAR_HOUR=08"
assert_exit 0 $?
assert_eq "$(count_create)" "1" "08 窗口建卡"
assert_contains "$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)" \
  "--idempotency-key radar-" "idempotency-key radar- 前缀"
RADF="$SB_ROOT/contrib-data/kanban-flight-radar.json"
assert_eq "$(jq -r '.kind // empty' "$RADF" 2>/dev/null)" "radar" "flight kind=radar"
case "$(jq -r '.card_id // empty' "$RADF" 2>/dev/null)" in t_stub_*) _pass "card_id 登记" ;; *) _fail "card_id 登记" "缺" ;; esac
[[ ! -f "$SB_ROOT/contrib-data/pending-radar.flag" ]] && _pass "建卡成功不置补跑旗标" || _fail "建卡成功不置补跑旗标" "旗标残留"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "SKILL.md" "卡 body 含 SKILL.md（模式二权威）"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "radar/" "卡 body 含产出路径 radar/"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban_complete" "卡 body 含收尾要求"

t_case "radar: 08 窗口建卡失败+QC 开 → 旗标落盘 + fallback 被 QC 挡（零 claude）+ fallback-skipped 事件"
quiet_sb
qopen
run_watch "RADAR_HOUR=08" "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(count_claude_prompt 'contrib-watch radar')" "0" "QC 开 → fallback 跳过 claude"
assert_file_contains "$SB_ROOT/contrib-data/pending-radar.flag" "$TODAY" "旗标落盘（内容=置旗日期）"
assert_eq "$(ev_key_count '-radar-fallback-skipped')" "1" "-radar-fallback-skipped 入账"
assert_eq "$(ev_key_count '-radar-card-fallback')" "1" "-radar-card-fallback 入账"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-radar.json" ]] && _pass "建卡失败不写登记" || _fail "建卡失败不写登记" "残留"

t_case "radar: 08 窗口建卡失败+QC 闭 → fallback claude radar 成功 → 旗标删除（兜底研判完成）"
quiet_sb
run_watch "RADAR_HOUR=08" "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(count_claude_prompt 'contrib-watch radar')" "1" "QC 闭 → fallback claude 被调"
[[ ! -f "$SB_ROOT/contrib-data/pending-radar.flag" ]] && _pass "兜底成功 → 旗标删除" || _fail "兜底成功 → 旗标删除" "旗标残留"
assert_eq "$(ev_key_count '-radar-card-fallback')" "1" "-radar-card-fallback 入账"

t_case "radar: 08 窗口建卡失败+fallback claude 也失败 → 旗标保留 + -radar-exit 事件 key 不变"
quiet_sb
run_watch "RADAR_HOUR=08" "STUB_HERMES_FAIL=1" "STUB_CLAUDE_FAIL=1"
assert_exit 0 $?
assert_file_contains "$SB_ROOT/contrib-data/pending-radar.flag" "$TODAY" "兜底再败 → 旗标必须存活"
assert_eq "$(ev_key_count '-radar-exit1')" "1" "旧 -radar-exit* key 不变"

t_case "radar: 有旗标+非 08 时段 → 补跑建卡 + 旗标保留（删除条件=研判完成）"
quiet_sb
printf '%s\n' "$TODAY" >"$SB_ROOT/contrib-data/pending-radar.flag"
run_watch "RADAR_HOUR=14"
assert_exit 0 $?
assert_eq "$(count_create)" "1" "窗口外旗标补跑建卡"
[[ -f "$SB_ROOT/contrib-data/kanban-flight-radar.json" ]] && _pass "flight-radar 登记" || _fail "flight-radar 登记" "缺"
[[ -f "$SB_ROOT/contrib-data/pending-radar.flag" ]] && _pass "建卡成功旗标保留（等卡终态删）" || _fail "旗标保留" "旗标被提前删"

t_case "radar: 卡 done+非 08 → 清登记 + 旗标删除 + 不建新卡"
quiet_sb
printf '%s\n' "$TODAY" >"$SB_ROOT/contrib-data/pending-radar.flag"
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "t_old" "done"
run_watch "RADAR_HOUR=14"
assert_exit 0 $?
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-radar.json" ]] && _pass "登记已清" || _fail "登记已清" "残留"
[[ ! -f "$SB_ROOT/contrib-data/pending-radar.flag" ]] && _pass "研判完成旗标删除" || _fail "旗标删除" "残留"
assert_eq "$(count_create)" "0" "非 08 不 fall-through（防 flag 情形系统性双跑）"

t_case "radar: 卡 done+08 窗口 → fall-through 建当日新卡（窗口确实未消费）"
quiet_sb
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "t_old" "done"
run_watch "RADAR_HOUR=08"
assert_exit 0 $?
assert_eq "$(count_create)" "1" "仅 08 窗口轮首探到前卡 done → fall-through 建卡"
assert_ne "$(jq -r '.card_id // empty' "$SB_ROOT/contrib-data/kanban-flight-radar.json" 2>/dev/null)" "t_old" "flight 指向新卡"

t_case "radar: 在飞 running+08 窗口 → 跳过（不建卡不 fallback，同 kind 单飞）"
quiet_sb
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "t_old" "running"
run_watch "RADAR_HOUR=08"
assert_exit 0 $?
assert_eq "$(count_create)" "0" "在飞不建新卡"
assert_eq "$(count_claude_prompt 'contrib-watch radar')" "0" "在飞不 fallback"
assert_eq "$(jq -r '.card_id // empty' "$SB_ROOT/contrib-data/kanban-flight-radar.json" 2>/dev/null)" "t_old" "登记保留"

t_case "radar: 在飞 blocked+gave_up+旗标存在+QC 开 → fallback 被挡 → 旗标保留（失败终态不删旗）"
quiet_sb
printf '%s\n' "$TODAY" >"$SB_ROOT/contrib-data/pending-radar.flag"
seed_flight_radar "t_old" "$(date +%s)"
seed_card_store "t_old" "blocked"
qopen
run_watch "RADAR_HOUR=14" "STUB_KANBAN_RUN_OUTCOME=gave_up"
assert_exit 0 $?
assert_eq "$(count_claude_prompt 'contrib-watch radar')" "0" "QC 开 → 兜底被挡"
assert_file_contains "$SB_ROOT/contrib-data/pending-radar.flag" "$TODAY" "失败终态旗标保留（B-2R）"
assert_eq "$(ev_key_count '-radar-card-fallback')" "1" "-radar-card-fallback 入账"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-radar.json" ]] && _pass "登记已清" || _fail "登记已清" "残留"

t_case "radar: 非 08+无旗标+无登记 → 零动作"
quiet_sb
run_watch "RADAR_HOUR=03"
assert_exit 0 $?
assert_eq "$(count_create)" "0" "零建卡"
assert_eq "$(count_claude_prompt 'contrib-watch radar')" "0" "零 claude"
[[ ! -f "$SB_ROOT/contrib-data/pending-radar.flag" ]] && _pass "零旗标" || _fail "零旗标" "残留"

t_finish
