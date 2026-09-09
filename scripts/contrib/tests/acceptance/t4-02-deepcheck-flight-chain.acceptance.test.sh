#!/usr/bin/env bash
# =============================================================================
# t4-02-deepcheck-flight-chain.acceptance.test.sh — T4 验收②：deepcheck flight 链式终态矩阵
#   C1  done + verdict(auto/high/low) + awaiting-approval → 编排层调 auto-gate：rc0 →
#       rq set approved（L2-auto 桥接保留，审查 B2）+ 清登记 + 继续为候选建新卡
#   C2  done + verdict(escalate) + awaiting-approval → auto-gate rc1 → 维持人工
#       （状态不被强改 approved）+ 清登记 + 继续建新卡
#   C3  done + rq=deep-check + 子卡在跑（children 查询）→ 保留登记 + 零建卡零 claude
#   C4  done + rq=deep-check + 子卡 blocked → rq set failed + refund + 清登记 +
#       -deepcheck-stale 事件（审查 I3 链悬挂告警面）+ 继续建新卡
#   C5  done + rq=failed → 清登记 + refund（幂等）+ 继续建新卡
#   C6  rq 查无（flight.rq_id 不在队列）→ 清登记 + -deepcheck-orphan 事件 + 零 refund
#   C7  失败终态（blocked + outcome=gave_up）→ 清 + refund + rq set failed +
#       -deepcheck-card-fallback 事件
#   C8  stale（DEEPCHECK_STALE_SECS=60，epoch-120）→ 清 + refund + rq set failed + stale 事件
#   C9  stale 下界守卫窗（SECS=3600，epoch-3595）→ 非终态未超时 → 保留登记跳过
#   C10 stale 上界（SECS=3600，epoch-3605）→ 触发 stale 清理
# 依据：state.md「## 设计文档」§2（deepcheck flight 终态分支——链式完成判定）+ §契约规约：
#   「stale 阈值=独立 DEEPCHECK_STALE_SECS（缺省 86400，不复用 6h）；事件 key 三族
#    -deepcheck-card-fallback / -deepcheck-stale / -deepcheck-orphan；全局单深检（任一
#    deepcheck 登记在飞→跳过）」
# CONTRACT_AMBIGUOUS：
#  - C7 失败终态分支的事件 key：任务矩阵钉 -deepcheck-card-fallback，设计 §1 事件清单把该 key
#    标注为「建卡失败」——按矩阵断言，实现若改用他 key 需回设计对齐
#  - C1/C2/C4/C5/C7/C8 的「继续建新卡」来自设计 §1 流程 ├─ 分支后顺序落入步骤 2/3 的结构；
#    若实现选择 return 则此处红——需回设计确认
#  - 事件 class 未钉死——只断言 key 子串
#  - 缺省 86400 不实测（24h 纪元不可采样）；阈值语义由 C8-C10 的注入旋钮覆盖
# 红队纪律：黑盒；每断言硬失败；无 skip。Mental Mutation：链完成判定退化为单卡判定（done 即
#   清）→ C3 保留断言挂；auto-gate 桥接删除 → C1 approved 挂；refund 删除 → C4/C5/C7/C8
#   预算返还断言挂；children 查询删除 → C4 子卡失败不触发 failed 挂；stale 守卫删除 → C9 挂；
#   orphan 事件删除 → C6 挂。
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

A_ID="rq-20260909-101"   # flight 登记的在飞深检项（deep 车道）
B_ID="rq-20260909-202"   # 触发 gate rc10 的新候选（probe 车道）

# ---- 本文件专用装具 ----

install_rq_recorder() { # rq.sh 调用记录器（透传真身）：观察 reserve/refund/set 调用
  mv "$SB_ROOT/scripts/contrib/rq.sh" "$SB_ROOT/scripts/contrib/rq-real.sh"
  cat > "$SB_ROOT/scripts/contrib/rq.sh" <<'EOF'
#!/bin/bash
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -n "$LOG_DIR" ]]; then
  line="rq|$PWD|"
  first=1
  for a in "$@"; do
    if [[ $first -eq 0 ]]; then line="$line "; fi
    line="$line${a//$'\n'/ }"
    first=0
  done
  printf '%s\n' "$line" >>"$LOG_DIR/calls.log"
fi
exec bash "${MARTIN_DIR:?}/scripts/contrib/rq-real.sh" "$@"
EOF
  chmod +x "$SB_ROOT/scripts/contrib/rq.sh"
}

seed_item() { sb_seed_queue_item "$1" "$2" "$3" "$4"; }

seed_deepcheck_flight() { # <rq_id> <lane> <card_id> <created_epoch>
  jq -n --arg rq "$1" --arg lane "$2" --arg id "$3" --argjson ep "$4" \
    '{kind:"deepcheck",card_id:$id,rq_id:$rq,lane:$lane,batch_file:"",created_epoch:$ep}' \
    > "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"
}

seed_card_store() { # <status>：flight 卡终态前置态（卡库 1 张 t_old）
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" \
    > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

seed_verdict() { # <id> <decision> <confidence> <risk_level> — auto-gate 输入（结构契约零改动）
  local d="$SB_ROOT/contrib-data/runs/deep-check/$1"
  mkdir -p "$d"
  jq -n --arg dec "$2" --arg conf "$3" --arg risk "$4" \
    '{decision:$dec,confidence:$conf,risk_level:$risk,reasons:[]}' > "$d/verdict.json"
}

seed_deep_budget_used() { # <id>：预置 deep 预算占用（refund 效果可观测，防 refund No-op 突变）
  local wk day
  wk="$(date +%G-W%V)"; day="$(date +%F)"
  jq --arg wk "$wk" --arg d "$day" --arg id "$1" \
    '.days[$d].used = 1 | .days[$d].items = [$id] | .weeks[$wk].used = 1 | .weeks[$wk].items = [$id]' \
    "$SB_ROOT/contrib-data/budget.json" > "$SB_ROOT/contrib-data/budget.json.tmp" \
    && mv "$SB_ROOT/contrib-data/budget.json.tmp" "$SB_ROOT/contrib-data/budget.json"
}

seed_draft() { # <id> — 真实链序：preflight 在 awaiting-approval 前已登记成稿（execute.sh 前置）
  local d="$SB_ROOT/contrib-data/pending/$1.md"
  printf '# 深检成稿（fixture）%s\n' "$1" > "$d"
  sb_run "bash \"\$MARTIN_DIR/scripts/contrib/rq.sh\" set-draft \"$1\" \"$d\"" >/dev/null
}

history_events() { # <id> → 该项 history 的 event 序列（每行一个）
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .history[]? | .event' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null || true
}

assert_ge1() { # <n> <label>：≥1 硬断言
  case "${1:-}" in
    ''|*[!0-9]*) _fail "$2" "非数值 [$1]" ;;
    *) [ "$1" -ge 1 ] && _pass "$2" || _fail "$2" "实得 $1 < 1" ;;
  esac
}

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
rq_lines()     { grep '^rq|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls_for() { hermes_lines | grep -c -- "--idempotency-key deepcheck-$1-" || true; }
claude_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'claude' || true; }
refund_calls_for() { rq_lines | grep -c -- "budget refund $1" || true; }

events_with()  { grep -c -- "$1" "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true; }
flight_field() { jq -r "$1" "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json" 2>/dev/null || echo ""; }
flight_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json" ]; }
budget_deep_used() { jq -r --arg d "$(date +%F)" '.days[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo "?"; }
budget_probe_used() { jq -r --arg d "$(date +%F)" '.probes[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo "?"; }
rq_state_of() {
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null || echo "?"
}

# chain_setup — 通用前置：A 已登记在飞 + B 为新候选 + refund 可观测（config 旋钮开）
chain_setup() { # <A_state> <card_status>
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  install_rq_recorder
  sb_config_set '.refund_failed_deep_check = true'
  seed_item "$A_ID" 101 deep "$1"
  seed_item "$B_ID" 202 probe queued
  seed_deepcheck_flight "$A_ID" deep "t_old" "$(date +%s)"
  seed_card_store "$2"
  CARD_STATUS="$2"   # 终态旋钮随 run 注入：兼容 list（读卡库）与 show（读 STUB_KANBAN_CARD_STATUS）
                     # 两种在飞查询实现——前置态对两种读法同真
}

run_deepcheck_entry() {
  sb_run -e "STUB_KANBAN_CARD_STATUS=${CARD_STATUS:-blocked}" "$@" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"'
}

# assert_harvest_continues <label> — 收割分支共用：清旧登记 + 流程继续为 B 建新卡
assert_harvest_continues() {
  local L="$1"
  assert_eq "$(create_calls_for "$B_ID")" "1" "$L 收割后继续为候选 $B_ID 建新卡（设计 §1 分支后顺序落入步骤 2/3）"
  assert_eq "$(flight_field '.rq_id')" "$B_ID" "$L 登记已换新项（旧登记清）"
  assert_ne "$(flight_field '.card_id')" "t_old" "$L 登记已换新卡"
}

# =============================================================================
t_case "C1 done+verdict(auto/high/low)+awaiting-approval → auto-gate rc0 → approved+execute 桥接 + 清登记"
chain_setup "awaiting-approval" "done"
seed_verdict "$A_ID" "auto" "high" "low"
seed_draft "$A_ID"
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "C1 run-deepcheck exit"
assert_eq "$(history_events "$A_ID" | grep -c '^approved$')" "1" \
  "C1 auto-gate rc0 → rq set approved 入 history（L2-auto 桥接保留，审查 B2；终态可能被 execute 失败链接管，故验 history 非终态）"
assert_ge1 "$(events_with "execute-fail-$A_ID")" "C1 编排层桥接 execute.sh 被调（执行链发起；沙箱 gh stub 下 TTL 失败属预期）"
assert_harvest_continues "C1"
assert_eq "$(claude_calls claude)" "0" "C1 收割+建卡主路零 claude"
assert_eq "$(budget_deep_used)" "0" "C1 成功收割不 refund deep 预算（无失败返还）"
assert_eq "$(budget_probe_used)" "1" "C1 新卡 probe reserve 已占额"
assert_eq "$(events_with "-deepcheck-card-fallback")" "0" "C1 零 card-fallback 事件"
assert_eq "$(events_with "-deepcheck-stale")" "0" "C1 零 stale 事件"
assert_eq "$(events_with "-deepcheck-orphan")" "0" "C1 零 orphan 事件"
sb_cleanup

# =============================================================================
t_case "C2 done+verdict(escalate)+awaiting-approval → auto-gate rc1 → 维持人工 + 清登记"
chain_setup "awaiting-approval" "done"
seed_verdict "$A_ID" "escalate" "high" "low"
seed_draft "$A_ID"
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "C2 run-deepcheck exit"
assert_eq "$(rq_state_of "$A_ID")" "awaiting-approval" "C2 auto-gate rc1 → 状态维持 awaiting-approval（不被强改 approved）"
assert_eq "$(history_events "$A_ID" | grep -c '^approved$')" "0" "C2 零 approved 迁移（升级人工，不进执行链）"
assert_harvest_continues "C2"
assert_eq "$(claude_calls claude)" "0" "C2 收割+建卡主路零 claude"
sb_cleanup

# =============================================================================
t_case "C3 done+rq=deep-check+子卡在跑（children 查询）→ 保留登记、零建卡零 claude"
chain_setup "deep-check" "done"
run_deepcheck_entry -e 'STUB_KANBAN_CHILDREN=["t_child"]' \
  -e 'STUB_KANBAN_STATUS_MAP={"t_child":"running"}' >/dev/null; RC=$?
assert_exit 0 $RC "C3 run-deepcheck exit"
assert_eq "$(flight_field '.card_id')" "t_old" "C3 子卡在跑 → 登记保留（preflight done ≠ 链完成）"
assert_eq "$(create_calls_for "$B_ID")" "0" "C3 链未完成 → 零新卡"
assert_eq "$(claude_calls claude)" "0" "C3 零 claude（在飞跳过≠fallback）"
assert_eq "$(events_with "-deepcheck-stale")" "0" "C3 子卡在跑零告警"
assert_eq "$(budget_deep_used)" "0" "C3 零 refund（预算不动）"
assert_eq "$(budget_probe_used)" "0" "C3 零 reserve（return 10 在步骤 2 前）"
assert_eq "$(rq_state_of "$A_ID")" "deep-check" "C3 A 状态不被动"
sb_cleanup

# =============================================================================
t_case "C4 done+rq=deep-check+子卡 blocked → rq set failed + refund + 清登记 + stale 事件"
chain_setup "deep-check" "done"
seed_deep_budget_used "$A_ID"
run_deepcheck_entry -e 'STUB_KANBAN_CHILDREN=["t_child"]' \
  -e 'STUB_KANBAN_STATUS_MAP={"t_child":"blocked"}' >/dev/null; RC=$?
assert_exit 0 $RC "C4 run-deepcheck exit"
assert_ge1 "$(history_events "$A_ID" | grep -c '^failed$')" "C4 子卡失败 → rq set failed 入 history（终态被同轮 retry 晋升接管的形态见 CONTRACT 注）"
assert_eq "$(budget_deep_used)" "0" "C4 refund 已返还（预置 1 → 0）"
assert_eq "$(refund_calls_for "$A_ID")" "1" "C4 budget refund 恰 1 次"
assert_eq "$(events_with "-deepcheck-stale")" "1" "C4 -deepcheck-stale 事件入账（链悬挂告警面，审查 I3）"
assert_harvest_continues "C4"
assert_eq "$(claude_calls claude)" "0" "C4 主路零 claude"
sb_cleanup

# =============================================================================
t_case "C5 done+rq=failed → 清登记 + refund + 继续建新卡（drill 后缀件：retry-failed 不晋升，failed 态才能存活到收割）"
chain_setup "queued" "done"   # A 项由 drill 变体单独播种
seed_item "rq-20260909-105-drill" 105 deep failed
seed_deepcheck_flight "rq-20260909-105-drill" deep "t_old" "$(date +%s)"
seed_deep_budget_used "rq-20260909-105-drill"
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "C5 run-deepcheck exit"
assert_eq "$(rq_state_of "rq-20260909-105-drill")" "failed" "C5 A 状态保持 failed（收割不改写）"
assert_eq "$(budget_deep_used)" "0" "C5 refund 已返还"
assert_ge1 "$(refund_calls_for "rq-20260909-105-drill")" "C5 budget refund 被调"
assert_harvest_continues "C5"
assert_eq "$(events_with "-deepcheck-orphan")" "0" "C5 rq 可查 → 零 orphan 事件"
sb_cleanup

# =============================================================================
t_case "C6 rq 查无（flight.rq_id 不在队列）→ 清登记 + -deepcheck-orphan 事件 + 零 refund"
chain_setup "queued" "done"
seed_deepcheck_flight "rq-20260909-777" deep "t_old" "$(date +%s)"   # 覆写为幽灵 rq_id
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "C6 run-deepcheck exit"
assert_eq "$(events_with "-deepcheck-orphan")" "1" "C6 -deepcheck-orphan 事件入账（人工复核面）"
assert_harvest_continues "C6"
assert_eq "$(refund_calls_for "rq-20260909-777")" "0" "C6 幽灵项零 refund"
sb_cleanup

# =============================================================================
t_case "C7 失败终态（blocked+outcome=gave_up）→ 清 + refund + rq set failed + card-fallback 事件"
chain_setup "deep-check" "blocked"
seed_deep_budget_used "$A_ID"
run_deepcheck_entry -e "STUB_KANBAN_RUN_OUTCOME=gave_up" >/dev/null; RC=$?
assert_exit 0 $RC "C7 run-deepcheck exit"
assert_ge1 "$(history_events "$A_ID" | grep -c '^failed$')" "C7 失败终态 → rq set failed 入 history"
assert_eq "$(budget_deep_used)" "0" "C7 refund 已返还"
assert_eq "$(events_with "-deepcheck-card-fallback")" "1" "C7 -deepcheck-card-fallback 事件入账（CONTRACT_AMBIGUOUS：key 按任务矩阵钉）"
assert_harvest_continues "C7"
assert_eq "$(claude_calls claude)" "0" "C7 失败终态→收割路，零 claude fallback"
sb_cleanup

# =============================================================================
t_case "C8 stale（DEEPCHECK_STALE_SECS=60，epoch-120s）→ 清 + refund + rq set failed + stale 事件"
chain_setup "deep-check" "running"
seed_deep_budget_used "$A_ID"
seed_deepcheck_flight "$A_ID" deep "t_old" "$(( $(date +%s) - 120 ))"
run_deepcheck_entry -e "DEEPCHECK_STALE_SECS=60" >/dev/null; RC=$?
assert_exit 0 $RC "C8 run-deepcheck exit"
assert_ge1 "$(history_events "$A_ID" | grep -c '^failed$')" "C8 stale → rq set failed 入 history"
assert_eq "$(budget_deep_used)" "0" "C8 refund 已返还"
assert_eq "$(events_with "-deepcheck-stale")" "1" "C8 -deepcheck-stale 事件入账"
assert_harvest_continues "C8"
sb_cleanup

# =============================================================================
t_case "C9 stale 下界守卫窗（SECS=3600，epoch-3595s）→ 未超时 → 保留登记跳过"
chain_setup "deep-check" "running"
seed_deepcheck_flight "$A_ID" deep "t_old" "$(( $(date +%s) - 3595 ))"
run_deepcheck_entry -e "DEEPCHECK_STALE_SECS=3600" >/dev/null
assert_eq "$(flight_field '.card_id')" "t_old" "C9 守卫窗内 → 登记保留"
assert_eq "$(create_calls_for "$B_ID")" "0" "C9 零新卡"
assert_eq "$(events_with "-deepcheck-stale")" "0" "C9 零 stale 事件"
assert_eq "$(rq_state_of "$A_ID")" "deep-check" "C9 状态不动"
assert_eq "$(budget_deep_used)" "0" "C9 预算不动"
sb_cleanup

# =============================================================================
t_case "C10 stale 上界（SECS=3600，epoch-3605s）→ 触发 stale 清理"
chain_setup "deep-check" "running"
seed_deep_budget_used "$A_ID"
seed_deepcheck_flight "$A_ID" deep "t_old" "$(( $(date +%s) - 3605 ))"
run_deepcheck_entry -e "DEEPCHECK_STALE_SECS=3600" >/dev/null
assert_ge1 "$(history_events "$A_ID" | grep -c '^failed$')" "C10 超时 → rq set failed 入 history"
assert_eq "$(budget_deep_used)" "0" "C10 refund 已返还"
assert_eq "$(events_with "-deepcheck-stale")" "1" "C10 stale 事件入账"
assert_ne "$(flight_field '.card_id')" "t_old" "C10 登记已清换新"
sb_cleanup

t_finish
