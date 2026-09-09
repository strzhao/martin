#!/usr/bin/env bash
# =============================================================================
# t7-07-config-knobs-redline.acceptance.test.sh — T7 验收⑦：config 旋钮落盘 + 红线（零 gh 写 /
#   零 LLM / 零网络写 / assets-snapshot.json 零触碰）
#   G1 场景11.P1 配置含 own_pr_alert_per_day 且值 == 2
#   G2 场景11.P2 全局微信告警日额度 max_alert_pushes_per_day == 30
#   R1 场景12.P1 任意一轮 gh argv 零写子命令（token 锚定闭集 grep == 0，argv 段经 awk $3 求值）
#   R2 场景12.P2 零 LLM 调用（calls.log grep -Eic 'claude|llm|deepseek|openai' == 0）
#   R3 场景12.P3 零网络写（grep -Ec 'hermes.*send|curl|wget' == 0）
#   R4 场景12.P4 全部轮次 assets-snapshot.json sha256 不变 + 存在另一新快照文件（契约名）
# 依据：state.md「## 设计文档」（config 两键 own_pr_alert_per_day=2 / max_alert_pushes_per_day
#   3→30；红线：零 LLM / 零 gh 写（只 pr list + pr view 只读）/ 零 push / 零评论 / 零 hermes
#   send / 不动 assets-snapshot.json；契约#6 测试以 calls.log 调用面闭集断言）+「## 验收场景」
#   场景 11.P1-P2、12.P1-P4（SSOT，12.P1 的 grep 模式逐字取自谓词）
# CONTRACT_AMBIGUOUS：
#   - 场景11 observe「contrib-data/config.json」未区分生产本机数据文件与测试沙箱种子——本套件
#     红线（不触真实 contrib-data）下取沙箱种子面（sb_seed_data），即设计改动面表
#     「contrib-data/config.json 改 + 沙箱种子 config（sb_new）同步补键」的可复现契约面；
#     生产本机文件（gitignore）不在此测，交付时人工核对
#   - 场景12「任意一轮」取两轮复合面：基线轮 + 差异轮（外部评论 stage-2 view + 终态剪枝 +
#     notify event 入账），使命中面最大化后再断言零写
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树）；每断言硬失败；
#   无 skip；全程 sb_new 沙箱 + 影子 stub，零真实外发。
# Mental Mutation：加 gh 写子命令（pr comment/close/merge 等）→R1 token 闭集红；绕道 -X POST
#   →R1 同式红；偷调 claude/LLM→R2 红；直接 hermes send/curl 推微信→R3 红；写 assets-snapshot
#   →R4 sha 红；不写自有快照→R4 存在性红；no-op（零调用零写零事件）→R1/R2/R3 前置自证
#   （gh 调用 >= 3）红——防「恒绿空壳」。
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
ASSETS_NAME="assets-snapshot.json"
EV_MARK=0

snap_f()     { printf '%s/contrib-data/%s' "$SB_ROOT" "$SNAP_NAME"; }
assets_f()   { printf '%s/contrib-data/%s' "$SB_ROOT" "$ASSETS_NAME"; }
ev_f()       { printf '%s/contrib-data/events.jsonl' "$SB_ROOT"; }
calls_log_f(){ printf '%s/stublog/calls.log' "$SB_ROOT"; }

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
ev_delta() {
  local n
  n="$(wc -l < "$(ev_f)" 2>/dev/null || printf 0)"
  printf '%d' $(( n - EV_MARK ))
}
sha_f() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
num_ge() {
  case "$1" in ''|*[!0-9]*) _fail "$3" "非数值 [$1]" ;; *) [ "$1" -ge "$2" ] && _pass "$3" || _fail "$3" "实得 $1 < 期望 >= $2" ;; esac
}
run_watch_proc() {
  sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/tmp/prs.json" \
         -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
         -e "STUB_DATE_TODAY=$D" \
         'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh"'
}
art() { mkdir -p /tmp/autopilot-artifacts && printf '%s\n' "$2" >"/tmp/autopilot-artifacts/场景$1.out"; }

# =============================================================================
t_case "G1/G2 场景11 config 旋钮落盘：own_pr_alert_per_day==2 且 max_alert_pushes_per_day==30"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
CFG="$SB_ROOT/contrib-data/config.json"
[[ -f "$CFG" ]] && _pass "G 前置：沙箱种子 config 存在" || _fail "G 前置：沙箱种子 config 存在" "sb_seed_data 未产出 config.json"
KNOB="$(jq -r '.own_pr_alert_per_day' "$CFG" 2>/dev/null)"
assert_eq "$KNOB" "2" "场景11.P1 own_pr_alert_per_day == 2"
ALERT="$(jq -r '.max_alert_pushes_per_day' "$CFG" 2>/dev/null)"
assert_eq "$ALERT" "30" "场景11.P2 max_alert_pushes_per_day == 30"
art "11.P1" "own_pr_alert_per_day=$KNOB"
art "11.P2" "max_alert_pushes_per_day=$ALERT"
sb_cleanup

# =============================================================================
t_case "R1-R4 场景12 红线：基线轮+差异轮复合面上零 gh 写/零 LLM/零网络写/assets 零触碰"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp/views"
install_date_stub
# R4 前置：既有 assets-snapshot.json（radar LLM 快照占位）+ 已知 sha
printf '{"generated_at":"2026-01-01T00:00:00Z","days":{}}\n' >"$(assets_f)"
ASSETS_SHA_BEFORE="$(sha_f "$(assets_f)")"
assert_ne "$ASSETS_SHA_BEFORE" "" "R4 前置：assets sha 可计算"
# 轮 A：基线（103201/103202 两 PR 全量建基线）
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3)" \
  "$(pr_list_entry 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2)"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol
write_view "$SB_ROOT/tmp/views" 103202 OPEN alice bob
EV_MARK="$(wc -l < "$(ev_f)" 2>/dev/null || printf 0)"
run_watch_proc >/dev/null
RC_A=$?
assert_exit 0 "$RC_A" "场景12 轮 A（基线）exit 0"
# 轮 B：差异面最大化——外部评论（stage-2 view + notify event 入账）+ 终态消失（MERGED 剪枝）
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 4)"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol dave
write_view "$SB_ROOT/tmp/views" 103202 MERGED alice
run_watch_proc >/dev/null
RC_B=$?
assert_exit 0 "$RC_B" "场景12 轮 B（差异）exit 0"
num_ge "$(ev_delta)" 2 "场景12 前置自证：差异轮真实入账（delta=$(ev_delta)）——防 no-op 恒绿"
num_ge "$(grep -c '^gh|' "$(calls_log_f)" 2>/dev/null || true)" 3 "场景12 前置自证：gh 调用面 >= 3（list+view+list）"

# R1 场景12.P1：gh argv 段（awk 按竖线取第 3 段，整行含 gh|cwd| 前缀须对裸 argv 求值）零写子命令
GH_ARGV="$(awk -F'|' '$1=="gh"{print $3}' "$(calls_log_f)" 2>/dev/null)"
W_N="$(printf '%s\n' "$GH_ARGV" | grep -Ec '(^| )(pr|issue|repo|release) (create|edit|delete|close|reopen|merge|comment|lock|label)( |$)|-X *(POST|PATCH|PUT|DELETE)' || true)"
assert_eq "$W_N" "0" "场景12.P1 gh argv 零写子命令（token 锚定闭集命中 0）"
art "12.P1" "write_hits=$W_N gh_lines=$(grep -c '^gh|' "$(calls_log_f)" 2>/dev/null || true)"

# R2 场景12.P2：零 LLM
LLM_N="$(grep -Eic 'claude|llm|deepseek|openai' "$(calls_log_f)" 2>/dev/null || true)"
assert_eq "$LLM_N" "0" "场景12.P2 零 LLM 调用（claude|llm|deepseek|openai 命中 0）"
art "12.P2" "llm_hits=$LLM_N"

# R3 场景12.P3：零网络写（不直接推微信）
NET_N="$(grep -Ec 'hermes.*send|curl|wget' "$(calls_log_f)" 2>/dev/null || true)"
assert_eq "$NET_N" "0" "场景12.P3 零网络写（hermes send|curl|wget 命中 0）"
art "12.P3" "net_hits=$NET_N"

# R4 场景12.P4：assets 零触碰 + 自有新快照存在（≠ assets）
assert_eq "$(sha_f "$(assets_f)")" "$ASSETS_SHA_BEFORE" "场景12.P4 assets-snapshot.json sha256 前后相等"
assert_eq "$(jq -e . "$(assets_f)" >/dev/null 2>&1 && printf yes || printf no)" "yes" "场景12.P4 assets 文件仍合法 JSON（未被截断/覆写）"
[[ -f "$(snap_f)" ]] && _pass "场景12.P4 存在另一新快照文件（own-pr-watch-snapshot.json）" \
  || _fail "场景12.P4 存在另一新快照文件" "自有快照缺失——写入面突变"
assert_ne "$(basename "$(snap_f)")" "assets-snapshot.json" "场景12.P4 新快照文件名 != assets-snapshot.json"
art "12.P4" "assets_unchanged=$( [ "$(sha_f "$(assets_f)")" = "$ASSETS_SHA_BEFORE" ] && echo true || echo false )"
sb_cleanup

t_finish
