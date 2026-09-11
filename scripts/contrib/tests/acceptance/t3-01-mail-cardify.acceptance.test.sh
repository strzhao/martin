#!/usr/bin/env bash
# =============================================================================
# t3-01-mail-cardify.acceptance.test.sh — T3 验收矩阵①：mail 段卡化 + cursor 异步推进（快照守卫）
#   M1  mrc==10 无登记 → 建 mail 卡：body 含 mail-pending 绝对路径+SKILL 模式五+himalaya 禁写
#       +不自行 commit-cursor+收尾双传；flight-mail 五键（含 pending_max_id 快照）；cursor 本轮不动
#   M2  在飞（running 未超时）→ 本轮跳过：零建卡/零 claude/零 commit/登记保留
#   M3  卡 done+pending 无增长 → 先 --commit-cursor 成功（cursor 100→101、pending 清空）后清登记
#   M4  卡 done+pending 有增长（102>快照 101）→ 零 commit（cursor 不动、pending 残留）只清登记
#   M5  blocked+outcome∈闭集(gave_up) → 清登记+fallback claude 成功→旧同步语义 commit-cursor
#   M6  blocked+outcome 非闭集 → 非失败终态 → 本轮跳过（登记保留、零 fallback）
#   M7  建卡失败（hermes down）→ fallback claude 被调 + -mail-card-fallback 恰 1 + 兜底成功后
#       commit-cursor（旧同步语义保留）
#   M8a QC 开 → 建卡照常（卡路不受 QC 限；顺延分支已删除）
#   M8b QC 开+建卡失败 → fallback 内 QC gate：零 claude + -mail-fallback-skipped 恰 1 + cursor 不动
#   M9  非终态超 6h（STALE_SECS）→ 清登记 + fallback + -mail-card-fallback
#   M10 mrc==0（无 pending）→ 零 mail 动作（回归）
#   M11 在飞期间人工 --drain（mrc==0 探测不到）→ 零建卡（终态检查不挪出 mrc==10 门，设计注 I5：
#       误建第二张卡 = 突变靶）；登记保留等 stale 自愈
# 依据：state.md「## 设计文档」§2（mail 段卡化）+ 任务级契约：
#   「kanban-flight-<kind>.json；mail 登记五键 {kind,card_id,batch_file,created_epoch,pending_max_id}」
#   「--commit-cursor 只在 ①卡终态 done 且快照守卫通过后先 commit 后清登记，或 ②fallback exit 0 后调用；
#     飞行窗口 pending 有增长时零 commit；在飞/失败/无 pending 时零调用」
#   「max id 口径 = mail_gate.sh 同一 jq 表达式 [.[].id|tonumber]|max；当前<快照归入不 commit 分支」
#   「失败终态 = blocked + runs[].outcome∈{gave_up,crashed,timed_out,spawn_failed}，禁 failed 字面量」
#   「事件新族：<日期>-mail-fallback-skipped / <日期>-mail-card-fallback（与 scan 对称）」
# 前置态构造（黑盒 fixture，契约钉死路径）：mail-cursor.json last_id=100 + mail-pending.json
#   非空 → mail_gate.sh 走「无新邮件+遗留 pending」路 exit 10（零 himalaya 依赖，确定性）。
#   flight-mail 五键登记 + stub 卡库 kanban-cards.jsonl 播种终态（同 t1-03 模式）。
# hour 注入：沙箱 $HOME/.local/bin/date 影子 stub（run-watch/kanban_card 均把该目录置于 PATH 首位），
#   仅 argv 恰为单个 '+%H' 时输出环境变量 STUB_DATE_HOUR 的值，其余透传 /bin/date——黑盒、不依赖实现 seam 命名。
# CONTRACT_AMBIGUOUS：
#   - M4 快照有增长后「当轮是否直接建新卡」（设计文本=『自然触发下轮新卡』）两读皆通——不断言
#     create 计数，只断言契约硬面：零 commit + 清登记 + 零 fallback
#   - commit 失败保留下轮重试（先 commit 后清登记的顺序分支）黑盒无法稳定注入失败——顺序由
#     M3 终态（cursor 已推进 ∧ 登记已清）+ M4（零 commit 时登记仍清）联合钉住
# 红队纪律：黑盒（未读 run-watch.sh 本次改动 / SKILL.md 新段）；每断言硬失败；无 skip；
#   Mental Mutation：删快照守卫→M4 红；守卫改「≥快照即 commit」→M4 红；删登记清理→M3/M5 红；
#   终态检查挪出 mrc==10→M11 红；恢复 QC 顺延→M8a 红；删 fallback QC gate→M8b 红；
#   事件 key 改后缀→M5/M7/M8b/M9 红；登记落旧单文件路径→M1/M2/M3 红。
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

install_fake_date() { # 沙箱 $HOME/.local/bin/date：仅劫持裸 '+%H'（run-watch:9 / kanban_card:154
  # 均把 $HOME/.local/bin 前置到 PATH 首位；%s/%F/ISO 等全部透传，epoch/幂等键不受影响）
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

mk_issues() { # 无 scan 命中的 issue 表（游标 200 > issue 101 → scan_gate exit 0，mail 段聚焦）
  local out="$1"
  printf '[{"number":101,"title":"old issue","labels":[{"name":"bug"}],"user":{"login":"alice"},"created_at":"2026-09-01T00:00:00Z","comments":0,"pull_request":null}]\n' > "$out"
}

seed_scan_cursor() {
  jq -n --argjson n 200 --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' \
    > "$SB_ROOT/contrib-data/scan-cursor.json"
}

seed_mail_cursor() { # last_id=100
  printf '{"last_id":100,"initialized":"2026-09-09T00:00:00Z"}\n' > "$SB_ROOT/contrib-data/mail-cursor.json"
}

seed_mail_pending() { # <id 们...> → pending 数组（id 字符串形态同 mail_gate 产出）
  local out="[" i first=1
  for i in "$@"; do
    [ "$first" -eq 1 ] && first=0 || out="$out,"
    out="$out{\"id\":\"$i\",\"subject\":\"[test/repo] notify #$i\",\"message_id\":\"m$i\",\"preview\":\"p$i\"}"
  done
  printf '%s]\n' "$out" > "$SB_ROOT/contrib-data/mail-pending.json"
}

seed_flight_mail() { # <card_id> <created_epoch> <pending_max_id> — 五键登记（契约字面 schema）
  jq -n --arg id "$1" --argjson ep "$2" --argjson pm "$3" \
    '{kind:"mail",card_id:$id,batch_file:"/tmp/batch-mail-fixture.json",created_epoch:$ep,pending_max_id:$pm}' \
    > "$SB_ROOT/contrib-data/kanban-flight-mail.json"
}

seed_card_store() { # <status>：在飞查询前置态（卡库 1 张 t_old 卡）
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" \
    > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

cursor_last_id() { jq -r '.last_id // 0' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null || echo "?"; }
pending_count() { jq 'length' "$SB_ROOT/contrib-data/mail-pending.json" 2>/dev/null || echo "?"; }
flight_mail_card() { jq -r '.card_id // ""' "$SB_ROOT/contrib-data/kanban-flight-mail.json" 2>/dev/null || echo ""; }
flight_mail_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]; }
flight_mail_keys() { jq -r 'keys | join(",")' "$SB_ROOT/contrib-data/kanban-flight-mail.json" 2>/dev/null || echo "?"; }

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls_kind() { hermes_lines | grep 'kanban create' | grep -c -- "--idempotency-key $1-" || true; }
claude_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c -- "$1" || true; }

mail_body_file() { # 建 mail 卡的 --body 副本（hermes stub 落 bodies/hermes-<n>.txt）
  grep -l "mail-pending.json" "$SB_ROOT"/stublog/bodies/hermes-*.txt 2>/dev/null | head -1
}

ev_key_count() { # <key 后缀>：events.jsonl 中 endswith 该后缀的条数（日期段不钉死）
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

qcon_open() { # 未来 epoch → quota_circuit check exit 1（QC_OPEN=1）
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SB_ROOT/contrib-data/.quota-circuit"
}

HOUR=14 # 默认非 08 时段（radar 分支静默，mail 段聚焦）；按用例覆盖
GHF=""
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  install_fake_date
  mk_issues "$SB_ROOT/tmp/issues.json"
  seed_scan_cursor
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}

run_watch() { sb_run -e "$GHF" -e "STUB_DATE_HOUR=$HOUR" "$@"; }

ge1() { # <n> <label>：≥1 硬断言（行为断言不受调用次数细节影响）
  case "${1:-}" in
    ''|*[!0-9]*) _fail "$2" "非数值 [$1]" ;;
    *) [ "$1" -ge 1 ] && _pass "$2" || _fail "$2" "实得 $1 < 1" ;;
  esac
}

# =============================================================================
t_case "M1 mrc==10 无登记 → 建 mail 卡：契约参数+body 四要素、flight-mail 五键快照、cursor 本轮不动"
common_setup
seed_mail_cursor
seed_mail_pending 101
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M1 run-watch exit"
assert_eq "$(create_calls_kind mail)" "1" "M1 恰 1 次 mail 建卡（idempotency-key mail- 前缀）"
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M1 建卡成功 → 零 claude mail fallback"
SPAN="$(hermes_lines | grep 'kanban create' | grep -- '--idempotency-key mail-')"
assert_contains "$SPAN" "--assignee contrib" "M1 建卡经 kanban_card 契约参数（--assignee contrib）"
assert_contains "$SPAN" "--json" "M1 建卡带 --json（解析卡 id 契约）"
assert_contains "$SPAN" "--max-retries 2" "M1 建卡带 --max-retries 2"
assert_not_contains "$SPAN" "subscribe" "M1 零订阅：mail 卡 create argv 禁 subscribe（终态零推送）"
BODYF="$(mail_body_file)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  _pass "M1 卡 body 副本已捕获"
  assert_file_contains "$BODYF" "$SB_ROOT/contrib-data/mail-pending.json" "M1 body 含 mail-pending.json 绝对路径"
  assert_file_contains "$BODYF" "SKILL.md" "M1 body 含 SKILL.md 模式五权威路径"
  assert_file_contains "$BODYF" "himalaya" "M1 body 含禁碰 himalaya 红线"
  assert_file_contains "$BODYF" "commit-cursor" "M1 body 明示不自行 commit-cursor（游标推进归 run-watch）"
  assert_file_contains "$BODYF" "kanban_complete" "M1 body 含收尾双传要求（kanban_complete）"
else
  _fail "M1 卡 body 副本已捕获" "bodies/hermes-*.txt 无 mail-pending 载荷（body 未进建卡 argv？）"
fi
flight_mail_exists && _pass "M1 flight-mail 登记存在" || _fail "M1 flight-mail 登记存在" "建卡成功应写 kanban-flight-mail.json（per-kind 新路径）"
assert_eq "$(flight_mail_keys)" "batch_file,card_id,created_epoch,kind,pending_max_id" "M1 登记五键精确键集（pending_max_id 仅 mail 携带）"
assert_eq "$(jq -r '.kind' "$SB_ROOT/contrib-data/kanban-flight-mail.json")" "mail" "M1 登记 kind=mail"
assert_eq "$(jq -r '.pending_max_id' "$SB_ROOT/contrib-data/kanban-flight-mail.json")" "101" "M1 快照 pending_max_id=当前 pending 最大 id（mail_gate 同源 jq 口径）"
assert_eq "$(jq -r '.created_epoch | type' "$SB_ROOT/contrib-data/kanban-flight-mail.json")" "number" "M1 created_epoch 数值"
assert_eq "$(cursor_last_id)" "100" "M1 cursor 本轮不动（异步推进：建卡≠commit）"
assert_eq "$(pending_count)" "1" "M1 pending 保留（commit-cursor 清空未发生 = 零 commit 旁证）"
assert_eq "$(ev_key_count -mail-card-fallback)" "0" "M1 零 card-fallback 事件"
assert_eq "$(ev_key_count -mail-fallback-skipped)" "0" "M1 零 fallback-skipped 事件"
assert_eq "$(notify_approvals)" "0" "M1 notify-state approvals 零新增（零订阅隔离）"
sb_cleanup

# =============================================================================
t_case "M2 在飞（running 未超时）→ 本轮跳过：零建卡/零 fallback/零 commit/登记保留"
common_setup
seed_mail_cursor
seed_mail_pending 101
seed_flight_mail "t_old" "$(date +%s)" 101
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M2 run-watch exit"
assert_eq "$(create_calls_kind mail)" "0" "M2 同 kind 单飞 → 不建第二张卡（契约 5）"
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M2 在飞 → 不触发 fallback"
assert_eq "$(cursor_last_id)" "100" "M2 在飞零 commit"
assert_eq "$(pending_count)" "1" "M2 pending 保留自然重研判"
assert_eq "$(flight_mail_card)" "t_old" "M2 登记保留"
assert_eq "$(ev_key_count -mail-card-fallback)" "0" "M2 正常在飞零告警"
sb_cleanup

# =============================================================================
t_case "M3 卡 done+pending 无增长 → 先 commit-cursor 成功（cursor 100→101+pending 清空）后清登记"
common_setup
seed_mail_cursor
seed_mail_pending 101
seed_flight_mail "t_old" "$(date +%s)" 101
seed_card_store "done"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M3 run-watch exit"
assert_eq "$(cursor_last_id)" "101" "M3 commit-cursor 被调：游标拨到快照 max id 101"
assert_eq "$(pending_count)" "0" "M3 commit-cursor 消费闭环：pending 清空"
if flight_mail_exists; then
  _fail "M3 登记已清" "done 收尾后 kanban-flight-mail.json 仍在（清登记缺失 → 下轮锁死在飞态）"
else
  _pass "M3 登记已清"
fi
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M3 done 路不触发 fallback"
assert_eq "$(create_calls_kind mail)" "0" "M3 done 路不建新卡（快照一致即闭环）"
assert_eq "$(ev_key_count -mail-card-fallback)" "0" "M3 零 fallback 事件"
sb_cleanup

# =============================================================================
t_case "M4 卡 done+pending 有增长（102>快照 101）→ 零 commit 只清登记（飞行窗口新邮件绝不静默消费）"
common_setup
seed_mail_cursor
seed_mail_pending 101 102
seed_flight_mail "t_old" "$(date +%s)" 101
seed_card_store "done"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M4 run-watch exit"
assert_eq "$(cursor_last_id)" "100" "M4 快照守卫：pending 有增长 → 零 commit（cursor 不动）"
assert_eq "$(pending_count)" "2" "M4 pending 残留驱动下轮新卡（不被静默消费）"
if flight_mail_exists; then
  _fail "M4 登记已清" "快照失配分支仍留 kanban-flight-mail.json"
else
  _pass "M4 登记已清"
fi
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M4 快照失配非失败 → 零 fallback"
assert_eq "$(ev_key_count -mail-card-fallback)" "0" "M4 零 card-fallback 事件"
sb_cleanup

# =============================================================================
t_case "M5 blocked+outcome=gave_up（闭集失败终态）→ 清登记+fallback claude 成功→旧同步语义 commit"
common_setup
seed_mail_cursor
seed_mail_pending 101
seed_flight_mail "t_old" "$(date +%s)" 101
seed_card_store "blocked"
run_watch -e STUB_KANBAN_RUN_OUTCOME=gave_up 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M5 run-watch exit"
assert_eq "$(create_calls_kind mail)" "0" "M5 失败终态不建新卡"
ge1 "$(claude_calls 'contrib-watch mail')" "M5 fallback claude -p '/contrib-watch mail' 被调"
assert_eq "$(cursor_last_id)" "101" "M5 兜底研判成功 → 旧同步语义 commit-cursor（契约分支②）"
assert_eq "$(pending_count)" "0" "M5 兜底成功 → pending 消费闭环"
if flight_mail_exists; then
  _fail "M5 登记已清" "失败终态后 kanban-flight-mail.json 仍在"
else
  _pass "M5 登记已清"
fi
assert_eq "$(ev_key_count -mail-card-fallback)" "1" "M5 -mail-card-fallback 恰 1（与 scan card_fallback 对称）"
sb_cleanup

# =============================================================================
t_case "M6 blocked+outcome 非闭集（agent_error）→ 非失败终态 → 本轮跳过（登记保留零 fallback）"
common_setup
seed_mail_cursor
seed_mail_pending 101
seed_flight_mail "t_old" "$(date +%s)" 101
seed_card_store "blocked"
run_watch -e STUB_KANBAN_RUN_OUTCOME=agent_error 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M6 run-watch exit"
assert_eq "$(create_calls_kind mail)" "0" "M6 不建新卡"
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M6 非重试耗尽 → 不 fallback（outcome 闭集锚定）"
assert_eq "$(flight_mail_card)" "t_old" "M6 登记保留"
assert_eq "$(cursor_last_id)" "100" "M6 零 commit"
assert_eq "$(ev_key_count -mail-card-fallback)" "0" "M6 零告警"
sb_cleanup

# =============================================================================
t_case "M7 建卡失败（hermes down）→ fallback claude+事件+兜底成功后 commit-cursor（旧同步语义保留）"
common_setup
seed_mail_cursor
seed_mail_pending 101
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M7 run-watch exit"
case "$(create_calls_kind mail)" in
  0) _fail "M7 前置自证" "mail create 零调用——注毒未生效，本用例空转" ;;
  *) _pass "M7 前置自证：mail 建卡确实被尝试后失败" ;;
esac
ge1 "$(claude_calls 'contrib-watch mail')" "M7 建卡失败 → fallback claude 被调"
assert_eq "$(ev_key_count -mail-card-fallback)" "1" "M7 -mail-card-fallback 恰 1（建卡失败分支 emit）"
if flight_mail_exists; then
  _fail "M7 失败不写登记" "建卡失败仍留 kanban-flight-mail.json（下轮锁死在飞态）"
else
  _pass "M7 失败不写登记"
fi
assert_eq "$(cursor_last_id)" "101" "M7 兜底成功 → commit-cursor（fallback 同步语义兜底保留）"
assert_eq "$(pending_count)" "0" "M7 兜底成功 → pending 闭环"
assert_eq "$(claude_calls 'contrib-watch scan')" "0" "M7 mail 故障不殃及 scan 路"
sb_cleanup

# =============================================================================
t_case "M8a QC 开 → mail 建卡照常发起（卡路不受 QC 限，T2 顺延分支删除）"
common_setup
seed_mail_cursor
seed_mail_pending 101
qcon_open
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M8a run-watch exit"
case "$(create_calls_kind mail)" in
  0) _fail "M8a QC 开建卡" "断路器开闸下 mail kanban create 零调用（顺延分支复活 = 突变）" ;;
  *) _pass "M8a QC 开 → mail 建卡照常发起" ;;
esac
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M8a 建卡路零 claude"
assert_eq "$(ev_key_count -mail-fallback-skipped)" "0" "M8a 建卡成功无需兜底 → 零 skipped 事件"
assert_eq "$(cursor_last_id)" "100" "M8a cursor 本轮不动"
sb_cleanup

t_case "M8b QC 开+建卡失败 → fallback 内 QC gate：零 claude + -mail-fallback-skipped 恰 1 + cursor 不动"
common_setup
seed_mail_cursor
seed_mail_pending 101
qcon_open
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M8b run-watch exit"
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M8b QC 开 → fallback 跳过 claude（gate 收窄钉死点）"
assert_eq "$(ev_key_count -mail-fallback-skipped)" "1" "M8b -mail-fallback-skipped 恰 1"
assert_eq "$(ev_key_count -mail-card-fallback)" "1" "M8b -mail-card-fallback 仍 emit（建卡失败分支先于 QC gate）"
assert_eq "$(cursor_last_id)" "100" "M8b claude 未跑 → 零 commit"
assert_eq "$(pending_count)" "1" "M8b pending 保留下轮"
sb_cleanup

# =============================================================================
t_case "M9 非终态超 6h（STALE_SECS=21600 陈旧守卫）→ 清登记+fallback+事件"
common_setup
seed_mail_cursor
seed_mail_pending 101
seed_flight_mail "t_old" "$(( $(date +%s) - 21605 ))" 101
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M9 run-watch exit"
assert_eq "$(create_calls_kind mail)" "0" "M9 陈旧在飞不建新卡"
ge1 "$(claude_calls 'contrib-watch mail')" "M9 陈旧守卫触发 fallback claude"
if flight_mail_exists; then
  _fail "M9 登记已清" "陈旧 flight 未清（停摆放大）"
else
  _pass "M9 登记已清"
fi
assert_eq "$(cursor_last_id)" "101" "M9 兜底成功 → commit-cursor"
assert_eq "$(ev_key_count -mail-card-fallback)" "1" "M9 -mail-card-fallback 恰 1"
sb_cleanup

# =============================================================================
t_case "M10 mrc==0（无 pending）→ 零 mail 动作（常规扫描语义回归）"
common_setup
seed_mail_cursor
printf '[]\n' > "$SB_ROOT/contrib-data/mail-pending.json"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M10 run-watch exit"
assert_eq "$(create_calls_kind mail)" "0" "M10 无 pending 不建卡"
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M10 无 pending 不研判"
if [ -e "$SB_ROOT/contrib-data/kanban-flight-mail.json" ]; then
  _fail "M10 零登记" "无 pending 却产出 mail 登记"
else
  _pass "M10 零登记"
fi
assert_eq "$(cursor_last_id)" "100" "M10 零 commit"
assert_eq "$(ev_key_count -mail-card-fallback)" "0" "M10 零告警"
sb_cleanup

# =============================================================================
t_case "M11 在飞期间人工 --drain（mrc==0 探测不到）→ 零建卡（终态检查不挪出 mrc==10 门，设计注 I5）"
common_setup
seed_mail_cursor
printf '[]\n' > "$SB_ROOT/contrib-data/mail-pending.json"
seed_flight_mail "t_old" "$(date +%s)" 101
seed_card_store "running"
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "M11 run-watch exit"
assert_eq "$(create_calls_kind mail)" "0" "M11 mrc==0 严禁建第二张 mail 卡（突变靶：终态检查挪出 mrc==10 门）"
assert_eq "$(claude_calls 'contrib-watch mail')" "0" "M11 零 fallback"
assert_eq "$(flight_mail_card)" "t_old" "M11 登记保留（等 6h stale 兜底自愈）"
assert_eq "$(cursor_last_id)" "100" "M11 零 commit"
sb_cleanup

t_finish
