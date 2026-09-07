#!/bin/zsh
# deep-check.sh — 三轮审编排（预算 reserve → 阶段1 preflight → 阶段2 redteam → 审批推送）
# 由 launchd 09:37 调 deep_check_gate.sh 后自动衔接；亦可手动：deep-check.sh <rq-id> [lane]
# 结构性 fresh-context：两阶段是两个独立 claude -p 进程，只靠文件版次传递（v1→v2→final）。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
TARGET_FILE="${DEEPCHECK_TARGET_FILE:-/tmp/.deepcheck-target}"
LOCK="${DEEPCHECK_LOCK:-/tmp/contrib-deepcheck.lock}"
LOG="$CONTRIB/logs/deepcheck.log"

ts() { date "+%Y-%m-%dT%H%M"; }

log() { echo "[$(date '+%F %T')] deepcheck: $*" >>"$LOG"; }

# claude CLI 探测（同 run-watch.sh）；seam：CLAUDE_BIN env 优先，空则走现有两级探测（默认语义=现状）
CLAUDE_BIN="${CLAUDE_BIN:-}"
if [[ -z "$CLAUDE_BIN" ]]; then
  CLAUDE_BIN="$(command -v claude 2>/dev/null)"
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  CLAUDE_BIN="$(ls -t "$HOME"/.nvm/versions/node/*/bin/claude 2>/dev/null | head -1)"
fi
if [[ -z "$CLAUDE_BIN" ]]; then
  log "找不到 claude CLI，放弃"
  exit 1
fi

# 模型 pin seam：settings.json env 注入的模型名可能带 [1M] 后缀（bigmodel 端点拒绝，09-06 深检实证）。
# claude CLI flag 优先级最高；默认读 ANTHROPIC_MODEL 剥后缀，CLAUDE_MODEL_PIN 显式覆盖；空=不加 flag（现状语义）
MODEL_PIN="${CLAUDE_MODEL_PIN:-}"
if [[ -z "$MODEL_PIN" ]]; then
  _raw="$(jq -r '.env.ANTHROPIC_MODEL // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)"
  MODEL_PIN="${_raw%\[*\]}"
fi
MODEL_FLAG=()
[[ -z "$MODEL_PIN" ]] || MODEL_FLAG=(--model "$MODEL_PIN")

# 阶段超时 seam：子 claude 卡死时编排层必须能走到 fail 路径（09-06 实证：子进程死后父 zsh 失收尸永挂 waitjobs）
PHASE_TIMEOUT="${DEEPCHECK_PHASE_TIMEOUT:-3600}"
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
# 锁自愈：SIGKILL/断电场景 EXIT trap 不执行，陈旧锁会永久卡死流水线（09-06 实证）；>4h 视为死锁残留清掉重拿
if [[ -d "$LOCK" ]]; then
  _lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo "$(date +%s)") ))
  if (( _lock_age > 10800 )); then
    log "陈旧锁 ${LOCK}（${_lock_age}s）清掉重拿"
    rmdir "$LOCK" 2>/dev/null || true
  fi
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  log "上轮深检仍在运行，跳过 $ID"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# 配额断路器：开闸期不做预算 reserve、不起 claude（09-06 八连 429 空烧沉淀）
QC="$MARTIN/scripts/contrib/quota_circuit.sh"
if [[ -x "$QC" ]]; then
  if ! qc_remain="$(zsh "$QC" check)"; then
    log "配额断路器打开（冷却剩余 ${qc_remain}s），跳过 $ID"
    exit 0
  fi
fi

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
  # 配额类失败 → 跳闸断路器（冷却期内 gate/编排全部跳过 LLM，不再每小时空烧）
  local quota_note=""
  if [[ -x "$QC" ]] && zsh "$QC" trip "$D/run.log" >/dev/null 2>&1; then
    quota_note="（配额类失败，断路器已跳闸：$("$QC" status 2>/dev/null)）"
  fi
  log "$ID 阶段 $1 失败${quota_note}，置 failed"
  "$RQ" set "$ID" failed --note "$1 失败${quota_note}" >>"$LOG" 2>&1 || true
  "$RQ" budget refund "$ID" --lane "$LANE" >>"$LOG" 2>&1 || true   # 内部按 refund_failed_deep_check 决定
  "$NOTIFY" event pipeline-failure --key "$(date +%F)-deepcheck-$ID" \
    --summary "深检 $ID 阶段 $1 失败${quota_note}（详见 runs/deep-check/$ID/run.log）" >/dev/null 2>&1 || true
  exit 1
}

# --- 阶段 1：strategist preflight + 亲手核 → 草稿 v2 ---
# cwd 必须在 MARTIN（skill 是项目级；agent 的相对路径命令也依赖它）
cd "$MARTIN" || exit 1
log "阶段1 preflight 启动"
# allowedTools 必须同时覆盖相对/绝对两种命令形态——agent 实测会用绝对路径调
# rq.sh，只放行相对形式时权限闸拒绝、编排契约（set-draft 注册）静默失败（09-05 实证）
run_phase "$PHASE_TIMEOUT" "$CLAUDE_BIN" "${MODEL_FLAG[@]}" -p "/contrib-watch deep-check $ID --phase preflight" \
  --permission-mode acceptEdits \
  --allowedTools "Read,Write,Edit,Grep,Glob,Agent,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(rg *),Bash(git diff *),Bash(git log *),Bash(git show *),Bash(scripts/contrib/rq.sh set *),Bash(scripts/contrib/rq.sh set-draft *),Bash(${MARTIN}/scripts/contrib/rq.sh set *),Bash(${MARTIN}/scripts/contrib/rq.sh set-draft *),Bash(rq.sh set *),Bash(rq.sh set-draft *)" \
  >>"$D/run.log" 2>&1 || fail preflight

# v2 草稿必须已登记；编排层自愈：文件在而队列字段缺 → 补注册而非整轮作废
# （agent 被权限闸拦住没跑成 set-draft 时，智力产物不该陪葬——09-05 双 probe 实证）
draft="$("$RQ" show "$ID" --json 2>/dev/null | jq -r '.draft // ""')"
if [[ -z "$draft" || ! -f "$draft" ]] && [[ -s "$CONTRIB/pending/$ID.md" ]]; then
  log "队列 .draft 缺失但 $CONTRIB/pending/$ID.md 在——编排层补注册"
  "$RQ" set-draft "$ID" "$CONTRIB/pending/$ID.md" >/dev/null 2>&1 || true
  draft="$("$RQ" show "$ID" --json 2>/dev/null | jq -r '.draft // ""')"
fi
if [[ -z "$draft" || ! -f "$draft" ]]; then
  fail "preflight（草稿未产出）"
fi
log "阶段1 preflight 完成 → $draft"
[[ -x "$QC" ]] && zsh "$QC" clear >/dev/null 2>&1   # 真实成功 = 配额可用实证，闭合断路器

# --- 阶段 2：fresh-context 红队（仅 deep 车道；probe 单轮免红队）---
if [[ "$LANE" == "deep" ]]; then
  log "阶段2 redteam 启动"
  run_phase "$PHASE_TIMEOUT" "$CLAUDE_BIN" "${MODEL_FLAG[@]}" -p "/contrib-watch deep-check $ID --phase redteam" \
    --permission-mode acceptEdits \
    --allowedTools "Read,Write,Edit,Grep,Glob,Bash(gh *),Bash(jq *),Bash(cat *),Bash(head *),Bash(tail *),Bash(ls *),Bash(wc *),Bash(grep *),Bash(rg *),Bash(git diff *),Bash(git log *),Bash(git show *),Bash(scripts/contrib/rq.sh set *),Bash(${MARTIN}/scripts/contrib/rq.sh set *),Bash(rq.sh set *)" \
    >>"$D/run.log" 2>&1 || fail redteam
  log "阶段2 redteam 完成"
else
  log "probe 车道免红队，直接待批"
fi

# --- 待批 / 自动批准分叉（09-06 用户拍板：默认自动，例外升级） ---
# 确定性闸门 auto-gate.sh：LLM verdict.json 只是输入，own-PR/低分/低置信/缺 verdict 一律升级人工
GATE="$MARTIN/scripts/approval/auto-gate.sh"
gate_out="$(bash "$GATE" "$ID" 2>&1)"; gate_rc=$?
log "auto-gate $ID: rc=$gate_rc $gate_out"

if [[ $gate_rc -eq 0 ]]; then
  # 自动批准：占坑 → 直接走确定性执行链（execute.sh 自带 TTL 复验/台账/回执/断路器，与用户点批准同一条路）
  "$RQ" set "$ID" approved --note "自动批准：${gate_out#AUTO|}" >>"$LOG" 2>&1
  log "==== 深检完成 $ID → 自动批准，进入执行链 ===="
  EXEC_CHANNEL=auto bash "$MARTIN/scripts/approval/execute.sh" "$ID" approved >>"$LOG" 2>&1 \
    || log "自动执行链异常（详见 approval-collect.log / 上文），项保持 approved 待收集链兜底"
else
  # 升级人工：卡点写回队列（通知层渲染「我定不了的点」清单）→ 照常推审批卡
  reason_text="${gate_out#ESCALATE|}"
  jq --arg id "$ID" --arg r "$reason_text" \
    '(.items[] | select(.id == $id) | .escalate_reasons) = [$r]' \
    "$CONTRIB/ready-queue.json" > "$CONTRIB/ready-queue.json.tmp" \
    && mv "$CONTRIB/ready-queue.json.tmp" "$CONTRIB/ready-queue.json" || true
  "$RQ" set "$ID" awaiting-approval --note "深检完成（lane=${LANE}），升级人工：$reason_text" >>"$LOG" 2>&1
  "$NOTIFY" approve "$ID" >>"$LOG" 2>&1 || log "审批推送失败（事件保留，补推链兜底）"
  log "==== 深检完成 $ID → awaiting-approval（升级人工）===="
fi
