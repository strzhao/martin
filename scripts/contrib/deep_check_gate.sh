#!/bin/bash
# deep_check_gate.sh — 深检闸门（无 LLM）：队列有可跑项且预算可行 → exit 10（目标 id 写 /tmp/.deepcheck-target）
# 由 launchd 09:37（run-deepcheck.sh）调用；亦可手动触发后接 deep-check.sh。
# exit: 0=无可跑项  10=有候选（id 已写 /tmp/.deepcheck-target）  其他=错误
set -euo pipefail

MARTIN="$HOME/workspace/martin"
RQ="$MARTIN/scripts/contrib/rq.sh"
CONFIG="$MARTIN/contrib-data/config.json"
TARGET_FILE="/tmp/.deepcheck-target"
LOG="$MARTIN/contrib-data/logs/deepcheck.log"

log() { echo "[$(date '+%F %T')] gate: $*" >>"$LOG"; }

# 残留锁清理（>3h 视为上轮卡死）
LOCK="/tmp/contrib-deepcheck.lock"
if [[ -d "$LOCK" ]]; then
  age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
  if (( age > 10800 )); then
    log "锁滞留 ${age}s，强清"
    rmdir "$LOCK" 2>/dev/null || true
  else
    log "上轮仍在运行（${age}s），跳过"
    exit 0
  fi
fi

# failed → queued（重试晋升，drill 件除外）
"$RQ" retry-failed >/dev/null

auto="$(jq -r '.auto_deep_check // true' "$CONFIG")"

# 1) probe 车道：不受 auto_deep_check 管（轻量），只受 probe_per_day 管
if [[ "$("$RQ" budget check --lane probe)" == "OK" ]]; then
  pid="$("$RQ" next --lane probe || true)"
  if [[ -n "$pid" ]]; then
    echo "$pid probe" > "$TARGET_FILE"
    log "候选（probe）: $pid"
    exit 10
  fi
fi

# 2) deep 车道：auto 开关 + 预算双闸；配额不够 → 告警通知（候选项排队等明日重试）
if [[ "$auto" == "true" ]]; then
  did="$("$RQ" next --lane deep || true)"
  if [[ -n "$did" ]]; then
    budget_check="$("$RQ" budget check --lane deep)"
    if [[ "$budget_check" == "OK" ]]; then
      echo "$did deep" > "$TARGET_FILE"
      log "候选（deep）: $did"
      exit 10
    else
      "$MARTIN/scripts/contrib/notify.sh" event deep-budget-exhausted \
        --key "$(date +%F)-deep-budget-${budget_check##* }" \
        --summary "深检${budget_check##* }配额已用完，候选 ${did} 排队等明日 09:37 自动重试（config.json 的 deep_check_per_day/week 可调）" >/dev/null 2>&1 || true
      "$MARTIN/scripts/contrib/notify.sh" flush >/dev/null 2>&1 || true
      log "候选 ${did} 因配额不足（${budget_check}）等待，已告警"
    fi
  fi
fi

log "无可跑项（auto=${auto}）"
exit 0
