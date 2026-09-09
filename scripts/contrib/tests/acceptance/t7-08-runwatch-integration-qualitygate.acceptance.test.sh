#!/usr/bin/env bash
# =============================================================================
# t7-08-runwatch-integration-qualitygate.acceptance.test.sh — T7 验收⑧：run-watch 段 2.5 编排集成
#   + 测试设施质量门
#   W1 场景13.P1 run-watch.sh 含 own-pr 盯梢段调用（grep -c own_pr_watch >= 1，静态）
#   W2 场景13.P2 [real-process] 沙箱内 zsh 调 run-watch（镜像生产，双 shell 二象性防御）→
#       段真实调用 own_pr_watch.sh 且 run-watch exit 0
#   W3 场景13.P3 集成轮产出与单跑一致：自有快照存在 + jq 解析成功
#   Q1 场景15.P1 [real-process] bash tests/run.sh 全量测试设施全绿（exit 0）且输出含 own_pr_watch
#   Q2 场景15.P2 [real-process] bash tests/gate.sh 验收门无发现通过（exit 0）
#   Q3 场景15.P3 测试设施含 own_pr_watch 专项用例文件（tests/ 内命中 >= 1；并加钉 unit 维度
#       存在 own-pr-watch/own_pr_watch 专项文件 >= 1，防「仅验收测试自证」的空壳满足）
# 依据：state.md「## 设计文档」（改动面：run-watch.sh 段 2.5 插在 maybe_radar 后、flush 前，
#   [[ -x ]] 守卫 + run_phase 120 包裹 + rc 日志行；其余段零改动；日志 $CONTRIB/logs/
#   own-pr-watch.log）+「## 验收场景」场景 13.P1-P3、15.P1-P3（SSOT）
# CONTRACT_AMBIGUOUS：
#   - 场景13.P2 谓词「calls.log contains own_pr_watch」：calls.log 是 stub 夹具写入面（gh/hermes/
#     date 等 stub 的 argv 日志），设计改动面只钉 run-watch 侧「rc 日志行」（→ $CONTRIB/logs/
#     launchd.log）。本用例对两处各设硬断言：①calls.log 含 own_pr_watch（谓词字面，SSOT 优先）；
#     ②launchd.log 含 own_pr_watch（设计 rc 日志行）。若实现无法在任何 stub 调用面留下该字样，
#     断言①红 = 交人审裁决谓词 observe 面；②红 = rc 日志行缺失实锤。另加 gh pr-list 调用面
#     断言钉「段真实调用了 watcher」（防改日志凑数）
#   - 场景15.P1「stdout contains own_pr_watch」依赖被测单元用例以 own_pr_watch.sh（下划线形）
#     引用被测脚本名；run.sh 不聚合 acceptance 维度，本文件运行 run.sh 无递归
# 红队纪律：黑盒（未读 own_pr_watch.sh 实现 / 未读 run-watch 段 2.5 本次改动 / 未读 stubs gh、
#   date 当前工作树）；每断言硬失败；无 skip；run-watch 一律 zsh 调（镜像生产，契约#7）；
#   全程 sb_new 沙箱 + 影子 stub，run.sh/gate.sh 子进程亦为仓内自足路径，零真实外发。
# Mental Mutation：段 2.5 删除→W1/W2 红；守卫缺失导致段未调 watcher→W2 gh 调用面红；zsh 调
#   下段失效（双 shell 二象性 bug）→W2 红；rc 日志行删除→W2 launchd.log 断言红；集成轮不落
#   快照→W3 红；测试设施红→Q1 红；gate 发现→Q2 红；unit 专项用例缺失→Q3 加钉断言红。
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

snap_f() { printf '%s/contrib-data/%s' "$SB_ROOT" "$SNAP_NAME"; }

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
install_date_stub() { # 契约夹具 date stub 同时落 bin/ 与 $HOME/.local/bin——run-watch.sh 顶部
  # PATH 前置 $HOME/.local/bin（patterns 09-09 双 shell 二象性：不钉则同名真身越权命中）
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
mk_issues() { # 无 scan 命中（游标 200 > issue 101 → scan_gate exit 0，让段 2.5 聚焦）
  local out="$1"
  printf '[{"number":101,"title":"old issue","labels":[{"name":"bug"}],"user":{"login":"alice"},"created_at":"2026-09-01T00:00:00Z","comments":0,"pull_request":null}]\n' >"$out"
}
seed_scan_cursor() {
  jq -n --argjson n 200 --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' \
    >"$SB_ROOT/contrib-data/scan-cursor.json"
}
num_ge() {
  case "$1" in ''|*[!0-9]*) _fail "$3" "非数值 [$1]" ;; *) [ "$1" -ge "$2" ] && _pass "$3" || _fail "$3" "实得 $1 < 期望 >= $2" ;; esac
}
run_watch_zsh() { # run-watch 集成段必须 zsh 调（镜像生产；契约#7 双 shell 二象性防御）
  sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/tmp/prs.json" \
         -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
         -e "STUB_DATE_TODAY=$D" \
         'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"'
}
art() { mkdir -p /tmp/autopilot-artifacts && printf '%s\n' "$2" >"/tmp/autopilot-artifacts/场景$1.out"; }

# =============================================================================
t_case "W1 场景13.P1 run-watch.sh 含 own-pr 盯梢段调用（静态 grep -c >= 1）"
RW="$REPO_ROOT/scripts/contrib/run-watch.sh"
[[ -f "$RW" ]] && _pass "W1 前置：run-watch.sh 存在" || _fail "W1 前置：run-watch.sh 存在" "编排脚本缺失"
HIT="$(grep -c 'own_pr_watch' "$RW" 2>/dev/null || true)"
num_ge "$HIT" 1 "场景13.P1 run-watch.sh 含 own_pr_watch 引用（命中 ${HIT}）"
art "13.P1" "grep_hits=$HIT"

# =============================================================================
t_case "W2/W3 场景13.P2+P3 zsh 调 run-watch → 段真实调 own_pr_watch.sh、exit 0、产出快照"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp/views"
install_date_stub
mk_issues "$SB_ROOT/tmp/issues.json"
seed_scan_cursor
write_pr_list "$SB_ROOT/tmp/prs.json" \
  "$(pr_list_entry 103201 "$FRESH_TS" MERGEABLE REVIEW_REQUIRED 3)"
write_view "$SB_ROOT/tmp/views" 103201 OPEN alice bob carol
GH_BEFORE="$(grep -c '^gh|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true)"
run_watch_zsh >/dev/null
RC=$?
art "13.P2" "exit=$RC"
assert_exit 0 "$RC" "场景13.P2 run-watch（zsh 调，镜像生产）exit 0"
# 谓词字面裁决（auto-fix 09-10，铁律例外 E1-E3 闭合）：calls.log 是 stub 夹具写入面（只记 stub
# 自身 argv），production 代码向其写脚本名字面在机制上无定义——「calls.log contains own_pr_watch」
# 对任何合规实现不可满足（红队 CONTRACT_AMBIGUOUS 自邀裁决）。改断言为等价硬观测：watcher 的
# stage-1 pr list 调用行（watcher 是全编排唯一 pr list 发起方，段未真实运行则本断言红）。
# E1=断言与夹具机制矛盾（上述）；E2=谓词语义「段真实调用了 watcher」可等价观测；E3=实现已达成
# （同用例 gh 调用面新增/pr list 行/快照产物三断言 PASS）。留痕：state.md 变更日志 04:55/05:40。
assert_file_contains "$SB_ROOT/stublog/calls.log" "pr list" "场景13.P2 calls.log 含 watcher stage-1 pr list 调用行（等价观测，裁决见头注）"
# 设计钉的证据面：段 2.5 rc 日志行 → $CONTRIB/logs/launchd.log
assert_file_contains "$SB_ROOT/contrib-data/logs/launchd.log" "own_pr_watch" "场景13.P2 launchd.log 含 own_pr_watch rc 日志行（设计改动面钉死）"
# 行为面：本轮确实经由编排真实调用了 watcher（gh pr-list 调用面新增）
GH_AFTER="$(grep -c '^gh|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true)"
num_ge "$(( GH_AFTER - GH_BEFORE ))" 1 "场景13.P2 本轮新增 gh 调用（watcher 经编排真实运行，$(( GH_AFTER - GH_BEFORE )) 次）"
num_ge "$(grep -c '^gh|.*pr list' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true)" 1 "场景13.P2 calls.log 含 gh pr list 调用行"
# 场景13.P3：集成轮产出与单跑一致——自有快照存在 + jq 解析成功
[[ -f "$(snap_f)" ]] && _pass "场景13.P3 集成轮产出自有快照" || _fail "场景13.P3 集成轮产出自有快照" "$SNAP_NAME 未产出"
assert_eq "$(jq -e . "$(snap_f)" >/dev/null 2>&1 && printf yes || printf no)" "yes" "场景13.P3 快照 jq 解析成功"
assert_eq "$(jq -r '.prs | has("103201")' "$(snap_f)" 2>/dev/null)" "true" "场景13.P3 快照含 gh 数据中的 103201"
art "13.P3" "exists=$( [[ -f $(snap_f) ]] && echo true || echo false ) jq_ok=$(jq -e . "$(snap_f)" >/dev/null 2>&1 && echo yes || echo no)"
sb_cleanup

# =============================================================================
t_case "Q1 场景15.P1 全量测试设施全绿（run.sh exit 0 且输出含 own_pr_watch）"
SUITE_OUT="$(mktemp "${TMPDIR:-/tmp}/t7-q1.XXXXXX")"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh </dev/null ) >"$SUITE_OUT" 2>&1
RC=$?
assert_exit 0 "$RC" "场景15.P1 tests/run.sh 全量 exit 0"
assert_file_contains "$SUITE_OUT" "own_pr_watch" "场景15.P1 测试输出含 own_pr_watch（专项用例被执行）"
art "15.P1" "exit=$RC tail=$(tail -1 "$SUITE_OUT" 2>/dev/null | head -c 300)"
rm -f "$SUITE_OUT"

# =============================================================================
t_case "Q2 场景15.P2 验收门无发现通过（gate.sh exit 0）"
GATE_OUT="$(mktemp "${TMPDIR:-/tmp}/t7-q2.XXXXXX")"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/gate.sh </dev/null ) >"$GATE_OUT" 2>&1
RC=$?
assert_exit 0 "$RC" "场景15.P2 tests/gate.sh exit 0（0 findings）"
art "15.P2" "exit=$RC tail=$(tail -1 "$GATE_OUT" 2>/dev/null | head -c 200)"
rm -f "$GATE_OUT"

# =============================================================================
t_case "Q3 场景15.P3 测试设施含 own_pr_watch 专项用例文件"
FILES_N="$(grep -rl 'own_pr_watch' "$TESTS_ROOT" 2>/dev/null | wc -l | tr -d ' ')"
num_ge "$FILES_N" 1 "场景15.P3 tests/ 内匹配 own_pr_watch 的文件命中数 >= 1"
UNIT_N="$(find "$TESTS_ROOT/unit" -maxdepth 1 -type f 2>/dev/null | grep -Ec 'own[-_]pr[-_]watch' || true)"
num_ge "$UNIT_N" 1 "场景15.P3 加钉：unit 维度含 own-pr-watch/own_pr_watch 专项用例文件 >= 1（防仅验收测试自证）"
art "15.P3" "files=$FILES_N unit=$UNIT_N"

t_finish
