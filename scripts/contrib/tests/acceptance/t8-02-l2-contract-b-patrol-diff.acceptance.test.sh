#!/usr/bin/env bash
# =============================================================================
# t8-02-l2-contract-b-patrol-diff.acceptance.test.sh — T8 红队验收②：契约 B（巡检侧差集）
#   DIM=acceptance；黑盒（未读 own_pr_watch.sh / l2_ledger.sh / notify.sh / rq.sh 实现，
#   仅依赖设计「公共接口面」逐字 + 沙箱 seam + stub 旋钮）
#   覆盖契约 B：未获批的 fork 分支 / 上游新 PR 会被小时级巡检验出（own-pr-unledgered 事件），
#   且首跑基线豁免存量、不误报。
#   谓词覆盖（SSOT「验收场景」）：
#     B.P1 首跑基线豁免存量 → 首跑零事件 ∧ baseline_epoch 为数值
#     B.P2 基线后新 PR 未记账被检出 → 恰 1 条 ∧ key <N>-unledgered ∧ 摘要含 approved.log
#          ∧ own-pr-activity 零误发
#     B.P3 record 补账后巡检吸收 → 真实 l2_ledger.sh record 后复跑零新事件（写读格式共识）
#     B.P4 fork 新分支被检出且可吸收 → fork-<分支>-unledgered 检出 1 条；record 后复跑吸收
#     B.P5 无变化复跑幂等 → 三跑增量 0/1/0
#     B.P6 巡检自身零对外写 → gh 写子命令=0 ∧ claude=0 ∧ hermes=0
#   Mental Mutation 靶点（B 组）：ledger_diff 基线不豁免（首跑即差集）→ B.P1 红；
#     key 改形 → B.P2/B.P4 红；ledger_ledgered 恒 1 → B.P3/B.P4 吸收段红；
#     sha 收纳丢失 → B.P4 末段复跑红；巡检 no-op → B.P2/B.P5/B.P6 前置红
#   fork 面夹具（黑盒环境镜像生产布局）：巡检的 fork 分支源 = $HOME/workspace/hermes-agent
#     仓内 refs/remotes/fork/*（git for-each-ref 只读探测）——沙箱内搭真 git 工作仓 + fork
#     裸仓，轮间「ref 推进」= 真 push --force + fetch 收纳 tracking ref；全部落在沙箱 mktemp
#     路径内。设计 seam 清单所列 STUB_GIT_FORK_REFS_FILE 经黑盒探针证实不被本实现消费
#     （夹具不依赖它；差异已登记红队报告）
#   黑盒依赖（契约冻结）：own_pr_watch.sh 零参数一轮、$CONTRIB/l2-ledger-state.json 首跑建且
#     baseline_epoch 为数值、非首跑用「连跑两轮真实巡检」构造（不依赖内部 schema）、
#     seam APPROVED_LOG / STUB_GH_PRS_FILE / STUB_GH_VIEW_DIR / STUB_DATE_TODAY、
#     机械事件类 own-pr-unledgered（notify.sh 机械类）
# CONTRACT_AMBIGUOUS：
#   - B.P4 record 的 (--issue|--pr) 二选一：fork 分支无 PR 形态取 --issue N
#   - pr list 影子数据含 createdAt/updatedAt/headRefName 字段（gh pr list --json 契约字段）
# 红队纪律：每断言硬失败、无 skip；全部轮次在 sb_new 沙箱 + 影子 stub 内运行，绝不触真实
#   contrib-data / 仓根 approved.log，绝不真调 gh/hermes/claude。
# =============================================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析——git rev-parse --show-toplevel 在 ${SELF_DIR} 无输出（非 git 仓库 / git 不可用）；本套件禁静默兜底到生产主 checkout" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

D="2027-06-01"
FRESH_C="2026-09-01T00:00:00Z"     # 存量 PR createdAt（早于真实今日常识，基线豁免口径无关）
FRESH_U="2026-09-10T00:00:00Z"     # 存量 PR updatedAt（fresh：距冻结 D 非停滞）
LEDGER=""
STATE_F=""
EV_F=""
PRS=""
HA=""
FK_BARE=""

mk_pr() { # <n> <headBranch> <createdAt> <updatedAt> → pr list 数组元素（own-author 评论，镜像 t7-01 形态）
  jq -cn --argjson n "$1" --arg h "$2" --arg c "$3" --arg u "$4" \
    '{number:$n, headRefName:$h, createdAt:$c, updatedAt:$u, mergeable:"MERGEABLE",
      reviewDecision:"REVIEW_REQUIRED", comments:[{author:{login:"strzhao"}}]}'
}

write_prs() { # <file> <entry...>
  local f="$1" arr="[]" e
  shift
  for e in "$@"; do arr="$(printf '%s' "$arr" | jq -c --argjson o "$e" '. + [$o]')"; done
  printf '%s\n' "$arr" >"$f"
}

write_view() { # <dir> <pr> — gh pr view 影子数据（防御性：巡检若走 pr view 不致失败）
  mkdir -p "$1"
  jq -cn --argjson n "$2" '{number:$n, state:"OPEN", reviewDecision:null, comments:[]}' >"$1/pr-$2.json"
}

fork_set_branch() { # <branch> <seed> — fork 裸仓推进分支（force push）+ 工作仓 fetch 收纳 tracking ref
  local br="$1" seed="$2" tmp="$SB_ROOT/tmp/forkseed"
  rm -rf "$tmp"
  git init -q "$tmp"
  git -C "$tmp" config user.email rt@redteam.local
  git -C "$tmp" config user.name rt
  printf '%s\n' "$seed" >"$tmp/f.txt"
  git -C "$tmp" add f.txt
  git -C "$tmp" commit -q -m "fork seed $seed"
  git -C "$tmp" branch -M "$br"
  git -C "$tmp" push -q --force "$FK_BARE" "$br" 2>/dev/null
  git -C "$HA" fetch -q fork 2>/dev/null
  rm -rf "$tmp"
}

common_setup() { # <pr-n> <pr-branch> <fork-branch> — 独立沙箱 + 存量 1 PR + 存量 1 fork 分支（均未记账）
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mkdir -p "$SB_ROOT/tmp/views"
  LEDGER="$SB_ROOT/contrib-data/approved.log"
  STATE_F="$SB_ROOT/contrib-data/l2-ledger-state.json"
  EV_F="$SB_ROOT/contrib-data/events.jsonl"
  PRS="$SB_ROOT/tmp/prs.json"
  # 真实 hermes-agent 工作仓 + fork 裸仓（镜像生产 $HOME/workspace/hermes-agent 布局）
  FK_BARE="$SB_ROOT/tmp/hermes-agent-fork.git"
  HA="$SB_HOME/workspace/hermes-agent"
  git init -q --bare "$FK_BARE" 2>/dev/null
  git init -q "$HA" 2>/dev/null
  git -C "$HA" config user.email rt@redteam.local
  git -C "$HA" config user.name rt
  printf 'base\n' >"$HA/base.txt"
  git -C "$HA" add base.txt
  git -C "$HA" commit -q -m init
  git -C "$HA" branch -M main 2>/dev/null
  git -C "$HA" remote add fork "$FK_BARE"
  git -C "$HA" push -q fork main 2>/dev/null
  git -C "$HA" fetch -q fork 2>/dev/null
  fork_set_branch "$3" "fork-base-$3"
  write_prs "$PRS" "$(mk_pr "$1" "$2" "$FRESH_C" "$FRESH_U")"
  write_view "$SB_ROOT/tmp/views" "$1"
}

sb_watch_run() { # 一轮真实巡检（零参数；seam -e 显式注入）
  sb_run \
    -e "APPROVED_LOG=$LEDGER" \
    -e "STUB_GH_PRS_FILE=$PRS" \
    -e "STUB_GH_VIEW_DIR=$SB_ROOT/tmp/views" \
    -e "STUB_DATE_TODAY=$D" \
    'bash "$MARTIN_DIR/scripts/contrib/own_pr_watch.sh"'
}

sb_l2() { # <l2 参数...> — 沙箱副本 l2_ledger.sh（写读闭环用真实写侧；锁目录由被测脚本自建）
  local a snippet=""
  for a in "$@"; do snippet="$snippet$(printf '%q ' "$a")"; done
  sb_run \
    -e "APPROVED_LOG=$LEDGER" \
    -e "L2_LEDGER_LOCKDIR=$SB_ROOT/locks/l2" \
    -e "RQ_SH=$SB_ROOT/scripts/contrib/rq.sh" \
    -e "STUB_DATE_TODAY=$D" \
    "bash \"\$MARTIN_DIR/scripts/contrib/l2_ledger.sh\" $snippet"
}

ev_count() { # events.jsonl 行数（缺失/空=0）
  local n=0
  if [[ -f "$EV_F" ]]; then n="$(grep -c '' "$EV_F" 2>/dev/null)"; fi
  printf '%s' "${n:-0}"
}
EV_MARK=0
ev_mark() { EV_MARK="$(ev_count)"; }
ev_delta() { # bash 3.2：算术表达式内不得放引号包裹的命令替换，先落普通变量
  local n
  n="$(ev_count)"
  printf '%d' $(( n - EV_MARK ))
}

l2_rows() { # 台账行数（缺失/空=0）
  local n=0
  if [[ -f "$LEDGER" ]]; then n="$(grep -c '' "$LEDGER" 2>/dev/null)"; fi
  printf '%s' "${n:-0}"
}

last_ev() { # <jq 表达式> → 末条事件字段
  tail -n 1 "$EV_F" 2>/dev/null | jq -r "$1 // \"MISSING\"" 2>/dev/null
}

delta_class_count() { # <class 子串> → 当前增量窗内该 class 计数（先 ev_mark，后置 EV_MARK_DELTA）
  local n
  n="$(tail -n "$EV_MARK_DELTA" "$EV_F" 2>/dev/null | jq -r '.class' 2>/dev/null | grep -cF -- "$1")"
  printf '%s' "${n:-0}"
}

gh_total() {
  local n
  n="$(awk -F'|' '$1 == "gh"' "$SB_STUBLOG/calls.log" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

gh_write_count() { # calls.log 中 gh 行 argv 带写子命令/写旗标的行数（deny list 口径）
  local pat n
  pat='(^|[| ])(pr|issue) (create|edit|close|merge|comment|reopen|delete|lock|unlock|pin|unpin|transfer|ready|update-branch|review)( |$)|(^|[| ])repo (create|delete|edit|fork|rename|sync|deploy-key)( |$)| (-f|-F|--field|--input)( |$)|(-X|--method) (POST|PUT|PATCH|DELETE)( |$)'
  n="$(awk -F'|' '$1 == "gh"' "$SB_STUBLOG/calls.log" 2>/dev/null | grep -cE "$pat")"
  printf '%s' "${n:-0}"
}

# =============================================================================
t_case "B.P1 首跑存量豁免：既有 PR+既有 fork 分支均未记账 → 零事件 + baseline_epoch 数值落盘"
common_setup 801 fix-b1 fix-base
ev_mark
sb_watch_run >/dev/null
RC=$?
assert_exit 0 "$RC" "B.P1 首轮巡检 exit 0"
assert_eq "$(ev_delta)" "0" "B.P1 首跑零事件（基线豁免存量；基线不豁免突变必红）"
BE="$(jq -r 'if type=="object" and has("baseline_epoch") then (.baseline_epoch|type) else "missing" end' "$STATE_F" 2>/dev/null)"
assert_eq "$BE" "number" "B.P1 l2-ledger-state.json 首跑落盘且 baseline_epoch 为数值"
ev_mark
sb_watch_run >/dev/null
RC2=$?
assert_exit 0 "$RC2" "B.P1 二轮巡检 exit 0"
assert_eq "$(ev_delta)" "0" "B.P1 二轮存量持续豁免零事件（连跑两轮构造非首跑口径）"
sb_cleanup

# =============================================================================
t_case "B.P2 基线后新未记账 PR 检出：恰 1 条 own-pr-unledgered（key/summary）+ own-pr-activity 零误发"
common_setup 901 fix-b2a fix-base
sb_watch_run >/dev/null
assert_eq "$(ev_count)" "0" "B.P2 前置：基线轮零事件"
write_prs "$PRS" "$(mk_pr 901 fix-b2a "$FRESH_C" "$FRESH_U")" \
                   "$(mk_pr 902 fix-b2 "2027-06-01T00:00:00Z" "2027-06-01T00:00:00Z")"
write_view "$SB_ROOT/tmp/views" 902
ev_mark
sb_watch_run >/dev/null
RC=$?
assert_exit 0 "$RC" "B.P2 检出轮 exit 0"
EV_MARK_DELTA="$(ev_delta)"
assert_eq "$EV_MARK_DELTA" "1" "B.P2 恰 1 条新事件"
assert_eq "$(last_ev '.class')" "own-pr-unledgered" "B.P2 事件类=机械类 own-pr-unledgered"
assert_eq "$(last_ev '.key')" "902-unledgered" "B.P2 key=<N>-unledgered（902-unledgered）"
assert_contains "$(last_ev '.summary')" "approved.log" "B.P2 摘要点 approved.log"
assert_eq "$(delta_class_count 'own-pr-activity')" "0" "B.P2 own-pr-activity 零误发"
sb_cleanup

# =============================================================================
t_case "B.P3 写读闭环：真实 l2_ledger.sh record 补账后复跑巡检 → 零新事件"
common_setup 901 fix-b3a fix-base
sb_watch_run >/dev/null
assert_eq "$(ev_count)" "0" "B.P3 前置：基线轮零事件"
write_prs "$PRS" "$(mk_pr 901 fix-b3a "$FRESH_C" "$FRESH_U")" \
                   "$(mk_pr 902 fix-b3 "2027-06-01T00:00:00Z" "2027-06-01T00:00:00Z")"
write_view "$SB_ROOT/tmp/views" 902
ev_mark
sb_watch_run >/dev/null
EV_MARK_DELTA="$(ev_delta)"
assert_eq "$EV_MARK_DELTA" "1" "B.P3 前置：轮间新 PR 检出恰 1 条"
assert_eq "$(last_ev '.key')" "902-unledgered" "B.P3 前置：检出 key=902-unledgered"
sb_l2 record --kind own-PR --pr 902 --channel "rt-b3" \
  --approval "APPROVE rt-b3 backfill" --branch fix-b3 \
  --url "https://github.com/NousResearch/hermes-agent/pull/902" \
  --summary "backfill 902" >/dev/null
RREC=$?
assert_exit 0 "$RREC" "B.P3 真实 record 补账 exit 0"
assert_eq "$(l2_rows)" "1" "B.P3 台账落 1 行（真实写侧产出）"
ev_mark
sb_watch_run >/dev/null
RC2=$?
assert_exit 0 "$RC2" "B.P3 补账后复跑 exit 0"
assert_eq "$(ev_delta)" "0" "B.P3 补账后复跑零新事件（writer/checker 格式共识；ledger_ledgered 恒 1 突变红）"
sb_cleanup

# =============================================================================
t_case "B.P4 fork 面：轮间 ref 推进未记账 → fork-<分支>-unledgered；record 后吸收 + sha 收纳"
common_setup 901 fix-b4 fix-fk
sb_watch_run >/dev/null
assert_eq "$(ev_count)" "0" "B.P4 前置：首跑基线吸收 fork 存量分支零事件"
fork_set_branch fix-fk "fork-advanced-2222"   # 轮间 ref 推进（tracking ref sha 前进）
ev_mark
sb_watch_run >/dev/null
RC=$?
assert_exit 0 "$RC" "B.P4 推进轮 exit 0"
EV_MARK_DELTA="$(ev_delta)"
assert_eq "$EV_MARK_DELTA" "1" "B.P4 检出恰 1 条"
assert_eq "$(last_ev '.class')" "own-pr-unledgered" "B.P4 fork 面事件类=机械类 own-pr-unledgered"
assert_eq "$(last_ev '.key')" "fork-fix-fk-unledgered" "B.P4 key=fork-<分支>-unledgered"
sb_l2 record --kind own-PR --issue 5100 --channel "rt-b4" \
  --approval "APPROVE rt-b4 fork sync" --branch fix-fk \
  --summary "fork sync fix-fk" >/dev/null
RREC=$?
assert_exit 0 "$RREC" "B.P4 record 补账 fork 分支 exit 0（--issue 形态；CONTRACT_AMBIGUOUS，见头注）"
assert_file_contains "$LEDGER" "branch=fix-fk" "B.P4 台账行含分支锚 branch=fix-fk"
ev_mark
sb_watch_run >/dev/null
assert_eq "$(ev_delta)" "0" "B.P4 补账后复跑吸收零新事件"
ev_mark
sb_watch_run >/dev/null
assert_eq "$(ev_delta)" "0" "B.P4 再复跑仍零（sha 收纳：推进后的 sha 不再回报；sha 收纳丢失突变红）"
sb_cleanup

# =============================================================================
t_case "B.P5 幂等：无变化三跑 events 零增长（增量 0/1/0）"
common_setup 601 fix-b5a fix-base
ev_mark
sb_watch_run >/dev/null
D1="$(ev_delta)"
assert_eq "$D1" "0" "B.P5 第一跑增量 0（基线）"
write_prs "$PRS" "$(mk_pr 601 fix-b5a "$FRESH_C" "$FRESH_U")" \
                   "$(mk_pr 602 fix-b5 "2027-06-01T00:00:00Z" "2027-06-01T00:00:00Z")"
write_view "$SB_ROOT/tmp/views" 602
ev_mark
sb_watch_run >/dev/null
D2="$(ev_delta)"
assert_eq "$D2" "1" "B.P5 第二跑增量 1（新未记账 PR 检出恰一次）"
ev_mark
sb_watch_run >/dev/null
D3="$(ev_delta)"
assert_eq "$D3" "0" "B.P5 第三跑增量 0（无变化不重报）"
sb_cleanup

# =============================================================================
t_case "B.P6 红线：巡检全程 gh argv 零写子命令、零 claude/hermes 调用"
common_setup 701 fix-b6a fix-base
sb_watch_run >/dev/null
assert_eq "$(ev_count)" "0" "B.P6 前置：基线轮零事件"
write_prs "$PRS" "$(mk_pr 701 fix-b6a "$FRESH_C" "$FRESH_U")" \
                   "$(mk_pr 702 fix-b6 "2027-06-01T00:00:00Z" "2027-06-01T00:00:00Z")"
write_view "$SB_ROOT/tmp/views" 702
ev_mark
sb_watch_run >/dev/null
EV_MARK_DELTA="$(ev_delta)"
assert_eq "$EV_MARK_DELTA" "1" "B.P6 前置：检出轮真实工作（零写断言非空转）"
assert_stub_called gh 1 "B.P6 巡检确有 gh 只读调用（防 no-op 空转绿）"
assert_eq "$(gh_write_count)" "0" "B.P6 gh argv 零写子命令/写旗标"
assert_stub_not_called claude "B.P6 零 claude 调用"
assert_stub_not_called hermes "B.P6 零 hermes 调用"
sb_cleanup

t_finish
