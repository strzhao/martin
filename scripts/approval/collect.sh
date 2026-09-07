#!/bin/bash
# collect.sh — L2-A 短码审批收集器（launchd com.stringzhao.approval-collect，StartInterval 90s）
#
# 用法:
#   collect.sh            # 单轮收集（launchd 周期触发；也可手动跑一轮）
#
# 每轮做两件事（设计 T5 / 契约 C7）:
#   1) 消费待决审批: jq 扫 state=="awaiting-approval" ∧ tunnel.code != null 的项 →
#      `tunnel drops decision <slug> --expect-code <code>`（C1 JSON+exit code）:
#        rc=0 matched  → 先 `rq.sh set <id> approved`（状态机单次迁移=防重复消费 SSOT）
#                       → 再 `execute.sh <id> <verdict> <comment>`
#        rc=3          → 无提交（no_submission 是待决态非异常），空转
#        rc=4          → 短码不匹配 → `notify.sh event approval-code-mismatch`（key 幂等，日≤3 沿用）
#        rc=其他        → invalid_slug/api_error → pipeline-failure 事件，本轮不重试
#      tunnel.code == null 的旧数据项跳过（C5 向后兼容，不调判定命令）
#   2) 搁置/过期页面回收: state ∈ {expired, shelved} ∧ removed_at == null ∧ 部署超 approval_ttl_hours
#      → tunnel rm + rq tunnel-removed（卡文案承诺超时搁置但公开页面无限期存活的缺口；7 天强删 sweep 仍兜底）
#
# 防重叠: mkdir 锁（90s 间隔 + 上一轮未完则本轮空转退出）
# 环境变量 seam（沙箱测试用，生产缺省=真值）:
#   CONTRIB_DATA_DIR / MARTIN_DIR / TUNNEL_BIN / GH_BIN / APPROVAL_DRY_RUN / APPROVED_LOG
#   APPROVAL_DRY_RUN=true → 本脚本一切写路径（rq/事件/tunnel rm/execute）只打印，判定命令照常（只读）
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
QUEUE="$CONTRIB/ready-queue.json"
CONFIG="$CONTRIB/config.json"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
EXECUTE="$MARTIN/scripts/approval/execute.sh"
# tunnel CLI 装在 nvm node bin（launchd PATH 极简找不到——09-06 装载后实证 rc=127）：
# env seam 优先 → PATH 查找 → nvm 布局探测（同 run-watch.sh 的 claude 探测先例）
TUNNEL_BIN="${TUNNEL_BIN:-}"
if [[ -z "$TUNNEL_BIN" ]]; then
  TUNNEL_BIN="$(command -v tunnel 2>/dev/null || true)"
fi
if [[ -z "$TUNNEL_BIN" ]]; then
  _tw_cand="$(ls -t "$HOME"/.nvm/versions/node/*/bin/tunnel 2>/dev/null | head -1 || true)"
  if [[ -n "$_tw_cand" ]]; then
    TUNNEL_BIN="$_tw_cand"
    # tunnel 是 node 包装脚本（exec node …）——node 本体也要可达，把 nvm bin 目录一并进 PATH
    PATH="$(dirname "$_tw_cand"):$PATH"
    export PATH
  fi
fi
TUNNEL_BIN="${TUNNEL_BIN:-tunnel}"
export TUNNEL_BIN   # execute.sh 子进程继承同一解析结果（它自己的默认 tunnel 在 launchd PATH 下不可达）
GH_BIN="${GH_BIN:-gh}"
APPROVED_LOG="${APPROVED_LOG:-$MARTIN/approved.log}"
DRY_RUN="${APPROVAL_DRY_RUN:-false}"
LOCKDIR="${APPROVAL_LOCKDIR:-/tmp/contrib-approval-collect.lock}"
LOG_DIR="$CONTRIB/logs"
LOG="$LOG_DIR/approval-collect.log"

log() { echo "[$(date '+%F %T')] approval-collect: $*" >> "$LOG"; }

# 不用 jq `//` 运算符：它把 JSON false 当 falsy（09-05 事故）；只把 null/缺失当缺省
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$v" && "$v" != "null" ]]; then
    echo "$v"
    return 0
  fi
  echo "$2"
}

record_event() { # <class> <key> <summary> → 事件入账（dry-run 只打印）
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] notify.sh event $1 --key $2 --summary $3"
    return 0
  fi
  "$NOTIFY" event "$1" --key "$2" --summary "$3" >>"$LOG" 2>&1 || true
}

collect_one() { # <id> → 0（任何 rc 都不中断本轮，逐项隔离）
  local id="$1"
  local slug code
  slug="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$QUEUE" 2>/dev/null)"
  code="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.code // ""' "$QUEUE" 2>/dev/null)"
  [[ "$slug" == "null" ]] && slug=""
  [[ "$code" == "null" ]] && code=""
  if [[ -z "$slug" || -z "$code" ]]; then
    log "${id}: slug/code 缺失（C5 旧数据），跳过不调判定命令"
    return 0
  fi

  local out="" rc=0
  # </dev/null：不把本层 while-read 的 herestring stdin 泄漏给子进程（09-06 红队实证：
  # gh stub 把继承来的剩余 id 队列 cat 进了调用账——生产语义上也杜绝任何子进程等 stdin 挂起）
  out="$(</dev/null "$TUNNEL_BIN" drops decision "$slug" --expect-code "$code" 2>>"$LOG")" || rc=$?

  if (( rc == 3 )); then
    log "${id}: 无提交（no_submission 待决态），继续等待"
    return 0
  fi
  if (( rc == 4 )); then
    log "${id}: 短码不匹配（code_mismatch），不消费"
    record_event "approval-code-mismatch" "${id}-$(date +%F)" \
      "${id} 审批页提交短码与卡内短码不一致（未消费，等正确提交）"
    return 0
  fi
  if (( rc != 0 )); then
    log "${id}: decision rc=${rc}（invalid_slug/api_error），本轮不重试"
    record_event "pipeline-failure" "collect-fail-${id}-$(date +%F)" \
      "collect ${id}: drops decision rc=${rc}（slug=${slug}）"
    return 0
  fi

  local matched verdict comment
  matched="$(jq -r '.matched // false' <<<"$out" 2>/dev/null)"
  verdict="$(jq -r '.verdict // ""' <<<"$out" 2>/dev/null)"
  comment="$(jq -r '.comment // ""' <<<"$out" 2>/dev/null)"
  [[ "$matched" == "true" && "$verdict" =~ ^(approved|rejected|revise)$ ]] || {
    log "${id}: decision rc=0 但输出异常（matched=${matched} verdict=${verdict}），本轮不消费"
    record_event "pipeline-failure" "collect-fail-${id}-$(date +%F)" \
      "collect ${id}: decision 输出违反 C1（matched/verdict）"
    return 0
  }

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] rq.sh set ${id} approved --note L2-A tunnel 短码批准 verdict=${verdict}"
    echo "[dry-run] execute.sh ${id} ${verdict}（comment ${#comment} 字符）"
    return 0
  fi

  # 消费标记先行：状态机单次迁移（awaiting-approval→approved 只可能发生一次）= 防重复消费 SSOT
  if ! "$RQ" set "$id" approved --note "L2-A tunnel 短码批准 verdict=${verdict}" >>"$LOG" 2>&1; then
    log "${id}: rq set approved 失败（可能已被并发路消费），本轮放弃"
    record_event "pipeline-failure" "collect-fail-${id}-$(date +%F)" \
      "collect ${id}: rq set approved 失败（并发消费？）"
    return 0
  fi
  log "${id}: matched verdict=${verdict}，已消费（approved），进入执行链"
  if ! "$EXECUTE" "$id" "$verdict" "$comment" >>"$LOG" 2>&1 </dev/null; then
    log "${id}: 执行链失败（见 approval-execute.log）"
    record_event "pipeline-failure" "execute-fail-${id}-$(date +%F)" \
      "execute ${id}（verdict=${verdict}）失败，已按 failed/事件落账"
  fi
  return 0
}

reclaim_expired() { # <ttl_hours> <now_epoch> → 搁置/过期页面回收
  local ttl="$1" ep="$2"
  local ids id slug
  ids="$(jq -r --argjson ep "$ep" --argjson ttl "$ttl" '
    .items[] | select((.state == "expired" or .state == "shelved")
      and .tunnel.slug != null and .tunnel.removed_at == null
      and (.tunnel.deployed_epoch // 0) > 0
      and ($ep - .tunnel.deployed_epoch) > $ttl * 3600) | .id' "$QUEUE" 2>/dev/null)"
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    slug="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$QUEUE" 2>/dev/null)"
    [[ "$slug" == "null" ]] && slug=""
    [[ -n "$slug" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] tunnel rm ${slug}（state 非 awaiting 且部署超 ${ttl}h 未删）"
      echo "[dry-run] rq.sh tunnel-removed ${id}"
      continue
    fi
    if "$TUNNEL_BIN" rm "$slug" >>"$LOG" 2>&1; then
      "$RQ" tunnel-removed "$id" >>"$LOG" 2>&1 || true
      log "回收 ${id}: tunnel rm ${slug}（部署超 ${ttl}h 未删，state 已非待决）"
    else
      log "回收 ${id}: tunnel rm ${slug} 失败（下轮重试；7 天强删 sweep 兜底）"
    fi
  done <<<"$ids"
  return 0
}

# ---------------- 入口 ----------------
# 队列缺失 = 流水线未初始化：空转退出零副作用（场景 7 语义）
[[ -f "$QUEUE" ]] || exit 0
mkdir -p "$LOG_DIR"

# 防重叠锁：90s 间隔短任务，上一轮未结束则本轮直接放弃
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  log "锁占用（上一轮未结束），本轮空转退出"
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

ttl_hours="$(cfg '.approval_ttl_hours' '48')"
now_ep="$(date +%s)"

# 1) 待决审批消费（code == null 的旧数据项天然不在候选集 = C5 兼容）
ids="$(jq -r '.items[] | select(.state == "awaiting-approval" and .tunnel.slug != null and .tunnel.code != null) | .id' "$QUEUE" 2>/dev/null)"
if [[ -n "$ids" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    collect_one "$id"
  done <<<"$ids"
fi

# 2) 搁置/过期页面回收
reclaim_expired "$ttl_hours" "$now_ep"
exit 0
