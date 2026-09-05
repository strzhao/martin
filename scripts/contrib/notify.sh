#!/bin/bash
# notify.sh — contrib-watch 事件与微信推送层
#
# 设计要点：
#   - events.jsonl 是唯一告警账本（同 key 幂等，推送状态在文件里，失败自然重试）
#   - **外发消息规范（09-05 用户拍板）**：禁止 raw dump 直推。flush 分两级——
#     ①机械事件（premise-dead/own-pr-activity/budget）→ 脚本渲染规范化模板卡
#       （同审批卡哲学：结构化=高效消费，不经 LLM）
#     ②叙事事件（pipeline-failure/未知类）→ AI 摘要层（claude -p 生成三段式人话）；
#       摘要失败=搁置重试，**永不降级回 raw dump**；3 败后 osascript 本地机械提示兜底
#   - 渠道隔离：event 支持 --channel（默认 contrib）；非 contrib 渠道事件只入账，
#     不占 contrib 告警限额、不进 contrib flush（归各自域的简报/AI 会话消费）
#   - flush 每小时由 run-watch 尾部调用：聚合未推送告警为一条微信；防双发三重
#     （min_interval + 当日计数 + /tmp 锁）
#   - 审批推送（🟡 卡片）与告警分开计数；回执独立计数不占限额（审批卡=规范化模板，豁免 AI 整理）
#   - hermes send 失败链：重试 1 次 → 事件保留 → 累计 3 败 osascript 本地通知兜底
#   - notify_dry_run=true 时只打印完整消息体与目标，不触 hermes/tunnel（AI 摘要照常生成）
#   - 测试沙箱：CONTRIB_DATA_DIR=<dir> 可把账本/配置整体指向临时目录
#
# 用法:
#   notify.sh event <class> --key K --summary S [--channel C]
#   notify.sh flush
#   notify.sh approve <id> | approve --all
#   notify.sh receipt <id> --summary S
#   notify.sh fallback <text>
set -uo pipefail

MARTIN="$HOME/workspace/martin"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
CONFIG="$CONTRIB/config.json"
QUEUE="$CONTRIB/ready-queue.json"
EVENTS="$CONTRIB/events.jsonl"
STATE="$CONTRIB/notify-state.json"
RQ="$MARTIN/scripts/contrib/rq.sh"
LOCK="/tmp/contrib-notify.lock"

# 不用 jq 的 // 运算符：它把 JSON false 当 falsy（notify_dry_run=false 曾被读成
# 默认 true，推送全静默 dry-run）——只把 null/缺失当缺省，false 是合法配置值
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null)"
  [[ -n "$v" && "$v" != "null" ]] && { echo "$v"; return; }
  echo "$2"
}
ts() { date "+%Y-%m-%dT%H:%M:%S%z"; }
today() { date +%F; }
now_epoch() { date +%s; }

TARGET="$(cfg '.notify_target' '""')"
# 环境变量 override（仅测试/演练用）：NOTIFY_DRY_RUN=false notify.sh approve <id>
DRY_RUN="${NOTIFY_DRY_RUN:-$(cfg '.notify_dry_run' 'true')}"

ensure_state() {
  [[ -f "$STATE" ]] || echo '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}' > "$STATE"
  touch "$EVENTS"
}

log() { echo "[$(date '+%F %T')] notify: $*" >> "$CONTRIB/logs/notify.log"; }

acquire_lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i+1)); (( i > 30 )) && { log "锁等待超时，放弃本轮"; exit 0; }
    sleep 1
  done
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

gateway_up() { pgrep -f "hermes_cli.main gateway" >/dev/null 2>&1; }

# _send <msg_file> <subject> → 0=成功 1=发送失败 3=网关不可达
_send() {
  local msg_file="$1" subject="$2"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "── [dry-run] 目标: $TARGET · 主题: $subject ──────────"
    cat "$msg_file"
    echo "──────────────────────────────────────────────"
    return 0
  fi
  if ! gateway_up; then
    log "网关不可达（pgrep hermes_cli.main gateway 落空）"
    return 3
  fi
  local rc=0
  hermes send --to "$TARGET" --file "$msg_file" --subject "$subject" --json >/tmp/contrib-send-last.json 2>>"$CONTRIB/logs/notify.log" || rc=$?
  if (( rc != 0 )); then
    log "hermes send 失败 rc=${rc}（$(head -c 200 /tmp/contrib-send-last.json 2>/dev/null)）"
    return 1
  fi
  # 双保险：exit 0 也要 success:true 才算投递成功
  if [[ "$(jq -r '.success // false' /tmp/contrib-send-last.json 2>/dev/null)" != "true" ]]; then
    log "hermes send exit=0 但 success≠true（$(head -c 200 /tmp/contrib-send-last.json 2>/dev/null)）"
    return 1
  fi
  return 0
}

_osascript() {
  osascript -e "display notification \"$1\" with title \"contrib-watch\" sound name \"Ping\"" 2>/dev/null || true
}

state_bump() { # state_bump <表名> <键> → 计数+1 并写回
  jq --arg t "$1" --arg k "$2" '.[$t][$k] = ((.[$t][$k] // 0) + 1)' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}
state_get() { jq -r --arg t "$1" --arg k "$2" '.[$t][$k] // 0' "$STATE"; }
state_set() { # state_set <表名> <键> <值> → 置值并写回（一次性标记用）
  jq --arg t "$1" --arg k "$2" --arg v "$3" '.[$t][$k] = $v' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# ---------------- 事件分级（外发消息规范的机械/叙事两级） ----------------
# 机械事件 = 高频、语义固定，模板卡即可高效消费（不经 LLM）；其余一律走 AI 摘要
is_mechanical() {
  case "$1" in
    probe-premise-dead|own-pr-activity|deep-budget-exhausted) return 0 ;;
    *) return 1 ;;
  esac
}
class_title() {
  case "$1" in
    probe-premise-dead)     echo "候选折损（占坑出局）" ;;
    own-pr-activity)        echo "自有 PR 动静" ;;
    deep-budget-exhausted)  echo "深检配额用尽" ;;
    *)                      echo "$1" ;;
  esac
}
class_action() {
  case "$1" in
    probe-premise-dead)     echo "farm 占坑属正常损耗，无需动作；radar 每日自动补新候选" ;;
    own-pr-activity)        echo "建议动作见各条；涉及 push/评论的动作需你批准（L2）" ;;
    deep-budget-exhausted)  echo "候选已自动排队，明日 09:37 自动重试；无需动作" ;;
    *)                      echo "" ;;
  esac
}

# _render_mechanical_card <batch_file> → stdout 模板卡（同类归并 + 固定动作行）
# 直接读 batch_file（已按渠道/未推过滤）——勿再回读 EVENTS 重过滤（jq index()
# 上下文陷阱与双份过滤都是故障面）
_render_mechanical_card() {
  local batch_file="$1" cls n=0
  echo "🟠【contrib 速报】$(date +%m-%d)"
  echo ""
  for cls in probe-premise-dead own-pr-activity deep-budget-exhausted; do
    local batch
    batch="$(jq -r --arg cls "$cls" \
      'select(.class == $cls) | .summary | sub("^radar [0-9-]+ premise 复验："; "")' \
      "$batch_file" 2>/dev/null)"
    [[ -z "$batch" ]] && continue
    n=$((n+1))
    local cnt; cnt="$(wc -l <<<"$batch" | tr -d ' ')"
    echo "▪ $(class_title "$cls")（${cnt} 条）"
    sed 's/^/· /' <<<"$batch"
    echo "↳ $(class_action "$cls")"
    echo ""
  done
  echo "（明细: contrib-data/events.jsonl）"
}

# _ai_digest <batch_json_file> <out_file> → 0=成功生成摘要
# AI 摘要层：把叙事类事件整理成三段式人话。失败返回非 0，事件保留待下轮——
# 绝不把原始 JSON 兜底出去（外发消息规范红线）。prompt 走 stdin 直给 claude -p，
# 不依赖项目级 skill（run-deepcheck 缺 cd 教训：路径/skill 依赖都是故障面）。
_ai_digest() {
  local in_file="$1" out_file="$2"
  if ! command -v claude >/dev/null 2>&1; then
    log "AI 摘要失败：claude 不在 PATH"
    return 1
  fi
  local prompt="/tmp/contrib-digest-prompt-$$.txt"
  {
    cat <<'EOF'
你是 contrib-watch 流水线的告警播报员，读者是 Hermes Agent 的维护者本人（非程序员场景，微信阅读）。把下面的原始告警事件整理成一条微信消息：

1. 三段式：发生了什么 → 为什么与他有关/多重要 → 建议他做什么（多数场景是"无需动作"，就明说）
2. 中文人类可读，机制黑话翻译成人话；rq-id / PR# / issue# 只作引用锚点，不当正文
3. ≤300 字；同类多条事件归并成一行汇总；只使用事件里已有的事实，不编造、不臆测原因，不确定写"待查"
4. 首行固定格式：🟠【contrib 告警】MM-DD（用今天日期）
5. 只输出消息正文本身，不要任何解释、前言或代码块包裹

黑话对照（用于翻译，不得照抄）：
- probe-premise-dead：ready-queue 候选机会的 issue 空间被其他贡献者占坑，候选作废（上游 AI farm 生态的正常损耗）
- own-pr-activity：我们自己的上游 PR 有新动静（维护者评论/mergeable 翻转/停滞超期）
- pipeline-failure：contrib-watch 流水线自身某环节失败（scan/深检/推送等）
- deep-budget-exhausted：当日深检配额用尽，候选自动排队明日重试
- rq-xxxxx：ready-queue 审批候选项编号；expired=已作废；awaiting-approval=等你审批

EOF
    echo "事件 JSON："
    cat "$in_file"
  } > "$prompt"
  # alarm 240s 防挂死；cwd=MARTIN（claude 需项目内环境）；prompt 走 stdin
  ( cd "$MARTIN" && perl -e 'alarm 240; exec @ARGV' claude -p < "$prompt" > "$out_file.raw" 2> "$out_file.err" )
  local rc=$?
  rm -f "$prompt"
  (( rc != 0 )) && { log "AI 摘要失败 rc=${rc}（$(tail -c 200 "$out_file.err" 2>/dev/null)）"; rm -f "$out_file.raw" "$out_file.err"; return 1; }
  # 校验：非空、长度合理、无命令回显病征
  local size; size="$(wc -c < "$out_file.raw" | tr -d ' ')"
  if (( size == 0 || size > 4000 )) || grep -q "Unknown command" "$out_file.raw" 2>/dev/null; then
    log "AI 摘要输出不合格（size=${size}），按失败处理"
    rm -f "$out_file.raw" "$out_file.err"
    return 1
  fi
  # 首行格式兜底：AI 忘了加报头则补上
  if ! head -1 "$out_file.raw" | grep -q "【contrib"; then
    { echo "🟠【contrib 告警】$(date +%m-%d)"; echo ""; cat "$out_file.raw"; } > "$out_file"
  else
    mv "$out_file.raw" "$out_file"
  fi
  rm -f "$out_file.err"
  return 0
}

# ---------------- event ----------------
cmd_event() {
  local cls="${1:-}"; shift || true
  local key="" summary="" channel="contrib"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="$2"; shift 2 ;;
      --summary) summary="$2"; shift 2 ;;
      --channel) channel="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$cls" && -n "$key" ]] || { echo "用法: event <class> --key K --summary S [--channel C]" >&2; exit 2; }
  ensure_state
  # 同 key 幂等
  if grep -qF "\"key\":\"$key\"" "$EVENTS" 2>/dev/null; then
    log "event $key 已在账（幂等跳过）"
    return 0
  fi
  jq -cn --arg ts "$(ts)" --arg cls "$cls" --arg key "$key" --arg summary "$summary" --arg ch "$channel" \
    '{ts: $ts, class: $cls, key: $key, channel: $ch, summary: $summary, pushed: false, attempts: 0, pushed_at: null}' \
    >> "$EVENTS"
  log "event + $cls $key (channel=$channel)"
}

# ---------------- flush（告警聚合推送，两级渲染） ----------------
cmd_flush() {
  ensure_state
  acquire_lock
  local min_interval; min_interval="$(cfg '.notify_min_interval_min' '20')"
  local max_alerts; max_alerts="$(cfg '.max_alert_pushes_per_day' '3')"
  local ep; ep="$(now_epoch)"
  local last; last="$(jq -r '.last_flush_epoch // 0' "$STATE")"

  if (( ep - last < min_interval * 60 )); then
    log "距上次 flush 不足 ${min_interval}min（防 08 窗口双发），跳过"
    return 0
  fi

  # 本轮批次 = contrib 渠道的未推事件（非 contrib 渠道只入账，归各自域消费）
  local batch_file="/tmp/contrib-batch-$$.json" keys_file="/tmp/contrib-keys-$$.txt"
  local body="/tmp/contrib-alerts-$$.txt"
  jq -c 'select(.pushed == false and (.channel // "contrib") == "contrib")' "$EVENTS" > "$batch_file" 2>/dev/null
  local unpushed; unpushed="$(wc -l < "$batch_file" | tr -d ' ')"
  if (( unpushed == 0 )); then rm -f "$batch_file" "$keys_file" "$body"; return 0; fi
  # keys 存 JSON 数组（裸字符串会被 jq 当非法 JSON——空卡事故教训）
  jq -s '[.[].key]' "$batch_file" > "$keys_file"

  # 当日告警限额
  local used; used="$(state_get alerts "$(today)")"
  if (( used >= max_alerts )); then
    _osascript "contrib 告警 ${unpushed} 条今日未推（限额 ${max_alerts} 已满），明日 09:17 对账补推"
    log "告警限额已满（${used}/${max_alerts}），${unpushed} 条留待补推"
    rm -f "$batch_file" "$keys_file" "$body"
    return 0
  fi

  # 两级渲染：混有任何叙事事件 → 整批走 AI 摘要；纯机械 → 模板卡
  # （分类逻辑必须在 bash/jq 侧完成——jq 里调不到 bash 函数）
  local narrative
  narrative="$(jq -s '[.[] | select((.channel // "contrib") == "contrib")
    | select((.class == "probe-premise-dead" or .class == "own-pr-activity" or .class == "deep-budget-exhausted") | not)] | length' \
    "$batch_file" 2>/dev/null)"
  narrative="${narrative:-0}"

  local rc=0
  if (( narrative > 0 )); then
    if [[ "$(cfg '.notify_digest' 'true')" == "true" ]]; then
      _ai_digest "$batch_file" "$body" || rc=1
      (( rc == 0 )) && log "叙事事件 ${narrative}/${unpushed} 条 → AI 摘要层"
    else
      log "notify_digest=false，叙事事件 ${narrative} 条挂账待 AI 会话转述"
      rc=1
    fi
  else
    _render_mechanical_card "$batch_file" > "$body"
    log "纯机械事件 ${unpushed} 条 → 模板卡（不经 LLM）"
  fi

  if (( rc == 0 )); then
    # 空卡守卫：剔除报头/脚注/空行后必须还剩实质内容——模板卡与 AI 摘要两种排版
    # 都要能通过；绝不发空壳卡、更不允许空卡把事件标记成已推（09-05 沙箱实测抓到此路径）
    # 注意用 grep -e 多模式：BSD grep 的 BRE 里 `^$\|..` 的 $ 中缀是字面量，交替会失效
    if (( $(grep -v -e '^🟠' -e '^（明细' -e '^$' "$body" 2>/dev/null | wc -l | tr -d ' ') == 0 )); then
      log "渲染产物无实质内容（空卡守卫触发），按失败挂账"
      rc=1
    fi
  fi
  if (( rc == 0 )); then
    _send "$body" "contrib-watch 告警" || rc=$?
  fi

  if (( rc == 0 )); then
    # 只标记本轮批次（contrib 渠道 + 批次内 key）；keys_file 是 JSON 数组
    python3 - "$EVENTS" "$keys_file" <<'PYEOF'
import json, sys
p, keys_f = sys.argv[1], sys.argv[2]
keys = set(json.load(open(keys_f)))
out = []
for l in open(p):
    l = l.rstrip("\n")
    if not l.strip():
        continue
    try:
        o = json.loads(l)
        if o.get("pushed") is False and o.get("key") in keys:
            import datetime
            o["pushed"] = True
            o["pushed_at"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        out.append(json.dumps(o, ensure_ascii=False))
    except Exception:
        out.append(l)
open(p, "w").write("\n".join(out) + "\n")
PYEOF
    state_bump alerts "$(today)"
    jq --argjson ep "$ep" '.last_flush_epoch = $ep' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    log "告警已推送（${unpushed} 条事件，rendering=$([[ $narrative -gt 0 ]] && echo ai-digest || echo template)）"
  else
    # 失败：批次内 attempts+1（事件保留，下轮重试；永不 raw dump 兜底）
    python3 - "$EVENTS" "$keys_file" <<'PYEOF' || true
import json, sys
p, keys_f = sys.argv[1], sys.argv[2]
keys = set(json.load(open(keys_f)))
out = []
for l in open(p):
    l = l.rstrip("\n")
    if not l.strip():
        continue
    try:
        o = json.loads(l)
        if o.get("pushed") is False and o.get("key") in keys:
            o["attempts"] = o.get("attempts", 0) + 1
        out.append(json.dumps(o, ensure_ascii=False))
    except Exception:
        out.append(l)
open(p, "w").write("\n".join(out) + "\n")
PYEOF
    # 连续 3 败 → osascript 本地机械提示（每至多一次/日，非 raw dump）
    local maxed
    maxed=$(jq -s '[.[] | select(.pushed == false and (.channel // "contrib") == "contrib" and (.attempts // 0) >= 3)] | length' "$EVENTS" 2>/dev/null || echo 0)
    if (( maxed > 0 )) && [[ "$(state_get fallback_notice "$(today)")" != "1" ]]; then
      _osascript "contrib ${maxed} 条告警多次推送未成（AI 摘要/通道失败），已挂账下轮重试——明细 contrib-data/events.jsonl"
      state_set fallback_notice "$(today)" 1
    fi
    log "告警推送失败 rc=${rc}（${unpushed} 条事件保留，下轮重试）"
  fi
  rm -f "$batch_file" "$keys_file" "$body"
}

# ---------------- approve（审批推送 🟡） ----------------
_build_approval_card() { # <id> → stdout 卡片文本
  local id="$1"
  jq -r --arg id "$id" '.items[] | select(.id == $id) |
    "🟡【L2 审批 #\(.id)】\(.disposition) 评论\n类型: \(.disposition)（lane=\(.lane)）\n目标: NousResearch/hermes-agent#\(.issue)\n概要: \(.title[0:80])\n质量: \(.score)/15（prio \(.priority)）；strategist+红队双审已过\n审阅: \(.tunnel.url // "见全文")\n全文: ~/workspace/martin/contrib-data/pending/\(.id).md\n回复「批 #\(.id)」/「改 #\(.id): 意见」/「否 #\(.id)」；48h 无回复自动搁置"' "$QUEUE"
}

cmd_approve() {
  ensure_state
  acquire_lock
  local target_id="${1:-}"
  local max_ap; max_ap="$(cfg '.max_approval_pushes_per_day' '3')"
  local dry_pushed=0

  local ids
  if [[ "$target_id" == "--all" ]]; then
    ids=$(jq -r '.items[] | select(.state == "awaiting-approval" and .draft != null) | .id' "$QUEUE")
  else
    ids="$target_id"
  fi
  [[ -n "$ids" ]] || { log "approve: 无可推项"; return 0; }

  for id in $ids; do
    local draft; draft="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .draft // ""' "$QUEUE")"
    if [[ -z "$draft" || ! -f "$draft" ]]; then
      log "approve $id: 草稿不存在（${draft}），跳过"
      continue
    fi
    # 已成功推过则不重复
    local ok; ok="$(jq -r --arg id "$id" --arg d "$(today)" '.approvals[$d].ok[$id] // false' "$STATE" 2>/dev/null)"
    [[ "$ok" == "true" ]] && continue

    # tunnel 部署（dry-run 跳过）
    if [[ "$DRY_RUN" != "true" ]] && command -v tunnel >/dev/null 2>&1; then
      local cur_url; cur_url="$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .tunnel.url // ""' "$QUEUE")"
      if [[ -z "$cur_url" ]]; then
        local deploy_out url
        deploy_out=$(tunnel deploy "$draft" -n "$id" 2>/dev/null || true)
        url=$(grep -oE 'https?://[^ ]+' <<<"$deploy_out" | tail -1)
        if [[ -n "$url" ]]; then
          "$RQ" tunnel-deploy "$id" "$url" "$id" >/dev/null
          log "approve $id: tunnel 已部署 $url"
        else
          log "approve $id: tunnel 部署失败（卡片将以全文路径代替）"
        fi
      fi
    fi

    local card="/tmp/contrib-approval-$id.txt"
    _build_approval_card "$id" > "$card"

    # 审批推送日限额（dry-run 不计）；approvals[date] = {count, ok:{}, fail:{}}
    local used; used="$(jq -r --arg d "$(today)" '.approvals[$d].count // 0' "$STATE")"
    if [[ "$DRY_RUN" != "true" ]] && (( used >= max_ap )); then
      _osascript "contrib 审批 $id 待推（今日审批推送限额 ${max_ap} 已满，明晨补推）"
      log "approve $id: 审批日限额已满（${used}/${max_ap}），留待补推"
      rm -f "$card"; continue
    fi

    local rc=0
    _send "$card" "contrib L2 审批 $id" || rc=$?
    if (( rc == 3 )); then
      _osascript "contrib 审批 $id 就绪（hermes 网关不可达，未推送）——明细 contrib-data/pending/$id.md"
      log "approve $id: 网关不可达，osascript 兜底"
    elif (( rc == 0 )); then
      if [[ "$DRY_RUN" != "true" ]]; then
        jq --arg d "$(today)" --arg id "$id" '
          .approvals[$d].count = ((.approvals[$d].count // 0) + 1)
          | .approvals[$d].ok[$id] = true' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      fi
      log "approve $id: 审批卡已推送（dry-run=${DRY_RUN}）"
      dry_pushed=$((dry_pushed+1))
    else
      local attempts; attempts="$(jq -r --arg id "$id" --arg d "$(today)" '.approvals[$d].fail[$id] // 0' "$STATE")"
      attempts=$((attempts+1))
      jq --arg d "$(today)" --arg id "$id" --argjson n "$attempts" '.approvals[$d].fail[$id] = $n' "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
      (( attempts >= 3 )) && _osascript "contrib 审批 $id 推送连续 ${attempts} 次失败（微信通道异常？）"
      log "approve $id: 推送失败（第 ${attempts} 次）"
    fi
    rm -f "$card"
  done
  (( dry_pushed > 0 )) && return 0 || return 0
}

# ---------------- receipt（回执，独立计数） ----------------
cmd_receipt() {
  ensure_state
  local id="${1:-}"; shift || true
  local summary=""
  while [[ $# -gt 0 ]]; do case "$1" in --summary) summary="$2"; shift 2 ;; *) shift ;; esac; done
  local msg="/tmp/contrib-receipt-$id.txt"
  printf '✅【contrib 回执】#%s 已执行\n%s\n（账目: martin/approved.log）\n' "$id" "$summary" > "$msg"
  local rc=0; _send "$msg" "contrib 回执 $id" || rc=$?
  if (( rc == 0 )); then
    state_bump receipts "$(today)"
    log "receipt $id 已发"
  else
    log "receipt $id 发送失败 rc=${rc}（不影响记账，明晨对账补报）"
  fi
  rm -f "$msg"
  return 0
}

# ---------------- fallback ----------------
cmd_fallback() {
  _osascript "${1:-contrib-watch 通知}"
  log "fallback: $1"
}

# ---------------- 入口 ----------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  event)   cmd_event "$@" ;;
  flush)   cmd_flush ;;
  approve) cmd_approve "$@" ;;
  receipt) cmd_receipt "$@" ;;
  fallback) cmd_fallback "$@" ;;
  help|*)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
