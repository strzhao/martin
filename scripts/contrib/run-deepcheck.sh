#!/bin/zsh
# run-deepcheck.sh — 深检 launchd 入口（每日 09:37）
#   1. 无 LLM 闸门（预算/候选探测）
#   2. 有候选 → 三轮审编排（两次独立 claude -p）→ 审批卡推送
# 所有产物落 contrib-data/，本脚本零上游写操作。
set -uo pipefail

MARTIN="$HOME/workspace/martin"
LOG="$MARTIN/contrib-data/logs/deepcheck.log"

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
  zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1
  echo "[$(date '+%F %T')] 深检编排完成 exit=$?" >>"$LOG"
elif (( rc == 0 )); then
  echo "[$(date '+%F %T')] 无候选，跳过" >>"$LOG"
else
  echo "[$(date '+%F %T')] gate 出错 rc=$rc" >>"$LOG"
fi

echo "[$(date '+%F %T')] ===== run-deepcheck done =====" >>"$LOG"
