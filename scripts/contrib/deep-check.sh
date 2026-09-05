#!/bin/zsh
# deep-check.sh — 三轮审编排（预算 reserve → 阶段1 preflight → 阶段2 redteam → 审批推送）
# 由 launchd 09:37 调 deep_check_gate.sh 后自动衔接；亦可手动：deep-check.sh <rq-id> [lane]
# 结构性 fresh-context：两阶段是两个独立 claude -p 进程，只靠文件版次传递（v1→v2→final）。
set -uo pipefail

MARTIN="$HOME/workspace/martin"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONTRIB="$MARTIN/contrib-data"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
TARGET_FILE="/tmp/.deepcheck-target"
LOCK="/tmp/contrib-deepcheck.lock"
LOG="$CONTRIB/logs/deepcheck.log"

ts() { date "+%Y-%m-%dT%H%M"; }

log() { echo "[$(date '+%F %T')] deepcheck: $*" >>"$LOG"; }

# claude CLI 探测（同 run-watch.sh）
CLAUDE_BIN="$(command -v claude 2>/dev/null)"
[[ -z "$CLAUDE_BIN" ]] && CLAUDE_BIN="$(ls -t "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | head -1)"
if [[ -z "$CLAUDE_BIN" ]]; then
  log "找不到 claude CLI，放弃"
  exit 1
fi

# --- 目标解析：参数优先，否则读 gate 产物 ---
if [[ -n "${1:-}" ]]; then
  ID="$1"
  LANE="${2:-deep}"
else
  if [[ ! -s "$TARGET_FILE" ]]; then
    log "无 gate 产物（${TARGET_FILE}），退出"
    exit 0
  fi
  read -r ID LANE < "$TARGET_FILE"
  rm -f "$TARGET_FILE"
fi
[[ -n "$ID" && -n "$LANE" ]] || { log "目标解析失败"; exit 1; }

# --- 防重入 ---
if ! mkdir "$LOCK" 2>/dev/null; then
  log "上轮深检仍在运行，跳过 $ID"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

D="$CONTRIB/runs/deep-check/$ID"
mkdir -p "$D"

log "==== 深检启动 $ID ===="
LANE="$(jq -r --arg id "$ID" '.items[] | select(.id == $id) | .lane' "$CONTRIB/ready-queue.json")"
if [[ -z "$LANE" || "$LANE" == "null" ]]; then
  log "队列中找不到 ${ID}，退出"
  exit 1
fi

# --- 状态预检：必须仍为 queued（gate 之后可能被 radar 判 expired）---
state="$(jq -r --arg id "$ID" '.items[] | select(.id == $id) | .state' "$CONTRIB/ready-queue.json")"
if [[ "$state" != "queued" ]]; then
  log "${ID} 当前 state=${state}（非 queued），跳过"
  exit 0
fi

# --- 预算 reserve ---
res="$("$RQ" budget reserve "$ID" --lane "$LANE" 2>&1)"
if [[ "$res" != "OK" ]]; then
  log "预算 reserve 失败：${res}，跳过 ${ID}"
  exit 0
fi

"$RQ" set "$ID" deep-check --note "deep-check 启动（lane=${LANE}）" >>"$LOG" 2>&1

fail() {
  log "$ID 阶段 $1 失败，置 failed"
  "$RQ" set "$ID" failed --note "$1 失败" >>"$LOG" 2>&1 || true
  "$RQ" budget refund "$ID" --lane "$LANE" >>"$LOG" 2>&1 || true   # 内部按 refund_failed_deep_check 决定
  "$NOTIFY" event pipeline-failure --key "$(date +%F)-deepcheck-$ID" \
    --summary "深检 $ID 阶段 $1 失败（详见 runs/deep-check/$ID/run.log）" >/dev/null 2>&1 || true
  exit 1
}

# --- 阶段 1：strategist preflight + 亲手核 → 草稿 v2 ---
log "阶段1 preflight 启动"
"$CLAUDE_BIN" -p "/contrib-watch deep-check $ID --phase preflight" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Write,Edit,Grep,Glob,Agent,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(rg *),Bash(scripts/contrib/rq.sh set *),Bash(scripts/contrib/rq.sh set-draft *)" \
  >>"$D/run.log" 2>&1 || fail preflight

# v2 草稿必须已登记
draft="$("$RQ" show "$ID" --json 2>/dev/null | jq -r '.draft // ""')"
if [[ -z "$draft" || ! -f "$draft" ]]; then
  fail "preflight（草稿未产出）"
fi
log "阶段1 preflight 完成 → $draft"

# --- 阶段 2：fresh-context 红队（仅 deep 车道；probe 单轮免红队）---
if [[ "$LANE" == "deep" ]]; then
  log "阶段2 redteam 启动"
  "$CLAUDE_BIN" -p "/contrib-watch deep-check $ID --phase redteam" \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,Grep,Glob,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(rg *),Bash(scripts/contrib/rq.sh set *)" \
    >>"$D/run.log" 2>&1 || fail redteam
  log "阶段2 redteam 完成"
else
  log "probe 车道免红队，直接待批"
fi

# --- 待批 + 推送审批卡 ---
"$RQ" set "$ID" awaiting-approval --note "深检完成（lane=${LANE}），草稿待批" >>"$LOG" 2>&1
"$NOTIFY" approve "$ID" >>"$LOG" 2>&1 || log "审批推送失败（事件保留，补推链兜底）"
log "==== 深检完成 $ID → awaiting-approval ===="
