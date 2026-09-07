#!/bin/zsh
# run-deepcheck.sh — 深检 launchd 入口（每日 09:37）
#   1. 无 LLM 闸门（预算/候选探测）
#   2. 有候选 → 三轮审编排（两次独立 claude -p）→ 审批卡推送
# 所有产物落 contrib-data/，本脚本零上游写操作。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
LOG="$CONTRIB/logs/deepcheck.log"

# launchd 默认 cwd=/，claude -p "/contrib-watch ..." 依赖 martin 的项目级 skill
# （.claude/skills/），不 cd 会在 preflight 直接 Unknown command（09-05 实证）
cd "$MARTIN" || exit 1

echo "[$(date '+%F %T')] ===== run-deepcheck start =====" >>"$LOG"

if zsh "$MARTIN/scripts/contrib/deep_check_gate.sh" >>"$LOG" 2>&1; then
  rc=0
else
  rc=$?
fi

if (( rc == 10 )); then
  echo "[$(date '+%F %T')] gate 命中候选 → 深检编排" >>"$LOG"
  # 整壳超时 seam：deep-check.sh 自身挂死时入口层兜底转成失败留证（09-06 实证：子进程死后
  # 父 zsh 失收尸永挂 waitjobs，内层 `|| fail` 永不触发，项卡 deep-check 需人工解锁）
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
elif (( rc == 0 )); then
  echo "[$(date '+%F %T')] 无候选，跳过" >>"$LOG"
else
  echo "[$(date '+%F %T')] gate 出错 rc=$rc" >>"$LOG"
fi

echo "[$(date '+%F %T')] ===== run-deepcheck done =====" >>"$LOG"
