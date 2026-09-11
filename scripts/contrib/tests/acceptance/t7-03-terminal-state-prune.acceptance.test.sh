#!/usr/bin/env bash
# =============================================================================
# t7-03-terminal-state-prune.acceptance.test.sh — T7 验收③：终态核实 + 高级事件 + 快照剪枝
#   T1 场景3.P1 PR 从 open 列表消失且核实 state==MERGED → 恰 1 条 own-pr-activity 终态事件
#       （含 103201、匹配 (?i)merge）+ 快照剪枝 103201
#   T2 场景3.P2 消失 PR 先经单 PR 终态核实查询（gh 调用本轮 >= 2：stage-1 list + stage-2 view）
#   T3 场景3.P3 消失 PR 核实 state==CLOSED → 恰 1 条终态事件（含 103202、匹配 (?i)clos）+ 剪枝
# 依据：state.md「## 设计文档」（PR 从 open 消失 → stage-2 gh pr view <N> --json state →
#   MERGED/CLOSED → 高级终态事件 + 快照剪枝；OPEN → 只日志保留快照；key <PR>-merged-<日期> /
#   <PR>-closed-<日期>）+「## 验收场景」场景 3.P1-P3（SSOT）
# CONTRACT_AMBIGUOUS：
#   - key 全形按契约字面 103201-merged-<D> / 103202-closed-<D> 断言（段序/分隔符若异，红=交人审）
#   - T2 的「先核实再剪枝」以本轮 gh 调用记录 >= 2 + 存在含 view+<PR> 的调用行做行为面钉死；
#     「先后次序」本身（list 先于 view）由 calls.log 追加序隐式自证，不单独断言
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树）；每断言硬失败；
#   无 skip；账本断言先 jq 归一化（双格式免疫）；全程 sb_new 沙箱 + 影子 stub，零真实外发。
# Mental Mutation：跳过 stage-2 直接剪枝（丢终态事件）→T1/T3 红；剪枝漏做→T1/T3 快照断言红；
#   类互换→T1 class 断言红；key 漏日期（stub 未接线）→T1/T3 key 断言红；MERGED/CLOSED 判定
#   互换→T1/T3 关键词断言红；no-op（零剪枝零事件）→T1/T3 红。
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

D="2027-06-01"
FRESH_TS="2027-05-30T00:00:00Z"
SNAP_NAME="own-pr-watch-snapshot.json"
EV_MARK=0
LOG_MARK=0

snap_f() { printf '%s/contrib-data/%s' "$SB_ROOT" "$SNAP_NAME"; }
ev_f()   { printf '%s/contrib-data/events.jsonl' "$SB_ROOT"; }

pr_rec() {
  jq -cn --arg n "$1" --arg u "$2" --arg m "$3" --arg r "$4" --argjson c "$5" --argjson e "$6" \
    '{number:($n|tonumber), updatedAt:$u, mergeable:$m, reviewDecision:$r, comments:$c, external_comments:$e}'
}
pr_list_entry() {
  # comments 镜像生产数组形态（qa-reviewer 09-10：真实 gh pr list comments 是数组）
  # <6>可选 authors-csv：缺省 strzhao×count（行 extn=0，与标量时代行为一致）
  jq -cn --argjson n "$1" --arg u "$2" --arg m "$3" --arg r "$4" --argjson c "$5" --arg a "${6:-}" \
    '{number:$n, updatedAt:$u, mergeable:$m, reviewDecision:$r,
      comments: (if $a == "" then (reduce range(0; $c) as $i ([]; . + [{author: {login: "strzhao"}}]))
                 else ($a | split(",") | map(select(length > 0)) | map({author: {login: .}})) end)}'
}
write_pr_list() {
  local f="$1" arr="[]" e
  shift
  for e in "$@"; do arr="$(printf '%s' "$arr" | jq -c --argjson o "$e" '. + [$o]')"; done
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$arr" >"$f"
}
write_view() { # <dir> <pr> <state> <author-login...>
  local dir="$1" pr="$2" st="$3" cmts="[]" a
  shift 3
  for a in "$@"; do cmts="$(printf '%s' "$cmts" | jq -c --arg a "$a" '. + [{author:{login:$a}}]')"; done
  mkdir -p "$dir"
  jq -cn --argjson n "$pr" --arg st "$st" --argjson c "$cmts" \
    '{number:$n, state:$st, reviewDecision:null, comments:$c}' >"$dir/pr-$pr.json"
}
seed_snapshot() {
  local arr="[]" p
  for p in "$@"; do arr="$(printf '%s' "$arr" | jq -c --argjson o "$p" '. + [$o]')"; done
  jq -n --argjson prs "$arr" --arg ts "${D}T00:00:00+08:00" \
    '{generated_at:$ts, prs:( reduce $prs[] as $p ({}; . + {($p.number|tostring): ($p | del(.number))}))}' \
    >"$(snap_f)"
}
install_date_stub() {
  local src="$TESTS_ROOT/stubs/date" got
  if [[ ! -f "$src" ]]; then
    _fail "date stub 契约夹具存在" "tests/stubs/date 缺失（设计改动面钉死的测试夹具未交付）"
    return 1
  fi
  _pass "date stub 契约夹具存在"
  mkdir -p "$SB_HOME/.local/bin"
  cp "$src" "$SB_ROOT/bin/date" && chmod +x "$SB_ROOT/bin/date"
  cp "$src" "$SB_HOME/.local/bin/date" && chmod +x "$SB_HOME/.local/bin/date"
  got="$(sb_run -e "STUB_DATE_TODAY=$D" 'date +%F' 2>/dev/null)"
  assert_eq "$got" "$D" "date stub 劫持裸 +%F 自证（冻结同日 D=${D}）"
  return 0
}
ev_mark() { EV_MARK="$(wc -l < "$(ev_f)" 2>/dev/null || printf 0)"; }
ev_delta() {
  local n
  n="$(wc -l < "$(ev_f)" 2>/dev/null || printf 0)"
  printf '%d' $(( n - EV_MARK ))
}
ev_new_json() { tail -n "+$((EV_MARK + 1))" "$(ev_f)" 2>/dev/null | jq -s '.' 2>/dev/null || printf '[]'; }
ev_new_blob() { ev_new_json | jq -r '.[] | ((.key // "") + " " + (.summary // ""))' 2>/dev/null; }
mark_log() { LOG_MARK="$(wc -l < "$SB_ROOT/stublog/calls.log" 2>/dev/null || printf 0)"; }
round_calls() { tail -n "+$((LOG_MARK + 1))" "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
gh_calls_in_round() { round_calls | grep -c '^gh|' || true; }
run_watch_proc() {
  sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/tmp/prs.json" \
         -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
         -e "STUB_DATE_TODAY=$D" \
         'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh"'
}
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mkdir -p "$SB_ROOT/tmp/views"
  install_date_stub
  return 0
}
art() { mkdir -p /tmp/autopilot-artifacts && printf '%s\n' "$2" >"/tmp/autopilot-artifacts/场景$1.out"; }

# =============================================================================
t_case "T1 场景3.P1 消失 PR 核实 MERGED → 1 条 own-pr-activity（含 103201、(?i)merge）+ 剪枝"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)" \
              "$(pr_rec 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2 2)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2)"   # 103201 已从 open 列表消失
write_view "$SB_ROOT/tmp/views" 103201 MERGED alice bob               # 终态核实=MERGED
write_view "$SB_ROOT/tmp/views" 103202 OPEN alice
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景3.P1 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景3.P1 恰 1 条终态事件"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-activity" "场景3.P1 class == own-pr-activity"
BLOB="$(ev_new_blob)"
assert_contains "$BLOB" "103201" "场景3.P1 新增行含 103201"
MERGE_N="$(printf '%s\n' "$BLOB" | grep -Eic -- 'merge' || true)"
case "$MERGE_N" in ''|*[!0-9]*) _fail "场景3.P1 匹配 (?i)merge" "非数值 [$MERGE_N]" ;; *) [ "$MERGE_N" -ge 1 ] && _pass "场景3.P1 新增行匹配 (?i)merge" || _fail "场景3.P1 新增行匹配 (?i)merge" "零命中" ;; esac
assert_eq "$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)" "103201-merged-$D" "场景3.P1 key=契约字面 <PR>-merged-<日期>"
assert_eq "$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)" "false" "场景3.P1 快照已剪枝 103201"
assert_eq "$(jq -r '.prs | has("103202")' "$(snap_f)" 2>/dev/null)" "true" "场景3.P1 快照保留 103202（剪枝精确到单 PR）"
assert_eq "$(jq -e . "$(snap_f)" >/dev/null 2>&1 && printf yes || printf no)" "yes" "场景3.P1 剪枝后快照仍合法 JSON"
art "3.P1" "delta=$(ev_delta) key=$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null) pruned201=$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)"
sb_cleanup

# =============================================================================
t_case "T2 场景3.P2 消失 PR 先经单 PR 终态核实查询（本轮 gh 调用 >= 2）"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json"    # 空 open 列表 → 103201 消失
write_view "$SB_ROOT/tmp/views" 103201 MERGED alice
mark_log
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景3.P2 watcher 正常完成"
GH_N="$(gh_calls_in_round)"
case "$GH_N" in
  ''|*[!0-9]*) _fail "场景3.P2 gh 调用条数 >= 2" "非数值 [$GH_N]" ;;
  *) [ "$GH_N" -ge 2 ] && _pass "场景3.P2 本轮 gh 调用记录 >= 2（stage-1 list + stage-2 view）" \
     || _fail "场景3.P2 gh 调用条数 >= 2" "实得 ${GH_N}（缺失终态核实查询=盲剪枝突变）" ;;
esac
VIEW_N="$(round_calls | grep '^gh|' | grep -- 'view' | grep -c -- '103201' || true)"
case "$VIEW_N" in
  ''|*[!0-9]*) _fail "场景3.P2 存在 view+103201 核实调用" "非数值 [$VIEW_N]" ;;
  *) [ "$VIEW_N" -ge 1 ] && _pass "场景3.P2 存在对 103201 的单 PR view 核实调用" \
     || _fail "场景3.P2 存在 view+103201 核实调用" "calls.log 本轮无 view+103201 行" ;;
esac
art "3.P2" "gh_calls=$GH_N"
sb_cleanup

# =============================================================================
t_case "T3 场景3.P3 消失 PR 核实 CLOSED → 1 条终态事件（含 103202、(?i)clos）+ 剪枝"
common_setup
seed_snapshot "$(pr_rec 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2 2)"
write_pr_list "$SB_ROOT/tmp/prs.json"    # 空 open 列表 → 103202 消失
write_view "$SB_ROOT/tmp/views" 103202 CLOSED alice
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景3.P3 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景3.P3 恰 1 条终态事件"
BLOB="$(ev_new_blob)"
assert_contains "$BLOB" "103202" "场景3.P3 新增行含 103202"
CLOS_N="$(printf '%s\n' "$BLOB" | grep -Eic -- 'clos' || true)"
case "$CLOS_N" in ''|*[!0-9]*) _fail "场景3.P3 匹配 (?i)clos" "非数值 [$CLOS_N]" ;; *) [ "$CLOS_N" -ge 1 ] && _pass "场景3.P3 新增行匹配 (?i)clos" || _fail "场景3.P3 新增行匹配 (?i)clos" "零命中" ;; esac
assert_eq "$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)" "103202-closed-$D" "场景3.P3 key=契约字面 <PR>-closed-<日期>"
assert_eq "$(jq -r '.prs | has("103202")' "$(snap_f)" 2>/dev/null)" "false" "场景3.P3 快照已剪枝 103202"
assert_eq "$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)" "false" "场景3.P3 快照无多余 PR"
assert_eq "$(jq -e . "$(snap_f)" >/dev/null 2>&1 && printf yes || printf no)" "yes" "场景3.P3 剪枝后快照仍合法 JSON"
art "3.P3" "delta=$(ev_delta) key=$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)"
sb_cleanup

t_finish
