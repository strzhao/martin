#!/bin/zsh
# run-deepcheck.sh — 深检 launchd 入口（每日 09:37 兜底；T4 卡化后语义=兜底建卡）
#   1. 无 LLM 闸门（预算/候选探测）
#   2. 有候选 → 建 preflight 卡主路（deepcheck_card.sh，与 run-watch 快车道同一 helper 两入口等价）；
#      建卡失败才 fallback claude 编排壳（deep-check.sh 原样保留）
#   3. 在飞（rc10）→ 日志跳过、绝不 fallback（防双轨并发 + budget 双 reserve——设计钉死点①）
# 所有产物落 contrib-data/，本脚本零上游写操作。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
LOG="$CONTRIB/logs/deepcheck.log"
DEEPCHECK_CARD="$MARTIN/scripts/contrib/deepcheck_card.sh"

# launchd 默认 cwd=/，claude -p "/contrib-watch ..." 依赖 martin 的项目级 skill
# （.claude/skills/），不 cd 会在 preflight 直接 Unknown command（09-05 实证）
cd "$MARTIN" || exit 1

# board 切换（T6）：深检卡与查询 pin contrib 专用 board（同 run-watch 一个开关；回退=删除本行
# 或外部 export KANBAN_BOARD=""——`${KANBAN_BOARD-contrib}` 只对 unset 取缺省，显式空串=显式回退）
export KANBAN_BOARD="${KANBAN_BOARD-contrib}"

echo "[$(date '+%F %T')] ===== run-deepcheck start =====" >>"$LOG"

# fallback claude 编排壳（建卡失败才走；原样保留——整壳超时 seam：deep-check.sh 自身挂死时
# 入口层兜底转成失败留证，09-06 实证：子进程死后父 zsh 失收尸永挂 waitjobs）
run_fallback_orch() {
  orch_rc=0
  orch_to="${DEEPCHECK_ORCH_TIMEOUT:-14400}"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$orch_to" zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1 || orch_rc=$?
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$orch_to" zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1 || orch_rc=$?
  else
    zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1 || orch_rc=$?
  fi
  echo "[$(date '+%F %T')] 深检编排完成 exit=$orch_rc" >>"$LOG"
  if (( orch_rc == 124 || orch_rc == 142 )); then
    echo "[$(date '+%F %T')] 深检编排超时被整壳兜底击杀（${orch_to}s）" >>"$LOG"
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-deepcheck-orch-timeout" \
      --summary "深检编排超时（${orch_to}s）被兜底击杀，队列项状态需人工复核" >/dev/null 2>&1 || true
  fi
}

# 终态收割先行（与 run-watch 快车道同序：凡存在登记每轮即查，链完成 → auto-gate 编排层桥接）
if [[ -x "$DEEPCHECK_CARD" ]]; then
  bash "$DEEPCHECK_CARD" harvest >>"$LOG" 2>&1 \
    || echo "[$(date '+%F %T')] deepcheck flight 收割异常（下轮重试）" >>"$LOG"
fi

if zsh "$MARTIN/scripts/contrib/deep_check_gate.sh" >>"$LOG" 2>&1; then
  rc=0
else
  rc=$?
fi

if (( rc == 10 )); then
  if [[ -x "$DEEPCHECK_CARD" ]]; then
    bash "$DEEPCHECK_CARD" create >>"$LOG" 2>&1
    dc_rc=$?
    if (( dc_rc == 0 )); then
      echo "[$(date '+%F %T')] 深检 preflight 卡已建（主路）" >>"$LOG"
    elif (( dc_rc == 10 )); then
      # 三态显式分支（重审钉死）：10=日志跳过、绝不走 fallback——在飞时走 fallback
      # = 双轨并发 + 双 reserve，击穿防双轨目标
      echo "[$(date '+%F %T')] 深检卡在飞/跳过（全局单深检语义），fallback 不启用" >>"$LOG"
    else
      echo "[$(date '+%F %T')] 深检建卡失败 rc=$dc_rc → fallback claude 编排壳" >>"$LOG"
      run_fallback_orch
    fi
  else
    echo "[$(date '+%F %T')] deepcheck_card.sh 缺失 → fallback claude 编排壳" >>"$LOG"
    run_fallback_orch
  fi
elif (( rc == 0 )); then
  echo "[$(date '+%F %T')] 无候选，跳过" >>"$LOG"
else
  echo "[$(date '+%F %T')] gate 出错 rc=$rc" >>"$LOG"
fi

echo "[$(date '+%F %T')] ===== run-deepcheck done =====" >>"$LOG"
