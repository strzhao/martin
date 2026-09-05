#!/bin/zsh
# contrib-watch launchd 入口：每小时 :07 触发
#   1. 廉价闸门（无 LLM）；有命中 → headless claude -p 研判（contrib-watch skill 的 scan 模式）
#   2. 每日 08 窗口 → radar（停滞 PR 雷达 + 自有资产盘点 + 至多 1 个本地自动构建）
# 所有产物落 contrib-data/，本脚本只做编排，不做任何对外动作（无 push/无评论）。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
LOG="$CONTRIB/logs/launchd.log"
LOCK="${WATCH_LOCK:-/tmp/contrib-watch.lock}"
ts() { date "+%Y-%m-%dT%H%M"; }

# claude CLI 装在 nvm node bin，版本目录随升级漂移——launchd PATH 极简，须运行时探测（09-03 修复 command not found）
# seam：CLAUDE_BIN env 优先，空则走现有两级探测（默认语义=现状）
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [[ -z "$CLAUDE_BIN" ]]; then
  CLAUDE_BIN="$(command -v claude 2>/dev/null)"
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  CLAUDE_BIN="$(ls -t "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | head -1)"
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  echo "[$(ts)] ⚠ 找不到 claude CLI（nvm/node 未装或路径漂移？），跳过 LLM 步骤" >>"$LOG"
  "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
    --key "$(date +%F)-no-claude-bin" --summary "run-watch 找不到 claude CLI（nvm 路径漂移？）" >/dev/null 2>&1 || true
fi
echo "[$(ts)] CLAUDE_BIN=$CLAUDE_BIN" >>"$LOG"

echo "[$(ts)] ===== run-watch start (hour=$(date +%H)) =====" >>"$LOG"

# 防重入（上一轮 LLM 还没跑完时跳过本轮）；锁滞留 >2h 视为残留 → 告警并强清
if ! mkdir "$LOCK" 2>/dev/null; then
  lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || date +%s) ))
  if (( lock_age > 7200 )); then
    echo "[$(ts)] ⚠ 锁滞留 ${lock_age}s（>2h，疑似残留），强清并继续" >>"$LOG"
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-lock-stale" --summary "contrib-watch 锁滞留超 2h，已强清（上轮 LLM 卡死？）" >/dev/null 2>&1 || true
    rmdir "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || { echo "[$(ts)] 强清失败，本轮放弃" >>"$LOG"; exit 0; }
  else
    echo "[$(ts)] 上一轮仍在运行（${lock_age}s），跳过" >>"$LOG"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

cd "$MARTIN"

# --- 1. 廉价闸门 ---
if zsh "$MARTIN/scripts/contrib/scan_gate.sh" >>"$LOG" 2>&1; then
  rc=0
else
  rc=$?
fi

if (( rc == 10 )); then
  echo "[$(ts)] 有域内命中 → headless 研判" >>"$LOG"
  [[ -n "$CLAUDE_BIN" ]] && "$CLAUDE_BIN" -p "/contrib-watch scan" \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,Grep,Glob,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *)" \
    >>"$LOG" 2>&1
  scan_rc=$?
  echo "[$(ts)] 研判完成 exit=$scan_rc" >>"$LOG"
  if (( scan_rc != 0 )); then
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-scan-exit$scan_rc" --summary "scan 研判 claude -p 失败 exit=$scan_rc" >/dev/null 2>&1 || true
  fi
elif (( rc == 0 )); then
  echo "[$(ts)] 无命中" >>"$LOG"
else
  echo "[$(ts)] 闸门出错 rc=${rc}（gh 网络抖动？下轮重试）" >>"$LOG"
  "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
    --key "$(date +%F)-gate-rc$rc" --summary "scan_gate 闸门异常 rc=$rc" >/dev/null 2>&1 || true
fi

# --- 2. 每日 radar（08 窗口；抽 maybe_radar 便于测试注入 hour，默认=现状 date +%H）---
maybe_radar() {
  local hour="${1:-$(date +%H)}"
  if [[ "$hour" == "08" ]]; then
    echo "[$(ts)] 每日 radar 启动" >>"$LOG"
    [[ -n "$CLAUDE_BIN" ]] && "$CLAUDE_BIN" -p "/contrib-watch radar" \
      --permission-mode acceptEdits \
      --allowedTools "Read,Write,Edit,Grep,Glob,Agent,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(git *),Bash(cd *),Bash(scripts/contrib/*),Bash(pytest *),Bash(python *),Bash(python3 *),Bash(ruff *),Bash(rg *)" \
      >>"$LOG" 2>&1
    radar_rc=$?
    echo "[$(ts)] radar 完成 exit=$radar_rc" >>"$LOG"
    if (( radar_rc != 0 )); then
      "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
        --key "$(date +%F)-radar-exit$radar_rc" --summary "radar claude -p 失败 exit=$radar_rc" >/dev/null 2>&1 || true
    fi
  fi
}
maybe_radar

# --- 3. 通知层：聚合推送本轮新增告警（失败不影响流水线退出码）---
if [[ -x "$MARTIN/scripts/contrib/notify.sh" ]]; then
  "$MARTIN/scripts/contrib/notify.sh" flush >>"$LOG" 2>&1 \
    || echo "[$(ts)] notify flush 失败（事件保留，下轮重试）" >>"$LOG"
fi

# --- 4. 快车道（09-04）：scan 刚产出候选 → 立即后台深检，不等明早 09:37（该窗口保留为兜底）---
if [[ -x "$MARTIN/scripts/contrib/deep_check_gate.sh" ]]; then
  zsh "$MARTIN/scripts/contrib/deep_check_gate.sh" >>"$LOG" 2>&1
  gate_rc=$?
  if (( gate_rc == 10 )); then
    echo "[$(ts)] 快车道：深检候选就绪 → 后台启动 deep-check.sh（nohup，不阻塞下一轮 scan）" >>"$LOG"
    nohup zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1 &
  elif (( gate_rc == 0 )); then
    echo "[$(ts)] 快车道：无可跑项" >>"$LOG"
  else
    echo "[$(ts)] 快车道：gate 出错 rc=$gate_rc" >>"$LOG"
  fi
fi

echo "[$(ts)] ===== run-watch done =====" >>"$LOG"
