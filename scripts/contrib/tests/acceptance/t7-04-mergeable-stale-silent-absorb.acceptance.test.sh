#!/usr/bin/env bash
# =============================================================================
# t7-04-mergeable-stale-silent-absorb.acceptance.test.sh — T7 验收④：低级事件 / UNKNOWN 静默 /
#   reviewDecision 静默吸收 / 停滞检测（高级配额满不抑制低级）
#   M1 场景4.P1 mergeable 在两个具体值间翻转（CONFLICTING→MERGEABLE）→ 恰 1 条 own-pr-info
#       （精确类串，防类互换）含 103201
#   M2 场景4.P2 当日高级事件已达上限（默认 own_pr_alert_per_day=2，种入 2 条跨 PR 高级事件）
#       → mergeable 翻转仍入账低级事件
#   M3 场景4.P3 updatedAt 龄超停滞阈值且无其他 diff（且高级配额满）→ 恰 1 条低级停滞事件
#       匹配 (?i)stale|age(d|ing)
#   M4 场景5.P1 mergeable 具体值→UNKNOWN → 零事件 + 快照吸收 UNKNOWN
#   M5 场景5.P2 mergeable UNKNOWN→具体值 → 零事件（快照吸收 MERGEABLE）
#   M6 场景5.P3 具体值↔具体值翻转（与 UNKNOWN 无关）→ 正常入账 1 条
#   M7 场景14.P1 仅 reviewDecision 变化 → exit 0 + 快照吸收 APPROVED
#   M8 场景14.P2 仅 reviewDecision 变化 → 新增行中匹配 (?i)comment|merge|clos 的行数 == 0
# 依据：state.md「## 设计文档」（mergeable 已知值间翻转→低级；任何含 UNKNOWN 的翻转→静默、快照
#   吸收；无 diff 且 updatedAt 龄 > stale_pr_days(config,默认10) → 低级停滞；低级 = own-pr-info
#   非 is_mechanical；低级不受子上限限）+「## 验收场景」场景 4.P1-P3、5.P1-P3、14.P1-P2（SSOT）
# CONTRACT_AMBIGUOUS：
#   - mergeable 具体值闭集按语义备注映射 MERGEABLE/CONFLICTING（UNKNOWN=瞬态）；翻转方向双向覆盖
#   - 停滞阈值经 config stale_pr_days（沙箱种子=10）+ 冻结日 D 双时钟设计：fresh updatedAt 距 D
#     2 天、距真实今日为负龄——任何一种龄值算法下均 < 阈值；stale 样本两种算法下均 > 阈值
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树）；每断言硬失败；
#   无 skip；账本断言先 jq 归一化（双格式免疫）；配额种入事件用 ts 与 key 双口径同日（防计数
#   基准歧义单边漏判）；全程 sb_new 沙箱 + 影子 stub，零真实外发。
# Mental Mutation：低级误发高级→M1/M2/M3 class 断言红；UNKNOWN 翻转发事件→M4/M5 delta 红；
#   UNKNOWN 不吸收进快照→M4 红 LOW 值翻转零事件化→M6 红；停滞检测删除→M3 红；停滞被高级
#   配额抑制→M3 红（预置配额满）；reviewDecision 变化发终态/评论语义事件→M8 红；不吸收
#   reviewDecision→M7 红。
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
FRESH_TS="2027-05-30T00:00:00Z"   # 距 D 2 天 / 距真实今日负龄 —— 双时钟读法均非停滞
STALE_TS="2026-01-01T00:00:00Z"   # 距 D 517 天 / 距真实今日 252 天 —— 双时钟读法均停滞
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
ev_seed() { # <class> <key> <summary> — 种入「当日 D」事件：ts 与 key 双口径同为冻结日
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
ev_new_lines_blob() { ev_new_json | jq -r '.[] | ((.key // "") + " " + (.summary // ""))' 2>/dev/null; }
num_ge() { # <actual> <min> <label>
  case "$1" in ''|*[!0-9]*) _fail "$3" "非数值 [$1]" ;; *) [ "$1" -ge "$2" ] && _pass "$3" || _fail "$3" "实得 $1 < 期望 >= $2" ;; esac
}
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
  write_view "$SB_ROOT/tmp/views" 103201 OPEN alice   # 防御性 view 影子（不触发 stage-2 也不失败）
  return 0
}
art() { mkdir -p /tmp/autopilot-artifacts && printf '%s\n' "$2" >"/tmp/autopilot-artifacts/场景$1.out"; }

# =============================================================================
t_case "M1 场景4.P1 mergeable 具体值间翻转（CONFLICTING→MERGEABLE）→ 恰 1 条 own-pr-info"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" CONFLICTING REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景4.P1 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景4.P1 恰 1 条事件"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-info" "场景4.P1 class == own-pr-info（精确串，防类互换突变）"
assert_contains "$(ev_new_lines_blob)" "103201" "场景4.P1 新增行含 103201"
art "4.P1" "delta=$(ev_delta) class=$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)"
sb_cleanup

# =============================================================================
t_case "M2 场景4.P2 当日高级事件已达上限（2）→ mergeable 翻转仍入账低级事件"
common_setup
ev_seed "own-pr-activity" "103202-comment-7-$D" "seed 高级事件 1（跨 PR 计数）"
ev_seed "own-pr-activity" "103202-comment-8-$D" "seed 高级事件 2（跨 PR 计数）"
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" CONFLICTING REVIEW_REQUIRED 3)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景4.P2 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景4.P2 高级配额满仍入账 1 条（低级不受限）"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-info" "场景4.P2 class == own-pr-info"
art "4.P2" "delta=$(ev_delta) class=$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)"
sb_cleanup

# =============================================================================
t_case "M3 场景4.P3 updatedAt 停滞超阈值且无其他 diff（配额满）→ 1 条低级停滞事件"
common_setup
ev_seed "own-pr-activity" "103202-comment-7-$D" "seed 高级事件 1（配额满前置）"
ev_seed "own-pr-activity" "103202-comment-8-$D" "seed 高级事件 2（配额满前置）"
seed_snapshot "$(pr_rec 103201 "$STALE_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$STALE_TS" MERGEABLE REVIEW_REQUIRED 3)"   # 除 updatedAt 龄外零 diff
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景4.P3 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景4.P3 恰 1 条停滞事件（不被高级配额满抑制）"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-info" "场景4.P3 class == own-pr-info"
STALE_N="$(ev_new_lines_blob | grep -Eic -- 'stale|age(d|ing)' || true)"
num_ge "$STALE_N" 1 "场景4.P3 新增行匹配 (?i)stale|age(d|ing)"
art "4.P3" "delta=$(ev_delta) class=$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null) blob=$(ev_new_lines_blob | tr '\n' ' ')"
sb_cleanup

# =============================================================================
t_case "M4 场景5.P1 mergeable 具体值→UNKNOWN → 零事件 + 快照吸收 UNKNOWN"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" UNKNOWN REVIEW_REQUIRED 3)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景5.P1 watcher 正常完成"
assert_eq "$(ev_delta)" "0" "场景5.P1 含 UNKNOWN 的翻转零事件"
assert_eq "$(jq -r '.prs["103201"].mergeable' "$(snap_f)" 2>/dev/null)" "UNKNOWN" "场景5.P1 快照已吸收 UNKNOWN"
art "5.P1" "delta=$(ev_delta) mergeable=$(jq -r '.prs["103201"].mergeable' "$(snap_f)" 2>/dev/null)"
sb_cleanup

# =============================================================================
t_case "M5 场景5.P2 mergeable UNKNOWN→具体值 → 零事件（快照吸收 MERGEABLE）"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" UNKNOWN REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景5.P2 watcher 正常完成"
assert_eq "$(ev_delta)" "0" "场景5.P2 UNKNOWN→具体值零事件"
assert_eq "$(jq -r '.prs["103201"].mergeable' "$(snap_f)" 2>/dev/null)" "MERGEABLE" "场景5.P2 快照吸收具体值（静默）"
art "5.P2" "delta=$(ev_delta)"
sb_cleanup

# =============================================================================
t_case "M6 场景5.P3 具体值↔具体值翻转（MERGEABLE→CONFLICTING）→ 正常入账 1 条"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" CONFLICTING REVIEW_REQUIRED 3)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景5.P3 watcher 正常完成"
assert_eq "$(ev_delta)" "1" "场景5.P3 与 UNKNOWN 无关的具体值翻转入账 1 条"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-info" "场景5.P3 class == own-pr-info（低级）"
art "5.P3" "delta=$(ev_delta)"
sb_cleanup

# =============================================================================
t_case "M7/M8 场景14.P1+P2 仅 reviewDecision 变化 → exit 0 + 吸收 APPROVED + 零终态/评论语义事件"
common_setup
seed_snapshot "$(pr_rec 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3 3)"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE APPROVED 3)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景14.P1 exit 0"
assert_eq "$(jq -r '.prs["103201"].reviewDecision' "$(snap_f)" 2>/dev/null)" "APPROVED" "场景14.P1 快照（103201 关联记录）吸收 APPROVED"
assert_eq "$(ev_delta)" "0" "场景14.P2 零新增行（静默吸收）"
SEM_N="$(ev_new_lines_blob | grep -Eic -- 'comment|merge|clos' || true)"
assert_eq "$SEM_N" "0" "场景14.P2 新增行中匹配 (?i)comment|merge|clos 的行数 == 0"
art "14.P1" "exit=$RC reviewDecision=$(jq -r '.prs["103201"].reviewDecision' "$(snap_f)" 2>/dev/null)"
art "14.P2" "delta=$(ev_delta) sem_lines=$SEM_N"
sb_cleanup

t_finish
