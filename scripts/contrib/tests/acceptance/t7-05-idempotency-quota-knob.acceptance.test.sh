#!/usr/bin/env bash
# =============================================================================
# t7-05-idempotency-quota-knob.acceptance.test.sh — T7 验收⑤：事件日级幂等 + own_pr_alert_per_day 旋钮
#   I1 场景6.P1 同 key 当日已存在账本 → 不重复入账（delta == 0）
#   I2 场景6.P2 同日另一 PR 不同 key → 正常入账（delta == 1 且含 103202）——幂等按 key 不按轮
#   Q1 场景10.P1 own_pr_alert_per_day=1 且当日高级数为 0 → 首个外部评论变化入账 1 条
#   Q2 场景10.P2 当日高级数 >= 旋钮 → 再发高级类变化被停发（零新增）
#   Q3 场景10.P3 当日高级已满 → 低级变化（mergeable 翻转）照常入账（含 103201）
# 依据：state.md「## 设计文档」（全部经 notify.sh event 其自身同 key 幂等兜底；子上限 = watcher
#   发高级事件前自查 events.jsonl 当日 own-pr-activity 已入账数（jq 解析非 grep——账本双格式防
#   format-drift），>= own_pr_alert_per_day(config,默认2) 停发高级；低级不受限）+「## 验收场景」
#   场景 6.P1-P2、10.P1-P3（SSOT）
# CONTRACT_AMBIGUOUS：
#   - 幂等由 watcher 自查与 notify.sh 双格式幂等兜底两层共同满足，本用例钉行为面（delta==0），
#     不钉具体层——任意层拦截均算设计满足
#   - 「当日」计数基准未钉（key 日期段 vs ts 日期段）：种入事件 ts 与 key 双口径同置冻结日 D，
#     两种读法下配额均满——防夹具歧义误伤实现
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树）；每断言硬失败；
#   无 skip；账本断言先 jq 归一化（双格式免疫：jq 紧凑 vs json.dumps 带空格）；
#   全程 sb_new 沙箱 + 影子 stub，零真实外发。
# Mental Mutation：幂等检查删除→I1 红（重复入账 delta=1）；幂等扩大成「每轮只 1 条」→I2 红；
#   旋钮不生效（配额永不拦）→Q2 红；旋钮误伤低级→Q3 红；旋钮缺省读法错（无键时非 2）→
#   t7-04 M2 红配对；配额只数本 PR→Q2/Q3 的跨 PR 种入（103202 计数、103201 触发）红。
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
write_view() {
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
ev_seed() { # <class> <key> <summary> — 种入「当日 D」事件（ts 与 key 双口径同日）
  jq -cn --arg ts "${D}T00:00:00+08:00" --arg cls "$1" --arg key "$2" --arg summary "$3" \
    '{ts:$ts, class:$cls, key:$key, channel:"contrib", summary:$summary, pushed:false, attempts:0, pushed_at:null}' \
    >>"$(ev_f)"
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
ev_new_blob() { ev_new_json | jq -r '.[] | ((.key // "") + " " + (.summary // ""))' 2>/dev/null | tr '\n' ' '; }
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
t_case "I1 场景6.P1 同 key 当日已存在 → 不重复入账（外部评论 1→2，key 已在账）"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 1 1)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2)"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob   # 2 条外部评论 → 当次 external_comments=2
ev_seed "own-pr-activity" "103201-comment-2-$D" "种入：同 key 事件当日已在账"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景6.P1 watcher 正常完成"
assert_eq "$(ev_delta)" "0" "场景6.P1 同 key 当日已存在 → 不重复入账"
art "6.P1" "delta=$(ev_delta)"
sb_cleanup

# =============================================================================
t_case "I2 场景6.P2 同日另一 PR 不同 key → 正常入账 1 条（幂等按 key 不按轮）"
common_setup
ev_seed "own-pr-activity" "103201-comment-9-$D" "种入：另一 PR 的当日事件"
seed_snapshot "$(pr_rec 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2 2)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103202 "$FRESH_TS" CONFLICTING REVIEW_REQUIRED 2)"   # 不同 PR、不同 key
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景6.P2 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景6.P2 不同 key 正常入账 1 条"
assert_contains "$(ev_new_blob)" "103202" "场景6.P2 新增行含 103202"
art "6.P2" "delta=$(ev_delta) blob=$(ev_new_blob)"
sb_cleanup

# =============================================================================
t_case "Q1 场景10.P1 own_pr_alert_per_day=1 且当日高级数为 0 → 首个外部评论变化入账 1 条"
common_setup
sb_config_set '.own_pr_alert_per_day = 1'
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 4)"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol dave
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景10.P1 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景10.P1 配额未满 → 高级事件入账 1 条"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-activity" "场景10.P1 class == own-pr-activity（高级）"
art "10.P1" "delta=$(ev_delta)"
sb_cleanup

# =============================================================================
t_case "Q2 场景10.P2 当日高级事件数 >= own_pr_alert_per_day(=1) → 高级类变化停发（零新增）"
common_setup
sb_config_set '.own_pr_alert_per_day = 1'
ev_seed "own-pr-activity" "103202-comment-9-$D" "种入：当日已有 1 条高级事件（跨 PR 计数）"
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 4)"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol dave   # 高级类变化（外部评论 3→4）
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景10.P2 watcher 正常完成（停发不等于失败）"
assert_eq "$(ev_delta)" "0" "场景10.P2 高级配额满 → 零新增"
art "10.P2" "delta=$(ev_delta)"
sb_cleanup

# =============================================================================
t_case "Q3 场景10.P3 当日高级已满 → 低级变化（mergeable 翻转）照常入账（含 103201）"
common_setup
sb_config_set '.own_pr_alert_per_day = 1'
ev_seed "own-pr-activity" "103202-comment-9-$D" "种入：当日已有 1 条高级事件（跨 PR 计数）"
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" CONFLICTING REVIEW_REQUIRED 3)"   # 低级类变化
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景10.P3 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景10.P3 低级事件照常入账"
assert_contains "$(ev_new_blob)" "103201" "场景10.P3 新增行含 103201"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-info" "场景10.P3 class == own-pr-info（低级不受限）"
art "10.P3" "delta=$(ev_delta) class=$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)"
sb_cleanup

t_finish
