#!/usr/bin/env bash
# =============================================================================
# t7-02-comment-diff-keycount.acceptance.test.sh — T7 验收②：评论 diff 分级 + 评论计数 key 防吞并
#   C1 场景2.P1 评论计数增加且新增评论者 ≠ strzhao → 恰 1 条 own-pr-activity（精确类串，防类互换）
#       含 103201、含冻结日 D；key = <PR>-comment-<external_comments>-<日期>（契约字面）
#   C2 场景2.P2 评论计数增加但新增评论者 == strzhao → 零事件 + 快照静默吸收（comments 更新、
#       external_comments 不变）
#   C3 场景7.P1 同日两次评论增长 → 恰 2 条、两条 key 互异
#   C4 场景7.P2 两条 key 分别携带当次评论计数 4 与 5
# 依据：state.md「## 设计文档」（comments 增 → stage-2 gh pr view <N> --json comments →
#   external_comments（作者≠strzhao）增 → 高级事件；不变=本人评论静默吸收；事件分级：高级 =
#   own-pr-activity，key <PR>-comment-<external_comments>-<日期> 计数进 key 防同日吞并）
#   +「## 验收场景」场景 2.P1-P2、场景 7.P1-P2（SSOT）
# CONTRACT_AMBIGUOUS：
#   - key 日期段格式取 date +%F 冻结值（设计 date stub 劫持裸 +%F → D=2027-06-01）；key 全形按
#     契约字面 <PR>-comment-<N>-<D> 断言相等——若实现段序/分隔符不同，红 = 交人审
#   - 评论计数口径 = 快照 external_comments（语义备注钉死）；基线快照直接按契约 schema 种入
#     external_comments=3，绕开「基线轮是否跑 stage-2」的未钉行为
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树）；每断言硬失败；
#   无 skip；账本断言一律先 jq 归一化（双格式免疫：jq 紧凑 vs json.dumps 带空格）；
#   全程 sb_new 沙箱 + 影子 stub，绝不真调 gh/hermes/claude。
# Mental Mutation：类互换（own-pr-info↔own-pr-activity）→C1 红；key 漏评论计数→C3/C4 红；
#   本人评论也触发→C2 红；静默吸收不更新快照→C2 快照断言红；no-op（永不发事件）→C1/C3 红；
#   key 不带 D（date stub 未接线）→C1/C4 含 D 断言红。
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
seed_snapshot() { # 契约 schema 直写快照（绕开基线轮行为未钉面）
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
ev_new_json() { # 新增行 → JSON 数组（jq 归一化，双格式免疫）
  tail -n "+$((EV_MARK + 1))" "$(ev_f)" 2>/dev/null | jq -s '.' 2>/dev/null || printf '[]'
}
ev_new_blob() { ev_new_json | jq -r '.[] | ((.key // "") + " " + (.summary // ""))' 2>/dev/null; }
comment_keys() { # 账本中 103201-comment-* 的 key（append 序）
  jq -rs '[.[] | select(.class == "own-pr-activity" and ((.key // "") | startswith("103201-comment-")))] | map(.key)' "$(ev_f)" 2>/dev/null
}
run_watch_proc() { # list 变更后重写 prs.json 再跑
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
t_case "C1 场景2.P1 外部新评论 → 恰 1 条 own-pr-activity（类精确串 + 103201 + D + key 契约形）"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 4 "alice,bob,carol,dave")"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol dave   # 4 条外部评论（作者≠strzhao；list 行作者对齐 view）
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景2.P1 前置：watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景2.P1 恰入账 1 条事件"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-activity" "场景2.P1 新增行 class == own-pr-activity（精确串，防类互换突变）"
BLOB="$(ev_new_blob)"
assert_contains "$BLOB" "103201" "场景2.P1 新增行含 103201"
assert_contains "$BLOB" "$D" "场景2.P1 新增行含冻结日 D"
assert_eq "$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)" "103201-comment-4-$D" "场景2.P1 key=契约字面 <PR>-comment-<N>-<日期>"
assert_eq "$(jq -r '.prs["103201"].comments' "$(snap_f)" 2>/dev/null)" "4" "场景2.P1 快照吸收 comments=4"
assert_eq "$(jq -r '.prs["103201"].external_comments' "$(snap_f)" 2>/dev/null)" "4" "场景2.P1 快照吸收 external_comments=4"
art "2.P1" "delta=$(ev_delta) class=$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null) key=$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)"
sb_cleanup

# =============================================================================
t_case "C2 场景2.P2 本人评论 → 零事件 + 快照静默吸收（comments 4、external_comments 不变）"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 4 "alice,bob,carol,strzhao")"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol strzhao   # 第 4 条是本人评论
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景2.P2 watcher 正常完成"
assert_eq "$(ev_delta)" "0" "场景2.P2 零事件（本人评论静默吸收）"
assert_eq "$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)" "true" "场景2.P2 快照含 103201"
assert_eq "$(jq -r '.prs["103201"].comments' "$(snap_f)" 2>/dev/null)" "4" "场景2.P2 快照已吸收 comments=4（静默更新非丢弃）"
assert_eq "$(jq -r '.prs["103201"].external_comments' "$(snap_f)" 2>/dev/null)" "3" "场景2.P2 external_comments 不变=3"
art "2.P2" "delta=$(ev_delta) comments=$(jq -r '.prs["103201"].comments' "$(snap_f)" 2>/dev/null)"
sb_cleanup

# =============================================================================
t_case "C3/C4 场景7.P1+P2 同日两次评论增长 → 恰 2 条、key 互异、分别携带计数 4 与 5"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
# 轮 1：comments 3→4，4 条外部评论
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 4 "alice,bob,carol,dave")"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol dave
ev_mark
run_watch_proc >/dev/null
assert_exit 0 "$?" "场景7 轮 1 正常完成"
assert_eq "$(ev_delta)" "1" "场景7 轮 1 恰 1 条"
# 轮 2：comments 4→5，5 条外部评论
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 5 "alice,bob,carol,dave,erin")"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol dave erin
ev_mark
run_watch_proc >/dev/null
assert_exit 0 "$?" "场景7 轮 2 正常完成"
assert_eq "$(ev_delta)" "1" "场景7 轮 2 恰 1 条"
assert_eq "$(comment_keys | jq -r 'length' 2>/dev/null)" "2" "场景7.P1 当日评论类事件恰 2 条"
K1="$(comment_keys | jq -r '.[0] // ""' 2>/dev/null)"
K2="$(comment_keys | jq -r '.[1] // ""' 2>/dev/null)"
assert_ne "$K1" "$K2" "场景7.P1 key(第一条) != key(第二条)（计数进 key 防同日吞并）"
assert_contains "$K1" "4" "场景7.P2 key(第一条) 含当次评论计数 4"
assert_contains "$K2" "5" "场景7.P2 key(第二条) 含当次评论计数 5"
assert_eq "$K1" "103201-comment-4-$D" "场景7.P2 第一条 key=契约字面 103201-comment-4-<D>"
assert_eq "$K2" "103201-comment-5-$D" "场景7.P2 第二条 key=契约字面 103201-comment-5-<D>"
art "7.P1" "k1=$K1 k2=$K2"
art "7.P2" "k1=$K1 k2=$K2"
sb_cleanup

t_finish
