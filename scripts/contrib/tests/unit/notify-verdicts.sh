#!/bin/bash
# notify-verdicts.sh — Tier U：判决落账三态（09-17 改动 2：判决权统一交判断层）
# 覆盖：cmd_event 新建行无 route 预写（契约 P11）/ _verdicts_expand 点名+未点名 push 兜底+
#   批外 key 忽略 / _apply_verdicts push·brief·suppress 三形态落账（C3 值域闭集：
#   push=pushed+pushed_at+route；brief=复用 _flush_brief_mark+当日简报成行；
#   suppress=pushed+route+route_reason 且**无 pushed_at**=显式终态非裸 pushed:false）/
#   sent_bool=false 零动作守卫。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "notify-verdicts.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
TODAY="$(date +%F)"

nf_fn() { # nf_fn <表达式> — 子进程 source notify.sh 后求值（NOTIFY_SOURCE_ONLY=1 不触发 main）
  sb_run -e "NOTIFY_SOURCE_ONLY=1" "source \"\$MARTIN_DIR/scripts/contrib/notify.sh\" >/dev/null 2>&1
$1"
}

mk_batch() { # mk_batch <name> — 从账本捞未推 contrib 行为批次文件（同 flush 口径），回显路径
  sb_run "jq -c 'select(.pushed == false and (.channel // \"contrib\") == \"contrib\")' \"\$CONTRIB_DATA_DIR/events.jsonl\" > \"\$CONTRIB_DATA_DIR/$1\""
  printf '%s' "$SB_ROOT/contrib-data/$1"
}

led() { # led <key> <字段> → 值（首个命中行；字段缺失 → 空串）
  jq -r -s --arg k "$1" --arg f "$2" '[.[] | select(.key == $k)][0] | if has($f) and (.[$f] != null) then (.[$f] | tostring) else "" end' "$EVENTS_FILE" 2>/dev/null
}

t_case "cmd_event：新建事件行无 route 字段（判决在 flush 判决时发生，不预写路由）"
sb_notify event own-pr-info --key v-new --summary "新契约锚" >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "v-new") | has("route")' "$EVENTS_FILE")" "false" "route 字段不存在"

t_case "_verdicts_expand：点名两 key + 未点名 push 兜底 + 批外 key 忽略"
sb_notify event own-pr-activity --key v-a --summary "A" >/dev/null
sb_notify event probe-premise-dead --key v-b --summary "B" >/dev/null
sb_notify event mail-needs-user --key v-c --summary "C" >/dev/null
sb_run "jq -n '[{key: \"v-a\", route: \"brief\", reason: \"留痕\"}, {key: \"v-b\", route: \"suppress\", reason: \"已自愈\"}, {key: \"ghost\", route: \"suppress\", reason: \"批外\"}]' > \"\$CONTRIB_DATA_DIR/v-verdicts.json\""
mk_batch v-batch.jsonl >/dev/null
out="$(nf_fn '_verdicts_expand "$CONTRIB_DATA_DIR/v-verdicts.json" "$CONTRIB_DATA_DIR/v-batch.jsonl"' | sort)"
assert_contains "$out" "$(printf 'v-a\tbrief\t留痕')" "点名 v-a → brief"
assert_contains "$out" "$(printf 'v-b\tsuppress\t已自愈')" "点名 v-b → suppress"
assert_contains "$out" "$(printf 'v-c\tpush\t')" "未点名 v-c → push 兜底（D1 缺席语义）"
assert_eq "$(printf '%s\n' "$out" | grep -c 'ghost')" "0" "批外 key ghost 忽略（无落账面）"

t_case "_apply_verdicts：缺席 verdicts → 全批 push（pushed=true + pushed_at + route 闭集回填）"
nf_fn '_apply_verdicts "" "$CONTRIB_DATA_DIR/v-batch.jsonl" contrib true' >/dev/null
assert_eq "$(led v-a route)" "push" "v-a route=push（兜底）"
assert_eq "$(led v-a pushed)" "true" "v-a pushed=true"
assert_eq "$(led v-b route)" "push" "v-b route=push（点名被缺席覆盖——本次调用未传 verdicts）"
assert_ne "$(led v-a pushed_at)" "" "pushed_at 落值"

t_case "_apply_verdicts：suppress = 显式终态（pushed=true + route + route_reason，无 pushed_at）"
sb_notify event agc-crash-spike --key v-s --summary "S" --channel contrib >/dev/null
mk_batch v-batch2.jsonl >/dev/null
sb_run "jq -n '[{key: \"v-s\", route: \"suppress\", reason: \"已自愈闭环\"}]' > \"\$CONTRIB_DATA_DIR/v-vs.json\""
nf_fn '_apply_verdicts "$CONTRIB_DATA_DIR/v-vs.json" "$CONTRIB_DATA_DIR/v-batch2.jsonl" contrib true' >/dev/null
assert_eq "$(led v-s pushed)" "true" "suppress 行 pushed=true（出队）"
assert_eq "$(led v-s route)" "suppress" "route=suppress"
assert_eq "$(led v-s route_reason)" "已自愈闭环" "route_reason 落判决理由"
assert_eq "$(jq -r 'select(.key == "v-s") | has("pushed_at")' "$EVENTS_FILE")" "false" "无 pushed_at 字段（has() 语义；未推送的诚实信号；禁裸 pushed:false 充当终态）"

t_case "_apply_verdicts：brief = 复用 _flush_brief_mark（route=brief + 当日简报机械小节成行）"
sb_notify event own-pr-info --key v-br --summary "进简报留痕" >/dev/null
mk_batch v-batch3.jsonl >/dev/null
sb_run "jq -n '[{key: \"v-br\", route: \"brief\"}]' > \"\$CONTRIB_DATA_DIR/v-vbr.json\""
nf_fn '_apply_verdicts "$CONTRIB_DATA_DIR/v-vbr.json" "$CONTRIB_DATA_DIR/v-batch3.jsonl" contrib true' >/dev/null
assert_eq "$(led v-br route)" "brief" "route=brief"
assert_eq "$(led v-br pushed)" "true" "brief 行 pushed=true"
BRIEF_FILE="$SB_ROOT/contrib-data/briefs/$TODAY.md"
[[ -f "$BRIEF_FILE" ]] && _pass "当日简报文件已建" || _fail "当日简报文件已建" "缺失 $BRIEF_FILE"
assert_file_contains "$BRIEF_FILE" "## 简报队列（机械落账）" "固定小节头"
assert_file_contains "$BRIEF_FILE" "\`v-br\`" "记录行含 key（复用 _brief_append_record）"

t_case "_apply_verdicts：suppress 缺 reason → 落账层补「（未附理由）」"
sb_notify event scan-hit --key v-nr --summary "无理由判决" >/dev/null
mk_batch v-batch4.jsonl >/dev/null
sb_run "jq -n '[{key: \"v-nr\", route: \"suppress\"}]' > \"\$CONTRIB_DATA_DIR/v-vnr.json\""
nf_fn '_apply_verdicts "$CONTRIB_DATA_DIR/v-vnr.json" "$CONTRIB_DATA_DIR/v-batch4.jsonl" contrib true' >/dev/null
assert_eq "$(led v-nr route_reason)" "（未附理由）" "缺省理由占位（不空串）"

t_case "_apply_verdicts：sent_bool 非 true → 零动作（只有真实送达才落终态）"
sb_notify event own-pr-activity --key v-guard --summary "守卫用例" >/dev/null
mk_batch v-batch5.jsonl >/dev/null
nf_fn '_apply_verdicts "" "$CONTRIB_DATA_DIR/v-batch5.jsonl" contrib false' >/dev/null
assert_eq "$(led v-guard pushed)" "false" "sent=false → 不标 pushed"
assert_eq "$(led v-guard route)" "" "sent=false → 无 route"

t_case "send-digest --verdicts schema 校验：非法 → FAIL bad-verdicts 且账本零动作"
sb_notify event own-pr-activity --key v-bad --summary "schema 守卫" >/dev/null
DIGEST_BAD="$SB_ROOT/contrib-data/v-digest.md"
printf '🟠【contrib 告警】%s\n\n实质内容行。\n' "$TODAY" >"$DIGEST_BAD"
mk_batch v-batch6.jsonl >/dev/null
sb_run "jq -n '[{key: \"v-bad\", route: \"unheard-route\"}]' > \"\$CONTRIB_DATA_DIR/v-vbad.json\""
before_pushed="$(jq -s '[.[] | select(.pushed == true)] | length' "$EVENTS_FILE")"
BATCH6="$(mk_batch v-batch6.jsonl)"
out="$(sb_notify send-digest --digest "$DIGEST_BAD" --batch "$BATCH6" --verdicts "$SB_ROOT/contrib-data/v-vbad.json")"
assert_exit 1 $?
assert_eq "$out" "FAIL bad-verdicts" "stdout 闭集 FAIL bad-verdicts"
assert_eq "$(jq -s '[.[] | select(.pushed == true)] | length' "$EVENTS_FILE")" "$before_pushed" "账本零 pushed 动作（校验先于副作用）"

t_case "send-digest --verdicts suppress：单 key 判不推 → 账本显式终态、零裸 pushed:false"
sb_notify event probe-premise-dead --key v-sd --summary "判决路单点" >/dev/null
mk_batch v-batch7.jsonl >/dev/null
sb_run "jq -n '[{key: \"v-sd\", route: \"suppress\", reason: \"设计驻停无决策点\"}]' > \"\$CONTRIB_DATA_DIR/v-vsd.json\""
BATCH7="$(mk_batch v-batch7.jsonl)"
out="$(sb_notify send-digest --digest "$DIGEST_BAD" --batch "$BATCH7" --verdicts "$SB_ROOT/contrib-data/v-vsd.json")"
assert_exit 0 $?
assert_eq "$out" "OK" "suppress 全批仍 OK（摘要为免推行说明）"
assert_eq "$(led v-sd route)" "suppress" "route=suppress（经唯一外发通道落账）"
assert_eq "$(led v-sd pushed_at)" "" "无 pushed_at"

sb_cleanup
t_finish
