#!/bin/bash
# own-pr-watch.sh — Tier U：own-PR 小时级机械盯梢（own_pr_watch.sh）stub 测试矩阵
# 覆盖：
#   ① 夹具自证：gh stub 既有行为 byte 级保留 + pr list/view 新分支 + date 影子 stub
#      + sb_new 拷贝 date stub + 种子 config own_pr_alert_per_day
#   ② own_pr_watch.sh 行为矩阵：首跑基线 / 外部评论(高级) / 本人评论(静默) / merged/closed
#      终态剪枝 / OPEN 消失保留 / mergeable 已知翻转(低级) / UNKNOWN 静默 / 停滞(低级)
#      / reviewDecision 吸收 / 日级幂等（账本双格式） / 子上限旋钮 / gh 失败断路四态
#      / 快照损坏重建 / exit 2 用法错误 / argv 形态锚 / 原子写自证 / class 精确串 / 红线调用面
#   ③ run-watch.sh 段 2.5 编排集成（zsh 调镜像生产，patterns 09-09 双 shell 二象性）
# 全部经 CONTRIB_DATA_DIR/GH_BIN/date stub 沙箱隔离，零真实 gh/notify 外发。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "own-pr-watch.sh"

WATCH="$CONTRIB_TEST_TARGET/own_pr_watch.sh"
[[ -f "$WATCH" ]] || { echo "FATAL: 找不到 $WATCH"; exit 1; }

D="2026-09-10"   # date stub 冻结日（事件 key 的当日口径）
FRESH_UPD="$(date -u "+%Y-%m-%dT%H:%M:%SZ")"
STALE_UPD="$(date -u -v-20d "+%Y-%m-%dT%H:%M:%SZ")"

DATA=""; SNAPF=""; EVENTS=""; WLOG=""; CALLS=""
new_sb() {
  sb_new >/dev/null 2>&1
  DATA="$SB_ROOT/contrib-data"
  SNAPF="$DATA/own-pr-watch-snapshot.json"
  EVENTS="$DATA/events.jsonl"
  WLOG="$DATA/logs/own-pr-watch.log"
  CALLS="$SB_ROOT/stublog/calls.log"
  mkdir -p "$SB_ROOT/gh-view"
}

# pr_row <number> <updatedAt> <mergeable> <authors-csv> → PR JSON（comments 由作者列表展开）
pr_row() {
  jq -cn --argjson n "$1" --arg upd "$2" --arg m "$3" --arg a "${4:-}" '
    {number: $n, updatedAt: $upd, mergeable: $m, reviewDecision: "",
     comments: ($a | split(",") | map(select(length > 0)) | map({author: {login: .}}))}'
}
row() { pr_row "$@" >>"$SB_ROOT/pr.rows"; }
set_prs() { jq -s . "$SB_ROOT/pr.rows" >"$SB_ROOT/gh-prs.json"; }

# set_view <num> <state> [authors-csv] — pr view 终态/评论核实数据文件
set_view() {
  jq -cn --argjson n "$1" --arg st "$2" --arg a "${3:-}" '
    {number: $n, state: $st,
     comments: ($a | split(",") | map(select(length > 0)) | map({author: {login: .}}))}' \
    >"$SB_ROOT/gh-view/pr-$1.json"
}

# run_watch [K=V ...] — 沙箱内跑 own_pr_watch（bash 显式调 = 生产 run-watch 段 2.5 同形态）
run_watch() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    -e "STUB_GH_PRS_FILE=$SB_ROOT/gh-prs.json" \
    -e "STUB_GH_VIEW_DIR=$SB_ROOT/gh-view" \
    -e "STUB_DATE_TODAY=$D" \
    'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh"'
}

ev_n() { wc -l <"$EVENTS" 2>/dev/null | tr -d ' '; }
snap_sha() { shasum -a 256 "$SNAPF" 2>/dev/null | awk '{print $1}'; }
gh_argv() { awk -F'|' '$1 == "gh" { print $3 }' "$CALLS" 2>/dev/null; }

# ---------------- ① 夹具自证 ----------------

t_case "gh stub: 既有行为 byte 级保留（api/ISSUES_FILE/FAIL/LATEST/--jq）"
STUBTMP="$(mktemp -d "${TMPDIR:-/tmp}/ownpr-stub.XXXXXX")"
printf '[{"number":42}]\n' >"$STUBTMP/issues.json"
out="$(STUB_LOG_DIR="$STUBTMP" bash "$TESTS_ROOT/stubs/gh" api repos/x/issues?state=all)"
assert_exit 0 $?
assert_eq "$out" "[]" "无旋钮默认空数组"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_GH_ISSUES_FILE="$STUBTMP/issues.json" bash "$TESTS_ROOT/stubs/gh" api repos/x/issues)"
assert_exit 0 $?
assert_contains "$out" '"number":42' "ISSUES_FILE 内容透出"
STUB_LOG_DIR="$STUBTMP" STUB_GH_FAIL=1 bash "$TESTS_ROOT/stubs/gh" api repos/x/issues >/dev/null 2>&1
assert_exit 1 $? "STUB_GH_FAIL=1 → exit 1"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_GH_LATEST=5555 bash "$TESTS_ROOT/stubs/gh" api repos/x/issues --jq '.[0].number')"
assert_exit 0 $?
assert_eq "$out" "5555" "--jq '.[0].number' + LATEST 语义原样"
line="$(grep '^gh|' "$STUBTMP/calls.log" | head -1)"
assert_contains "$line" "gh|$PWD|" "calls.log 行格式保留（gh|cwd|argv）"

t_case "gh stub: pr list / pr view 新分支 + 旋钮未设零行为变化"
printf '[{"number":103201}]\n' >"$STUBTMP/prs.json"
mkdir -p "$STUBTMP/view"
printf '{"state":"MERGED"}\n' >"$STUBTMP/view/pr-103201.json"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_GH_PRS_FILE="$STUBTMP/prs.json" bash "$TESTS_ROOT/stubs/gh" pr list --author strzhao --state open --json number)"
assert_exit 0 $?
assert_contains "$out" '"number":103201' "pr list → PRS_FILE 透出"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_GH_ISSUES_FILE="$STUBTMP/issues.json" bash "$TESTS_ROOT/stubs/gh" pr list --author strzhao --state open)"
assert_contains "$out" '"number":42' "pr list 无 PRS 旋钮 → 落回 ISSUES_FILE（既有行为保留）"
out="$(STUB_LOG_DIR="$STUBTMP" bash "$TESTS_ROOT/stubs/gh" pr list --author strzhao --state open)"
assert_eq "$out" "[]" "pr list 全无旋钮 → []"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_GH_VIEW_DIR="$STUBTMP/view" bash "$TESTS_ROOT/stubs/gh" pr view 103201 --json state)"
assert_exit 0 $?
assert_contains "$out" '"state":"MERGED"' "pr view <N> → pr-<N>.json"
STUB_LOG_DIR="$STUBTMP" STUB_GH_VIEW_DIR="$STUBTMP/view" bash "$TESTS_ROOT/stubs/gh" pr view 9999 --json state >/dev/null 2>&1
assert_exit 1 $? "pr view 文件缺失 → exit 1（单 PR 失败可模拟）"
out="$(STUB_LOG_DIR="$STUBTMP" bash "$TESTS_ROOT/stubs/gh" pr view 103201 --json state)"
assert_eq "$out" "[]" "pr view 无 VIEW_DIR 旋钮 → 既有通用尾 []"
rm -rf "$STUBTMP"

t_case "date stub: STUB_DATE_TODAY 劫持裸 +%F/+%H，其余透传；未设全量透传"
STUBTMP="$(mktemp -d "${TMPDIR:-/tmp}/ownpr-date.XXXXXX")"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_DATE_TODAY="$D" bash "$TESTS_ROOT/stubs/date" +%F)"
assert_eq "$out" "$D" "+%F 冻结"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_DATE_TODAY="$D" bash "$TESTS_ROOT/stubs/date" +%H)"
assert_eq "$out" "00" "+%H 冻结（缺省 00，避开 radar 08 窗）"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_DATE_TODAY="$D" STUB_DATE_HOUR=08 bash "$TESTS_ROOT/stubs/date" +%H)"
assert_eq "$out" "08" "STUB_DATE_HOUR 覆盖"
out="$(STUB_LOG_DIR="$STUBTMP" STUB_DATE_TODAY="$D" bash "$TESTS_ROOT/stubs/date" +%s)"
case "$out" in
  ''|*[!0-9]*) _fail "+%s 透传" "非数字输出 [$out]" ;;
  *) _pass "+%s 透传（epoch 不冻结，停滞龄用真实钟）" ;;
esac
real_out="$(/bin/date "+%Y-%m-%dT%H:%M:%S%z")"
stub_out="$(STUB_LOG_DIR="$STUBTMP" STUB_DATE_TODAY="$D" bash "$TESTS_ROOT/stubs/date" "+%Y-%m-%dT%H:%M:%S%z")"
assert_eq "$stub_out" "$real_out" "复合格式透传 /bin/date"
out="$(STUB_LOG_DIR="$STUBTMP" bash "$TESTS_ROOT/stubs/date" +%F)"
assert_eq "$out" "$(/bin/date +%F)" "旋钮未设 → +%F 真实日期（既有套件零行为变化）"
rm -rf "$STUBTMP"

t_case "sb_new: date stub 已拷贝 + 种子 config own_pr_alert_per_day"
new_sb
[[ -x "$SB_ROOT/bin/date" ]] && _pass "sb_new 拷贝 date stub 到沙箱 bin/" || _fail "sb_new 拷贝 date stub 到沙箱 bin/" "$SB_ROOT/bin/date 缺失"
assert_eq "$(jq -r '.own_pr_alert_per_day' "$DATA/config.json")" "2" "种子 config own_pr_alert_per_day=2"

# ---------------- ② own_pr_watch.sh 行为矩阵 ----------------

t_case "首跑建基线：exit 0 + 快照四字段 + 零事件 + 非 assets-snapshot"
new_sb
printf 'SENTINEL-ASSETS\n' >"$DATA/assets-snapshot.json"
assets_sha="$(shasum -a 256 "$DATA/assets-snapshot.json" | awk '{print $1}')"
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
row 103202 "$FRESH_UPD" CONFLICTING "teknium1,strzhao"
set_prs
run_watch
assert_exit 0 $?
assert_file_contains "$SNAPF" "103201" "快照含 103201"
assert_file_contains "$SNAPF" "103202" "快照含 103202"
rec="$(jq -r '.prs["103201"]' "$SNAPF")"
assert_contains "$rec" '"updatedAt"' "记录含 updatedAt"
assert_contains "$rec" '"mergeable"' "记录含 mergeable"
assert_contains "$rec" '"reviewDecision"' "记录含 reviewDecision"
assert_contains "$rec" '"comments"' "记录含 comments"
assert_eq "$(jq -r '.prs["103202"].external_comments' "$SNAPF")" "1" "external_comments=作者≠strzhao 计数"
# D4 加性：快照条目含 headRefOid/headRefName 字段（pr_row 夹具未提供 ⇒ 缺省空串也算字段存在）
jq -e '.prs["103201"] | has("headRefOid") and has("headRefName")' "$SNAPF" >/dev/null 2>&1
assert_exit 0 $? "快照记录含 headRefOid/headRefName 字段（D4 加性映射）"
assert_eq "$(jq -r '.prs["103202"] | has("headRefOid") and has("headRefName")' "$SNAPF")" "true" "双条目均含 headRef 两字段"
assert_eq "$(jq -r '.prs["103201"].headRefOid // ""' "$SNAPF")" "" "headRefOid 缺省空串（夹具未提供）"
assert_eq "$(jq -r '.prs["103201"].headRefName // ""' "$SNAPF")" "" "headRefName 缺省空串（夹具未提供）"
assert_eq "$(ev_n)" "0" "首跑零事件"
assert_eq "$(jq -r '.prs | length' "$SNAPF")" "2" "快照 PR 数"

t_case "首跑基线轮 assets-snapshot.json 永不被触碰"
assert_eq "$(shasum -a 256 "$DATA/assets-snapshot.json" | awk '{print $1}')" "$assets_sha" "哨兵 sha 不变"
assert_ne "$(basename "$SNAPF")" "assets-snapshot.json" "自有快照文件名 != assets-snapshot.json"

t_case "外部新评论 → 恰 1 条 own-pr-activity（class 精确串 + key 含 PR/计数/当日）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch"
set_prs
set_view 103201 OPEN "strzhao,alt-glitch"
before="$(ev_n)"
gh_before="$(stub_count gh)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "1" "delta == 1"
newline="$(tail -1 "$EVENTS")"
assert_contains "$newline" '"class":"own-pr-activity"' "class 精确串 own-pr-activity"
assert_contains "$newline" "103201" "行含 PR 号"
assert_contains "$newline" "$D" "行含冻结当日 D"
assert_contains "$newline" "comment-1-" "key 携带 external_comments=1"
assert_eq "$(( $(stub_count gh) - gh_before ))" "2" "stage-1 + stage-2 comments 核实（评论增才二次查询）"

t_case "本人评论（external_comments 不增）→ 静默吸收 + 快照更新"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "teknium1,strzhao"
set_prs
run_watch
assert_exit 0 $?
row 103201 "$FRESH_UPD" MERGEABLE "teknium1,strzhao,strzhao"
set_prs
set_view 103201 OPEN "teknium1,strzhao,strzhao"
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "本人评论 delta == 0"
assert_eq "$(jq -r '.prs["103201"].comments' "$SNAPF")" "3" "快照 comments 吸收到 3"
assert_eq "$(jq -r '.prs["103201"].external_comments' "$SNAPF")" "1" "external_comments 不变"

t_case "PR 消失 + state=MERGED → 高级终态事件 + 快照剪枝 + 先核实后剪枝"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
row 103202 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
run_watch
set_view 103201 MERGED
: >"$SB_ROOT/pr.rows"
row 103202 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "1" "delta == 1"
newline="$(tail -1 "$EVENTS")"
assert_contains "$newline" '"class":"own-pr-activity"' "终态事件 class=own-pr-activity"
assert_contains "$newline" "103201" "行含 103201"
if printf '%s' "$newline" | grep -Eiq 'merge'; then
  _pass "行匹配 (?i)merge"
else
  _fail "行匹配 (?i)merge" "行=[$newline]"
fi
assert_eq "$(jq -r '.prs["103201"] // empty' "$SNAPF")" "" "快照已剪枝 103201"
assert_eq "$(jq -r '.prs | length' "$SNAPF")" "1" "快照剩 103202"
assert_eq "$(gh_argv | grep -c 'pr view')" "1" "消失 PR 先 stage-2 终态核实（本轮 gh 调用 >= 2）"

t_case "PR 消失 + state=CLOSED → 高级终态事件（clos 语义）+ 剪枝"
new_sb
row 103202 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
run_watch
set_view 103202 CLOSED
: >"$SB_ROOT/pr.rows"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "1" "delta == 1"
newline="$(tail -1 "$EVENTS")"
assert_contains "$newline" "103202" "行含 103202"
if printf '%s' "$newline" | grep -Eiq 'clos'; then
  _pass "行匹配 (?i)clos"
else
  _fail "行匹配 (?i)clos" "行=[$newline]"
fi
assert_eq "$(jq -r '.prs | length' "$SNAPF")" "0" "快照剪枝到空"

t_case "PR 消失 + state=OPEN（瞬时态）→ 零事件 + 快照保留"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
set_view 103201 OPEN
: >"$SB_ROOT/pr.rows"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "OPEN 消失零事件"
assert_eq "$(jq -r '.prs | length' "$SNAPF")" "1" "快照保留该 PR"

t_case "mergeable 已知值间翻转 → own-pr-info 低级事件（class 精确串）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
row 103201 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "1" "delta == 1"
newline="$(tail -1 "$EVENTS")"
assert_contains "$newline" '"class":"own-pr-info"' "class 精确串 own-pr-info"
assert_contains "$newline" "103201" "行含 103201"
assert_contains "$newline" "$D" "行含当日 D"
# D4 加性：absorb 轮（非基线）条目合并语义——headRef 两字段存续（下轮自然再生新形态，不整条替换）
jq -e '.prs["103201"] | has("headRefOid") and has("headRefName")' "$SNAPF" >/dev/null 2>&1
assert_exit 0 $? "absorb 轮快照条目 headRef 两字段存续（对象合并不冲掉加性字段）"

t_case "mergeable 含 UNKNOWN 的翻转 → 静默吸收（双向）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
row 103201 "$FRESH_UPD" UNKNOWN "strzhao"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "具体值→UNKNOWN 零事件"
assert_contains "$(jq -r '.prs["103201"].mergeable' "$SNAPF")" "UNKNOWN" "快照吸收 UNKNOWN"
row 103201 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "UNKNOWN→具体值亦静默"

t_case "停滞：无其他 diff 且 updatedAt 超 stale_pr_days → own-pr-info（阈值内不报）"
new_sb
row 103201 "$STALE_UPD" MERGEABLE "strzhao"
set_prs
run_watch
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "1" "超 20 天（>10）→ delta == 1"
newline="$(tail -1 "$EVENTS")"
assert_contains "$newline" '"class":"own-pr-info"' "停滞事件 class=own-pr-info"
if printf '%s' "$newline" | grep -Eiq 'stale|aged|aging'; then
  _pass "行匹配 (?i)stale|age(d|ing)"
else
  _fail "行匹配 (?i)stale|age(d|ing)" "行=[$newline]"
fi
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
before="$(ev_n)"
run_watch
assert_eq "$(( $(ev_n) - before ))" "0" "updatedAt 新鲜（<10 天）零停滞事件"

t_case "仅 reviewDecision 变化 → 静默吸收（exit 0 + 零事件 + 新值入快照）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
jq -c 'if .number == 103201 then .reviewDecision = "APPROVED" else . end' "$SB_ROOT/pr.rows" >"$SB_ROOT/pr.rows.2" && mv "$SB_ROOT/pr.rows.2" "$SB_ROOT/pr.rows"
set_prs
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "reviewDecision 变化零事件"
assert_contains "$(jq -r '.prs["103201"].reviewDecision' "$SNAPF")" "APPROVED" "新值吸收进快照"
nev="$(tail -n +$(( before + 1 )) "$EVENTS" 2>/dev/null)"
if printf '%s' "$nev" | grep -Eiq 'comment|merge|clos'; then
  _fail "新增行无终态/评论语义" "实得 [$nev]"
else
  _pass "新增行无 comment/merge/clos 语义"
fi

t_case "日级幂等 + 账本双格式：同 key 已在账（jq 紧凑与 json.dumps 带空格两形态）不重复入账"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
# json.dumps 带空格形态（flush 账本重写形态）预置同 key 事件
printf '{"ts": "%s", "class": "own-pr-activity", "key": "103201-comment-2-%s", "channel": "contrib", "summary": "seeded", "pushed": false, "attempts": 0, "pushed_at": null}\n' \
  "$(date "+%Y-%m-%dT%H:%M:%S%z")" "$D" >>"$EVENTS"
row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch,alt-glitch"
set_prs
set_view 103201 OPEN "strzhao,alt-glitch,alt-glitch"
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "带空格形态同 key → 幂等零入账"
# jq 紧凑形态预置另一 PR 的 key → 本 PR 照常入账
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
row 103202 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
jq -cn --arg d "$D" '{ts: "x", class: "own-pr-activity", key: ("103202-comment-9-" + $d), channel: "contrib", summary: "seeded", pushed: false, attempts: 0, pushed_at: null}' >>"$EVENTS"
row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch"
set_prs
set_view 103201 OPEN "strzhao,alt-glitch"
before="$(ev_n)"
run_watch
assert_eq "$(( $(ev_n) - before ))" "1" "他 PR 已有事件不吞并本 PR（key 不同照常入账）"
assert_contains "$(tail -1 "$EVENTS")" "103201" "新入账行含 103201"

t_case "子上限（own_pr_alert_per_day=1）：第 2 条高级停发；低级不受限"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
sb_config_set '.own_pr_alert_per_day = 1'
run_watch
row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch"
set_prs
set_view 103201 OPEN "strzhao,alt-glitch"
before="$(ev_n)"
run_watch
assert_eq "$(( $(ev_n) - before ))" "1" "配额 1：首个外部评论照发"
row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch,alt-glitch"
set_prs
set_view 103201 OPEN "strzhao,alt-glitch,alt-glitch"
before="$(ev_n)"
run_watch
assert_eq "$(( $(ev_n) - before ))" "0" "配额满 → 高级停发（零新增）"
row 103201 "$FRESH_UPD" CONFLICTING "strzhao,alt-glitch,alt-glitch"
set_prs
before="$(ev_n)"
run_watch
assert_eq "$(( $(ev_n) - before ))" "1" "配额满不抑制低级（mergeable 翻转照发）"
assert_contains "$(tail -1 "$EVENTS")" '"class":"own-pr-info"' "低级 class 精确串"

t_case "子上限计数对账本双格式免疫（json.dumps 带空格形态也计入配额）"
for form in spaced compact; do
  new_sb
  row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
  set_prs
  sb_config_set '.own_pr_alert_per_day = 1'
  if [[ "$form" == "spaced" ]]; then
    printf '{"ts": "%s", "class": "own-pr-activity", "key": "99999-comment-1-%s", "channel": "contrib", "summary": "seeded", "pushed": false, "attempts": 0, "pushed_at": null}\n' \
      "$(date "+%Y-%m-%dT%H:%M:%S%z")" "$D" >>"$EVENTS"
  else
    jq -cn --arg d "$D" '{ts: "x", class: "own-pr-activity", key: ("99999-comment-1-" + $d), channel: "contrib", summary: "seeded", pushed: false, attempts: 0, pushed_at: null}' >>"$EVENTS"
  fi
  row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch"
  set_prs
  set_view 103201 OPEN "strzhao,alt-glitch"
  before="$(ev_n)"
  run_watch
  assert_eq "$(( $(ev_n) - before ))" "0" "[$form] 带空格外源高级事件计入当日配额 → 停发"
done

t_case "gh 失败断路：首败 exit 1 零写零事件；连败 2 故障事件；连败 3 幂等；成功清零"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
sha_before="$(snap_sha)"
before="$(ev_n)"
run_watch "STUB_GH_FAIL=1"
assert_exit 1 $? "首败 exit 1"
assert_eq "$(snap_sha)" "$sha_before" "零快照写（sha 不变）"
assert_eq "$(( $(ev_n) - before ))" "0" "首败零事件"
assert_eq "$(cat "$DATA/.ownpr-watch-fail" 2>/dev/null)" "1" "连败计数=1"
before="$(ev_n)"
run_watch "STUB_GH_FAIL=1"
assert_exit 1 $?
assert_eq "$(( $(ev_n) - before ))" "1" "连败恰达 2 → 恰 1 条故障事件"
newline="$(tail -1 "$EVENTS")"
assert_contains "$newline" '"class":"pipeline-failure"' "故障事件 class"
assert_contains "$newline" "$D" "故障 key 含当日（日级幂等）"
assert_eq "$(cat "$DATA/.ownpr-watch-fail" 2>/dev/null)" "2" "连败计数=2"
before="$(ev_n)"
run_watch "STUB_GH_FAIL=1"
assert_exit 1 $?
assert_eq "$(( $(ev_n) - before ))" "0" "连败 3 → 故障事件日级幂等不再入账"
run_watch
assert_exit 0 $? "恢复轮 exit 0"
assert_eq "$(ls "$DATA/.ownpr-watch-fail" 2>/dev/null)" "" "成功清零（计数文件移除）"
before="$(ev_n)"
run_watch "STUB_GH_FAIL=1"
assert_exit 1 $?
assert_eq "$(( $(ev_n) - before ))" "0" "恢复后首败不告警（计数已清零）"

t_case "stage-2 失败（pr view 数据缺失→stub exit 1 旋钮）→ 按 gh 失败断路（零写零事件计入连败）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch                        # 基线轮（无评论增，不触 stage-2）
row 103201 "$FRESH_UPD" MERGEABLE "strzhao,alt-glitch"
set_prs
rm -f "$SB_ROOT/gh-view/pr-103201.json"   # 旋钮：view 缺失 → stub pr view exit 1
sha_before="$(snap_sha)"
before="$(ev_n)"
run_watch
assert_exit 1 $? "stage-2 失败按 gh 失败处理（exit 1）"
assert_eq "$(snap_sha)" "$sha_before" "stage-2 失败零快照写"
assert_eq "$(( $(ev_n) - before ))" "0" "stage-2 失败零事件"
assert_eq "$(cat "$DATA/.ownpr-watch-fail" 2>/dev/null)" "1" "stage-2 失败计入连败计数"

t_case "快照损坏 → 重建基线（exit 0 零事件 + 日志 rebuild/corrupt 痕迹）；下轮真实变化正常检出"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
printf 'THIS-IS-NOT-JSON{{{' >"$SNAPF"
before="$(ev_n)"
run_watch
assert_exit 0 $?
assert_eq "$(( $(ev_n) - before ))" "0" "损坏重建零事件"
jq -e 'type == "object"' "$SNAPF" >/dev/null 2>&1
assert_exit 0 $? "重建后快照为合法 JSON"
assert_file_contains "$SNAPF" "103201" "重建快照含当前 PR"
hits="$(grep -Eic 'rebuild|corrupt|baseline' "$WLOG" 2>/dev/null || true)"
if [[ "${hits:-0}" -ge 1 ]]; then
  _pass "日志留痕 rebuild/corrupt/baseline（${hits} 命中）"
else
  _fail "日志留痕 rebuild/corrupt/baseline" "own-pr-watch.log 零命中"
fi
row 103201 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
before="$(ev_n)"
run_watch
assert_eq "$(( $(ev_n) - before ))" "1" "重建后下一轮真实变化正常检出"

t_case "用法错误 → exit 2（单发无参数闭集）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
sb_run 'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh" unexpected-arg' >/dev/null 2>&1
assert_exit 2 $?

t_case "argv 形态锚：pr list 必带 --author strzhao --state open（防漏过滤突变）"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
assert_exit 0 $?
hits="$(gh_argv | grep -Ec 'pr list( .*)? --author strzhao --state open' || true)"
if [[ "${hits:-0}" -ge 1 ]]; then
  _pass "argv 锚 pr list( .*)? --author strzhao --state open 命中"
else
  _fail "argv 锚 pr list( .*)? --author strzhao --state open 命中" "argv=[$(gh_argv | tr '\n' ';')]"
fi

t_case "原子写自证：多轮后快照恒合法 JSON + 零 *.tmp 残留"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
run_watch
row 103201 "$FRESH_UPD" CONFLICTING "strzhao"
set_prs
run_watch
run_watch
run_watch
jq -e 'type == "object" and (.prs | type == "object")' "$SNAPF" >/dev/null 2>&1
assert_exit 0 $? "三轮后快照仍为合法 JSON"
tmps="$(ls "$DATA"/*.tmp "$DATA"/own-pr-watch-snapshot.json.tmp 2>/dev/null || true)"
assert_eq "${tmps:-}" "" "contrib-data 根零 .tmp 残留（tmp+mv 原子写）"

t_case "红线调用面闭集：零 gh 写子命令 / 零 LLM / 零网络写"
new_sb
row 103201 "$STALE_UPD" MERGEABLE "strzhao"
set_prs
run_watch
run_watch
argv="$(gh_argv)"
writes="$(printf '%s\n' "$argv" | grep -Ec '(^| )(pr|issue|repo|release) (create|edit|delete|close|reopen|merge|comment|lock|label)( |$)|-X *(POST|PATCH|PUT|DELETE)' || true)"
assert_eq "${writes:-0}" "0" "gh argv 零写子命令（token 锚定闭集）"
llm="$(grep -Eic 'claude|llm|deepseek|openai' "$CALLS" 2>/dev/null || true)"
assert_eq "${llm:-0}" "0" "calls.log 零 LLM 痕迹"
net="$(grep -Ec 'hermes.*send|curl|wget' "$CALLS" 2>/dev/null || true)"
assert_eq "${net:-0}" "0" "calls.log 零网络写（hermes send/curl/wget）"

# ---------------- ③ run-watch.sh 段 2.5 编排集成（zsh 调镜像生产） ----------------

t_case "run-watch 集成：含 own-pr 段调用 + 段 rc 日志 + 产物与单跑一致"
new_sb
row 103201 "$FRESH_UPD" MERGEABLE "strzhao"
set_prs
assert_file_contains "$CONTRIB_TEST_TARGET/run-watch.sh" "own_pr_watch" "run-watch 含 own-pr 段（静态锚）"
sb_run \
  -e "STUB_GH_PRS_FILE=$SB_ROOT/gh-prs.json" \
  -e "STUB_GH_VIEW_DIR=$SB_ROOT/gh-view" \
  -e "STUB_DATE_TODAY=$D" \
  -e "RADAR_HOUR=00" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
assert_exit 0 $? "run-watch 整链 exit 0"
jq -e 'type == "object"' "$SNAPF" >/dev/null 2>&1
assert_exit 0 $? "集成轮产出快照且合法 JSON"
assert_file_contains "$SNAPF" "103201" "集成快照含 103201"
assert_file_contains "$DATA/logs/launchd.log" "own-PR 盯梢 exit=0" "段 rc 日志行落 launchd.log"
hits="$(gh_argv | grep -Ec 'pr list( .*)? --author strzhao --state open' || true)"
if [[ "${hits:-0}" -ge 1 ]]; then
  _pass "集成轮 gh argv 含 own-PR 盯梢 stage-1 调用"
else
  _fail "集成轮 gh argv 含 own-PR 盯梢 stage-1 调用" "argv=[$(gh_argv | tr '\n' ';')]"
fi

t_case "run-watch 集成：own_pr_watch 缺失（非可执行）→ 编排零致命（守卫跳过）"
new_sb
mv "$SB_ROOT/scripts/contrib/own_pr_watch.sh" "$SB_ROOT/own-pr-watch.bak" 2>/dev/null || true
sb_run \
  -e "STUB_DATE_TODAY=$D" \
  -e "RADAR_HOUR=00" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
assert_exit 0 $? "脚本缺席整链仍 exit 0（[[ -x ]] 守卫）"

t_finish
