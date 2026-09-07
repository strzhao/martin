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

# 模型 pin seam：settings.json env 注入的模型名可能带 [1M] 后缀（bigmodel 端点拒绝，09-06 深检实证）。
# claude CLI flag 优先级最高；默认读 ANTHROPIC_MODEL 剥后缀，CLAUDE_MODEL_PIN 显式覆盖；空=不加 flag（现状语义）
MODEL_PIN="${CLAUDE_MODEL_PIN:-}"
if [[ -z "$MODEL_PIN" ]]; then
  _raw="$(jq -r '.env.ANTHROPIC_MODEL // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)"
  MODEL_PIN="${_raw%\[*\]}"
fi
MODEL_FLAG=()
[[ -z "$MODEL_PIN" ]] || MODEL_FLAG=(--model "$MODEL_PIN")

# 阶段超时 seam：claude -p 卡死时不得拖死整条 hourly 链（09-06 实证同类挂死模式）
WATCH_PHASE_TIMEOUT="${WATCH_PHASE_TIMEOUT:-2700}"
run_phase() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$secs" "$@"
  else
    "$@"   # 无超时工具：退化为直跑（现状语义）
  fi
}

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

# 配额断路器（09-06 八连 429 空烧沉淀）：开闸期跳过一切 LLM 步骤（scan 研判/radar），
# 廉价闸门与 notify flush 照跑；冷却到期自动闭合，放一次真实尝试
QC="$MARTIN/scripts/contrib/quota_circuit.sh"
QC_OPEN=0
if [[ -x "$QC" ]]; then
  if ! qc_remain="$(zsh "$QC" check)"; then
    QC_OPEN=1
    echo "[$(ts)] 配额断路器打开（冷却剩余 ${qc_remain}s），本轮跳过 scan/radar LLM 步骤" >>"$LOG"
  fi
fi

# --- 1. 廉价闸门 ---
if zsh "$MARTIN/scripts/contrib/scan_gate.sh" >>"$LOG" 2>&1; then
  rc=0
else
  rc=$?
fi

if (( rc == 10 && QC_OPEN == 1 )); then
  echo "[$(ts)] 有域内命中但断路器打开，研判顺延" >>"$LOG"
elif (( rc == 10 )); then
  echo "[$(ts)] 有域内命中 → headless 研判" >>"$LOG"
  [[ -n "$CLAUDE_BIN" ]] && run_phase "$WATCH_PHASE_TIMEOUT" "$CLAUDE_BIN" "${MODEL_FLAG[@]}" -p "/contrib-watch scan" \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,Grep,Glob,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *)" \
    >>"$LOG" 2>&1
  scan_rc=$?
  echo "[$(ts)] 研判完成 exit=$scan_rc" >>"$LOG"
  if (( scan_rc != 0 )); then
    [[ -x "$QC" ]] && zsh "$QC" trip "$LOG" >/dev/null 2>&1 && echo "[$(ts)] 配额签名命中，断路器跳闸" >>"$LOG"
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-scan-exit$scan_rc" --summary "scan 研判 claude -p 失败 exit=$scan_rc" >/dev/null 2>&1 || true
  else
    [[ -x "$QC" ]] && zsh "$QC" clear >/dev/null 2>&1   # 成功 = 配额可用实证
  fi
elif (( rc == 0 )); then
  echo "[$(ts)] 无命中" >>"$LOG"
else
  echo "[$(ts)] 闸门出错 rc=${rc}（gh 网络抖动？下轮重试）" >>"$LOG"
  "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
    --key "$(date +%F)-gate-rc$rc" --summary "scan_gate 闸门异常 rc=$rc" >/dev/null 2>&1 || true
fi

# --- 1.5 邮件检查（09-07）：GitHub 通知未读 → AI 三通道研判（auto 流水线内动作 / important
#     推微信 mail-needs-user / routine 进简报）。采集零 LLM 成本照常跑（同 scan_gate 待遇），
#     断路器只挡研判步。首启只定位游标不回灌存量。失败 fail-soft 不拖死 hourly 链。---
if [[ -x "$MARTIN/scripts/contrib/mail_gate.sh" ]]; then
  mrc=0
  "$MARTIN/scripts/contrib/mail_gate.sh" >>"$LOG" 2>&1 || mrc=$?
  if (( mrc == 10 && QC_OPEN == 1 )); then
    echo "[$(ts)] 有新 GitHub 邮件但断路器打开，研判顺延（pending 保留下轮）" >>"$LOG"
  elif (( mrc == 10 )); then
    echo "[$(ts)] 有新 GitHub 邮件 → headless 研判" >>"$LOG"
    [[ -n "$CLAUDE_BIN" ]] && run_phase "$WATCH_PHASE_TIMEOUT" "$CLAUDE_BIN" "${MODEL_FLAG[@]}" -p "/contrib-watch mail" \
      --permission-mode acceptEdits \
      --allowedTools "Read,Write,Edit,Grep,Glob,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(scripts/contrib/rq.sh list *),Bash(scripts/contrib/rq.sh add *),Bash(scripts/contrib/notify.sh event *),Bash(scripts/contrib/mail_gate.sh --commit-cursor)" \
      >>"$LOG" 2>&1
    mail_rc=$?
    echo "[$(ts)] 邮件研判完成 exit=$mail_rc" >>"$LOG"
    if (( mail_rc != 0 )); then
      [[ -x "$QC" ]] && zsh "$QC" trip "$LOG" >/dev/null 2>&1 && echo "[$(ts)] 配额签名命中，断路器跳闸" >>"$LOG"
      "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
        --key "$(date +%F)-mail-exit$mail_rc" --summary "邮件研判 claude -p 失败 exit=$mail_rc" >/dev/null 2>&1 || true
    else
      [[ -x "$QC" ]] && zsh "$QC" clear >/dev/null 2>&1
      # 研判成功才推进游标（失败的轮次 pending 保留，下轮重研判——幂等靠 event --key）
      "$MARTIN/scripts/contrib/mail_gate.sh" --commit-cursor >>"$LOG" 2>&1 || true
    fi
  elif (( mrc == 0 )); then
    echo "[$(ts)] 邮件闸门：无新 GitHub 通知" >>"$LOG"
  else
    echo "[$(ts)] 邮件闸门出错 rc=${mrc}（himalaya/网络抖动？下轮重试）" >>"$LOG"
  fi
fi

# --- 2. 每日 radar（08 窗口；抽 maybe_radar 便于测试注入 hour，默认=现状 date +%H）---
maybe_radar() {
  local hour="${1:-$(date +%H)}"
  if [[ "$hour" == "08" && "$QC_OPEN" == "1" ]]; then
    echo "[$(ts)] radar 窗口到但断路器打开，跳过" >>"$LOG"
  elif [[ "$hour" == "08" ]]; then
    echo "[$(ts)] 每日 radar 启动" >>"$LOG"
    [[ -n "$CLAUDE_BIN" ]] && run_phase "$WATCH_PHASE_TIMEOUT" "$CLAUDE_BIN" "${MODEL_FLAG[@]}" -p "/contrib-watch radar" \
      --permission-mode acceptEdits \
      --allowedTools "Read,Write,Edit,Grep,Glob,Agent,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(git *),Bash(cd *),Bash(scripts/contrib/*),Bash(pytest *),Bash(python *),Bash(python3 *),Bash(ruff *),Bash(rg *)" \
      >>"$LOG" 2>&1
    radar_rc=$?
    echo "[$(ts)] radar 完成 exit=$radar_rc" >>"$LOG"
    if (( radar_rc != 0 )); then
      [[ -x "$QC" ]] && zsh "$QC" trip "$LOG" >/dev/null 2>&1 && echo "[$(ts)] 配额签名命中，断路器跳闸" >>"$LOG"
      "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
        --key "$(date +%F)-radar-exit$radar_rc" --summary "radar claude -p 失败 exit=$radar_rc" >/dev/null 2>&1 || true
    else
      [[ -x "$QC" ]] && zsh "$QC" clear >/dev/null 2>&1
    fi
  fi
}
maybe_radar

# --- 3. 通知层：聚合推送本轮新增告警（失败不影响流水线退出码）---
if [[ -x "$MARTIN/scripts/contrib/notify.sh" ]]; then
  "$MARTIN/scripts/contrib/notify.sh" flush >>"$LOG" 2>&1 \
    || echo "[$(ts)] notify flush 失败（事件保留，下轮重试）" >>"$LOG"
  # 审批卡补推 sweep（09-07 双修①跨轮兜底）：每小时重推卡死的审批卡（发送失败零重试曾致
  # rq-20260907-104693 卡死 6h）。安全由 notify.sh 现有机制保证：premise TTL 发卡前复验 /
  # ok 项幂等跳过 / 重推时 B-1 回收旧 tunnel 页 / 48h deadline 由 awaiting_epoch 派生不漂移
  "$MARTIN/scripts/contrib/notify.sh" approve --all >>"$LOG" 2>&1 \
    || echo "[$(ts)] 审批卡补推 sweep 异常（下轮重试）" >>"$LOG"
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
