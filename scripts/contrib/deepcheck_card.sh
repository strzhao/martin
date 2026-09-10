#!/bin/bash
# deepcheck_card.sh — T4 深检依赖卡 helper（两入口等价地基：run-watch 快车道 + run-deepcheck 09:37）
#
# 子命令:
#   harvest               — deepcheck flight 终态收割（链式完成判定；fail-soft，恒 exit 0）
#   create [rq-id] [lane] — 建卡主路（互斥锁内：flight 检查 → budget reserve → 建卡 → flight 登记）
#                           无参时读 DEEPCHECK_TARGET_FILE（gate 产物 "<rq-id> <lane>"），
#                           成功后 rm（与 fallback deep-check.sh:66 对称，防跨轮幽灵建卡）
# create exit 闭集: 0=已建卡  10=跳过（在飞/全局单深检/项非 queued/锁被占）  1=建卡失败（调用方 fallback）
#
# 设计锚点（T4 state.md §1/§2/契约规约）:
#   - 全局单深检: 任一 deepcheck 登记在飞（无论 rq-id 是否相同）→ create exit 10
#     （语义与 deep-check.sh 既有 LOCK 一致）；重复消费防 dedup 靠 rq 状态机（queued→deep-check 迁移原子）
#   - attempt 级幂等键 deepcheck-<rq-id>-<attempt-epoch>: 同项重试循环每次新 key，避开上游
#     「同 key 返回既有卡」行为（kanban_db.py:3193-3197）拿回旧 blocked 卡的死锁
#   - 互斥锁 $CONTRIB/locks/deepcheck-card.lock 覆盖 check→reserve→create→登记全程
#     （>3h 残留强清，同 deep-check.sh:79 先例）；harvest 与 create 同锁，堵两入口 check-then-act 竞速
#   - 链完成判定序: preflight 卡 done ≠ 链完成（redteam 子卡由 worker 自建，不在本登记）——
#     done 分支: rq=awaiting-approval → 队列 .draft 自愈（空/失联且约定位置 pending/<rq-id>.md
#     有稿即补 set-draft；补不来 → -deepcheck-draft-missing + 维持人工路，绝不放行 auto-gate——
#     否则 execute.sh 取不到草稿 → failed → 重排队死循环，rq-20260910-106667 实证）→
#     编排层 auto-gate.sh（rc0 → rq set approved + execute.sh，
#     复刻 deep-check.sh:177-182；非 0 → 维持 awaiting-approval 人工路）→ 清登记；
#     rq=deep-check → 补查子卡终态（kanban show children → 逐个二次 show）；rq=failed → 清+refund；
#     查无/异常 → 清 + -deepcheck-orphan（人工复核）
#   - stale 阈值独立 DEEPCHECK_STALE_SECS（缺省 86400=24h——两卡链+redteam 子卡排队所需，
#     不复用 scan/mail 的 6h）
#   - budget reserve/refund 本脚本（编排层）专属；worker 卡内绝对禁碰（SKILL 卡模式段钉死）
#   - refund 幂等：budget 账本查无该 id 的 reserve 记录时跳过（rq.sh refund 对 used 每调必减）
# 事件族（新增四族，--key 日幂等）: <日期>-deepcheck-card-fallback（建卡失败/卡失败终态）/
#   <日期>-deepcheck-stale（陈旧清/子卡失败）/ <日期>-deepcheck-orphan（终态查无）/
#   <日期>-deepcheck-draft-missing（链 done 但草稿未登记且约定位置无稿——维持人工路不静默）
# seam: MARTIN_DIR / CONTRIB_DATA_DIR / DEEPCHECK_TARGET_FILE / DEEPCHECK_STALE_SECS /
#       FLIGHT_TIMEOUT / HERMES_BIN（透传 kanban_card.sh）
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
KBC="$MARTIN/scripts/contrib/kanban_card.sh"
SKILL_MD="$MARTIN/.claude/skills/contrib-watch/SKILL.md"
AUTO_GATE="$MARTIN/scripts/approval/auto-gate.sh"
EXECUTE="$MARTIN/scripts/approval/execute.sh"
QUEUE="$CONTRIB/ready-queue.json"
BUDGET="$CONTRIB/budget.json"
FLIGHT="$CONTRIB/kanban-flight-deepcheck.json"
CARD_LOCK="$CONTRIB/locks/deepcheck-card.lock"
TARGET_FILE="${DEEPCHECK_TARGET_FILE:-/tmp/.deepcheck-target}"
STALE_SECS="${DEEPCHECK_STALE_SECS:-86400}"
FLIGHT_TIMEOUT="${FLIGHT_TIMEOUT:-30}"
LOG="$CONTRIB/logs/deepcheck.log"
HERMES_BIN="${HERMES_BIN:-hermes}"

log() { echo "[$(date '+%F %T')] deepcheck-card: $*" >>"$LOG"; }

# 阶段超时 seam（同 run-watch run_phase 三级退化；flight 查询挂死不拖死调用方）
run_phase() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or die "exec: $!"' "$secs" "$@"
  else
    "$@"
  fi
}

# board seam（T6）：KANBAN_BOARD 非空时 kanban 调用 pin 到该 board——--board 是 kanban 父级
# flag，必须插在子命令前；空=不 pin（default board 回退态）。与建卡口 kanban_card.sh 同一 env 同源。
hermes_call() {
  local -a board_args=()
  [[ -n "${KANBAN_BOARD:-}" ]] && board_args=(--board "$KANBAN_BOARD")
  run_phase "$FLIGHT_TIMEOUT" env -u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY \
    "$HERMES_BIN" kanban ${board_args[@]+"${board_args[@]}"} "$@"
}

emit_event() { # <key-suffix> <summary> — notify 缺席不阻塞主流程
  bash "$NOTIFY" event pipeline-failure --key "$(date +%F)-$1" --summary "$2" >/dev/null 2>&1 || true
}

refund_once() { # <id> <lane> — 幂等 refund：budget 账本查无 reserve 记录时跳过
  local id="$1" lane="$2" present
  if [[ "$lane" == "probe" ]]; then
    present="$(jq -r --arg id "$id" '([.probes[].items[]? ] | index($id)) != null' "$BUDGET" 2>/dev/null || echo false)"
  else
    present="$(jq -r --arg id "$id" '([.days[].items[]?] + [.weeks[].items[]?] | index($id)) != null' "$BUDGET" 2>/dev/null || echo false)"
  fi
  if [[ "$present" != "true" ]]; then
    log "$id refund 跳过（budget 账本无 reserve 记录——已 refund 或未 reserve）"
    return 0
  fi
  "$RQ" budget refund "$id" --lane "$lane" >>"$LOG" 2>&1 || true
}

rq_state() { # <id> → state（查无 → 空）
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' "$QUEUE" 2>/dev/null || true
}

card_status_of() { # <card_id> → status（查询失败/查无 → 空）
  local list_json status
  list_json="$(hermes_call list --json 2>>"$LOG")" || { echo ""; return 0; }
  status="$(printf '%s' "$list_json" | jq -r --arg id "$1" '[.[] | select(.id == $id)][0].status // empty' 2>>"$LOG" || true)"
  printf '%s' "$status"
}

card_outcome_of() { # <card_id> → 最近 runs outcome（查询失败 → 空）
  local show_json outcome
  show_json="$(hermes_call show "$1" --json 2>>"$LOG")" || { echo ""; return 0; }
  outcome="$(printf '%s' "$show_json" | jq -r '[.runs[]? | select(.outcome != null)][-1].outcome // empty' 2>>"$LOG" || true)"
  printf '%s' "$outcome"
}

# child_statuses <preflight_card_id> → " <s1> <s2> ..."（无子卡 → 空串）；查询失败 return 1
child_statuses() {
  local show_json children c st out=""
  show_json="$(hermes_call show "$1" --json 2>>"$LOG")" || return 1
  children="$(printf '%s' "$show_json" | jq -r '(.children // []) | .[]' 2>>"$LOG")" || return 1
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    st="$(hermes_call show "$c" --json 2>>"$LOG" | jq -r '.task.status // empty' 2>>"$LOG")" || return 1
    out="$out ${st:-unknown}"
  done <<<"$children"
  printf '%s' "$out"
}

acquire_lock() { # >3h 残留强清（deep-check.sh:79 先例）；成功 0 / 被占 1
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

# harvest_locked — 前置：已持锁且 FLIGHT 为合法 JSON 对象。
# 链式终态判定；return 0=登记已清/自愈  10=仍在飞（保留登记）
harvest_locked() {
  local card_id rq_id lane card_status state age outcome cstatuses gate_out gate_rc=0
  local draft_path pending_path verdict_path
  card_id="$(jq -r 'if .kind == "deepcheck" then (.card_id // empty) else empty end' "$FLIGHT" 2>/dev/null || true)"
  if [[ -z "$card_id" ]]; then
    log "flight-deepcheck 非法/缺 card_id → 清除（自愈）"
    rm -f "$FLIGHT"
    return 0
  fi
  rq_id="$(jq -r '.rq_id // ""' "$FLIGHT" 2>/dev/null || true)"
  lane="$(jq -r '.lane // "deep"' "$FLIGHT" 2>/dev/null || true)"
  card_status="$(card_status_of "$card_id")"
  case "$card_status" in
    done)
      state="$(rq_state "$rq_id")"
      case "$state" in
        awaiting-approval)
          # 队列 .draft 自愈（deep-check.sh:146-155 编排路同款缺口补齐）：worker 完成
          # preflight+redteam、写出约定位置成稿却漏 rq.sh set-draft 时，队列项 .draft 为空 →
          # auto-gate 放行后 execute.sh 取不到草稿 → failed → 重排队 → 无限循环
          # （rq-20260910-106667 实证）。判定口径照抄编排路：空 or 文件失联；
          # 补不来 → -deepcheck-draft-missing 事件 + 维持 awaiting-approval 人工路（不静默），
          # 绝不 auto-gate / 绝不 set approved / 绝不 refund（refund 归编排层 failed 分支）。
          draft_path="$(jq -r --arg id "$rq_id" '.items[] | select(.id == $id) | (.draft // "")' "$QUEUE" 2>/dev/null || true)"
          pending_path="$CONTRIB/pending/$rq_id.md"
          if [[ -z "$draft_path" || ! -f "$draft_path" ]] && [[ -s "$pending_path" ]]; then
            if "$RQ" set-draft "$rq_id" "$pending_path" >>"$LOG" 2>&1; then
              log "$rq_id 队列 .draft 缺失但 $pending_path 在 → 补注册（自愈）"
            else
              log "$rq_id 草稿补注册失败（set-draft rc≠0）→ 重读后按缺失判定"
            fi
            draft_path="$(jq -r --arg id "$rq_id" '.items[] | select(.id == $id) | (.draft // "")' "$QUEUE" 2>/dev/null || true)"
          fi
          if [[ -z "$draft_path" || ! -f "$draft_path" ]]; then
            verdict_path="$CONTRIB/runs/deep-check/$rq_id/verdict.json"
            if [[ -s "$verdict_path" ]]; then
              emit_event "deepcheck-draft-missing" \
                "深检链 ${rq_id} 卡已 done、verdict 已产出，但 contrib-data/pending/${rq_id}.md 缺失 → 草稿未登记，跳过自动执行链，维持人工路（人工复核）"
            else
              emit_event "deepcheck-draft-missing" \
                "深检链 ${rq_id} 卡已 done，但 contrib-data/pending/${rq_id}.md 缺失且 verdict 亦缺 → 草稿未登记，跳过自动执行链，维持人工路（人工复核）"
            fi
            rm -f "$FLIGHT"
            log "$rq_id 草稿缺失（约定位置无稿）→ 不放行 auto-gate，维持 awaiting-approval 人工路，登记已清"
            return 0
          fi
          # 链完成 → 编排层 auto-gate 桥接（审查 B2：主路保留 L2-auto，复刻 deep-check.sh:177-182；
          # verdict 缺失/低分/own-PR 由 auto-gate 内部硬条件升级人工——模型意见只是输入）
          gate_out="$(bash "$AUTO_GATE" "$rq_id" 2>>"$LOG")" || gate_rc=$?
          log "链完成（$rq_id awaiting-approval）→ auto-gate: rc=$gate_rc ${gate_out:0:160}"
          if (( gate_rc == 0 )); then
            "$RQ" set "$rq_id" approved --note "自动批准：${gate_out#AUTO|}" >>"$LOG" 2>&1 || true
            EXEC_CHANNEL=auto bash "$EXECUTE" "$rq_id" approved >>"$LOG" 2>&1 \
              || log "自动执行链异常（项保持 approved 待收集链兜底）"
          fi
          rm -f "$FLIGHT"
          log "preflight 卡 $card_id done → 链收尾完成，登记已清"
          return 0
          ;;
        deep-check)
          # 补查子卡终态（上游 children 返回 id 数组，子卡 status 需逐个二次 show——实现注①）
          if cstatuses="$(child_statuses "$card_id")"; then
            case "$cstatuses" in
              *blocked*)
                "$RQ" set "$rq_id" failed --note "redteam 子卡 blocked（链悬挂收口）" >>"$LOG" 2>&1 || true
                refund_once "$rq_id" "$lane"
                rm -f "$FLIGHT"
                emit_event "deepcheck-stale" "深检链悬挂收口：$rq_id redteam 子卡 blocked → 置 failed + refund"
                return 0
                ;;
              *)
                # 子卡在跑 / done 但 worker 漏 set（实现注③）/ 子卡未建 → 保留登记，stale 24h 兜底
                log "preflight done 且 rq=deep-check（子卡 status=${cstatuses:-未建}）→ 保留登记"
                return 10
                ;;
            esac
          else
            log "子卡终态查询失败 → 保留登记（下轮重查）"
            return 10
          fi
          ;;
        failed)
          refund_once "$rq_id" "$lane"
          rm -f "$FLIGHT"
          log "$rq_id 已 failed → 清登记（refund 幂等）"
          return 0
          ;;
        expired)
          # 09-09 生产首跑实锤：worker premise TTL 复验 NO-GO 置 expired（farm 生态正常损耗，
          # 候选半衰期小时级）——refund 自身 reserve + 清登记，仅日志不发微信告警（噪音控制）
          refund_once "$rq_id" "$lane"
          rm -f "$FLIGHT"
          log "$rq_id 已 expired（premise 死亡 NO-GO）→ 清登记 + refund（幂等）"
          return 0
          ;;
        "")
          rm -f "$FLIGHT"
          emit_event "deepcheck-orphan" "深检 preflight 卡 $card_id done 但队列项 ${rq_id:-空} 查无（人工复核）"
          log "${rq_id:-空} 查无 → 清登记 + orphan 告警"
          return 0
          ;;
        *)
          rm -f "$FLIGHT"
          emit_event "deepcheck-orphan" "深检链 $rq_id 卡 done 但状态异常 state=${state}（人工复核）"
          log "$rq_id 状态异常 state=${state} → 清登记 + orphan 告警"
          return 0
          ;;
      esac
      ;;
    blocked)
      outcome="$(card_outcome_of "$card_id")"
      case "$outcome" in
        gave_up|crashed|timed_out|spawn_failed)
          "$RQ" set "$rq_id" failed --note "preflight 卡 blocked（outcome=${outcome}，重试耗尽）" >>"$LOG" 2>&1 || true
          refund_once "$rq_id" "$lane"
          rm -f "$FLIGHT"
          emit_event "deepcheck-card-fallback" "深检卡路失败：preflight 卡 $card_id blocked（outcome=${outcome}，重试耗尽），$rq_id 置 failed，下轮 gate 重试"
          return 0
          ;;
        *)
          log "preflight 卡 $card_id blocked（outcome=${outcome:-未知}，非重试耗尽）→ 保留登记"
          return 10
          ;;
      esac
      ;;
    ready|running|triage|todo|scheduled|review)
      age=$(( $(date +%s) - $(jq -r '.created_epoch // 0' "$FLIGHT" 2>/dev/null || echo 0) ))
      if (( age > STALE_SECS )); then
        "$RQ" set "$rq_id" failed --note "deepcheck flight 陈旧 ${age}s（> ${STALE_SECS}s）" >>"$LOG" 2>&1 || true
        refund_once "$rq_id" "$lane"
        rm -f "$FLIGHT"
        emit_event "deepcheck-stale" "深检卡 $card_id 非终态超 ${STALE_SECS}s（age=${age}s）→ 清登记 + $rq_id 置 failed"
        return 0
      fi
      log "preflight 卡 $card_id 在飞（status=$card_status age=${age}s）→ 保留登记"
      return 10
      ;;
    *)
      # 查无此 id（archived/清理/异常）→ 视同失败终态收口，事件走 -deepcheck-orphan（终态查无族）
      "$RQ" set "$rq_id" failed --note "preflight 卡 $card_id 查无终态" >>"$LOG" 2>&1 || true
      refund_once "$rq_id" "$lane"
      rm -f "$FLIGHT"
      emit_event "deepcheck-orphan" "深检 preflight 卡 $card_id 查无终态（archived/清理？）→ $rq_id 置 failed 待人工复核"
      return 0
      ;;
  esac
}

write_body() { # <rq-id> <lane> — preflight 卡 body（stdout；契约见 T4 设计 §1/§5）
  local id="$1" lane="$2"
  printf '# contrib 深检 preflight 卡（rq: %s，lane: %s）\n\n' "$id" "$lane"
  printf '## 任务\n\n'
  printf -- '- rq-id: %s   lane: %s\n' "$id" "$lane"
  printf -- '- 队列项读取（premises/ammo/score）: %s\n' "$QUEUE"
  printf -- '- 工作模式与三轮审 rubric 权威: %s 模式四（deep-check）——执行 --phase preflight 阶段职责\n' "$SKILL_MD"
  printf '\n## 产出契约（绝对路径）\n\n'
  printf -- '- strategist 审视报告: %s/runs/deep-check/%s/preflight.md\n' "$CONTRIB" "$id"
  printf -- '- 吸收后草稿 v2: %s/pending/%s.md（头部注释记版次与依据）\n' "$CONTRIB" "$id"
  printf -- '- 状态推进: 阶段开始时项仍为 queued，完成本卡职责后执行 rq.sh set %s deep-check\n' "$id"
  printf '\n## lane 分叉（钉死）\n\n'
  if [[ "$lane" == "probe" ]]; then
    printf -- '- lane=probe: 免红队、不建子卡（probe 单轮免红队策略红线）。你自己写 verdict.json（契约见下）+ rq.sh set %s awaiting-approval 后收尾\n' "$id"
  else
    printf -- '- lane=deep: preflight 完成后由你自建 redteam 子卡（fresh-context 铁律：全新上下文，不得读 preflight.md 结论先入为主——只读 %s/pending/%s.md v2）。命令模板：\n' "$CONTRIB" "$id"
    printf -- '  hermes kanban create "深检 redteam %s" --parent <本卡 id> --assignee contrib --idempotency-key "deepcheck-redteam-%s-<attempt-epoch>" --max-retries 2 --json\n' "$id" "$id"
    printf -- '  （--parent 填本卡 id，即你任务上下文中的 task id；必须带 --assignee contrib，缺省会错轨到 default profile）\n'
    printf -- '  子卡 body 必含: %s 模式四 --phase redteam 段职责 + 下方 verdict.json 契约原文\n' "$SKILL_MD"
    printf -- '  子卡 redteam 完成后必须 rq.sh set %s awaiting-approval（编排层 harvest 据此判定链完成并进入 auto-gate 桥接；漏 set = 链悬挂到 stale 兜底）\n' "$id"
  fi
  printf '\n## verdict.json 契约（deep 车道 redteam 子卡 / probe 车道本卡 必须写出）\n\n'
  printf -- '- 路径: %s/runs/deep-check/%s/verdict.json\n' "$CONTRIB" "$id"
  printf -- '- 结构: {"decision": "auto | escalate", "confidence": "high | medium | low", "risk_level": "low | medium | high", "goods": {"status": "offered | forge-lane | none", "note": "三态判定依据一句（见 SKILL 模式四 Goods 判定）"}, "reasons": ["escalate 时必填：每条 = 一个具体的、你定不了的点"]}\n'
  printf -- '- goods.status 必填（09-09 commit 进仓优先闸）：offered=库存带 offer / forge-lane=缺口可修已立项 / none=纯 review；缺失或非法 = auto-gate fail-closed 升级人工\n'
  printf -- '- auto 门槛（宁升勿放）与判定细则以 %s 模式四第 5 点原文为准\n' "$SKILL_MD"
  printf -- '- 审批卡推送由编排层 auto-gate/补推 sweep 承担：worker 不调 hermes send、不重复推\n'
  printf '\n## 红线（必须遵守）\n\n'
  printf -- '- gh 只读：零 issue/PR 写、零评论、零 push\n'
  printf -- '- rq.sh 授权仅限 set/list/show 且只针对本项 %s；budget reserve/refund 为编排层专属，卡内绝对禁碰（rq.sh refund 每调必减，双调=预算超发）\n' "$id"
  printf -- '- 链悬挂纪律：无法完成时必须先 rq.sh set %s failed + notify.sh event pipeline-failure 再收尾（编排层下轮 failed 分支接管 refund）\n' "$id"
  printf -- '- -q 模式禁脚本形态：python -c / jq -e / 任何 * -e 一律不可用\n'
  printf '\n## 收尾要求\n\n'
  printf -- '- 完成调 kanban_complete 时必须同时传 summary 与 result\n'
}

cmd_harvest() {
  if [[ ! -s "$FLIGHT" ]]; then
    exit 0
  fi
  if ! jq -e 'type == "object"' "$FLIGHT" >/dev/null 2>&1; then
    # 损坏登记 fail-soft 不动，留 create 自愈
    exit 0
  fi
  if ! acquire_lock; then
    log "harvest: 建卡锁被占 → 本轮跳过"
    exit 0
  fi
  trap 'rmdir "$CARD_LOCK" 2>/dev/null' EXIT
  harvest_locked >/dev/null 2>&1 || true
  exit 0
}

cmd_create() {
  local arg_id="${1:-}" arg_lane="${2:-}"
  if ! acquire_lock; then
    log "create: 建卡锁被占（另一入口在建卡）→ 跳过"
    exit 10
  fi
  trap 'rmdir "$CARD_LOCK" 2>/dev/null' EXIT

  # 1. flight 检查（锁内；done 终态就地收割——设计 §1 step0）
  local harvest_rc=0
  if [[ -s "$FLIGHT" ]] && jq -e 'type == "object"' "$FLIGHT" >/dev/null 2>&1; then
    harvest_locked
    harvest_rc=$?
  elif [[ -e "$FLIGHT" ]]; then
    log "flight-deepcheck 损坏（非 JSON 对象）→ 清除自愈"
    rm -f "$FLIGHT"
  fi
  if (( harvest_rc == 10 )); then
    log "深检在飞 → create 跳过（全局单深检语义）"
    exit 10
  fi

  # 2. 目标解析：参数优先，否则读 gate 产物（deep-check.sh:57-67 同语义）
  local id="$arg_id" lane="$arg_lane" qlane state
  if [[ -z "$id" ]]; then
    if [[ ! -s "$TARGET_FILE" ]]; then
      log "无 gate 产物（${TARGET_FILE}）→ 跳过"
      exit 10
    fi
    read -r id lane < "$TARGET_FILE"
  fi
  if [[ -z "$id" ]]; then
    log "目标解析失败（空 rq-id）"
    exit 1
  fi
  # lane 以队列字段为权威（deep-check.sh:98 同语义），gate 产物 lane 兜底
  qlane="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .lane' "$QUEUE" 2>/dev/null || true)"
  if [[ -n "$qlane" && "$qlane" != "null" ]]; then
    lane="$qlane"
  fi
  [[ -n "$lane" ]] || lane="deep"

  # 3. 状态预检：必须仍为 queued（deep-check.sh:104-109 同语义；状态推进交 worker 卡内）
  state="$(rq_state "$id")"
  if [[ "$state" != "queued" ]]; then
    log "$id 当前 state=${state:-查无}（非 queued）→ 跳过"
    exit 10
  fi

  # 4. budget reserve（编排层专属；失败 → 放弃，调用方走 fallback）
  local res
  res="$("$RQ" budget reserve "$id" --lane "$lane" 2>>"$LOG")" || true
  case "$res" in
    OK*) : ;;
    *)
      log "预算 reserve 失败：${res:-空输出}，放弃 $id"
      exit 1
      ;;
  esac

  # 5. 建 preflight 卡（attempt 级幂等键）
  local body_ts body_file card_json card_id rc2=0
  body_ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$CONTRIB/card-bodies" 2>/dev/null || true
  body_file="$CONTRIB/card-bodies/deepcheck-${id}-${body_ts}.body.md"
  write_body "$id" "$lane" >"$body_file"
  card_json="$(bash "$KBC" create --kind deepcheck \
    --title "深检 preflight ${id} [${lane}]" \
    --body-file "$body_file" \
    --idempotency-key "deepcheck-${id}-$(date +%s)" 2>>"$LOG")" || rc2=$?
  card_id="$(printf '%s' "$card_json" | jq -r '.id // empty' 2>/dev/null || true)"
  if (( rc2 != 0 )) || [[ -z "$card_id" ]]; then
    log "深检建卡失败（rc=${rc2}）→ refund + fallback 告警"
    refund_once "$id" "$lane"
    emit_event "deepcheck-card-fallback" "深检建卡失败（rq=${id}，rc=${rc2}），已按旋钮 refund 并回落编排层 fallback"
    exit 1
  fi

  # 6. flight 登记（写盘失败并入 create 失败分支——设计注②收窄孤儿卡窗口）
  local flight_rc=0
  jq -n --arg kind deepcheck --arg cid "$card_id" --arg rq "$id" --arg lane "$lane" \
    --arg bf "" --argjson e "$(date +%s)" \
    '{kind: $kind, card_id: $cid, rq_id: $rq, lane: $lane, batch_file: $bf, created_epoch: $e}' \
    >"$FLIGHT.tmp" 2>>"$LOG" || flight_rc=$?
  if (( flight_rc != 0 )); then
    rm -f "$FLIGHT.tmp"
    log "flight 登记写盘失败 → refund + fallback 告警"
    refund_once "$id" "$lane"
    emit_event "deepcheck-card-fallback" "深检 flight 登记失败（rq=${id}），已按旋钮 refund"
    exit 1
  fi
  mv "$FLIGHT.tmp" "$FLIGHT"

  # 7. TARGET_FILE 消费（审查 I5：与 fallback deep-check.sh:66 对称，防跨轮幽灵建卡）
  rm -f "$TARGET_FILE"
  log "深检 preflight 卡已建 ${card_id}（rq=${id} lane=${lane}）"
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
  *)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
