#!/bin/bash
# notify-digest-cardify.sh — Tier U：notify.sh digest 卡化（T5）
# 覆盖：
#   ① send-digest 子命令：happy path（发送+账本标记+sent:true 回写）/ 幂等快路（sent:true 已存在
#     → OK 零副作用）/ 限额拒发 / dry-run（sent:false reason=dry-run + exit 0）/ 发送失败回写 /
#     空卡守卫 / 锁超时 FAIL lock-timeout（自包带超时锁）
#   ② flush 叙事批异步化：建卡（flight 四键+幂等键 digest-<日期>-<md5 前 8>+body 红线）/
#     在飞挂账 attempts 不增 / done+sent:true 消费零账本动作且本轮不建新卡（双写禁止+防卡风暴）/
#     done+sent:false 异常收口 fallback / blocked fallback / stale（DIGEST_STALE_SECS 注入）fallback /
#     notify_digest=false 旧语义 / 建卡失败 fallback / 机械路径回归（模板卡零 LLM 不变）
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN/CLAUDE_BIN stub 沙箱隔离，零真实 hermes/claude/微信调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "notify-digest-cardify.sh"

TODAY="$(date +%F)"

# ---- 通用工具 ----
count_send() { # hermes send 调用次数（calls.log 行形如 hermes|cwd|send --to ...）
  [[ -f "$CONTRIB_TEST_STUB_LOG/calls.log" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_create() {
  [[ -f "$CONTRIB_TEST_STUB_LOG/calls.log" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "hermes" && index($0, "kanban create") { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_claude() {
  [[ -f "$CONTRIB_TEST_STUB_LOG/calls.log" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "claude" { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
last_create_line() {
  awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
pushed_count() { # events.jsonl 中 pushed==true 行数
  jq -s '[.[] | select(.pushed == true)] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}
batch_sent_field() { # <batch_file> → true|false（显式 sent:true 控制行）
  local n
  n="$(jq -s '[.[] | select(.sent == true)] | length' "$1" 2>/dev/null || echo 0)"
  [[ "${n:-0}" -ge 1 ]] && printf 'true' || printf 'false'
}
batch_reason() { # <batch_file> → 末个控制行 reason（无=空）
  jq -rs '[.[] | select(has("sent"))] | last | .reason // empty' "$1" 2>/dev/null || true
}

# ---- 种子工具 ----
seed_card_store() { # <card_id> <status> — 在飞查询前置态
  printf '{"id":"%s","status":"%s","assignee":"contrib","priority":0}\n' "$1" "$2" \
    >"$SB_ROOT/stublog/kanban-cards.jsonl"
}
seed_flight_digest() { # <card_id> <status> <epoch> <snapshot_path|>
  jq -n --arg kind digest --arg id "$1" --arg bf "${4:-}" --argjson e "$3" \
    '{kind: $kind, card_id: $id, batch_file: $bf, created_epoch: $e}' \
    >"$SB_ROOT/contrib-data/kanban-flight-digest.json"
  seed_card_store "$1" "$2"
}
make_batch() { # <path> <key...> — 从 events.jsonl 按未推 contrib 过滤出批次文件（同 flush 口径）
  jq -c 'select(.pushed == false and (.channel // "contrib") == "contrib")' \
    "$SB_ROOT/contrib-data/events.jsonl" >"$1" 2>/dev/null
}
make_digest() { # <path> — 合法摘要文件（报头+实质行）
  { printf '🟠【contrib 告警】%s\n\n' "$(date +%m-%d)"
    printf 'scan 研判 claude -p 失败 exit=1，已挂账下轮重试；无需动作。\n'
  } >"$1"
}

# ================= ① send-digest 子命令 =================

t_case "send-digest: happy path → OK exit0 + 账本 pushed + sent:true 回写（含 send_result 佐证）"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key sd-1 --summary "叙事事件 A" >/dev/null
BATCH="$SB_ROOT/contrib-data/pending/digest-test.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-test.digest.md"
mkdir -p "$SB_ROOT/contrib-data/pending"
make_batch "$BATCH"
make_digest "$DIGEST"
out="$(sb_notify send-digest --digest "$DIGEST" --batch "$BATCH")"
assert_exit 0 $?
assert_eq "$out" "OK" "stdout 闭集 OK"
assert_eq "$(batch_sent_field "$BATCH")" "true" "批次回写 sent:true"
assert_eq "$(jq -s '[.[] | select(has("sent"))][0].send_result.success // false' "$BATCH" 2>/dev/null)" "true" "send_result 佐证落行"
assert_eq "$(jq -r 'select(.key == "sd-1") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "true" "账本标记 pushed"
assert_not_contains "$(jq -r 'select(.key == "sd-1") | .pushed_at' "$SB_ROOT/contrib-data/events.jsonl")" "null" "pushed_at 落值"
assert_eq "$(jq -r --arg d "$TODAY" '.alerts[$d] // 0' "$SB_ROOT/contrib-data/notify-state.json")" "1" "state_bump alerts"
assert_eq "$(count_send)" "1" "hermes send 恰一次"

t_case "send-digest: 幂等快路（批次已 sent:true）→ OK exit0 零副作用（零 send 零账本动作）"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key sd-idem --summary "幂等快路" >/dev/null
BATCH="$SB_ROOT/contrib-data/pending/digest-idem.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-idem.digest.md"
make_batch "$BATCH"
make_digest "$DIGEST"
printf '%s\n' '{"sent":true,"reason":null,"sent_at":"t","send_result":{"success":true}}' >>"$BATCH"
before_pushed="$(pushed_count)"
out="$(sb_notify send-digest --digest "$DIGEST" --batch "$BATCH")"
assert_exit 0 $?
assert_eq "$out" "OK" "幂等快路 stdout OK"
assert_eq "$(count_send)" "0" "零 hermes send（防 worker 重试双发）"
assert_eq "$(pushed_count)" "$before_pushed" "零账本动作"

t_case "send-digest: 限额满 → FAIL limit exit1 + sent:false reason=limit + 拒发"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key sd-limit --summary "限额用例" >/dev/null
BATCH="$SB_ROOT/contrib-data/pending/digest-limit.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-limit.digest.md"
make_batch "$BATCH"
make_digest "$DIGEST"
sb_state_set ".alerts[\"$TODAY\"] = 3"
out="$(sb_notify send-digest --digest "$DIGEST" --batch "$BATCH")"
assert_exit 1 $?
assert_eq "$out" "FAIL limit" "stdout 闭集 FAIL limit"
assert_eq "$(batch_sent_field "$BATCH")" "false" "sent:false"
assert_eq "$(batch_reason "$BATCH")" "limit" "reason=limit"
assert_eq "$(count_send)" "0" "拒发零 send"
assert_eq "$(jq -r 'select(.key == "sd-limit") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "false" "不标 pushed"

t_case "send-digest: dry_run=true → exit0 OK + sent:false reason=dry-run + 打印消息体 + 零真实 send"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key sd-dry --summary "dry-run 用例" >/dev/null
BATCH="$SB_ROOT/contrib-data/pending/digest-dry.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-dry.digest.md"
make_batch "$BATCH"
make_digest "$DIGEST"
out="$(sb_run -e "NOTIFY_DRY_RUN=true" \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIGEST' --batch '$BATCH'")"
assert_exit 0 $?
assert_eq "$(printf '%s' "$out" | tail -1)" "OK" "末行 OK（worker 据 OK normal-complete）"
assert_contains "$out" "[dry-run]" "完整消息体与目标打印（同 _send 语义）"
assert_eq "$(batch_sent_field "$BATCH")" "false" "sent:false"
assert_eq "$(batch_reason "$BATCH")" "dry-run" "reason=dry-run"
assert_eq "$(count_send)" "0" "零真实 send"

t_case "send-digest: 发送失败 → FAIL send exit1 + sent:false reason=send（attempts 不动，留 flush fallback 路）"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key sd-fail --summary "发送失败用例" >/dev/null
BATCH="$SB_ROOT/contrib-data/pending/digest-fail.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-fail.digest.md"
make_batch "$BATCH"
make_digest "$DIGEST"
out="$(sb_run -e "STUB_HERMES_FAIL=1" \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIGEST' --batch '$BATCH'")"
assert_exit 1 $?
assert_eq "$out" "FAIL send" "stdout 闭集 FAIL send"
assert_eq "$(batch_sent_field "$BATCH")" "false" "sent:false"
assert_eq "$(batch_reason "$BATCH")" "send" "reason=send"
assert_eq "$(jq -r 'select(.key == "sd-fail") | .attempts' "$SB_ROOT/contrib-data/events.jsonl")" "0" "attempts 不计（防卡重试×flush 重试双计数）"

t_case "send-digest: B-2 佐证新鲜度守卫——_send_result_fresh（陈旧/缺失 → 空佐证，新鲜 → 放行）"
sb_new >/dev/null 2>&1
# 集成路无法构造真陈旧（stub 失败也会经 > 重写 NOTIFY_SEND_LAST）——直测守卫函数：
# source 模式（NOTIFY_SOURCE_ONLY=1，notify.sh 既有 source guard）只装载纯函数
out="$(sb_run '
NOTIFY_SOURCE_ONLY=1
source "$MARTIN_DIR/scripts/contrib/notify.sh" >/dev/null 2>&1
started="$(date +%s)"
r1="$(_send_result_fresh "$started")"
printf "{\"success\":true,\"id\":\"leftover\"}\n" >"$NOTIFY_SEND_LAST"
touch -t 202001010000 "$NOTIFY_SEND_LAST"
r2="$(_send_result_fresh "$started")"
touch "$NOTIFY_SEND_LAST"
r3="$(_send_result_fresh "$started")"
printf "r1=[%s]|r2=[%s]|r3=[%s]" "$r1" "$r2" "$r3"
')"
assert_contains "$out" "r1=[]" "文件缺失 → 空佐证"
assert_contains "$out" "r2=[]" "陈旧残留（mtime < 调用起点）→ 空佐证（不得冒充本次 send_result）"
assert_contains "$out" "r3=[$NOTIFY_SEND_LAST" "本次新鲜回写 → 放行佐证"

t_case "send-digest: 空卡守卫 → FAIL empty-card exit1 + sent:false reason=empty-card"
sb_new >/dev/null 2>&1
BATCH="$SB_ROOT/contrib-data/pending/digest-empty.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-empty.digest.md"
printf '🟠【contrib 告警】09-09\n\n（明细: contrib-data/events.jsonl）\n' >"$DIGEST"
printf '%s\n' '{"ts":"t","class":"pipeline-failure","key":"sd-empty","channel":"contrib","summary":"s","pushed":false,"attempts":0,"pushed_at":null}' >"$BATCH"
out="$(sb_notify send-digest --digest "$DIGEST" --batch "$BATCH")"
assert_exit 1 $?
assert_eq "$out" "FAIL empty-card" "stdout 闭集 FAIL empty-card"
assert_eq "$(batch_reason "$BATCH")" "empty-card" "reason=empty-card"
assert_eq "$(count_send)" "0" "零 send"

t_case "send-digest: 锁超时 → FAIL lock-timeout exit1（自包带超时锁，不静默 exit 0）"
sb_new >/dev/null 2>&1
BATCH="$SB_ROOT/contrib-data/pending/digest-lock.json"
DIGEST="$SB_ROOT/contrib-data/pending/digest-lock.digest.md"
make_batch "$BATCH"
make_digest "$DIGEST"
mkdir -p "$NOTIFY_LOCK"   # 占坑模拟他方持锁
out="$(sb_run -e "DIGEST_LOCK_TIMEOUT=1" \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIGEST' --batch '$BATCH'")"
assert_exit 1 $?
assert_eq "$out" "FAIL lock-timeout" "stdout 闭集 FAIL lock-timeout"
assert_eq "$(batch_sent_field "$BATCH")" "false" "未回写 sent:true"
rmdir "$NOTIFY_LOCK" 2>/dev/null || true

# ================= ② flush 叙事批异步化 =================

t_case "flush: 叙事批+无登记 → 建 digest 卡（flight 四键+快照+幂等键格式）+ 挂账 attempts 不增 + 零 claude 零 send"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-1 --summary "叙事事件一" >/dev/null
sb_notify event mail-needs-user --key fl-2 --summary "叙事事件二" >/dev/null
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
DFLIGHT="$SB_ROOT/contrib-data/kanban-flight-digest.json"
assert_eq "$(jq -r '.kind // empty' "$DFLIGHT" 2>/dev/null)" "digest" "flight kind=digest"
case "$(jq -r '.card_id // empty' "$DFLIGHT" 2>/dev/null)" in t_stub_*) _pass "flight card_id 登记" ;; *) _fail "flight card_id 登记" "缺" ;; esac
SNAP="$(jq -r '.batch_file // empty' "$DFLIGHT" 2>/dev/null)"
[[ -n "$SNAP" && -f "$SNAP" ]] && _pass "batch_file=快照路径且落盘" || _fail "batch_file=快照路径且落盘" "actual=$SNAP"
assert_eq "$(jq -r '.created_epoch > 0' "$DFLIGHT" 2>/dev/null)" "true" "created_epoch"
assert_eq "$(jq -rS 'keys | join(",")' "$DFLIGHT" 2>/dev/null)" "batch_file,card_id,created_epoch,kind" "flight 恰四键（同 scan 构）"
create_idem="$(sed -n 's/.*--idempotency-key \([a-z0-9-]*\) .*/\1/p' <<<"$(last_create_line)" | tail -1)"
if [[ "$create_idem" =~ ^digest-[0-9]{8}-[0-9a-f]{8}$ ]]; then
  _pass "幂等键 digest-<日期>-<md5 前 8>（实际 ${create_idem}）"
else
  _fail "幂等键 digest-<日期>-<md5 前 8>" "actual=${create_idem}"
fi
assert_eq "$(count_claude)" "0" "主路零 claude"
assert_eq "$(count_send)" "0" "主路零 hermes send（异步化：发送在 worker 卡内）"
assert_eq "$(jq -r 'select(.key == "fl-1") | .attempts' "$SB_ROOT/contrib-data/events.jsonl")" "0" "在飞挂账 attempts 不增"
assert_eq "$(jq -r 'select(.key == "fl-1") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "false" "事件保留未推"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "$SNAP" "卡 body 含快照路径"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" ".digest.md" "卡 body 含摘要输出路径约定"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "三段式" "卡 body 含三段式规范"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "send-digest" "卡 body 含唯一外发通道"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "禁 hermes send 直调" "卡 body 含禁直调红线"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "raw dump" "卡 body 含永不 raw dump 红线"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban_complete" "卡 body 含收尾双传要求"
[[ -n "$body_copy" ]] && assert_not_contains "$(cat "$body_copy")" '"summary":"叙事事件一"' "body 无 raw 事件正文直推"

t_case "flush: 在飞（非终态）→ 本轮跳过（不建新卡/fallback，attempts 不增，登记保留）"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-infly --summary "在飞用例" >/dev/null
seed_flight_digest "t_old" "running" "$(date +%s)" ""
before_create="$(count_create)"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(( $(count_create) - before_create ))" "0" "在飞不建新卡（同 kind 单飞）"
assert_eq "$(count_claude)" "0" "在飞不 fallback"
assert_eq "$(jq -r '.card_id // empty' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)" "t_old" "登记保留"
assert_eq "$(jq -r 'select(.key == "fl-infly") | .attempts' "$SB_ROOT/contrib-data/events.jsonl")" "0" "attempts 不增（在飞非失败）"

t_case "flush: done+sent:true 消费 → 零账本动作（双写禁止）+ 清登记清快照 + 本轮不建新卡（防卡风暴）"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-consume --summary "消费用例" >/dev/null
SNAP="$SB_ROOT/contrib-data/pending/digest-consume.json"
make_batch "$SNAP"
printf '%s\n' '{"sent":true,"reason":null,"sent_at":"t","send_result":{"success":true}}' >>"$SNAP"
printf '🟠 摘要内容\n' >"${SNAP%.json}.digest.md"   # 摘要文件前置态
jq -c 'select(.key == "fl-consume") | .pushed = true' "$SB_ROOT/contrib-data/events.jsonl" >"$SB_ROOT/contrib-data/events.jsonl.tmp" \
  && mv "$SB_ROOT/contrib-data/events.jsonl.tmp" "$SB_ROOT/contrib-data/events.jsonl"   # 模拟 worker 已标记
seed_flight_digest "t_old" "done" "$(date +%s)" "$SNAP"
sb_notify event pipeline-failure --key fl-fresh --summary "消费轮新攒事件" >/dev/null   # 本轮新批
before_pushed="$(pushed_count)"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(pushed_count)" "$before_pushed" "零新增 pushed 标记（账本双写禁止）"
assert_eq "$(count_create)" "0" "消费轮不建新卡（保守单调）"
assert_eq "$(count_send)" "0" "消费轮零发送"
assert_eq "$(count_claude)" "0" "消费轮零 claude"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "登记已清" || _fail "登记已清" "残留"
[[ ! -f "$SNAP" ]] && _pass "快照消费即删" || _fail "快照消费即删" "残留"
[[ ! -f "${SNAP%.json}.digest.md" ]] && _pass "摘要文件消费即删" || _fail "摘要文件消费即删" "残留"
assert_eq "$(jq -r 'select(.key == "fl-fresh") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "false" "新攒事件留待下小时轮（不丢）"

t_case "flush: done 但 sent:false（worker 完成未发送）→ 清登记 + fallback_ai 接管 + 快照清理"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-nosent --summary "异常收口用例" >/dev/null
SNAP="$SB_ROOT/contrib-data/pending/digest-nosent.json"
make_batch "$SNAP"
printf '%s\n' '{"sent":false,"reason":"dry-run","sent_at":"t","send_result":null}' >>"$SNAP"
seed_flight_digest "t_old" "done" "$(date +%s)" "$SNAP"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(count_claude)" "1" "fallback claude 被调"
assert_eq "$(count_send)" "1" "fallback _send 被调"
assert_eq "$(jq -r 'select(.key == "fl-nosent") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "true" "fallback 成功标 pushed"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "登记已清" || _fail "登记已清" "残留"
[[ ! -f "$SNAP" ]] && _pass "快照清理" || _fail "快照清理" "残留"

t_case "flush: blocked 失败终态 → 清登记 + fallback + attempts 递增"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-blocked --summary "失败终态用例" >/dev/null
seed_flight_digest "t_old" "blocked" "$(date +%s)" ""
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(count_claude)" "1" "fallback claude 被调"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "登记已清" || _fail "登记已清" "残留"
assert_eq "$(jq -r 'select(.key == "fl-blocked") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "true" "fallback 成功消费"

t_case "flush: stale（DIGEST_STALE_SECS 注入短值）→ 清登记 + fallback + digest-stale 事件"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-stale --summary "stale 用例" >/dev/null
seed_flight_digest "t_old" "running" "$(( $(date +%s) - 30000 ))" ""
out="$(sb_run -e "NOTIFY_DRY_RUN=false" -e "DIGEST_STALE_SECS=60" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(count_claude)" "1" "stale → fallback"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "陈旧登记已清" || _fail "陈旧登记已清" "残留"
assert_eq "$(jq -s '[.[] | select(((.key // "") | endswith("-digest-stale")))] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null)" "1" "digest-stale 事件入账"

t_case "flush: notify_digest=false → 不建卡直接挂账（旧语义），attempts+1"
sb_new >/dev/null 2>&1
sb_config_set '.notify_digest = false'
sb_notify event pipeline-failure --key fl-nodigest --summary "旧语义用例" >/dev/null
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 1 $?
assert_eq "$(count_create)" "0" "零建卡"
assert_eq "$(count_claude)" "0" "零 claude"
assert_eq "$(jq -r 'select(.key == "fl-nodigest") | .attempts' "$SB_ROOT/contrib-data/events.jsonl")" "1" "attempts+1（挂账）"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "零登记" || _fail "零登记" "残留"

t_case "flush: 建卡失败 → fallback_ai 旧路接管 + 不写登记 + 快照清理"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-createfail --summary "建卡失败用例" >/dev/null
out="$(sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 1 $?
assert_eq "$(count_claude)" "1" "fallback claude 被调"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "失败不写登记" || _fail "失败不写登记" "残留"
assert_eq "$(jq -r 'select(.key == "fl-createfail") | .attempts' "$SB_ROOT/contrib-data/events.jsonl")" "1" "fallback 发送也败 → attempts+1"
assert_eq "$(ls "$SB_ROOT/contrib-data/pending"/digest-*.json 2>/dev/null | wc -l | tr -d ' ')" "0" "快照清理（无残留 digest-*.json）"

t_case "flush: 纯机械批回归 → 模板卡零 LLM 不变（零建卡零 claude，hermes send 恰一次）"
sb_new >/dev/null 2>&1
sb_notify event probe-premise-dead --key fl-mech --summary "radar 2026-09-09 premise 复验：#102413 已被占坑出局" >/dev/null
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(count_create)" "0" "零建卡"
assert_eq "$(count_claude)" "0" "零 claude"
assert_eq "$(count_send)" "1" "hermes send 恰一次（模板卡）"
assert_eq "$(jq -r 'select(.key == "fl-mech") | .pushed' "$SB_ROOT/contrib-data/events.jsonl")" "true" "机械事件标 pushed"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "▪ 候选折损" "模板卡实质行（▪ 开头）"

t_case "flush: 混合批（机械+叙事）→ 整批走 digest 卡（快照含机械事件）"
sb_new >/dev/null 2>&1
sb_notify event own-pr-activity --key fl-mix-m --summary "机械事件" >/dev/null
sb_notify event pipeline-failure --key fl-mix-n --summary "叙事事件" >/dev/null
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(count_create)" "1" "混合批建 digest 卡"
SNAP="$(jq -r '.batch_file // empty' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null)"
[[ -n "$SNAP" ]] && assert_eq "$(jq -s '[.[] | select(.key == "fl-mix-m")] | length' "$SNAP" 2>/dev/null)" "1" "快照含机械事件（整批语义）"
assert_eq "$(count_claude)" "0" "混合批零 claude（主路）"

t_case "send-digest: 全链闭环——flush 建卡 → worker send-digest → 卡 done 消费零账本动作（不丢不重）"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key fl-loop --summary "闭环用例" >/dev/null
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
FLIGHT="$SB_ROOT/contrib-data/kanban-flight-digest.json"
SNAP="$(jq -r '.batch_file // empty' "$FLIGHT" 2>/dev/null)"
CARD_ID="$(jq -r '.card_id // empty' "$FLIGHT" 2>/dev/null)"
[[ -n "$SNAP" && -n "$CARD_ID" ]] && _pass "第一轮建卡+登记" || _fail "第一轮建卡+登记" "缺"
DIGEST="${SNAP%.json}.digest.md"
make_digest "$DIGEST"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIGEST' --batch '$SNAP'")"
assert_exit 0 $?
assert_eq "$out" "OK" "worker send-digest OK"
assert_eq "$(pushed_count)" "1" "worker 已标 pushed"
# 第二轮 flush：卡 done + 批次 sent:true → 消费闭环（回拨时间闸门 + 补一个新叙事事件构造非空批）
printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$CARD_ID" >"$SB_ROOT/stublog/kanban-cards.jsonl"
sb_state_set '.last_flush_epoch = 0'
sb_notify event pipeline-failure --key fl-loop2 --summary "消费轮新攒事件" >/dev/null
before_pushed="$(pushed_count)"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(pushed_count)" "$before_pushed" "消费轮零新增 pushed（不重）"
[[ ! -f "$FLIGHT" ]] && _pass "flight 清" || _fail "flight 清" "残留"
[[ ! -f "$SNAP" ]] && _pass "快照清" || _fail "快照清" "残留"
[[ ! -f "${SNAP%.json}.body.md" ]] && _pass "B-3 卡 body 清" || _fail "B-3 卡 body 清" "残留 ${SNAP%.json}.body.md"
[[ ! -f "${SNAP%.json}.card.json" ]] && _pass "B-3 卡 json 清" || _fail "B-3 卡 json 清" "残留 ${SNAP%.json}.card.json"
[[ ! -f "${SNAP%.json}.digest.md" ]] && _pass "B-3 摘要文件清" || _fail "B-3 摘要文件清" "残留"

sb_cleanup

t_case "B-3 建卡失败即清——digest 建卡失败后 pending/ 零该轮派生残留"
sb_new >/dev/null 2>&1
sb_notify event pipeline-failure --key b3-fail --summary "建卡失败清理用例" >/dev/null
before_bodies="$(ls "$SB_ROOT"/contrib-data/pending/ 2>/dev/null | wc -l | tr -d ' ')"
sb_run -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
after_bodies="$(ls "$SB_ROOT"/contrib-data/pending/ 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$after_bodies" "$before_bodies" "建卡失败 → 派生文件（快照/摘要/body/json）零残留（B-3）"

sb_cleanup
t_finish
