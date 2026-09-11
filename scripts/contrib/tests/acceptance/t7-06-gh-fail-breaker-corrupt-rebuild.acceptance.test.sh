#!/usr/bin/env bash
# =============================================================================
# t7-06-gh-fail-breaker-corrupt-rebuild.acceptance.test.sh — T7 验收⑥：gh 失败断路 + 快照损坏重建
#   F0 前置：真实基线轮成功（快照由 watcher 写出，供 sha 对比与连败计数起算）
#   F1 场景8.P1 gh 第 1 次失败 → exit 1 + 快照 sha256 不变 + 零事件
#   F2 场景8.P2 连续第 2 次失败 → 恰 1 条流水线故障事件（class pipeline-failure、
#       key=<日期>-ownpr-watch-down、匹配 (?i)fail|pipeline、含 D）
#   F3 场景8.P3 连续第 3 次失败 → 故障事件日级幂等，零新增
#   F4 场景8.P4 中间夹一轮成功（无 diff）后再次单次失败 → 零故障事件（连败计数已清零）
#   F5 场景9.P1+P2 快照损坏（非法 JSON）→ exit 0 + 零事件 + 重建合法快照 + 留日志痕迹
#       （grep -Eic 'rebuild|corrupt|baseline' >= 1，observe=watcher 自有日志 ∪ stderr）
#   F6 场景9.P3 重建后的下一轮出现真实变化 → 正常检出入账（含 103201）
# 依据：state.md「## 设计文档」（任何 gh 调用失败 → 本轮中止：零快照写零事件 exit 1；连败计数
#   $CONTRIB/.ownpr-watch-fail 仅成功清零；连败恰达 2 → pipeline-failure event --key
#   <日期>-ownpr-watch-down（notify 幂等防第 3+ 次重复）；快照损坏（jq 解析失败）→ 重建基线：
#   exit 0 零事件 + 日志留痕 corrupt/rebuild 字样；自有日志 $CONTRIB/logs/own-pr-watch.log）
#   +「## 验收场景」场景 8.P1-P4、9.P1-P3（SSOT）
# CONTRACT_AMBIGUOUS：
#   - 场景8.P2 谓词断言为 (?i)fail|pipeline 正则；本用例加钉 design 字面（class==pipeline-failure、
#     key==<D>-ownpr-watch-down），若实现事件形态不同则红=交人审（设计文档已钉此二字面）
#   - 场景9.P2 observe 为「stderr 或沙箱日志文件」——按谓词自身的析取口径对两并集计数
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树）；每断言硬失败；
#   无 skip；账本断言先 jq 归一化（双格式免疫）；gh 失败经既有契约旋钮 STUB_GH_FAIL=1（既有
#   行为 byte 级保留）；全程 sb_new 沙箱 + 影子 stub，零真实外发。
# Mental Mutation：失败轮仍写快照→F1 sha 红；失败轮入账事件→F1 delta 红；连败计数丢失/成功
#   不清零→F2 红（恰 1）或 F4 红（清零失效）；故障事件 key 漏日期→F2 含 D 红；第 3+ 次重复
#   入账→F3 红；损坏重建发告警→F5 delta 红；重建不落日志→F5 痕迹断言红；重建后真实变化漏检
#   →F6 红。
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
watch_log_f() { printf '%s/contrib-data/logs/own-pr-watch.log' "$SB_ROOT"; }

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
ev_new_full_blob() { ev_new_json | jq -r '.[] | ((.class // "") + " " + (.key // "") + " " + (.summary // ""))' 2>/dev/null | tr '\n' ' '; }
sha_f() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
gh_stub_count() { grep -c '^gh|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
mark_log() { LOG_MARK="$(wc -l < "$SB_ROOT/stublog/calls.log" 2>/dev/null || printf 0)"; }
round_gh_calls() { tail -n "+$((LOG_MARK + 1))" "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c '^gh|' || true; }
run_watch_proc() { # $@: 额外 -e K=V（如 STUB_GH_FAIL=1）
  local -a extra=()
  if [ "$#" -gt 0 ]; then extra=("$@"); fi
  sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/tmp/prs.json" \
         -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
         -e "STUB_DATE_TODAY=$D" \
         ${extra[@]+"${extra[@]}"} \
         'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh"'
}
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mkdir -p "$SB_ROOT/tmp/views"
  install_date_stub
  return 0
}
seed_two_prs() {
  write_pr_list "$SB_ROOT/tmp/prs.json" \
    "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3)" \
    "$(pr_list_entry 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2)"
  write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol
  write_view "$SB_ROOT/tmp/views" 103202 OPEN alice bob
}
art() { mkdir -p /tmp/autopilot-artifacts && printf '%s\n' "$2" >"/tmp/autopilot-artifacts/场景$1.out"; }

# =============================================================================
t_case "F0 前置：真实基线轮成功（watcher 自写快照 + 零事件）"
common_setup
seed_two_prs
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "F0 基线轮 exit 0（场景1.P1 路径复用）"
assert_eq "$(ev_delta)" "0" "F0 基线轮零事件"
[[ -f "$(snap_f)" ]] && _pass "F0 快照已由 watcher 写出" || _fail "F0 快照已由 watcher 写出" "基线轮未写快照，sha 对比失去前提"
# 前置自证：gh stub 已接线且本轮被调（基线是否附带 stage-2 view 属未钉行为，只断言 >= 1）
GH_F0="$(stub_count gh)"
case "$GH_F0" in ''|*[!0-9]*) _fail "F0 前置自证：gh 被调" "非数值 [$GH_F0]" ;; *) [ "$GH_F0" -ge 1 ] && _pass "F0 前置自证：gh stage-1 被调（$GH_F0 次）" || _fail "F0 前置自证：gh 被调" "gh stub 零调用——沙箱注毒未生效" ;; esac

# =============================================================================
t_case "F1/F2/F3/F4 场景8 gh 失败断路：首败中止不写、连败 2 告警、3+ 幂等、成功清零"
# --- F1：第 1 次失败 ---
SHA_BEFORE="$(sha_f "$(snap_f)")"
assert_ne "$SHA_BEFORE" "" "F1 前置：快照 sha 可计算"
run_watch_proc -e "STUB_GH_FAIL=1" >/dev/null
RC=$?
assert_exit 1 "$RC" "场景8.P1 gh 第 1 次失败 → exit 1 中止本轮"
assert_eq "$(sha_f "$(snap_f)")" "$SHA_BEFORE" "场景8.P1 快照 sha256 轮前后相等（零快照写）"
assert_eq "$(ev_delta)" "0" "场景8.P1 零事件入账"
GH_ALL="$(gh_stub_count)"
case "$GH_ALL" in ''|*[!0-9]*) _fail "场景8.P1 前置自证" "非数值 [$GH_ALL]" ;; *) [ "$GH_ALL" -ge 2 ] && _pass "场景8.P1 前置自证：gh 失败真实发生（累计 gh 调用 ${GH_ALL}）" || _fail "场景8.P1 前置自证" "gh 未被调用，注毒未生效" ;; esac
art "8.P1" "exit=$RC sha_equal=$( [ "$(sha_f "$(snap_f)")" = "$SHA_BEFORE" ] && echo true || echo false ) delta=$(ev_delta)"

# --- F2：连续第 2 次失败 ---
ev_mark
run_watch_proc -e "STUB_GH_FAIL=1" >/dev/null
RC=$?
assert_exit 1 "$RC" "场景8.P2 第 2 次失败仍 exit 1"
assert_eq "$(ev_delta)" "1" "场景8.P2 恰入账 1 条流水线故障事件"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "pipeline-failure" "场景8.P2 class == pipeline-failure（设计字面）"
assert_eq "$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)" "$D-ownpr-watch-down" "场景8.P2 key == <日期>-ownpr-watch-down（设计字面）"
BLOB2="$(ev_new_full_blob)"
FAIL_N="$(printf '%s\n' "$BLOB2" | grep -Eic -- 'fail|pipeline' || true)"
case "$FAIL_N" in ''|*[!0-9]*) _fail "场景8.P2 匹配 (?i)fail|pipeline" "非数值 [$FAIL_N]" ;; *) [ "$FAIL_N" -ge 1 ] && _pass "场景8.P2 新增行匹配 (?i)fail|pipeline" || _fail "场景8.P2 匹配 (?i)fail|pipeline" "零命中" ;; esac
assert_contains "$BLOB2" "$D" "场景8.P2 新增行含冻结日 D"
art "8.P2" "delta=$(ev_delta) key=$(ev_new_json | jq -r '.[0].key // ""' 2>/dev/null)"

# --- F3：连续第 3 次失败（故障事件日级幂等） ---
ev_mark
run_watch_proc -e "STUB_GH_FAIL=1" >/dev/null
RC=$?
assert_exit 1 "$RC" "场景8.P3 第 3 次失败仍 exit 1"
assert_eq "$(ev_delta)" "0" "场景8.P3 故障事件日级幂等 → 零新增"
art "8.P3" "delta=$(ev_delta)"

# --- F4：中间夹一轮成功（无 diff）→ 计数清零；再单次失败 → 零故障事件 ---
seed_two_prs   # 与基线快照零 diff 的成功轮
mark_log
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景8.P4 中间成功轮 exit 0"
assert_eq "$(ev_delta)" "0" "场景8.P4 成功轮零事件"
GH_F4="$(round_gh_calls)"
case "$GH_F4" in ''|*[!0-9]*) _fail "场景8.P4 前置自证：成功轮 gh 被调" "非数值 [$GH_F4]" ;; *) [ "$GH_F4" -ge 1 ] && _pass "场景8.P4 前置自证：成功轮 gh 真实被调（$GH_F4 次，计数清零路径真实走过）" || _fail "场景8.P4 前置自证：成功轮 gh 被调" "成功轮零 gh 调用——清零自证失效" ;; esac
ev_mark
run_watch_proc -e "STUB_GH_FAIL=1" >/dev/null
RC=$?
assert_exit 1 "$RC" "场景8.P4 恢复后首败仍 exit 1"
assert_eq "$(ev_delta)" "0" "场景8.P4 连败计数已清零 → 单次失败零故障事件"
art "8.P4" "exit=$RC delta=$(ev_delta)"
sb_cleanup

# =============================================================================
t_case "F5 场景9.P1+P2 快照损坏 → exit 0 + 零事件 + 重建合法快照 + 日志痕迹"
common_setup
seed_two_prs
printf 'THIS IS NOT JSON {{{ broken' >"$(snap_f)"
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景9.P1 损坏快照 → exit 0（重建基线非失败）"
assert_eq "$(ev_delta)" "0" "场景9.P1 重建基线零事件"
JQ_OK="$(jq -e . "$(snap_f)" >/dev/null 2>&1 && printf yes || printf no)"
assert_eq "$JQ_OK" "yes" "场景9.P1 重建后快照 jq 解析成功"
assert_eq "$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)" "true" "场景9.P1 重建快照含 103201"
assert_eq "$(jq -r '.prs | has("103202")' "$(snap_f)" 2>/dev/null)" "true" "场景9.P1 重建快照含 103202"
LOG_N="$( { cat "$(watch_log_f)" 2>/dev/null; cat "$SB_ROOT/last-run.out" 2>/dev/null; } | grep -Eic -- 'rebuild|corrupt|baseline' || true )"
case "$LOG_N" in
  ''|*[!0-9]*) _fail "场景9.P2 日志痕迹 >= 1" "非数值 [$LOG_N]" ;;
  *) [ "$LOG_N" -ge 1 ] && _pass "场景9.P2 留下日志痕迹（rebuild|corrupt|baseline 命中 ${LOG_N}）" \
     || _fail "场景9.P2 日志痕迹 >= 1" "watcher 自有日志与 stderr 均无 rebuild|corrupt|baseline 字样（静默重建无痕）" ;;
esac
art "9.P1" "exit=$RC jq=$JQ_OK delta=$(ev_delta)"
art "9.P2" "log_hits=$LOG_N"
sb_cleanup

# =============================================================================
t_case "F6 场景9.P3 重建后的下一轮出现真实变化 → 正常检出并入账（含 103201）"
common_setup
seed_two_prs
printf 'CORRUPTED SNAPSHOT ###' >"$(snap_f)"
run_watch_proc >/dev/null   # 重建基线轮
[[ -f "$(snap_f)" ]] && _pass "F6 前置：基线已重建" || _fail "F6 前置：基线已重建" "重建失败，下一轮比较失去前提"
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" CONFLICTING REVIEW_REQUIRED 3)" \
  "$(pr_list_entry 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2)"   # 真实变化：103201 翻转
ev_mark
run_watch_proc >/dev/null
RC=$?
assert_exit 0 "$RC" "场景9.P3 下一轮 exit 0"
assert_eq "$(ev_delta)" "1" "场景9.P3 真实变化正常入账 1 条"
assert_contains "$(ev_new_blob)" "103201" "场景9.P3 新增行含 103201"
assert_eq "$(ev_new_json | jq -r '.[0].class // ""' 2>/dev/null)" "own-pr-info" "场景9.P3 class == own-pr-info（mergeable 翻转）"
art "9.P3" "delta=$(ev_delta) blob=$(ev_new_blob)"
sb_cleanup

t_finish
