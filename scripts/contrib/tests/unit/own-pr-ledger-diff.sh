#!/bin/bash
# own-pr-ledger-diff.sh — Tier U：own_pr_watch.sh 的 L2 台账差集段（#108006 缺口闭环）
# 覆盖：
#   ① 首跑/状态损坏 → 建基线（零事件、exit 0、状态含数值 baseline_epoch）
#   ② 上游 PR 面：createdAt >= 基线且无台账 → 恰 1 条 own-pr-unledgered（class 精确串 + key 形态）
#   ③ 吸纳面：已记账（branch token / pull-N 锚）/ createdAt 早于基线 / createdAt 缺失 → 零事件
#   ④ fork 面：refs/remotes/fork/* sha 推进且无台账 → fork-<分支>-unledgered；已记账 → 零事件
#   ⑤ 幂等：同缺口二次运行不增事件（notify event 同 key 兜底）
#   ⑥ notify 机械渲染：own-pr-unledgered 走模板卡（零 LLM），标题/动作行齐备
#   ⑦ 红线：gh argv 零写子命令、零 claude/网络写（本段不引入任何对外能力）
# 全部 sb_new 沙箱 + 影子 stub；零真实 gh / 零真实 fork 仓 / 零生产 contrib-data 写入。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "own-pr-ledger-diff.sh"

WATCH_REL="scripts/contrib/own_pr_watch.sh"
D="2026-09-12"
BASE_EPOCH=1767196800            # 2026-01-01：台账基线（fixture createdAt 用 2026-06-01，晚于它）
PR_CREATED="2026-06-01T00:00:00Z"
OLD_CREATED="2025-06-01T00:00:00Z"

DATA=""; SNAP=""; STATE=""; LEDGER=""; EVENTS=""; WLOG=""; CALLS=""
new_sb() {
  sb_new >/dev/null 2>&1
  DATA="$SB_ROOT/contrib-data"
  SNAP="$DATA/own-pr-watch-snapshot.json"
  STATE="$DATA/l2-ledger-state.json"
  LEDGER="$SB_ROOT/approved.log"
  EVENTS="$DATA/events.jsonl"
  WLOG="$DATA/logs/own-pr-watch.log"
  CALLS="$SB_STUBLOG/calls.log"
  mk_git_stub
  mkdir -p "$SB_ROOT/gh-view"
  : >"$SB_ROOT/pr.rows"
}

# mk_git_stub：fork refs 由 STUB_GIT_FORK_REFS_FILE 提供（缺省 exit 1 = 仓不存在 fail-soft）
mk_git_stub() {
  cat >"$SB_ROOT/bin/git" <<'EOF'
#!/bin/bash
LOG_DIR="${STUB_LOG_DIR:-/nonexistent}"
printf 'git|%s|%s\n' "$PWD" "$*" >>"$LOG_DIR/calls.log" 2>/dev/null || true
case "$*" in
  *"for-each-ref"*)
    if [[ -n "${STUB_GIT_FORK_REFS_FILE:-}" && -f "$STUB_GIT_FORK_REFS_FILE" ]]; then
      cat "$STUB_GIT_FORK_REFS_FILE"
      exit 0
    fi
    exit 1 ;;
esac
exit 0
EOF
  chmod +x "$SB_ROOT/bin/git"
}

# set_pr <num> <updatedAt> <mergeable> <branch> <createdAt> [接尾注释: "", "nocreated", "nobranch"]
set_pr() {
  local num="$1" upd="$2" m="$3" br="$4" created="$5" mode="${6:-}"
  if [[ "$mode" == "nocreated" ]]; then created=""; fi
  if [[ "$mode" == "nobranch" ]]; then br=""; fi
  jq -cn --argjson n "$num" --arg upd "$upd" --arg m "$m" --arg br "$br" --arg c "$created" \
    '{number: $n, updatedAt: $upd, mergeable: $m, reviewDecision: "", comments: [],
      headRefName: $br, createdAt: $c}' >>"$SB_ROOT/pr.rows"
  jq -s . "$SB_ROOT/pr.rows" >"$SB_ROOT/gh-prs.json"
}

# seed_snapshot [<num> ...] — 预置 own-pr 快照（避开首跑基线早退分支）
seed_snapshot() {
  local num obj="{}"
  for num in "$@"; do
    obj="$(jq -c --arg k "$num" \
      '. + {($k): {updatedAt: "2026-06-01T00:00:00Z", mergeable: "MERGEABLE", reviewDecision: "", comments: 0, external_comments: 0}}' \
      <<<"$obj")"
  done
  jq -n --arg ts "2026-06-01T00:00:00Z" --argjson prs "$obj" '{generated_at: $ts, prs: $prs}' >"$SNAP"
}

# seed_state <baseline_epoch> [fork_refs_json]
seed_state() {
  local refs="${2:-}"
  [[ -n "$refs" ]] || refs='{}'
  jq -n --argjson ep "$1" --argjson refs "$refs" \
    '{version: 1, baseline_epoch: $ep, baseline_at: "2026-01-01T00:00:00Z", fork_refs: $refs, last_run: "2026-01-01T00:00:00Z"}' \
    >"$STATE"
}

run_watch() { # [K=V ...] — bash 显式调（生产 run-watch 段 2.5 同形态）
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    -e "STUB_GH_PRS_FILE=$SB_ROOT/gh-prs.json" \
    -e "STUB_GH_VIEW_DIR=$SB_ROOT/gh-view" \
    -e "STUB_DATE_TODAY=$D" \
    "bash \"\$MARTIN_DIR/$WATCH_REL\""
}

diff_events() { # <class> → 该类事件行（无则空）
  [[ -f "$EVENTS" ]] || return 0
  jq -c --arg c "$1" 'select(.class == $c)' "$EVENTS" 2>/dev/null || true
}
diff_count() { diff_events "$1" | grep -c . || true; }
gh_argv() { awk -F'|' '$1 == "gh" { print $3 }' "$CALLS" 2>/dev/null || true; }

# ---------------- ① 基线 ----------------
t_case "首跑：台账状态缺失 → 建基线、零事件、exit 0"
new_sb
set_pr 108006 "2026-06-01T00:00:00Z" MERGEABLE contrib/kanban-resource-gate "$PR_CREATED"
run_watch >/dev/null
assert_exit 0 $? "首跑 exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "0" "基线轮零缺口事件"
[[ -f "$STATE" ]] && _pass "台账状态文件已建" || _fail "台账状态文件已建" "$STATE 缺失"
assert_eq "$(jq -r '.baseline_epoch | type' "$STATE" 2>/dev/null)" "number" "baseline_epoch 为数值"

t_case "状态损坏：非 JSON → 重建基线、零事件、exit 0"
printf 'not-json{{{' >"$STATE"
run_watch >/dev/null
assert_exit 0 $? "损坏态 exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "0" "重建轮零事件"
assert_eq "$(jq -r '.baseline_epoch | type' "$STATE" 2>/dev/null)" "number" "基线已重建"

# ---------------- ② 上游 PR 面：缺口检出 ----------------
t_case "缺口检出：基线后创建的 PR 无台账 → 恰 1 条 own-pr-unledgered"
new_sb
set_pr 108006 "2026-06-01T00:00:00Z" MERGEABLE contrib/kanban-resource-gate "$PR_CREATED"
seed_snapshot 108006
seed_state "$BASE_EPOCH"
run_watch >/dev/null
assert_exit 0 $? "exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "1" "恰 1 条缺口事件"
line="$(diff_events own-pr-unledgered)"
assert_contains "$line" '"key":"108006-unledgered"' "key=<PR>-unledgered（无日期=一次即持久）"
assert_contains "$line" "108006" "摘要含 PR 号"
assert_contains "$line" "approved.log" "摘要点明台账缺口"
assert_eq "$(diff_count own-pr-activity)" "0" "不误发 own-pr-activity"
assert_file_contains "$WLOG" "台账差集 1" "盯梢日志记录差集计数（可诊断）"

t_case "幂等：同缺口二次运行事件数不增"
run_watch >/dev/null
assert_exit 0 $? "二次运行 exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "1" "事件数仍 1（同 key 幂等）"

# ---------------- ③ 吸纳面：不误报 ----------------
t_case "已记账（branch token）→ 零缺口"
new_sb
set_pr 108006 "2026-06-01T00:00:00Z" MERGEABLE contrib/kanban-resource-gate "$PR_CREATED"
seed_snapshot 108006
seed_state "$BASE_EPOCH"
printf '%s\n' "2026-09-11T15:00:00+0800 | hermes-contrib | issue #108006 own-PR 处置（L2-B 会话内批准执行）：批 | L2-B 会话内批准 | https://github.com/NousResearch/hermes-agent/pull/108006 branch=contrib/kanban-resource-gate" >"$LEDGER"
run_watch >/dev/null
assert_exit 0 $? "exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "0" "有台账 → 零缺口"

t_case "已记账（仅 pull-N 锚，无分支 token）→ 零缺口"
new_sb
set_pr 108006 "2026-06-01T00:00:00Z" MERGEABLE contrib/kanban-resource-gate "$PR_CREATED"
seed_snapshot 108006
seed_state "$BASE_EPOCH"
printf '%s\n' "2026-09-11T15:00:00+0800 | hermes-contrib | own-PR 落地 | L2-B 会话内批准 | https://github.com/NousResearch/hermes-agent/pull/108006" >"$LEDGER"
run_watch >/dev/null
assert_eq "$(diff_count own-pr-unledgered)" "0" "PR 号锚命中 → 零缺口"

t_case "存量豁免：createdAt 早于基线 → 零缺口"
new_sb
set_pr 65100 "2026-06-01T00:00:00Z" MERGEABLE fix/qqbot-tier-low-platform-default "$OLD_CREATED"
seed_snapshot 65100
seed_state "$BASE_EPOCH"
run_watch >/dev/null
assert_exit 0 $? "exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "0" "基线前 PR 豁免（存量 8 张 open PR 不被误报）"

t_case "createdAt 缺失（旧夹具/形态漂移）→ 零缺口"
new_sb
set_pr 108006 "2026-06-01T00:00:00Z" MERGEABLE contrib/kanban-resource-gate "" nocreated
seed_snapshot 108006
seed_state "$BASE_EPOCH"
run_watch >/dev/null
assert_exit 0 $? "exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "0" "createdAt 缺失 → 吸纳"

# ---------------- ④ fork 面 ----------------
t_case "fork 面：ref 推进且无台账 → fork-<分支>-unledgered"
new_sb
printf 'refs/remotes/fork/fix/qqbot-drain|abcdef1234567890\n' >"$SB_ROOT/forkrefs.txt"
seed_snapshot
seed_state "$BASE_EPOCH" '{"refs/remotes/fork/fix/qqbot-drain":"oldsha0000000000"}'
run_watch STUB_GIT_FORK_REFS_FILE="$SB_ROOT/forkrefs.txt" >/dev/null
assert_exit 0 $? "exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "1" "恰 1 条 fork 缺口事件"
assert_contains "$(diff_events own-pr-unledgered)" '"key":"fork-fix_qqbot-drain-unledgered"' "key=fork-<分支>-unledgered"
assert_contains "$(diff_events own-pr-unledgered)" "fix/qqbot-drain" "摘要含分支名"

t_case "fork 面：台账已记分支 → 零缺口；sha 收纳后不再重复"
new_sb
printf 'refs/remotes/fork/fix/qqbot-drain|abcdef1234567890\n' >"$SB_ROOT/forkrefs.txt"
seed_snapshot
seed_state "$BASE_EPOCH" '{"refs/remotes/fork/fix/qqbot-drain":"oldsha0000000000"}'
printf '%s\n' "2026-09-11T15:00:00+0800 | hermes-contrib | PR #75453 own-PR 处置 | L2-B 会话内批准 | https://x/pull/75453 branch=fix/qqbot-drain" >"$LEDGER"
run_watch STUB_GIT_FORK_REFS_FILE="$SB_ROOT/forkrefs.txt" >/dev/null
assert_exit 0 $? "exit 0"
assert_eq "$(diff_count own-pr-unledgered)" "0" "有台账 → 零缺口"
run_watch STUB_GIT_FORK_REFS_FILE="$SB_ROOT/forkrefs.txt" >/dev/null
assert_eq "$(diff_count own-pr-unledgered)" "0" "sha 已收纳进快照 → 不因未推进重复报"

t_case "fork 仓缺失（for-each-ref 失败）→ fail-soft 零缺口"
new_sb
seed_snapshot
seed_state "$BASE_EPOCH" '{}'
run_watch >/dev/null
assert_exit 0 $? "exit 0（git 不可达不拖死盯梢）"
assert_eq "$(diff_count own-pr-unledgered)" "0" "零缺口"

# ---------------- ⑤ 红线 ----------------
t_case "红线：本段零 gh 写子命令、零 LLM 调用"
new_sb
set_pr 108006 "2026-06-01T00:00:00Z" MERGEABLE contrib/kanban-resource-gate "$PR_CREATED"
seed_snapshot 108006
seed_state "$BASE_EPOCH"
run_watch >/dev/null
argv="$(gh_argv)"
writes="$(printf '%s\n' "$argv" | grep -Ec '(^| )(pr|issue|repo|release) (create|edit|delete|close|reopen|merge|comment|lock|label)( |$)|-X *(POST|PATCH|PUT|DELETE)' || true)"
assert_eq "${writes:-0}" "0" "gh argv 零写子命令"
assert_eq "$(stub_count claude)" "0" "零 claude 调用"
assert_eq "$(stub_count hermes)" "0" "零 hermes 调用（不直接推送）"

# ---------------- ⑥ notify 机械渲染 ----------------
t_case "notify 渲染：own-pr-unledgered 走模板卡（零 LLM）+ 标题/动作行"
new_sb
sb_notify event own-pr-unledgered --key 108006-unledgered \
  --summary "PR #108006（分支 contrib/kanban-resource-gate）已发布，但 approved.log 无对应台账" >/dev/null
sb_run -e "NOTIFY_DRY_RUN=false" "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" flush" >/dev/null
assert_exit 0 $? "flush exit 0"
assert_eq "$(stub_count claude)" "0" "纯机械批零 claude（不经 AI 摘要）"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && _pass "模板卡已发送" || _fail "模板卡已发送" "无 hermes 消息体副本"
assert_file_contains "$body_copy" "自有 PR 台账缺口" "模板卡标题（class_title）"
assert_file_contains "$body_copy" "l2_ledger.sh" "动作行指向补记工具"
assert_eq "$(jq -r 'select(.key == "108006-unledgered") | .pushed' "$EVENTS")" "true" "事件已标 pushed"

sb_cleanup
t_finish
