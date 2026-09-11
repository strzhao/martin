#!/usr/bin/env bash
# =============================================================================
# t4-03-deepcheck-dual-track-guard.acceptance.test.sh — T4 验收③：防双轨 + fallback + 互斥锁 +
#   reserve 时序 + 零改动自证
#   D1  flight 在飞 × run-watch 快车道 → 零建卡、零 fallback claude、预算零消耗（防双轨核心）
#   D2  flight 在飞（跨 rq-id）× run-deepcheck → 同上（全局单深检：任一登记在飞即跳过）
#   D3  建卡互斥锁（deepcheck-card.lock 持有中）→ 第二次调用在锁内被跳过：零建卡零 claude
#   D4  锁残留 >3h → 强清后正常建卡
#   D5  reserve 时序：budget reserve 先于 kanban create（记录器行序断言）+ reserve 占额
#   D6  reserve 失败（DENY）→ 零建卡零 claude 零登记零预算消耗
#   D7  建卡失败 → fallback deep-check.sh 被调（run-deepcheck 前台路）：claude 恰 1 次
#       （零双 fallback）+ card-fallback 事件 + reserve/refund 配平（budget 零双 reserve）
#   D8  建卡失败 → fallback（run-watch nohup 路）：claude 恰 1 次 + card-fallback 事件
#   D9  零改动自证：deep_check_gate.sh / deep-check.sh / auto-gate.sh / rq.sh 工作树 vs HEAD
#       vs T3 锚（48b0d58）零 diff
# 依据：state.md「## 设计文档」§1 步骤 0（专属互斥锁）/§2 步骤 2（reserve 时序）/§3（run-deepcheck
#   三态显式分支：10=日志跳过、绝不走 fallback；1=才 fallback）+ 输出契约 2（防双轨：在飞零
#   fallback claude、budget 零双 reserve）+ 输出契约 5（deep-check.sh 零改动保留）
# CONTRACT_AMBIGUOUS：
#  - D3 锁持有中被跳过时的返回码（0/10）未钉死——只断言「零建卡零 claude零事件」的行为面
#  - D8 run-watch fallback 为 nohup 后台：以轮询「rq set failed」终态标记收敛后再计数
#  - 锁路径 $CONTRIB/locks/deepcheck-card.lock 为设计 §1 字面量——实现改名即红（契约对齐面）
# 红队纪律：黑盒；每断言硬失败；无 skip。Mental Mutation：在飞走 fallback → D1/D2 claude 挂；
#   互斥锁删除 → D3 两入口并发双建卡（本测以持锁注入表达）；锁强清删除 → D4 挂；reserve 挪到
#   create 后 → D5 行序断言挂；reserve 失败仍建卡 → D6 挂；fallback 双跑 → D7/D8 claude==1 挂；
#   refund 缺失 → D7 预算配平挂；偷改零改动文件 → D9 挂。
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

T3_ANCHOR="${T4_T3_ANCHOR:-48b0d58}" # T3 commit：deepcheck 零改动四文件的改动前基线

# ---- 本文件专用装具 ----

install_rq_recorder() { # rq.sh 调用记录器（透传真身）：reserve/refund/set 行序与计数
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
if [[ "${STUB_RQ_RESERVE_FAIL:-}" == "1" && "${1:-}" == "budget" && "${2:-}" == "reserve" ]]; then
  echo "DENY day-limit"
  exit 1
fi
exec bash "${MARTIN_DIR:?}/scripts/contrib/rq-real.sh" "$@"
EOF
  chmod +x "$SB_ROOT/scripts/contrib/rq.sh"
}

install_fake_date() { # 沙箱 date stub：仅劫持裸 '+%H'（radar 窗口消除），其余透传
  mkdir -p "$SB_HOME/.local/bin"
  cat > "$SB_HOME/.local/bin/date" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "+%H" && "$#" -eq 1 ]]; then
  printf '%s\n' "${STUB_DATE_HOUR:-14}"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$SB_HOME/.local/bin/date"
}

seed_item() { sb_seed_queue_item "$1" "$2" "$3" "$4"; }

seed_deepcheck_flight() { # <rq_id> <lane> <card_id> <created_epoch>
  jq -n --arg rq "$1" --arg lane "$2" --arg id "$3" --argjson ep "$4" \
    '{kind:"deepcheck",card_id:$id,rq_id:$rq,lane:$lane,batch_file:"",created_epoch:$ep}' \
    > "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"
}

seed_card_store() { # <status>：在飞前置态（卡库 1 张 t_old）
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" \
    > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
rq_lines()     { grep '^rq|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls_for() { hermes_lines | grep -c -- "--idempotency-key deepcheck-$1-" || true; }
claude_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'claude' || true; }
reserve_calls() { rq_lines | grep -c 'budget reserve ' || true; }
refund_calls()  { rq_lines | grep -c 'budget refund ' || true; }

events_with()  { grep -c -- "$1" "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true; }
flight_field() { jq -r "$1" "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json" 2>/dev/null || echo ""; }
flight_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json" ]; }
budget_deep_used() { jq -r --arg d "$(date +%F)" '.days[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo "?"; }
rq_state_of() {
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null || echo "?"
}

wait_log() { # <pattern> <timeout_secs> — nohup 后台路收敛轮询（终态标记出现或超时）
  local i=0
  while [ "$i" -lt "$(($2 * 2))" ]; do
    grep -qF -- "$1" "$SB_ROOT/stublog/calls.log" 2>/dev/null && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

run_deepcheck_entry() { sb_run "$@" 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"'; }
run_watch_entry()     { sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json" "$@" \
                          'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"'; }

common_setup() { # 沙箱 + rq 记录器 + gh 空命中 + date 影子 + refund 可观测
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  install_rq_recorder
  install_fake_date
  sb_config_set '.refund_failed_deep_check = true'
  printf '[]\n' > "$SB_ROOT/tmp/issues.json"
}

# =============================================================================
t_case "D1 flight 在飞 × run-watch 快车道 → 零建卡、零 fallback claude、预算零消耗"
common_setup
seed_item "rq-20260909-101" 101 deep queued
seed_deepcheck_flight "rq-20260909-101" deep "t_old" "$(date +%s)"
seed_card_store "running"
run_watch_entry >/dev/null; RC=$?
assert_exit 0 $RC "D1 run-watch exit"
assert_eq "$(create_calls_for "rq-20260909-101")" "0" "D1 在飞 → 零第二张卡（同 kind 单飞）"
assert_eq "$(claude_calls claude)" "0" "D1 在飞 → 零 fallback claude（防双轨核心断言）"
assert_eq "$(flight_field '.card_id')" "t_old" "D1 登记保留"
assert_eq "$(budget_deep_used)" "0" "D1 budget 零双 reserve"
assert_eq "$(events_with "-deepcheck-card-fallback")" "0" "D1 在飞跳过零 fallback 事件"
assert_eq "$(rq_state_of "rq-20260909-101")" "queued" "D1 状态不被在飞轮改写"
sb_cleanup

# =============================================================================
t_case "D2 flight 在飞（跨 rq-id）× run-deepcheck → 全局单深检：同样零建卡零 fallback"
common_setup
seed_item "rq-20260909-202" 202 probe queued   # 新候选 ≠ 登记项
seed_deepcheck_flight "rq-20260909-101" deep "t_old" "$(date +%s)"
seed_card_store "running"
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "D2 run-deepcheck exit（三态显式分支：10=日志跳过，脚本不失败）"
assert_eq "$(create_calls_for "rq-20260909-202")" "0" "D2 任一 deepcheck 登记在飞 → 零新卡（全局单深检）"
assert_eq "$(claude_calls claude)" "0" "D2 在飞 → 绝不走 fallback（rc10 分支，防双轨+双 reserve）"
assert_eq "$(flight_field '.card_id')" "t_old" "D2 登记保留"
assert_eq "$(budget_deep_used)" "0" "D2 budget 零双 reserve"
assert_eq "$(events_with "-deepcheck-card-fallback")" "0" "D2 零 fallback 事件"
sb_cleanup

# =============================================================================
t_case "D3 建卡互斥锁持有中 → 第二次调用在锁内被跳过：零建卡零 claude"
common_setup
seed_item "rq-20260909-101" 101 deep queued
mkdir -p "$SB_ROOT/contrib-data/locks/deepcheck-card.lock"   # 模拟并发第一调用正持锁
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "D3 run-deepcheck exit"
assert_eq "$(create_calls_for "rq-20260909-101")" "0" "D3 锁内 → 零建卡（check→reserve→create→登记 全程互斥）"
assert_eq "$(claude_calls claude)" "0" "D3 锁内跳过 ≠ fallback：零 claude"
assert_eq "$(flight_exists && echo yes || echo no)" "no" "D3 零 flight 登记"
assert_eq "$(budget_deep_used)" "0" "D3 锁内跳过零 reserve"
sb_cleanup

# =============================================================================
t_case "D4 锁残留 >3h → 强清后正常建卡（deep-check.sh:79 先例口径）"
common_setup
seed_item "rq-20260909-101" 101 deep queued
mkdir -p "$SB_ROOT/contrib-data/locks/deepcheck-card.lock"
touch -t 202001010000 "$SB_ROOT/contrib-data/locks/deepcheck-card.lock"   # mtime 远古 → 残留
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "D4 run-deepcheck exit"
assert_eq "$(create_calls_for "rq-20260909-101")" "1" "D4 残留锁强清 → 建卡不被永久卡死"
flight_exists && _pass "D4 flight 正常登记" || _fail "D4 flight 正常登记" "强清后未登记"
sb_cleanup

# =============================================================================
t_case "D5 reserve 时序：budget reserve 先于 kanban create（记录器行序断言）"
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_deepcheck_entry >/dev/null
RES_LINE="$(grep -n 'budget reserve ' "$SB_ROOT/stublog/calls.log" 2>/dev/null | tail -1 | cut -d: -f1)"
CRT_LINE="$(grep -n 'kanban create' "$SB_ROOT/stublog/calls.log" 2>/dev/null \
  | grep -- '--idempotency-key deepcheck-' | head -1 | cut -d: -f1)"
case "$RES_LINE" in
  ''|*[!0-9]*) _fail "D5 reserve 被调" "calls.log 无 budget reserve 行" ;;
  *)
    case "$CRT_LINE" in
      ''|*[!0-9]*) _fail "D5 create 被调" "calls.log 无 deepcheck 建卡行" ;;
      *) [ "$RES_LINE" -lt "$CRT_LINE" ] \
        && _pass "D5 reserve 行($RES_LINE) < create 行($CRT_LINE)：在建卡前被调" \
        || _fail "D5 reserve 时序" "reserve($RES_LINE) 未先于 create($CRT_LINE)"
    esac ;;
esac
assert_eq "$(budget_deep_used)" "1" "D5 reserve 占额生效（deep 当日 1）"
sb_cleanup

# =============================================================================
t_case "D6 reserve 失败（DENY）→ 零建卡零 claude 零登记零预算消耗"
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_deepcheck_entry -e "STUB_RQ_RESERVE_FAIL=1" >/dev/null; RC=$?
assert_exit 0 $RC "D6 run-deepcheck exit"
assert_eq "$(create_calls_for "rq-20260909-101")" "0" "D6 reserve 失败 → 零建卡（防超发时序闸）"
assert_eq "$(claude_calls claude)" "0" "D6 fallback 路同样 reserve 失败 → 零 claude（同一轮零 LLM 消耗）"
flight_exists && _fail "D6 零 flight 登记" "reserve 失败仍写登记（会把下轮锁死在飞态）" \
  || _pass "D6 零 flight 登记"
assert_eq "$(budget_deep_used)" "0" "D6 预算零消耗"
sb_cleanup

# =============================================================================
t_case "D7 建卡失败 → fallback deep-check.sh（run-deepcheck 前台路）：claude 恰 1 次 + 配平"
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_deepcheck_entry -e "STUB_HERMES_FAIL=1" -e "STUB_CLAUDE_FAIL=1" >/dev/null; RC=$?
assert_exit 0 $RC "D7 run-deepcheck exit"
assert_eq "$(create_calls_for "rq-20260909-101")" "1" "D7 前置：建卡确实被尝试（stub 注毒生效）"
assert_eq "$(claude_calls claude)" "1" "D7 fallback claude 被调且只跑一次（preflight 失败即止，零双 fallback）"
assert_eq "$(events_with "-deepcheck-card-fallback")" "1" "D7 card-fallback 事件入账"
assert_eq "$(rq_state_of "rq-20260909-101")" "failed" "D7 fallback preflight 失败 → rq set failed"
assert_eq "$(reserve_calls)" "2" "D7 reserve 恰 2 次（卡路 + fallback 各 1，refund 先行故无双 reserve）"
assert_eq "$(refund_calls)" "2" "D7 refund 恰 2 次（卡路失败 + fallback fail 路各 1）"
assert_eq "$(budget_deep_used)" "0" "D7 budget 配平（reserve×2 − refund×2 = 0，零双 reserve 实证）"
flight_exists && _fail "D7 失败不写 flight" "建卡失败仍留登记" || _pass "D7 失败不写 flight"
if [ -e "$SB_ROOT/locks/deepcheck-target" ]; then
  _fail "D7 TARGET_FILE 已消费" "fallback 结束后残留（跨轮幽灵建卡隐患）"
else
  _pass "D7 TARGET_FILE 已消费（fallback deep-check.sh 读取后 rm，与主路成功对称）"
fi
sb_cleanup

# =============================================================================
t_case "D8 建卡失败 → fallback（run-watch nohup 路）：claude 恰 1 次 + card-fallback 事件"
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_watch_entry -e "STUB_HERMES_FAIL=1" -e "STUB_CLAUDE_FAIL=1" >/dev/null; RC=$?
assert_exit 0 $RC "D8 run-watch exit"
# nohup 后台路收敛轮询：等 claude 调用行出现（preflight 失败后 fail 路不再有 claude，计数即稳定），
# 再等第 2 次 refund（fail 路收尾）——整链落账后再断言（"set failed" 字样不可用作标记：卡 body
# 的链悬挂纪律句含同字面，会假命中）
if wait_log "claude|" 20; then
  _pass "D8 nohup fallback 收敛（claude 调用行出现）"
else
  _fail "D8 nohup fallback 收敛" "20s 内未观察到 fallback claude 调用"
fi
i=0
while [ "$i" -lt 40 ] && [ "$(refund_calls)" -lt 2 ]; do sleep 0.5; i=$((i + 1)); done
assert_eq "$(claude_calls claude)" "1" "D8 fallback claude 恰 1 次（nohup 收割坑已由 plist 旗标解，零双跑）"
assert_eq "$(events_with "-deepcheck-card-fallback")" "1" "D8 card-fallback 事件入账"
assert_eq "$(budget_deep_used)" "0" "D8 budget 配平（含 fail 路收尾 refund）"
sb_cleanup

# =============================================================================
t_case "D9 零改动自证：T4 暂存集不含四文件（rq.sh 等系共享基建，并行会话合法改动不入本任务断言——09-09 语义精确化：改验暂存 diff 而非工作树 vs HEAD）"
for f in deep_check_gate.sh deep-check.sh auto-gate.sh rq.sh; do
  if [ -f "$REPO_ROOT/scripts/contrib/$f" ]; then p="scripts/contrib/$f"; else p="scripts/approval/$f"; fi
  git -C "$REPO_ROOT" diff --cached --exit-code HEAD -- "$p" >/dev/null 2>&1
  assert_exit 0 $? "D9 $p 在 T4 暂存集中零 diff（工作树改动可能来自并行会话，不归本任务）"
  if git -C "$REPO_ROOT" cat-file -e "$T3_ANCHOR" 2>/dev/null; then
    git -C "$REPO_ROOT" diff --cached --exit-code "$T3_ANCHOR" -- "$p" >/dev/null 2>&1
    assert_exit 0 $? "D9 $p 暂存集 vs T3 锚 $T3_ANCHOR 零 diff（防 HEAD 前移使检查空转）"
  else
    _fail "D9 T3 锚不可解析" "commit $T3_ANCHOR 不在仓内——可用 T4_T3_ANCHOR 覆盖"
  fi
done

t_finish
