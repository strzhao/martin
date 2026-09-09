#!/bin/bash
# contrib-watch 廉价闸门（无 LLM）：增量拉新 issue → 域内粗滤 → 有命中才值得唤起 LLM 研判
# 设计依据：context 经济是 KPI（harness 原则④）——每小时跑一次，零命中时不开 LLM
#
# 用法:
#   scan_gate.sh          正常扫描（读游标，增量粗滤；命中双写批次文件+pending-hits.json，exit 10）
#   scan_gate.sh --init   游标拨到当前最新 issue 号（首次部署/重置用，不产生命中）
#   scan_gate.sh --drain  人工确认已消费后清空 pending（fallback 研判路保留，此为手动兜底）
#
# exit code: 0=无新命中  10=有命中待研判  其他=出错
set -euo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
DATA="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
REPO="NousResearch/hermes-agent"
CURSOR="$DATA/scan-cursor.json"
PENDING="$DATA/pending-hits.json"
# 命令 seam（默认值=现状硬编码；测试套件经此注入影子 stub，生产语义零改变）
GH_BIN="${GH_BIN:-gh}"
BACKLOG_ALERT=80
LOGDIR="$DATA/logs"
mkdir -p "$LOGDIR" "$DATA/briefs" "$DATA/radar" "$DATA/runs" "$DATA/pending-batches"
TS=$(date +%Y-%m-%dT%H%M)
LOG="$LOGDIR/scan-gate.log"

log() { echo "[$TS] $*" >>"$LOG"; }

if [[ "${1:-}" == "--init" ]]; then
  latest=$("$GH_BIN" api "repos/$REPO/issues?state=all&per_page=1" --jq '.[0].number')
  jq -n --argjson n "$latest" --arg d "$(date -u +%FT%TZ)" '{last_issue: $n, initialized: $d}' > "$CURSOR"
  printf '[]\n' > "$PENDING"
  log "cursor --init 拨到 #${latest}，pending 清空"
  echo "cursor initialized at #$latest"
  exit 0
fi

if [[ "${1:-}" == "--drain" ]]; then
  printf '[]\n' > "$PENDING"
  log "pending 人工清空（--drain）"
  echo "pending drained"
  exit 0
fi

last=$(jq -r '.last_issue // 0' "$CURSOR" 2>/dev/null || echo 0)
raw=$("$GH_BIN" api "repos/$REPO/issues?state=open&sort=created&direction=desc&per_page=50" 2>>"$LOG")
max_seen=$(jq '[.[].number] | max // 0' <<<"$raw")
seen_new=$(jq "[.[] | select(.pull_request == null and .number > $last)] | length" <<<"$raw")

# 粗滤（09-04 反转为黑名单；09-09 修订：kanban 移出黑名单——用户 kanban 重度使用）
# 只排除已知零契合域（desktop/dashboard 等零部署面；kanban 09-09 起放行给 LLM rubric），
# 其余全部放行给 LLM rubric——rubric 首维「领域契合 0」自动 skip，不会产生队列噪音。
# 依据：用户拍板 token 充裕 + 扩大 issue 范围；排除 duplicate/invalid；只看 issue（pull_request==null）
hits=$(jq -c '
  def excluded:
    (([.labels[].name] | join(",")) | test("comp/desktop|comp/dashboard"))
      or (.title | test("desktop|dashboard|hosted rooms?|local model|wake word|sherpa|bot marketplace|bot mode"; "i"));
  [.[] | select(
      .pull_request == null
      and .number > '"$last"'
      and (([.labels[].name] | index("duplicate")) == null)
      and (([.labels[].name] | index("invalid")) == null)
      and (excluded | not)
    ) | {number, title, labels: [.labels[].name], author: .user.login, created: .created_at, comments: .comments}]
' <<<"$raw")

hit_count=$(jq 'length' <<<"$hits")
log "cursor=#$last 新issue=$seen_new 域内命中=$hit_count"

if (( seen_new >= 50 )); then
  log "WARN 单次新 issue ≥50（停机后追赶？），更早的已跳过——必要时手动降低游标补扫"
fi

if (( hit_count > 0 )); then
  # 双写（契约 1b）：批次文件为主（卡路/fallback 共同数据源），pending-hits.json 兼容写保留至 T6
  BATCH_TS="$(date +%Y%m%d-%H%M%S)"
  BATCH_FILE="$DATA/pending-batches/batch-$BATCH_TS.json"
  printf '%s\n' "$hits" | jq 'map(. + {state: "pending"})' > "$BATCH_FILE"
  # 兼容写：保留原合并去重逻辑，但**删除 cap 挤出**（积压改走告警面，不静默丢数据）
  if [[ -s "$PENDING" ]] && jq -e 'type == "array"' "$PENDING" >/dev/null 2>&1; then
    jq --argjson new "$hits" '. + $new | unique_by(.number) | sort_by(.number)' \
      "$PENDING" > "$PENDING.tmp" && mv "$PENDING.tmp" "$PENDING"
  else
    printf '%s\n' "$hits" > "$PENDING"
  fi
  # 指针文件：run-watch 建卡时消费（批次路径/时间戳/条数）
  jq -n --arg f "$BATCH_FILE" --arg ts "$BATCH_TS" --argjson n "$hit_count" \
    '{batch_file: $f, ts: $ts, count: $n}' > "$DATA/scan-latest-batch.json"
fi

jq --argjson m "$max_seen" --arg d "$(date -u +%FT%TZ)" \
  '.last_issue = $m | .last_scan = $d' "$CURSOR" > "$CURSOR.tmp" && mv "$CURSOR.tmp" "$CURSOR"

# 积压告警面（契约 1：告警不丢弃）：批次文件（state=pending 项）与 pending-hits 两源
# 按 .number 去重合并计数——双写含同一批 hit，直接求和会双计使阈值语义减半
ph_json='[]'
if [[ -s "$PENDING" ]] && jq -e 'type == "array"' "$PENDING" >/dev/null 2>&1; then
  ph_json="$(cat "$PENDING")"
fi
backlog_pending='[]'
backlog_corrupt=0
# 双 shell 兼容（生产 run-watch 用 zsh 调本脚本、shebang 是 bash——compgen 只存在于 bash，
# zsh 下 command not found 使 guard 恒假=批次静默零计入）。zsh 开 null_glob 让无匹配展开为空，
# bash 走 [[ -e ]] 字面量守卫，两条路径同一循环语义。
if [[ -n "${ZSH_VERSION:-}" ]]; then
  setopt null_glob
fi
_agg='[]'
for _bf in "$DATA/pending-batches"/batch-*.json; do
  [[ -e "$_bf" ]] || continue
  # 逐文件容错聚合（worker 是 LLM 直接写文件，单个坏文件不得静默清零告警面）
  if _one="$(jq -c '[.[] | select(.state? == "pending")]' "$_bf" 2>>"$LOG")" && [[ -n "$_one" ]]; then
    _agg="$(jq -cn --argjson a "$_agg" --argjson o "$_one" '$a + $o' 2>>"$LOG" || printf '%s' "$_agg")"
  else
    backlog_corrupt=$((backlog_corrupt + 1))
    log "WARN 批次文件解析失败（疑似 worker 写坏，不计入积压）：$_bf"
  fi
done
backlog_pending="$_agg"
backlog="$(jq -n --argjson b "$backlog_pending" --argjson p "$ph_json" \
  '$b + $p | unique_by(.number) | length' 2>>"$LOG" || echo 0)"
if (( backlog_corrupt > 0 )); then
  log "WARN ${backlog_corrupt} 个批次文件损坏，积压口径不含其条目——需人工检查 pending-batches/"
  if [[ -x "$MARTIN/scripts/contrib/notify.sh" ]]; then
    bash "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-backlog-corrupt" \
      --summary "${backlog_corrupt} 个 scan 批次文件损坏（worker 写坏？），积压告警口径失真，需人工检查 pending-batches/" \
      >>"$LOG" 2>&1 || true
  fi
fi
if (( backlog > BACKLOG_ALERT )); then
  log "WARN 研判积压 ${backlog} 条（>${BACKLOG_ALERT}），告警不丢弃"
  if [[ -x "$MARTIN/scripts/contrib/notify.sh" ]]; then
    bash "$MARTIN/scripts/contrib/notify.sh" event pipeline-failure \
      --key "$(date +%F)-backlog" \
      --summary "scan 研判积压 ${backlog} 条（两源去重）> ${BACKLOG_ALERT}，消费速度落后" \
      >>"$LOG" 2>&1 || true
  fi
fi

if (( hit_count > 0 )); then
  log "$hit_count 条命中写入批次 $BATCH_FILE + pending（总积压 $backlog 条）→ 触发研判卡"
  exit 10
fi
exit 0
