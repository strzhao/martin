#!/usr/bin/env bash
# =============================================================================
# t7-01-first-run-baseline.acceptance.test.sh — T7 验收①：首跑建基线（红队，仅依据设计文档）
#   B1 场景1.P1 [real-process] 无快照 + gh 返回 2 个 open PR → own_pr_watch.sh exit 0
#   B2 场景1.P2 写出自有新快照：契约文件名 own-pr-watch-snapshot.json（≠ assets-snapshot.json）、
#       jq 可解析、含 103201 与 103202
#   B3 场景1.P3 每个 PR 记录同时含 updatedAt/mergeable/reviewDecision/comments 四字段
#   B4 场景1.P4 首跑（无上一份快照可比）零事件：events.jsonl 行数差 == 0
#   B5 契约#1 锚：未知子命令 → exit 2（用法错误）〔CONTRACT_AMBIGUOUS，见下〕
#   B6 契约#2 锚：原子写（tmp+mv）→ 轮后无 own-pr-watch-snapshot.json.tmp* 残留
# 依据：state.md「## 设计文档」（快照 schema/路径 $CONTRIB/own-pr-watch-snapshot.json；exit 语义
#   闭集 0=正常完成含基线轮；「新出现 PR → 基线吸收零事件（含首跑全量建基线）」；原子写 tmp+mv）
#   +「## 验收场景」场景 1.P1-P4（SSOT，期望值字面量取自谓词 assert 字段）
# CONTRACT_AMBIGUOUS：
#   - B5 exit 2 触发面：设计只钉「2=用法错误」+「单发无子命令」，未钉 argv 闭集——本用例取
#     「携带任何子命令即用法错误」读法；若实现选择忽略 argv（exit 0），本用例红 = 交人审裁决
#   - 「文件名 != assets-snapshot.json」按契约文件名逐字断言 own-pr-watch-snapshot.json 落在
#     契约路径；assets 零触碰的 sha 级断言在 t7-07（场景12.P4）
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 stubs gh、date 当前工作树；seam 名取自设计
#   改动面表逐字）；每断言硬失败；无 skip；全部轮次在 sb_new 沙箱 + 影子 stub 内运行，
#   绝不真调 gh/hermes/claude，绝不触真实 contrib-data。
# Mental Mutation：删快照写入→B2 红（no-op 实现「快照不存在类断言必红」）；写错文件名/写进
#   assets-snapshot.json→B2 红；快照缺四字段之一→B3 红；首跑入账事件→B4 红；tmp 直写不 mv→B6 红；
#   用法错误回退 exit 0/1→B5 红。
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

D="2027-06-01"                    # 冻结同日 D（≠真实今日：含 D 的断言对「date stub 未接线」突变敏感）
FRESH_TS="2027-05-30T00:00:00Z"   # 距 D 2 天（非停滞）；距真实今日为负龄——双时钟读法均 fresh
SNAP_NAME="own-pr-watch-snapshot.json"   # 契约文件名（逐字）
EV_MARK=0

snap_f() { printf '%s/contrib-data/%s' "$SB_ROOT" "$SNAP_NAME"; }
ev_f()   { printf '%s/contrib-data/events.jsonl' "$SB_ROOT"; }

pr_rec() { # <n> <updatedAt> <mergeable> <reviewDecision> <comments> <external_comments> → 契约 schema 记录
  jq -cn --arg n "$1" --arg u "$2" --arg m "$3" --arg r "$4" --argjson c "$5" --argjson e "$6" \
    '{number:($n|tonumber), updatedAt:$u, mergeable:$m, reviewDecision:$r, comments:$c, external_comments:$e}'
}
pr_list_entry() { # <n> <updatedAt> <mergeable> <reviewDecision> <comments(int)> → pr list 数组元素
  # comments 镜像生产数组形态（qa-reviewer 09-10：真实 gh pr list comments 是数组）
  # <6>可选 authors-csv：缺省 strzhao×count（行 extn=0，与标量时代行为一致）
  jq -cn --argjson n "$1" --arg u "$2" --arg m "$3" --arg r "$4" --argjson c "$5" --arg a "${6:-}" \
    '{number:$n, updatedAt:$u, mergeable:$m, reviewDecision:$r,
      comments: (if $a == "" then (reduce range(0; $c) as $i ([]; . + [{author: {login: "strzhao"}}]))
                 else ($a | split(",") | map(select(length > 0)) | map({author: {login: .}})) end)}'
}
write_pr_list() { # <file> <entry...>
  local f="$1" arr="[]" e
  shift
  for e in "$@"; do arr="$(printf '%s' "$arr" | jq -c --argjson o "$e" '. + [$o]')"; done
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$arr" >"$f"
}
write_view() { # <dir> <pr> <state> <author-login...> — gh pr view <N> 影子数据（契约：pr-<N>.json）
  local dir="$1" pr="$2" st="$3" cmts="[]" a
  shift 3
  for a in "$@"; do cmts="$(printf '%s' "$cmts" | jq -c --arg a "$a" '. + [{author:{login:$a}}]')"; done
  mkdir -p "$dir"
  jq -cn --argjson n "$pr" --arg st "$st" --argjson c "$cmts" \
    '{number:$n, state:$st, reviewDecision:null, comments:$c}' >"$dir/pr-$pr.json"
}
install_date_stub() { # 契约夹具 tests/stubs/date（STUB_DATE_TODAY 劫持裸 +%F/+%H）→ 沙箱 bin/ + $HOME/.local/bin
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
run_watch_proc() { # 直接跑 own_pr_watch.sh —— 镜像生产调用形态（bash 显式调，契约#7）
  sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/tmp/prs.json" \
         -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
         -e "STUB_DATE_TODAY=$D" \
         'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh"'
}
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mkdir -p "$SB_ROOT/tmp/views"
  install_date_stub
  write_pr_list "$SB_ROOT/tmp/prs.json" \
    "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3)" \
    "$(pr_list_entry 103202 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 2)"
  # 防御性提供 view 影子数据：基线吸收若走 stage-2 也不致 gh 失败（不影响 B1-B4 断言面）
  write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol
  write_view "$SB_ROOT/tmp/views" 103202 OPEN alice bob
  return 0
}
art() { mkdir -p /tmp/autopilot-artifacts && printf '%s\n' "$2" >"/tmp/autopilot-artifacts/场景$1.out"; }

# =============================================================================
t_case "B1/B2/B3/B4/B6 首跑建基线：exit 0 + 契约快照四字段 + 零事件 + 无 tmp 残留"
common_setup
ev_mark
run_watch_proc >/dev/null
RC=$?
art "1.P1" "exit=$RC"
assert_exit 0 "$RC" "场景1.P1 首跑退出 0（完整一轮盯梢）"

# 场景1.P2：自有新快照落盘（存在 ∧ 契约文件名 ≠ assets-snapshot.json ∧ jq 解析成功 ∧ 含两 PR）
if [[ -f "$(snap_f)" ]]; then
  _pass "场景1.P2 快照文件存在（契约路径 ${SNAP_NAME}）"
else
  _fail "场景1.P2 快照文件存在" "契约路径无快照（删快照写入突变 / no-op 实现必红）"
fi
assert_ne "$(basename "$(snap_f)")" "assets-snapshot.json" "场景1.P2 快照文件名 ≠ assets-snapshot.json"
JQ_OK="$(jq -e . "$(snap_f)" >/dev/null 2>&1 && printf yes || printf no)"
assert_eq "$JQ_OK" "yes" "场景1.P2 快照 jq 解析成功"
assert_eq "$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)" "true" "场景1.P2 快照含 103201"
assert_eq "$(jq -r '.prs | has("103202")' "$(snap_f)" 2>/dev/null)" "true" "场景1.P2 快照含 103202"
art "1.P2" "exists=$( [[ -f $(snap_f) ]] && echo true || echo false ) jq=$JQ_OK"

# 场景1.P3：每 PR 记录同时含 updatedAt/mergeable/reviewDecision/comments 四字段
K201="$(jq -r '.prs["103201"] | [has("updatedAt"),has("mergeable"),has("reviewDecision"),has("comments")] | join(",")' "$(snap_f)" 2>/dev/null)"
K202="$(jq -r '.prs["103202"] | [has("updatedAt"),has("mergeable"),has("reviewDecision"),has("comments")] | join(",")' "$(snap_f)" 2>/dev/null)"
assert_eq "$K201" "true,true,true,true" "场景1.P3 103201 记录含 updatedAt/mergeable/reviewDecision/comments"
assert_eq "$K202" "true,true,true,true" "场景1.P3 103202 记录含 updatedAt/mergeable/reviewDecision/comments"
art "1.P3" "103201=$K201 103202=$K202"

# 场景1.P4：首跑零事件
assert_eq "$(ev_delta)" "0" "场景1.P4 首跑 events.jsonl 行数差 == 0"
art "1.P4" "delta=$(ev_delta)"

# 契约#2 锚：原子写 tmp+mv → 无 tmp 残留
N_TMP="$(find "$SB_ROOT/contrib-data" -maxdepth 1 -name 'own-pr-watch-snapshot.json.tmp*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$N_TMP" "0" "契约#2 原子写：轮后无 own-pr-watch-snapshot.json.tmp* 残留"
sb_cleanup

# =============================================================================
t_case "B5 未知子命令 → exit 2（契约#1 用法错误；CONTRACT_AMBIGUOUS：argv 闭集未钉，红=交人审）"
common_setup
sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/tmp/prs.json" \
  -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
  -e "STUB_DATE_TODAY=$D" \
  'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh" bogus-subcommand' >/dev/null 2>&1
RC=$?
assert_exit 2 "$RC" "契约#1 未知子命令 → exit 2（用法错误）"
sb_cleanup

t_finish
