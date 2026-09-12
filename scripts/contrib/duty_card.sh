#!/bin/bash
# duty_card.sh — contrib 值班卡 helper（值班环编排侧三子命令：create / harvest / apply）
#
# 用途：contrib 域值班环——同时刻至多一张「contrib 值班卡」在飞，worker 按卡内嵌
#       state brief（六源伤情巡检）与模式七契约值守 contrib 域；本脚本承担建卡、
#       终态收割、归档代行三段编排，由 run-watch 尾部值班段（或人工 / launchd 一次性
#       作业，须非 worker 进程上下文）调起。
#
# 子命令:
#   create [--force]  — 建值班卡主路（互斥锁内八步：建卡锁 → flight 在飞检查 → 节流 →
#                       state brief → 写 body 五段 → 建卡 → flight 登记 → 写节流戳）
#   harvest           — 幂等清登记（登记卡终态/查无 → rm flight；在途/查询失败/JSON 坏 →
#                       保留；全程 fail-soft 恒 exit 0）
#   apply [--dry-run] — 扫 duty-ledger.md 的 archive-request 行，逐条复核五条（board 存在 /
#                       status ∈ {blocked,gave_up} / 非 running / 卡龄 >24h / 所提 rq 无
#                       awaiting-approval 与 approved 态项）：合格代行归档落 executed 行，
#                       不合格与幂等跳过落 skipped 行（下轮重试）；--dry-run 零写入；恒 exit 0
# create exit 闭集: 0=已建卡  10=跳过（在飞/节流窗口内/锁被占）  1=失败（brief 取不到/
#                   建卡失败/flight 登记写盘失败/body 写盘失败）；harvest 与 apply 恒 0
#
# 分工裁决（BRIEFING §2 白名单二分，为何 apply 是编排层专属）：archive 不归 worker 动手——
#   worker 进程被框架 fence（子进程继承 HERMES_DELEGATED_CHILD_CONTEXT=1，kanban 写动词
#   archive/create/complete 与 kanban_db 写事务一律 fail-closed，锚 hermes_cli/kanban.py:214-241
#   的 denied 集合与 kanban_db._assert_not_delegated_child_mutation），值班卡 worker 只判定+
#   声明（台账 archive-request 行），归档由本脚本 apply 在非 worker 进程上下文代行。
#   禁绕过：本脚本绝不 unset 该 fence 闸、绝不直连 SQLite 写板、绝不走任何写板旁路。
#
# 建卡调用面为何自持：kanban_card.sh 的 --kind 闭集（scan|mail|radar|deepcheck|digest|upstream）
#   不含 duty，且本卡红线四禁改既有脚本 → 建卡调用面按 kanban_card.sh create 契约逐条同源
#   自持（env -u 三连 / --board 父级 flag 位插 kanban 与子命令之间 / {id,status} 归一化 /
#   --idempotency-key / --max-retries 2 / --json），待 D1 迁移时收归 kanban_card.sh 白名单。
# 事件族（--key 日幂等；notify 缺席不阻塞）: <日期>-duty-brief-fail（brief 取不到）/
#   <日期>-duty-card-fail（建卡失败 / flight 登记写盘失败 / body 写盘失败）
# seam: MARTIN_DIR / CONTRIB_DATA_DIR / KANBAN_BOARD / DUTY_INTERVAL_SECS（节流秒，缺省 7200）/
#   HERMES_BIN / HERMES_TIMEOUT（create 调用超时，缺省 60）/ FLIGHT_TIMEOUT（list/show/archive
#   调用超时，缺省 30）/ DUTY_APPLY_DRY_RUN（=1 等价 apply --dry-run）
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
STATE_BRIEF="$MARTIN/scripts/contrib/state_brief.sh"
QUEUE="$CONTRIB/ready-queue.json"
LEDGER="$CONTRIB/duty-ledger.md"
FLIGHT="$CONTRIB/kanban-flight-duty.json"
CARD_LOCK="$CONTRIB/locks/duty-card.lock"
STAMP="$CONTRIB/.duty-last-create"
DUTY_INTERVAL_SECS="${DUTY_INTERVAL_SECS:-7200}"
case "${DUTY_INTERVAL_SECS}" in
  *[!0-9]*) DUTY_INTERVAL_SECS=7200 ;;
esac
FLIGHT_TIMEOUT="${FLIGHT_TIMEOUT:-30}"
HERMES_TIMEOUT="${HERMES_TIMEOUT:-60}"
LOG="$CONTRIB/logs/duty.log"
HERMES_BIN="${HERMES_BIN:-hermes}"
# board 缺省语义（规格钉死：未设=contrib、显式空串=不 pin）——${X-d} 只对 unset 取缺省；
# 裸调（launchd/人工）无 run-watch 的 export 兜底，必须在 seam 层自持解析，否则卡落默认板
KANBAN_BOARD="${KANBAN_BOARD-contrib}"

log() { echo "[$(date '+%F %T')] duty-card: $*" >>"$LOG"; }

usage() {
  sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# 阶段超时 seam（同 run-watch/deepcheck_card run_phase 三级退化；hermes 挂死不拖死调用方）
run_phase() {
  local secs="${1}"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$secs" "$@"
  else
    "$@"
  fi
}

# hermes_call <secs> <args...> — C1 调用面：run_phase 包裹 + env -u 三连（CC shell env 劫持
# 防御）+ --board 插在 kanban 与子命令之间（父级 flag 位置，尾部追加=上游 unrecognized
# arguments 硬失败）；bash 空数组 +guard（bash 3.2 空 array 展开防 set -u 报 unbound）
hermes_call() {
  local secs="${1}"; shift
  local -a board_args=()
  [[ -n "${KANBAN_BOARD:-}" ]] && board_args=(--board "$KANBAN_BOARD")
  run_phase "$secs" env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
    "$HERMES_BIN" kanban ${board_args[@]+"${board_args[@]}"} "$@"
}

emit_event() { # <key-suffix> <summary> — notify 缺席不阻塞主流程（C7 惯用法）
  bash "$NOTIFY" event pipeline-failure --key "$(date +%F)-${1}" --summary "${2}" >/dev/null 2>&1 || true
}

acquire_lock() { # >3h 残留强清（deepcheck_card.sh:131-141 同源）；成功 0 / 被占 1
  if [[ -d "$CARD_LOCK" ]]; then
    local age=$(( $(date +%s) - $(stat -f %m "$CARD_LOCK" 2>/dev/null || echo "$(date +%s)") ))
    if (( age > 10800 )); then
      log "陈旧建卡锁 ${age}s 强清"
      rmdir "$CARD_LOCK" 2>/dev/null || true
    fi
  fi
  mkdir -p "$CONTRIB/locks" 2>/dev/null || true
  mkdir "$CARD_LOCK" 2>/dev/null
}

board_list_json() { # → contrib board list --json 原文（失败/超时非零退出）
  hermes_call "$FLIGHT_TIMEOUT" list --json 2>>"$LOG"
}

list_is_array() { # <json 串> → 0=合法 JSON 数组
  printf '%s' "$1" | jq -e 'type == "array"' >/dev/null 2>&1
}

card_status_from_list() { # <list_json> <card_id> → status（查无 → 空）
  local status
  status="$(printf '%s' "$1" | jq -r --arg id "$2" '[.[] | select(.id == $id)][0].status // empty' 2>>"$LOG" || true)"
  printf '%s' "$status"
}

# flight_inflight — create 的 flight 在飞检查（设计步骤二）。
#   return 0=登记卡在飞（保留登记，调用方 exit 10）
#   return 1=无登记/坏 JSON/非法登记/登记卡终态/查无 → 已按语义清除或不存在（可继续）
#   return 2=登记卡终态查询失败（fail-closed：调用方按在飞处理 exit 10）
flight_inflight() {
  [[ -s "$FLIGHT" ]] || return 1
  if ! jq -e 'type == "object"' "$FLIGHT" >/dev/null 2>&1; then
    log "flight-duty 损坏（非 JSON 对象）→ 清除自愈"
    rm -f "$FLIGHT"
    return 1
  fi
  local fid=""
  fid="$(jq -r 'if .kind == "duty" then (.card_id // empty) else empty end' "$FLIGHT" 2>/dev/null || true)"
  if [[ -z "$fid" ]]; then
    log "flight-duty 非法/缺 card_id → 清除（自愈）"
    rm -f "$FLIGHT"
    return 1
  fi
  local ljson="" lrc=0 fstatus=""
  ljson="$(board_list_json)" || lrc=$?
  if (( lrc != 0 )) || ! list_is_array "$ljson"; then
    log "flight-duty 登记卡 ${fid} 终态查询失败"
    return 2
  fi
  fstatus="$(card_status_from_list "$ljson" "$fid")"
  case "$fstatus" in
    done|archived|cancelled)
      log "值班卡 ${fid} 已终态（${fstatus}）→ 旧登记清除"
      rm -f "$FLIGHT"
      return 1
      ;;
    "")
      log "值班卡 ${fid} 查无 → 旧登记清除"
      rm -f "$FLIGHT"
      return 1
      ;;
    *)
      log "值班卡在飞（${fid} status=${fstatus}）"
      return 0
      ;;
  esac
}

ensure_ledger() { # 台账不存在则首建（表头 + 行格式说明；运行时产物，不入库）
  [[ -f "$LEDGER" ]] && return 0
  mkdir -p "$CONTRIB" 2>/dev/null || true
  {
    printf '# contrib 值班台账（duty-ledger；运行时产物，不入库）\n\n'
    printf '行格式（六列管道分隔）：| 时间 | 动作 | 对象 | 状态 | 判据：… | decisionReason：… |\n'
    printf '动作闭集：flight-clean / rq-expired / budget-refund / archive-request / archive\n\n'
  } >"$LEDGER"
}

ledger_append() { # <对象> <状态> <判据> — 追加 archive 动作台账行（六列；decisionReason 固定措辞）
  ensure_ledger
  printf '| %s | archive | %s | %s | 判据：%s | decisionReason：编排层代行（worker 进程被框架 fence，kanban 写 fail-closed） |\n' \
    "$(date '+%F %H:%M')" "${1}" "${2}" "${3}" >>"$LEDGER"
}

ledger_has_executed() { # <id> → 0=台账已有该 id 的 archive executed 行（幂等基准）
  awk -F'|' -v id="${1}" '
    {
      for (i = 1; i <= NF; i++) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", $i) }
      if ($3 == "archive" && $4 == id && $5 == "executed") { found = 1 }
    }
    END { if (found) { exit 0 } exit 1 }
  ' "$LEDGER" 2>>"$LOG"
}

ledger_request_ids() { # → 全部 archive-request 目标卡 id（每行一个 dedup；awk -F'|' 分列 +
  #                       trim 容空格差异。executed 幂等过滤在调用方做——幂等跳过也须落
  #                       skipped 台账行，故此处不过滤）
  awk -F'|' '
    {
      for (i = 1; i <= NF; i++) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", $i) }
      if ($3 == "archive-request" && $4 != "") { req[$4] = 1 }
    }
    END { for (id in req) { print id } }
  ' "$LEDGER" 2>>"$LOG" | sort || true
}

write_body() { # <brief 全文> — 值班卡 body（stdout；五段固定结构，BRIEFING §1 步骤五）
  local brief="${1}"
  printf '# contrib 值班卡（贡献域值班，contrib-watch 模式七 duty）\n\n'
  printf -- '- 卡型：贡献域值班卡（contrib duty）——同时刻至多一张在飞；建卡受在飞守卫与 %s 秒节流双闸\n' "${DUTY_INTERVAL_SECS}"
  printf -- '- 生成时间：%s（编排层 duty_card.sh create 生成）\n' "$(date '+%F %T')"
  printf '\n## state brief 全文\n\n'
  printf '%s\n' "$brief"
  printf '\n## 行动手册（worker 契约，白名单与红线原文）\n\n'
  cat <<'DUTY_MANUAL_EOF'
### 0. 角色与分工（白名单二分裁决）
你（值班卡 worker）能动手的只有第 2 点白名单三项；archive（归档卡）你只判定与声明
（写台账 archive-request 行），由编排层 duty_card.sh apply 代行执行。理由：worker 进程
被框架 fence——子进程继承 HERMES_DELEGATED_CHILD_CONTEXT=1，kanban 写动词
（archive/create/complete）与 kanban_db 写事务一律 fail-closed（锚 hermes_cli/kanban.py:214-241）。
禁绕过：禁 unset 该 fence 闸、禁直连 SQLite 写板、禁任何写板旁路。

### 1. 领卡与伤情判定
读卡 body → 逐节读下方内嵌 state brief（第 1-6 节各带「伤情判定」行）→ 按判定行动：
正常=不动手但记台账；注意=记录观察；告警=按白名单处理或升级事件；degraded=记台账并在
summary 报告缺源。

### 2. 白名单（可动手，仅此三项）
- 清 kanban-flight-*.json 陈旧登记：仅登记卡已终态（done/archived/cancelled）或查无时才清。
- rq.sh set <id> expired：仅实查确认 premise 死亡、且该项仍处深检自有态（queued/deep-check）
  ——L2 链态（awaiting-approval/approved）归审批链，不可直达 expired。
- rq.sh budget refund <id> --lane <deep|probe>：仅 budget 账本确有该 id 的 reserve 记录才退
  （refund 每调必减 used，双调=预算超发）。

### 3. archive 只声明不执行
台账追加一行：| <时间> | archive-request | <目标卡 id> | pending | 判据：<…> | decisionReason：<…> |
由编排层 duty_card.sh apply 复核后代行归档（其复核五条：目标卡在 board 存在 / status ∈
{blocked, gave_up} / 非 running / 卡龄 >24h / 卡所提 rq 无 awaiting-approval 与 approved 态项）。

### 4. 红线（禁止）
任何 push / gh 写 / 微信外发 / 改 approved.log / 触碰 awaiting-approval 与 approved 态项
（含其 rq 与关联卡，如 rq-20260912-812574 与 t_f8c0d470）/ 删除任何 rq 项 / 归档 running
或龄 ≤24h 的卡 / 改既有脚本。

### 5. 台账强制产出
contrib-data/duty-ledger.md 每动作一行（六列管道分隔）：
| <YYYY-MM-DD HH:MM> | <动作> | <对象> | <状态> | 判据：<…> | decisionReason：<…> |
动作闭集：flight-clean / rq-expired / budget-refund / archive-request / archive。
不动手的判定也要记一行；文件不存在则首建并写表头与行格式说明。

### 6. 白名单外发现 → 升级
bash scripts/contrib/notify.sh event pipeline-failure --key <日期>-duty-<短标识> --summary <30 字内>
（受每日 3 条硬闸，宁进简报不进微信）+ 写台账 + 写进 summary。

### 7. 收尾
kanban_complete 必须同时传 summary 与 result；summary 三段式（发生了什么/为何重要/建议动作），
自包含（用户只看得到它）。
DUTY_MANUAL_EOF
  printf '\n## 深入阅读指针\n\n'
  printf -- '- 工作模式权威：%s 模式七（duty）\n' "$MARTIN/.claude/skills/contrib-watch/SKILL.md"
  printf -- '- 值班台账：%s（本卡全部动作与判定的留痕面）\n' "$LEDGER"
  printf '\n## 收尾要求\n\n'
  printf -- '- 完成调 kanban_complete 时必须同时传 summary 与 result\n'
  printf -- '- summary 三段式：发生了什么 / 为何重要 / 建议动作（自包含，用户只看得到它）\n'
}

cmd_harvest() { # 幂等清登记，fail-soft 恒 exit 0
  if [[ ! -s "$FLIGHT" ]]; then
    exit 0
  fi
  if ! jq -e 'type == "object"' "$FLIGHT" >/dev/null 2>&1; then
    log "harvest: flight-duty 坏 JSON → 保留（create 自愈面）"
    exit 0
  fi
  if ! acquire_lock; then
    log "harvest: 建卡锁被占 → 本轮跳过"
    exit 0
  fi
  trap 'rmdir "$CARD_LOCK" 2>/dev/null' EXIT
  local fid="" ljson="" lrc=0 fstatus=""
  fid="$(jq -r 'if .kind == "duty" then (.card_id // empty) else empty end' "$FLIGHT" 2>/dev/null || true)"
  if [[ -z "$fid" ]]; then
    log "harvest: flight-duty 非法/缺 card_id → 保留（create 自愈面）"
    exit 0
  fi
  ljson="$(board_list_json)" || lrc=$?
  if (( lrc != 0 )) || ! list_is_array "$ljson"; then
    log "harvest: 登记卡 ${fid} 终态查询失败 → 保留登记"
    exit 0
  fi
  fstatus="$(card_status_from_list "$ljson" "$fid")"
  case "$fstatus" in
    done|archived|cancelled)
      rm -f "$FLIGHT"
      log "harvest: 值班卡 ${fid} 已终态（${fstatus}）→ 登记已清"
      ;;
    "")
      rm -f "$FLIGHT"
      log "harvest: 值班卡 ${fid} 查无 → 登记已清"
      ;;
    *)
      log "harvest: 值班卡 ${fid} 在飞（status=${fstatus}）→ 保留登记"
      ;;
  esac
  exit 0
}

cmd_create() { # 八步：锁 → flight → 节流 → brief → body → 建卡 → 登记 → 戳
  local force=0
  case "${1:-}" in
    "") : ;;
    --force) force=1 ;;
    *) usage ;;
  esac

  # 1. 建卡锁（mkdir 语义；残留 >3h 强清；trap EXIT 释放）
  if ! acquire_lock; then
    log "create: 建卡锁被占 → 跳过"
    exit 10
  fi
  trap 'rmdir "$CARD_LOCK" 2>/dev/null' EXIT

  # 2. flight 检查（同时刻仅一张值班卡在飞；终态/查无/坏文件清登记继续）
  flight_inflight
  case $? in
    0)
      log "create: 值班卡在飞 → 跳过"
      exit 10
      ;;
    2)
      log "create: 登记卡终态查询失败 → 按在飞跳过（fail-closed）"
      exit 10
      ;;
  esac

  # 3. 节流（旗标文件语义；--force 仅人工/测试用；戳写盘成功才计入——见步骤八）
  if (( force == 1 )); then
    log "create: --force 跳过节流（人工/测试）"
  else
    local last="" gap=0
    last="$(cat "$STAMP" 2>/dev/null || true)"
    case "$last" in
      ''|*[!0-9]*) last="" ;;
    esac
    if [[ -n "$last" ]]; then
      gap=$(( $(date +%s) - last ))
      if (( gap >= 0 && gap < DUTY_INTERVAL_SECS )); then
        log "create: 节流窗口内（距今 ${gap}s < ${DUTY_INTERVAL_SECS}s）→ 跳过"
        exit 10
      fi
    fi
  fi

  # 4. state brief（stdout 即 brief md；rc≠0/空输出/缺「伤情判定」锚 → 失败）
  local brief="" brc=0
  brief="$(bash "$STATE_BRIEF" 2>>"$LOG")" || brc=$?
  if (( brc != 0 )) || [[ -z "$brief" ]] || [[ "$brief" != *"伤情判定"* ]]; then
    log "create: state brief 取不到（rc=${brc} len=${#brief}，或缺「伤情判定」锚）→ 建卡中止"
    emit_event "duty-brief-fail" "值班卡 state brief 取不到，建卡中止"
    exit 1
  fi

  # 5. 写 body 文件（函数 stdout 重定向落盘，同 deepcheck write_body 范式；五段固定结构）
  local body_ts="" body_file=""
  body_ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CONTRIB/card-bodies" 2>/dev/null || true
  body_file="$CONTRIB/card-bodies/duty-${body_ts}.body.md"
  if ! write_body "$brief" >"$body_file" 2>>"$LOG"; then
    log "create: body 写盘失败（${body_file}）→ 建卡中止"
    emit_event "duty-card-fail" "值班卡 body 写盘失败，建卡中止"
    exit 1
  fi

  # 6. 建卡（自持调用面：C2 flag 面 + {id,status} 归一化，.id 缺失=失败）
  local title="" resp="" crc=0 normalized="" card_id=""
  title="contrib 值班卡 ${body_ts%??}"
  resp="$(hermes_call "$HERMES_TIMEOUT" create "$title" \
    --body "$(cat "$body_file")" \
    --assignee contrib \
    --idempotency-key "duty-${body_ts}" \
    --max-retries 2 \
    --json 2>>"$LOG")" || crc=$?
  normalized="$(printf '%s' "$resp" | jq -c '{id,status}' 2>/dev/null || true)"
  if [[ -n "$normalized" ]]; then
    card_id="$(printf '%s' "$normalized" | jq -r '.id // empty' 2>/dev/null || true)"
  fi
  if (( crc != 0 )) || [[ -z "$normalized" ]] || [[ -z "$card_id" ]]; then
    log "create: 值班卡建卡失败（rc=${crc}）→ 告警"
    emit_event "duty-card-fail" "值班卡建卡失败（rc=${crc}），下轮值班段重试"
    exit 1
  fi

  # 7. flight 登记写盘（jq -n 构造 > .tmp && mv 原子化；失败 → 清 .tmp + 告警 + exit 1）
  local flrc=0
  jq -n --arg kind duty --arg cid "$card_id" --argjson e "$(date +%s)" \
    '{kind: $kind, card_id: $cid, created_epoch: $e}' \
    >"$FLIGHT.tmp" 2>>"$LOG" || flrc=$?
  if (( flrc != 0 )); then
    rm -f "$FLIGHT.tmp"
    log "create: flight-duty 登记写盘失败 → 告警（卡 ${card_id} 由 harvest/create 自愈兜底）"
    emit_event "duty-card-fail" "值班卡 flight 登记写盘失败，下轮重试"
    exit 1
  fi
  mv "$FLIGHT.tmp" "$FLIGHT"

  # 8. 写节流戳（写盘成功才计入；失败只记日志——在飞守卫仍兜底互斥，不计入失败闭集）
  if ! printf '%s\n' "$(date +%s)" >"$STAMP" 2>>"$LOG"; then
    log "节流戳写盘失败（本戳不计入；在飞守卫兜底互斥）"
  fi
  log "create: 值班卡已建 ${card_id}（title=${title} body=${body_file}）"
  exit 0
}

apply_skip() { # <id> <dry> <短理由（日志/dry-run 打印用）> <判据（台账 skipped 行）> —
  #               复核不过/幂等跳过的统一出口：正常轮落 skipped 六列台账行，dry-run 只打印零写入
  local id="${1}" dry="${2}" reason="${3}" crit="${4}"
  if (( dry == 1 )); then
    printf '[dry-run] 将跳过 %s（%s）\n' "$id" "$reason"
    log "apply: ${id} ${reason}（dry-run：零写入）"
  else
    ledger_append "$id" "skipped" "$crit"
    log "apply: ${id} ${reason} → 跳过（skipped 台账行已落，下轮重试）"
  fi
  return 0
}

apply_one() { # <id> <dry:0|1> <board_list_json> — 单目标复核五条 + 代行归档（fail-soft；
  #              复核不过落 skipped 台账行，判据写明不过的具体项：状态与卡龄）
  local id="${1}" dry="${2}" ljson="${3}"
  local exists="" sjson="" src=0 status="" status_disp="" created_at="" created_epoch="" title="" body=""
  local age=0 age_str="" verdict="" rq_ids="" rq_id="" st=""
  # 复核 1：目标卡在 contrib board 存在
  exists="$(printf '%s' "$ljson" | jq -r --arg id "$id" '[.[] | select(.id == $id)] | length' 2>>"$LOG" || true)"
  if [[ -z "$exists" || "$exists" == "0" ]]; then
    apply_skip "$id" "$dry" "复核1 不过（board 查无）" "复核1 不过：board 查无（状态与卡龄不可证）"
    return 0
  fi
  sjson="$(hermes_call "$FLIGHT_TIMEOUT" show "$id" --json 2>>"$LOG")" || src=$?
  if (( src != 0 )) || [[ -z "$sjson" ]] || ! printf '%s' "$sjson" | jq -e 'has("task")' >/dev/null 2>&1; then
    apply_skip "$id" "$dry" "show 失败/不可解析" "复核不可完成：show 查询失败/不可解析（状态与卡龄不可证）"
    return 0
  fi
  status="$(printf '%s' "$sjson" | jq -r '.task.status // empty' 2>>"$LOG" || true)"
  status_disp="${status:-未知}"
  # 卡龄先证（created_at 缺失/不可解析 = 龄不可证；epoch 直取，ISO 串由 jq fromdateiso8601 兜底）
  created_at="$(printf '%s' "$sjson" | jq -r '.task.created_at // empty' 2>>"$LOG" || true)"
  case "$created_at" in
    ''|null) created_epoch="" ;;
    *[!0-9]*)
      created_epoch="$(printf '%s' "$created_at" | jq -r 'try fromdateiso8601 catch ""' 2>/dev/null || true)"
      ;;
    *) created_epoch="$created_at" ;;
  esac
  if [[ -z "$created_epoch" || "$created_epoch" == "0" ]]; then
    age_str="不可证"
  else
    age=$(( $(date +%s) - created_epoch ))
    age_str="${age}s"
  fi
  verdict="status=${status_disp} 卡龄=${age_str}"
  # 复核 2：当前状态 ∈ {blocked, gave_up}
  case "$status" in
    blocked|gave_up) : ;;
    *)
      apply_skip "$id" "$dry" "复核2 不过（status=${status_disp} 不在 {blocked,gave_up}）" \
        "复核2 不过：status=${status_disp} 不在 {blocked,gave_up}，${verdict}"
      return 0
      ;;
  esac
  # 复核 3：非 running（防御位：被复核 2 闭集蕴含，按契约五条保留显式判定）
  if [[ "$status" == "running" ]]; then
    apply_skip "$id" "$dry" "复核3 不过（running）" "复核3 不过：running，${verdict}"
    return 0
  fi
  # 复核 4：卡龄 >24h（now - created_at）
  if [[ "$age_str" == "不可证" ]]; then
    apply_skip "$id" "$dry" "复核4 不过（created_at 缺失/不可解析）" \
      "复核4 不过：卡龄不可证（created_at 缺失/不可解析），${verdict}"
    return 0
  fi
  if (( age <= 86400 )); then
    apply_skip "$id" "$dry" "复核4 不过（卡龄 ${age}s ≤24h）" "复核4 不过：卡龄=${age}s ≤86400s（24h），${verdict}"
    return 0
  fi
  title="$(printf '%s' "$sjson" | jq -r '.task.title // empty' 2>>"$LOG" || true)"
  body="$(printf '%s' "$sjson" | jq -r '.task.body // empty' 2>>"$LOG" || true)"
  # 复核 5：卡所提 rq（标题与 body 中 rq-YYYYMMDD-xxxxx）无 awaiting-approval / approved 态项
  #   （rq 态从 ready-queue.json 查；awaiting-approval/approved 归审批链，零触碰）
  rq_ids="$(printf '%s\n%s\n' "$title" "$body" | grep -oE 'rq-[0-9]{8}-[0-9]+' | sort -u || true)"
  if [[ -n "$rq_ids" ]]; then
    while IFS= read -r rq_id; do
      [[ -n "$rq_id" ]] || continue
      st="$(jq -r --arg id "$rq_id" '[.items[] | select(.id == $id)][0].state // empty' "$QUEUE" 2>/dev/null || true)"
      case "$st" in
        awaiting-approval|approved)
          apply_skip "$id" "$dry" "复核5 不过（${rq_id} 态=${st}）" \
            "复核5 不过：${rq_id} 态=${st}（审批链所有），${verdict}"
          return 0
          ;;
      esac
    done <<<"$rq_ids"
  fi
  if (( dry == 1 )); then
    printf '[dry-run] 将归档 %s（%s，rq 无 awaiting-approval/approved 态项）\n' "$id" "$verdict"
    log "apply: ${id} 复核五条全过（dry-run：零写入）"
    return 0
  fi
  # 执行：同建卡调用面（env -u 与超时包裹）；失败只记日志（executed 行不落，下轮重试）
  local arc_rc=0
  hermes_call "$FLIGHT_TIMEOUT" archive "$id" >>"$LOG" 2>&1 || arc_rc=$?
  if (( arc_rc != 0 )); then
    log "apply: ${id} 归档调用失败（rc=${arc_rc}）→ 只记日志（下轮重试）"
    return 0
  fi
  ledger_append "$id" "executed" "复核通过 ${verdict}，所提 rq 无 awaiting-approval/approved 态项"
  log "apply: ${id} 已代行归档（executed 台账行已落）"
  return 0
}

cmd_apply() { # 编排层代行 L1 特权动作，fail-soft 恒 exit 0
  local dry=0
  case "${1:-}" in
    "") : ;;
    --dry-run) dry=1 ;;
    *) log "apply: 未知参数 ${1}（忽略）" ;;
  esac
  [[ "${DUTY_APPLY_DRY_RUN:-}" == "1" ]] && dry=1
  if [[ ! -f "$LEDGER" ]]; then
    log "apply: 台账尚不存在（无 archive-request 行）→ 无事可做"
    exit 0
  fi
  local ljson="" lrc=0
  ljson="$(board_list_json)" || lrc=$?
  if (( lrc != 0 )) || ! list_is_array "$ljson"; then
    log "apply: board list 查询失败/不可解析 → 本轮放弃（fail-soft）"
    exit 0
  fi
  local targets="" id
  targets="$(ledger_request_ids)"
  if [[ -z "$targets" ]]; then
    log "apply: 无 archive-request 行 → 无事可做"
    exit 0
  fi
  if (( dry == 1 )); then
    log "apply: --dry-run 生效（只打印清单零写入）"
  fi
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    # 幂等：台账已有同 id 的 archive executed 行 → 跳过（同样落 skipped 台账行留痕）
    if ledger_has_executed "$id"; then
      if (( dry == 1 )); then
        printf '[dry-run] 将跳过 %s（已有 executed 行幂等）\n' "$id"
        log "apply: ${id} 已有 executed 台账行 → 幂等跳过（dry-run：零写入）"
      else
        ledger_append "$id" "skipped" "已有 executed 行幂等跳过"
        log "apply: ${id} 已有 executed 台账行 → 幂等跳过（skipped 台账行已落）"
      fi
      continue
    fi
    apply_one "$id" "$dry" "$ljson"
  done <<<"$targets"
  exit 0
}

case "${1:-}" in
  harvest)
    shift
    cmd_harvest "$@"
    ;;
  create)
    shift
    cmd_create "$@"
    ;;
  apply)
    shift
    cmd_apply "$@"
    ;;
  *)
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
