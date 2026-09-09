#!/bin/zsh
# contrib-watch launchd 入口：每小时 :07 触发（T1-T5 卡化后编排骨架：每段=闸门→建卡→flight→flush）
#   1. 廉价闸门（无 LLM）；有命中 → contrib 研判卡主路（hermes kanban 卡，worker 研判；
#      claude -p 仅兜底）
#   1.5 邮件闸门 → mail 研判卡（同上分层）
#   2. 每日 08 窗口/补跑旗标 → radar 研判卡
#   3. notify flush（叙事批 digest 卡异步 + 审批卡补推 sweep）
#   4. 快车道深检 → deepcheck 依赖卡链（preflight 卡 → worker 自建 redteam 子卡）
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
# hermes seam（T1 卡化）：kanban list/show 终态查询用；kanban_card.sh 经 env 透传同一 seam
HERMES_BIN="${HERMES_BIN:-hermes}"
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

# board 切换（T6 实机验证 PASS 后启用）：contrib 域全部 kanban 调用（建卡+flight 查询+digest/
# deepcheck 查询）pin 到 contrib 专用 board——并发预算与 default board 隔离。回退=删除本 export
# 或外部 export KANBAN_BOARD=""（`${KANBAN_BOARD-contrib}` 只对 unset 取缺省——显式空串=显式回退，
# 沙箱测试依赖此语义）。kanban_card/run-watch/notify/deepcheck_card 四处 seam 均「env 空=不 pin」。
# 实机验证证据见 .autopilot/project/tasks/T6-*.handoff.md
export KANBAN_BOARD="${KANBAN_BOARD-contrib}"

# 阶段超时 seam：只裹 claude 兜底路与 flight 查询（建卡是本地快操作，重入锁已防并发；
# 卡研判的执行预算归 dispatcher/worker 管，编排层不越权兜底）
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

# --- T3 全局件：flight per-kind 迁移 + 终态查询 seam（scan/mail/radar 三段共用）---
# flight v2：单对象 kanban-flight.json（历史仅 scan 使用）→ kanban-flight-<kind>.json。
# 迁移=一次性 mv（检测到旧文件且 -scan 命名不存在）；读端保留旧文件回落（kind==scan 只读），双保险。
OLD_FLIGHT="$CONTRIB/kanban-flight.json"
if [[ -f "$OLD_FLIGHT" && ! -e "$CONTRIB/kanban-flight-scan.json" ]]; then
  mv "$OLD_FLIGHT" "$CONTRIB/kanban-flight-scan.json" 2>/dev/null \
    && echo "[$(ts)] flight 迁移：kanban-flight.json → kanban-flight-scan.json" >>"$LOG"
fi
SKILL_MD="$MARTIN/.claude/skills/contrib-watch/SKILL.md"
STALE_SECS=21600   # flight 陈旧守卫 6h：防 dispatcher 停机使 flight 永非终态 → 跳过放大停摆
FLIGHT_TIMEOUT="${FLIGHT_TIMEOUT:-30}"   # flight 查询挂死守卫（B4）：hermes list/show 超时秒数
# flight 终态查询用：run_phase 包裹（timeout→perl→直跑三级退化）——hermes 挂死不再拖死整轮。
# board seam（T6）：KANBAN_BOARD 非空时 kanban 调用统一 pin 到该 board——--board 是 kanban
# 父级 flag，必须插在子命令前（hermes kanban --board X list/show）；空=不 pin（default board
# 回退态）。查询与 kanban_card.sh（同一 env）建卡同源，flight 查询才看得到卡所在 board 的卡。
hermes_call() {
  local -a board_args=()
  [[ -n "${KANBAN_BOARD:-}" ]] && board_args=(--board "$KANBAN_BOARD")
  run_phase "$FLIGHT_TIMEOUT" env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
    "$HERMES_BIN" kanban "${board_args[@]}" "$@"
}

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

# 配额断路器（09-06 八连 429 空烧沉淀；T2 语义收窄）：QC 只管 claude 兜底路（GLM 配额）——
# 这里只做开闸可见性日志；真实消费在各 fallback 函数内自查（zsh $QC check），建卡路不受限。
# （T6 清理：原配额开闸标记变量在 T3 卡化后已无读者，删除——语义等价保留 check 本身。）
QC="$MARTIN/scripts/contrib/quota_circuit.sh"
if [[ -x "$QC" ]]; then
  if ! qc_remain="$(zsh "$QC" check)"; then
    echo "[$(ts)] 配额断路器打开（冷却剩余 ${qc_remain}s，仅挡 claude 兜底路）" >>"$LOG"
  fi
fi

# --- 1. 廉价闸门 ---
if zsh "$MARTIN/scripts/contrib/scan_gate.sh" >>"$LOG" 2>&1; then
  rc=0
else
  rc=$?
fi

if (( rc == 10 )); then
  # --- scan 研判主路（T1 卡化）：flight 检查 → 建卡（hermes contrib 卡）→ claude -p 降级兜底 ---
  # T3 flight per-kind：scan 登记迁至 kanban-flight-scan.json（旧文件已在顶部 mv 迁移；
  # 此处回落读仅为 mv 失败时的双保险——旧文件 kind==scan 只读不写）
  FLIGHT="$CONTRIB/kanban-flight-scan.json"
  SCAN_LATEST="$CONTRIB/scan-latest-batch.json"

  fallback_scan() {
    # QC gate（T2 语义收窄）：断路器仅挡 claude 兜底路——QC 开 → 跳过 claude + 幂等告警入账
    if [[ -x "$QC" ]] && ! zsh "$QC" check >/dev/null 2>&1; then
      echo "[$(ts)] 断路器仅挡兜底路（GLM 配额），本轮 fallback 跳过（claude 未调用）" >>"$LOG"
      "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
        --key "$(date +%F)-scan-fallback-skipped" \
        --summary "scan fallback 被配额断路器挡下（GLM 配额冷却中），本轮 claude 兜底未执行" >/dev/null 2>&1 || true
      return 0
    fi
    echo "[$(ts)] scan fallback → claude -p 旧路" >>"$LOG"
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
  }

  card_fallback() {  # 卡路失败 → 告警入账 + claude 旧路兜底
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-scan-card-fallback" \
      --summary "scan 建卡路失败（${1:-unknown}），已回落 claude 旧路兜底" >/dev/null 2>&1 || true
    fallback_scan
  }

  clear_flight() { rm -f "$FLIGHT"; }

  create_scan_card() {
    local batch_file body_file card_json card_id body_ts rc=0
    batch_file="$(jq -r '.batch_file // empty' "$SCAN_LATEST" 2>/dev/null || true)"
    body_ts="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$CONTRIB/pending-batches"
    body_file="$CONTRIB/pending-batches/batch-$body_ts.body.md"
    {
      printf '# contrib scan 研判卡\n\n'
      printf '## 任务\n\n'
      if [[ -n "$batch_file" ]]; then
        printf -- '- 批次文件（研判对象，权威数据源）: %s\n' "$batch_file"
      else
        printf -- '- 批次文件: 无指针——按 SKILL.md 模式一第 1 步自行读最新含 pending 项的批次文件\n'
      fi
      printf -- '- 工作模式与评分 rubric 权威: %s 模式一（scan）\n' "$SKILL_MD"
      printf -- '- 指针: %s\n\n' "$SCAN_LATEST"
      printf '## 红线（必须遵守）\n\n'
      printf -- '- gh 只读：零 issue/PR 写、零评论、零 push\n'
      printf -- '- rq.sh 只允许本地渠道动作（list/add/set/set-draft 等），禁任何对外动作\n'
      printf -- '- -q 模式禁脚本形态：python -c / jq -e / * -e 一律不可用\n'
      printf -- '- 不写 briefs 与 ready-queue 之外的争议面\n\n'
      printf '## 收尾要求\n\n'
      printf -- '- 逐条研判完立即写回批次文件该条：state=done + decision/score/breakdown/rationale/space_check\n'
      printf -- '- 完成调 kanban_complete 时必须同时传 summary 与 result\n'
    } >"$body_file"
    card_json="$(bash "$MARTIN/scripts/contrib/kanban_card.sh" create \
      --kind scan --title "contrib scan 研判 batch-$body_ts" \
      --body-file "$body_file" \
      --json-out "$CONTRIB/pending-batches/batch-$body_ts.card.json" 2>>"$LOG")" || rc=$?
    if (( rc != 0 )); then
      echo "[$(ts)] scan 建卡失败（rc=${rc}）" >>"$LOG"
      card_fallback "建卡失败 rc=$rc"
      return 0
    fi
    card_id="$(printf '%s' "$card_json" | jq -r '.id // empty' 2>/dev/null || true)"
    if [[ -z "$card_id" ]]; then
      echo "[$(ts)] scan 建卡输出缺 id" >>"$LOG"
      card_fallback "建卡输出缺 id"
      return 0
    fi
    jq -n --arg kind scan --arg id "$card_id" \
      --arg bf "${batch_file:-}" --argjson e "$(date +%s)" \
      '{kind: $kind, card_id: $id, batch_file: $bf, created_epoch: $e}' \
      >"$FLIGHT.tmp" && mv "$FLIGHT.tmp" "$FLIGHT"
    echo "[$(ts)] scan 研判卡已建 ${card_id}（batch=${batch_file:-无指针}）" >>"$LOG"
  }

  flight_card_id=""
  flight_src="$FLIGHT"
  if [[ ! -s "$flight_src" && -s "$OLD_FLIGHT" ]] && jq -e 'type == "object"' "$OLD_FLIGHT" >/dev/null 2>&1 \
    && [[ "$(jq -r '.kind // ""' "$OLD_FLIGHT" 2>/dev/null || true)" == "scan" ]]; then
    flight_src="$OLD_FLIGHT"   # 迁移失败时的旧文件回落读（只读）
  fi
  if [[ -s "$flight_src" ]] && jq -e 'type == "object"' "$flight_src" >/dev/null 2>&1; then
    flight_card_id="$(jq -r 'if .kind == "scan" then (.card_id // empty) else empty end' "$flight_src" 2>/dev/null || true)"
  fi

  if [[ -z "$flight_card_id" ]]; then
    # 无在飞卡 → 建卡主路
    create_scan_card
  else
    card_status=""
    if list_json="$(hermes_call list --json 2>>"$LOG")"; then
      card_status="$(printf '%s' "$list_json" | jq -r --arg id "$flight_card_id" \
        '[.[] | select(.id == $id)][0].status // empty' 2>>"$LOG" || true)"
    fi
    case "$card_status" in
      done)
        echo "[$(ts)] scan 卡 $flight_card_id 已 done → 清 flight，本轮新命中另建新卡" >>"$LOG"
        clear_flight
        create_scan_card
        ;;
      blocked)
        run_outcome=""
        if show_json="$(hermes_call show "$flight_card_id" --json 2>>"$LOG")"; then
          run_outcome="$(printf '%s' "$show_json" | jq -r '[.runs[]? | select(.outcome != null)][-1].outcome // empty' 2>>"$LOG" || true)"
        fi
        case "$run_outcome" in
          gave_up|crashed|timed_out|spawn_failed)
            echo "[$(ts)] scan 卡 $flight_card_id blocked（outcome=${run_outcome}，重试耗尽）→ fallback" >>"$LOG"
            clear_flight
            card_fallback "卡 blocked outcome=$run_outcome"
            ;;
          *)
            echo "[$(ts)] scan 卡 $flight_card_id blocked（outcome=${run_outcome:-未知}，非重试耗尽）→ 本轮跳过" >>"$LOG"
            ;;
        esac
        ;;
      ready|running|triage|todo|scheduled|review)
        flight_age=$(( $(date +%s) - $(jq -r '.created_epoch // 0' "$FLIGHT" 2>/dev/null || echo 0) ))
        if (( flight_age > STALE_SECS )); then
          echo "[$(ts)] scan 卡 $flight_card_id 非终态超 ${STALE_SECS}s（age=${flight_age}s）→ 清 + fallback" >>"$LOG"
          clear_flight
          card_fallback "flight 陈旧 ${flight_age}s"
        else
          echo "[$(ts)] scan 卡 $flight_card_id 在飞（status=$card_status age=${flight_age}s）→ 本轮跳过" >>"$LOG"
        fi
        ;;
      *)
        # 查无此 id（archived/清理/异常）→ 异常视同失败
        echo "[$(ts)] scan 卡 $flight_card_id 查无终态（status=${card_status:-空}）→ 清 + fallback" >>"$LOG"
        clear_flight
        card_fallback "flight 卡查无"
        ;;
    esac
  fi
elif (( rc == 0 )); then
  echo "[$(ts)] 无命中" >>"$LOG"
else
  echo "[$(ts)] 闸门出错 rc=${rc}（gh 网络抖动？下轮重试）" >>"$LOG"
  "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
    --key "$(date +%F)-gate-rc$rc" --summary "scan_gate 闸门异常 rc=$rc" >/dev/null 2>&1 || true
fi

# --- 1.5 邮件检查（09-07；T3 卡化）：GitHub 通知未读 → AI 三通道研判（auto 流水线内动作 /
#     important 推微信 mail-needs-user / routine 进简报）。采集零 LLM 成本照常跑（同 scan_gate
#     待遇）。研判主路 = mail 卡（contrib worker）；claude -p 降级为兜底（旧同步语义保留）。
#     cursor 推进从同步改异步：卡终态 done + cursor 快照守卫通过才 --commit-cursor。
#     失败 fail-soft 不拖死 hourly 链。---
MAIL_FLIGHT="$CONTRIB/kanban-flight-mail.json"
MAIL_PENDING="$CONTRIB/mail-pending.json"

# 快照口径钉死：与 mail_gate.sh --commit-cursor 同一 jq 表达式（mail_gate.sh:46）
mail_pending_max_id() {
  local f="$1" v=0
  if [[ -s "$f" ]]; then
    v="$(jq -r '[.[].id | tonumber] | max // 0' "$f" 2>/dev/null || echo 0)"
  fi
  printf '%s' "$v"
}

fallback_mail() {
  # QC gate（T2 语义）：断路器仅挡 claude 兜底路——QC 开 → 跳过 claude + 幂等告警入账
  if [[ -x "$QC" ]] && ! zsh "$QC" check >/dev/null 2>&1; then
    echo "[$(ts)] 断路器仅挡兜底路（GLM 配额），mail fallback 跳过（claude 未调用）" >>"$LOG"
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-mail-fallback-skipped" \
      --summary "mail fallback 被配额断路器挡下（GLM 配额冷却中），本轮 claude 兜底未执行" >/dev/null 2>&1 || true
    return 0
  fi
  echo "[$(ts)] mail fallback → claude -p 旧路" >>"$LOG"
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
    # 研判成功才推进游标（旧同步语义兜底保留；失败轮次 pending 保留，下轮重研判——幂等靠 event --key）
    "$MARTIN/scripts/contrib/mail_gate.sh" --commit-cursor >>"$LOG" 2>&1 || true
  fi
}

card_fallback_mail() {  # 卡路失败 → 告警入账 + claude 旧路兜底
  "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
    --key "$(date +%F)-mail-card-fallback" \
    --summary "mail 建卡路失败（${1:-unknown}），已回落 claude 旧路兜底" >/dev/null 2>&1 || true
  fallback_mail
}

create_mail_card() {
  local body_ts body_file card_json card_id pmax rc=0
  body_ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CONTRIB/card-bodies"
  body_file="$CONTRIB/card-bodies/mail-$body_ts.body.md"
  {
    printf '# contrib mail 研判卡\n\n'
    printf '## 任务\n\n'
    printf -- '- 输入（只读，mail_gate 预取快照）: %s\n' "$MAIL_PENDING"
    printf -- '- 工作模式与三通道判定权威: %s 模式五（mail）\n' "$SKILL_MD"
    printf '\n## 红线（必须遵守）\n\n'
    printf -- '- 禁碰 himalaya 写操作（mark/move/delete/send 一律禁止）；只依据 preview 研判\n'
    printf -- '- 不自行 commit-cursor、不动 mail-cursor.json（run-watch 按卡终态推进游标）\n'
    printf -- '- gh 只读；rq.sh 只允许本地渠道动作；-q 模式禁脚本形态：python -c / jq -e / * -e 一律不可用\n'
    printf '\n## 收尾要求\n\n'
    printf -- '- 完成调 kanban_complete 时必须同时传 summary 与 result\n'
  } >"$body_file"
  card_json="$(bash "$MARTIN/scripts/contrib/kanban_card.sh" create \
    --kind mail --title "contrib mail 研判 $body_ts" \
    --body-file "$body_file" \
    --json-out "$CONTRIB/card-bodies/mail-$body_ts.card.json" 2>>"$LOG")" || rc=$?
  if (( rc != 0 )); then
    echo "[$(ts)] mail 建卡失败（rc=${rc}）" >>"$LOG"
    card_fallback_mail "建卡失败 rc=$rc"
    return 0
  fi
  card_id="$(printf '%s' "$card_json" | jq -r '.id // empty' 2>/dev/null || true)"
  if [[ -z "$card_id" ]]; then
    echo "[$(ts)] mail 建卡输出缺 id" >>"$LOG"
    card_fallback_mail "建卡输出缺 id"
    return 0
  fi
  # 登记第五键 pending_max_id = 建卡时 pending 最大 id 快照（cursor 本轮不动）。
  # batch_file 为空串占位（T6 契约补句）：mail 数据源=mail-pending.json 本体，无批次文件概念；
  # radar 同（产出=briefs/radar 报告，无输入批次）。flight 的 batch_file 键仅 scan/deepcheck 为实路径
  # （deepcheck 亦空串——其数据源是 ready-queue 项，T4 起空串为合法值）。
  pmax="$(mail_pending_max_id "$MAIL_PENDING")"
  jq -n --arg kind mail --arg id "$card_id" --arg bf "" --argjson e "$(date +%s)" --argjson p "$pmax" \
    '{kind: $kind, card_id: $id, batch_file: $bf, created_epoch: $e, pending_max_id: $p}' \
    >"$MAIL_FLIGHT.tmp" && mv "$MAIL_FLIGHT.tmp" "$MAIL_FLIGHT"
  echo "[$(ts)] mail 研判卡已建 ${card_id}（pending_max_id 快照=${pmax}）" >>"$LOG"
}

if [[ -x "$MARTIN/scripts/contrib/mail_gate.sh" ]]; then
  mrc=0
  "$MARTIN/scripts/contrib/mail_gate.sh" >>"$LOG" 2>&1 || mrc=$?
  if (( mrc == 10 )); then
    mail_flight_card=""
    if [[ -s "$MAIL_FLIGHT" ]] && jq -e 'type == "object"' "$MAIL_FLIGHT" >/dev/null 2>&1; then
      mail_flight_card="$(jq -r 'if .kind == "mail" then (.card_id // empty) else empty end' "$MAIL_FLIGHT" 2>/dev/null || true)"
    fi
    if [[ -n "$mail_flight_card" ]]; then
      # 终态检查嵌在 mrc==10 门内（设计注 I5：登记在飞 ⇒ pending 非空 ⇒ mrc==10）
      card_status=""
      if list_json="$(hermes_call list --json 2>>"$LOG")"; then
        card_status="$(printf '%s' "$list_json" | jq -r --arg id "$mail_flight_card" \
          '[.[] | select(.id == $id)][0].status // empty' 2>>"$LOG" || true)"
      fi
      case "$card_status" in
        done)
          # cursor 快照守卫：当前 pending 与建卡时快照一致才 commit；有增长/缩减（人工 drain）
          # 只清登记不 commit——飞行窗口内新邮件绝不被静默消费，残留 pending 驱动下轮新卡
          mail_snap="$(jq -r '.pending_max_id // 0' "$MAIL_FLIGHT" 2>/dev/null || echo 0)"
          mail_cur="$(mail_pending_max_id "$MAIL_PENDING")"
          if [[ "$mail_cur" == "$mail_snap" ]]; then
            if "$MARTIN/scripts/contrib/mail_gate.sh" --commit-cursor >>"$LOG" 2>&1; then
              rm -f "$MAIL_FLIGHT"
              echo "[$(ts)] mail 卡 ${mail_flight_card} done → 快照一致（#${mail_cur}）→ commit-cursor + 清登记" >>"$LOG"
            else
              echo "[$(ts)] mail 卡 done → commit-cursor 失败，登记保留下轮重试" >>"$LOG"
            fi
          else
            rm -f "$MAIL_FLIGHT"
            echo "[$(ts)] mail 卡 done → pending 有变化（当前#${mail_cur} vs 快照#${mail_snap}）→ 只清登记不 commit" >>"$LOG"
          fi
          ;;
        blocked)
          run_outcome=""
          if show_json="$(hermes_call show "$mail_flight_card" --json 2>>"$LOG")"; then
            run_outcome="$(printf '%s' "$show_json" | jq -r '[.runs[]? | select(.outcome != null)][-1].outcome // empty' 2>>"$LOG" || true)"
          fi
          case "$run_outcome" in
            gave_up|crashed|timed_out|spawn_failed)
              echo "[$(ts)] mail 卡 ${mail_flight_card} blocked（outcome=${run_outcome}，重试耗尽）→ fallback" >>"$LOG"
              rm -f "$MAIL_FLIGHT"
              card_fallback_mail "卡 blocked outcome=$run_outcome"
              ;;
            *)
              echo "[$(ts)] mail 卡 ${mail_flight_card} blocked（outcome=${run_outcome:-未知}，非重试耗尽）→ 本轮跳过" >>"$LOG"
              ;;
          esac
          ;;
        ready|running|triage|todo|scheduled|review)
          flight_age=$(( $(date +%s) - $(jq -r '.created_epoch // 0' "$MAIL_FLIGHT" 2>/dev/null || echo 0) ))
          if (( flight_age > STALE_SECS )); then
            echo "[$(ts)] mail 卡 ${mail_flight_card} 非终态超 ${STALE_SECS}s（age=${flight_age}s）→ 清 + fallback" >>"$LOG"
            rm -f "$MAIL_FLIGHT"
            card_fallback_mail "flight 陈旧 ${flight_age}s"
          else
            echo "[$(ts)] mail 卡 ${mail_flight_card} 在飞（status=$card_status age=${flight_age}s）→ 本轮跳过（pending 保留自然重研判）" >>"$LOG"
          fi
          ;;
        *)
          # 查无此 id（archived/清理/异常）→ 异常视同失败
          echo "[$(ts)] mail 卡 ${mail_flight_card} 查无终态（status=${card_status:-空}）→ 清 + fallback" >>"$LOG"
          rm -f "$MAIL_FLIGHT"
          card_fallback_mail "flight 卡查无"
          ;;
      esac
    else
      echo "[$(ts)] 有新 GitHub 邮件 → 建 mail 研判卡" >>"$LOG"
      create_mail_card
    fi
  elif (( mrc == 0 )); then
    echo "[$(ts)] 邮件闸门：无新 GitHub 通知" >>"$LOG"
  else
    echo "[$(ts)] 邮件闸门出错 rc=${mrc}（himalaya/网络抖动？下轮重试）" >>"$LOG"
  fi
fi

# --- 2. 每日 radar（T3 卡化 + 补跑旗标）：研判主路 = radar 卡（contrib worker）；claude -p
#     降级为兜底。补跑旗标 pending-radar.flag：QC 开/hermes 不可用致窗口错过时落盘，任意时段
#     补跑；删除条件 = radar 研判实际完成（卡终态 done 或 fallback claude exit 0）。---
RADAR_FLIGHT="$CONTRIB/kanban-flight-radar.json"
RADAR_FLAG="$CONTRIB/pending-radar.flag"

fallback_radar() {
  # QC gate（T2 语义）：断路器仅挡 claude 兜底路——QC 开 → 跳过 claude + 幂等告警入账
  if [[ -x "$QC" ]] && ! zsh "$QC" check >/dev/null 2>&1; then
    echo "[$(ts)] 断路器仅挡兜底路（GLM 配额），radar fallback 跳过（claude 未调用）" >>"$LOG"
    "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-radar-fallback-skipped" \
      --summary "radar fallback 被配额断路器挡下（GLM 配额冷却中），本轮 claude 兜底未执行" >/dev/null 2>&1 || true
    return 0
  fi
  echo "[$(ts)] radar fallback → claude -p 旧路" >>"$LOG"
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
    rm -f "$RADAR_FLAG"   # 兜底研判完成 → 旗标删除（删除条件=研判实际完成）
  fi
}

card_fallback_radar() {  # 卡路失败 → 告警入账 + claude 旧路兜底（旗标不动，由 fallback 终态处置）
  "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
    --key "$(date +%F)-radar-card-fallback" \
    --summary "radar 建卡路失败（${1:-unknown}），已回落 claude 旧路兜底" >/dev/null 2>&1 || true
  fallback_radar
}

create_radar_card() {
  local body_ts body_file card_json card_id rc=0
  body_ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CONTRIB/card-bodies"
  body_file="$CONTRIB/card-bodies/radar-$body_ts.body.md"
  {
    printf '# contrib radar 研判卡\n\n'
    printf '## 任务\n\n'
    printf -- '- 工作模式与 rubric 权威: %s 模式二（radar）\n' "$SKILL_MD"
    printf -- '- 产出路径: %s/radar/%s.md（照旧两节）+ briefs 追加雷达摘要\n' "$CONTRIB" "$(date +%F)"
    printf '\n## 红线（必须遵守）\n\n'
    printf -- '- gh 只读；零 push、零评论、零对外动作\n'
    printf -- '- 自动构建只到本地（模式三绝不 push / 绝不 gh pr create）\n'
    printf -- '- rq.sh 只允许本地渠道动作；-q 模式禁脚本形态：python -c / jq -e / * -e 一律不可用\n'
    printf '\n## 收尾要求\n\n'
    printf -- '- 完成调 kanban_complete 时必须同时传 summary 与 result\n'
  } >"$body_file"
  card_json="$(bash "$MARTIN/scripts/contrib/kanban_card.sh" create \
    --kind radar --title "contrib radar $(date +%F)" \
    --body-file "$body_file" \
    --json-out "$CONTRIB/card-bodies/radar-$body_ts.card.json" 2>>"$LOG")" || rc=$?
  if [[ $rc -ne 0 || -z "$(printf '%s' "$card_json" | jq -r '.id // empty' 2>/dev/null || true)" ]]; then
    echo "[$(ts)] radar 建卡失败（rc=${rc}）→ 置/保补跑旗标" >>"$LOG"
    [[ -f "$RADAR_FLAG" ]] || printf '%s\n' "$(date +%F)" >"$RADAR_FLAG"
    card_fallback_radar "建卡失败 rc=$rc"
    return 0
  fi
  card_id="$(printf '%s' "$card_json" | jq -r '.id // empty' 2>/dev/null || true)"
  # 建卡成功 → 登记在飞；旗标不动（删除条件=卡终态 done 或 fallback 成功）
  jq -n --arg kind radar --arg id "$card_id" --arg bf "" --argjson e "$(date +%s)" \
    '{kind: $kind, card_id: $id, batch_file: $bf, created_epoch: $e}' \
    >"$RADAR_FLIGHT.tmp" && mv "$RADAR_FLIGHT.tmp" "$RADAR_FLIGHT"
  echo "[$(ts)] radar 研判卡已建 ${card_id}（旗标不动）" >>"$LOG"
}

maybe_radar() {
  local hour="${1:-$(date +%H)}"
  local radar_card="" card_status="" run_outcome="" flight_age list_json show_json
  # ① 凡存在 radar 登记每轮即查终态（不受窗口门控——防 done 滞留到次日）
  if [[ -s "$RADAR_FLIGHT" ]] && jq -e 'type == "object"' "$RADAR_FLIGHT" >/dev/null 2>&1; then
    radar_card="$(jq -r 'if .kind == "radar" then (.card_id // empty) else empty end' "$RADAR_FLIGHT" 2>/dev/null || true)"
  fi
  if [[ -n "$radar_card" ]]; then
    card_status=""
    if list_json="$(hermes_call list --json 2>>"$LOG")"; then
      card_status="$(printf '%s' "$list_json" | jq -r --arg id "$radar_card" \
        '[.[] | select(.id == $id)][0].status // empty' 2>>"$LOG" || true)"
    fi
    case "$card_status" in
      done)
        rm -f "$RADAR_FLIGHT"
        rm -f "$RADAR_FLAG"   # 研判完成 → 旗标删除
        echo "[$(ts)] radar 卡 ${radar_card} 已 done → 清登记 + 旗标清除" >>"$LOG"
        if [[ "$hour" != "08" ]]; then
          return 0
        fi
        # 重审 I1：仅 08 窗口轮首探到前卡 done 时当日窗口才确实未消费 → fall-through 建卡；
        # flag 情形 fall-through 会系统性双跑，故 fall-through 仅 hour==08
        echo "[$(ts)] 08 窗口内探到前卡 done → fall-through 建当日卡" >>"$LOG"
        ;;
      blocked)
        run_outcome=""
        if show_json="$(hermes_call show "$radar_card" --json 2>>"$LOG")"; then
          run_outcome="$(printf '%s' "$show_json" | jq -r '[.runs[]? | select(.outcome != null)][-1].outcome // empty' 2>>"$LOG" || true)"
        fi
        case "$run_outcome" in
          gave_up|crashed|timed_out|spawn_failed)
            echo "[$(ts)] radar 卡 ${radar_card} blocked（outcome=${run_outcome}，重试耗尽）→ fallback（旗标不动）" >>"$LOG"
            rm -f "$RADAR_FLIGHT"
            card_fallback_radar "卡 blocked outcome=$run_outcome"
            ;;
          *)
            echo "[$(ts)] radar 卡 ${radar_card} blocked（outcome=${run_outcome:-未知}，非重试耗尽）→ 本轮跳过" >>"$LOG"
            ;;
        esac
        return 0
        ;;
      ready|running|triage|todo|scheduled|review)
        flight_age=$(( $(date +%s) - $(jq -r '.created_epoch // 0' "$RADAR_FLIGHT" 2>/dev/null || echo 0) ))
        if (( flight_age > STALE_SECS )); then
          echo "[$(ts)] radar 卡 ${radar_card} 非终态超 ${STALE_SECS}s（age=${flight_age}s）→ 清 + fallback（旗标保留）" >>"$LOG"
          rm -f "$RADAR_FLIGHT"
          card_fallback_radar "flight 陈旧 ${flight_age}s"
        else
          echo "[$(ts)] radar 卡 ${radar_card} 在飞（status=$card_status age=${flight_age}s）→ 本轮跳过" >>"$LOG"
        fi
        return 0
        ;;
      *)
        # 查无此 id（archived/清理/异常）→ 异常视同失败（旗标保留，等下轮）
        echo "[$(ts)] radar 卡 ${radar_card} 查无终态（status=${card_status:-空}）→ 清 + fallback" >>"$LOG"
        rm -f "$RADAR_FLIGHT"
        card_fallback_radar "flight 卡查无"
        return 0
        ;;
    esac
  fi
  # ② 窗口或旗标存在且无登记 → 建卡（QC 开仍建卡：卡路不受 QC 限）
  if [[ "$hour" == "08" || -f "$RADAR_FLAG" ]]; then
    echo "[$(ts)] radar 窗口/旗标命中 → 建 radar 研判卡" >>"$LOG"
    create_radar_card
  fi
  # ③ 非窗口 && 无登记 && 无旗标 → 原样无动作
}
# RADAR_HOUR 测试 seam：空（缺省）=现状 date +%H，生产语义零变化
maybe_radar "${RADAR_HOUR:-}"

# --- 2.5 own-PR 机械盯梢（09-10）：零 LLM diff——strzhao 名下 open PR 对机械快照比对，
#     事件入既有 events.jsonl 消费链（高级 own-pr-activity/低级 own-pr-info；当轮被段 3 flush 消费）。
#     gh 失败断路/快照损坏重建都在脚本内自理（exit 1 只记日志，不拖死 hourly 链）；bash 显式调
#     （脚本 shebang 是 bash，双 shell 二象性防御），120s 超时兜底防 gh 挂死。---
OWNPR_WATCH="$MARTIN/scripts/contrib/own_pr_watch.sh"
if [[ -x "$OWNPR_WATCH" ]]; then
  ownpr_rc=0
  run_phase 120 bash "$OWNPR_WATCH" >>"$LOG" 2>&1 || ownpr_rc=$?
  # 字面 own_pr_watch 入日志（t7-08 场景13.P2 断言锚；保留既有中文短语兼容 unit:540）
  echo "[$(ts)] own_pr_watch own-PR 盯梢 exit=$ownpr_rc" >>"$LOG"
fi

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

# --- 4. 快车道（09-04；T4 卡化）：深检两阶段改 kanban 依赖卡链（preflight 卡 → worker 自建
#     redteam 子卡 --parent 关联）。建卡主路 = deepcheck_card.sh create（两入口等价地基）；
#     claude 编排（deep-check.sh）降级为 fallback（建卡失败才走，nohup 不阻塞下一轮 scan；
#     contrib-watch.plist 已确认 AbandonProcessGroup=true，收割坑已解）---
DEEPCHECK_CARD="$MARTIN/scripts/contrib/deepcheck_card.sh"
if [[ -x "$DEEPCHECK_CARD" ]]; then
  # 终态收割先行（radar 先例：凡存在登记每轮即查，不受 gate 命中门控）——
  # 链完成 → auto-gate 编排层桥接（L2-auto 保留）
  bash "$DEEPCHECK_CARD" harvest >>"$LOG" 2>&1 \
    || echo "[$(ts)] deepcheck flight 收割异常（下轮重试）" >>"$LOG"
fi
if [[ -x "$MARTIN/scripts/contrib/deep_check_gate.sh" ]]; then
  zsh "$MARTIN/scripts/contrib/deep_check_gate.sh" >>"$LOG" 2>&1
  gate_rc=$?
  if (( gate_rc == 10 )); then
    if [[ -x "$DEEPCHECK_CARD" ]]; then
      bash "$DEEPCHECK_CARD" create >>"$LOG" 2>&1
      dc_rc=$?
      case $dc_rc in
        0)
          echo "[$(ts)] 快车道：深检 preflight 卡已建（主路）" >>"$LOG"
          ;;
        10)
          # 在飞/全局单深检 → 跳过（绝不 fallback：在飞走 fallback = 双轨并发 + 双 reserve）
          echo "[$(ts)] 快车道：深检卡在飞/跳过（全局单深检语义）" >>"$LOG"
          ;;
        *)
          echo "[$(ts)] 快车道：深检建卡失败 rc=$dc_rc → fallback deep-check.sh（nohup）" >>"$LOG"
          nohup zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1 &
          ;;
      esac
    else
      echo "[$(ts)] 快车道：deepcheck_card.sh 缺失 → fallback deep-check.sh（nohup）" >>"$LOG"
      nohup zsh "$MARTIN/scripts/contrib/deep-check.sh" >>"$LOG" 2>&1 &
    fi
  elif (( gate_rc == 0 )); then
    echo "[$(ts)] 快车道：无可跑项" >>"$LOG"
  else
    echo "[$(ts)] 快车道：gate 出错 rc=$gate_rc" >>"$LOG"
  fi
fi

echo "[$(ts)] ===== run-watch done =====" >>"$LOG"
