#!/bin/bash
# contrib-watch 廉价闸门（无 LLM）：增量拉新 issue → 域内粗滤 → 有命中才值得唤起 LLM 研判
# 设计依据：context 经济是 KPI（harness 原则④）——每小时跑一次，零命中时不开 LLM
#
# 用法:
#   scan_gate.sh          正常扫描（读游标，增量粗滤；命中写批次文件，exit 10）
#   scan_gate.sh --init   游标拨到当前最新 issue 号（首次部署/重置用，不产生命中）
#   scan_gate.sh --drain  人工确认已消费后的兜底清账：把批次文件内 state=pending 项
#                         改写为 drained（T6 兼容写撤销后唯一数据源=批次文件）
#
# exit code: 0=无新命中  10=有命中待研判  其他=出错
set -euo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
DATA="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
REPO="NousResearch/hermes-agent"
CURSOR="$DATA/scan-cursor.json"
# 命令 seam（默认值=现状硬编码；测试套件经此注入影子 stub，生产语义零改变）
GH_BIN="${GH_BIN:-gh}"
BACKLOG_ALERT=80
LOGDIR="$DATA/logs"
mkdir -p "$LOGDIR" "$DATA/briefs" "$DATA/radar" "$DATA/runs" "$DATA/pending-batches"
TS=$(date +%Y-%m-%dT%H%M)
LOG="$LOGDIR/scan-gate.log"

log() { echo "[$TS] $*" >>"$LOG"; }

# 批次文件 glob（双 shell 兼容：生产 run-watch 用 zsh 调本脚本、shebang 是 bash——compgen 只存在于
# bash，zsh 下 command not found 使 guard 恒假=批次静默零计数。zsh 开 null_glob 让无匹配展开为空，
# bash 走 [[ -e ]] 字面量守卫，两条路径同一循环语义。）
batch_files() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt null_glob
  fi
  for _bf in "$DATA/pending-batches"/batch-*.json; do
    [[ -e "$_bf" ]] || continue
    printf '%s\n' "$_bf"
  done
}

if [[ "${1:-}" == "--init" ]]; then
  latest=$("$GH_BIN" api "repos/$REPO/issues?state=all&per_page=1" --jq '.[0].number')
  jq -n --argjson n "$latest" --arg d "$(date -u +%FT%TZ)" '{last_issue: $n, initialized: $d}' > "$CURSOR"
  log "cursor --init 拨到 #${latest}"
  echo "cursor initialized at #$latest"
  exit 0
fi

if [[ "${1:-}" == "--drain" ]]; then
  # 人工兜底清账：批次文件内 state=pending → drained（done/异常项不动；坏文件跳过不炸）
  drained_total=0
  while IFS= read -r _bf; do
    if jq -e 'type == "array"' "$_bf" >/dev/null 2>&1; then
      _n="$(jq '[.[] | select(.state? == "pending")] | length' "$_bf" 2>>"$LOG" || echo 0)"
      jq 'map(if .state? == "pending" then .state = "drained" else . end)' \
        "$_bf" > "$_bf.tmp" 2>>"$LOG" && mv "$_bf.tmp" "$_bf"
      drained_total=$((drained_total + _n))
    else
      log "WARN --drain 跳过损坏批次文件：$_bf"
    fi
  done < <(batch_files)
  log "pending 人工清空（--drain）：${drained_total} 条 pending → drained"
  echo "drained ${drained_total}"
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
  # 唯一数据源=批次文件（T6 兼容写撤销，契约 1b 过渡期结束）：卡路/fallback 共同读这里
  BATCH_TS="$(date +%Y%m%d-%H%M%S)"
  BATCH_FILE="$DATA/pending-batches/batch-$BATCH_TS.json"
  printf '%s\n' "$hits" | jq 'map(. + {state: "pending"})' > "$BATCH_FILE"
  # 指针文件：run-watch 建卡时消费（批次路径/时间戳/条数）
  jq -n --arg f "$BATCH_FILE" --arg ts "$BATCH_TS" --argjson n "$hit_count" \
    '{batch_file: $f, ts: $ts, count: $n}' > "$DATA/scan-latest-batch.json"
fi

jq --argjson m "$max_seen" --arg d "$(date -u +%FT%TZ)" \
  '.last_issue = $m | .last_scan = $d' "$CURSOR" > "$CURSOR.tmp" && mv "$CURSOR.tmp" "$CURSOR"

# 积压告警面（契约 1：告警不丢弃）：唯一数据源=批次文件的 state=pending 项，
# 跨批次文件按 .number 去重计数（T6 撤销兼容双写源后口径收窄为单源）
backlog_corrupt=0
_agg='[]'
while IFS= read -r _bf; do
  # 逐文件容错聚合（worker 是 LLM 直接写文件，单个坏文件不得静默清零告警面）
  if _one="$(jq -c '[.[] | select(.state? == "pending")]' "$_bf" 2>>"$LOG")" && [[ -n "$_one" ]]; then
    _agg="$(jq -cn --argjson a "$_agg" --argjson o "$_one" '$a + $o' 2>>"$LOG" || printf '%s' "$_agg")"
  else
    backlog_corrupt=$((backlog_corrupt + 1))
    log "WARN 批次文件解析失败（疑似 worker 写坏，不计入积压）：$_bf"
  fi
done < <(batch_files)
backlog="$(jq -n --argjson b "$_agg" '$b | [.[].number] | unique | length' 2>>"$LOG" || echo 0)"
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
      --summary "scan 研判积压 ${backlog} 条（批次单源去重）> ${BACKLOG_ALERT}，消费速度落后" \
      >>"$LOG" 2>&1 || true
  fi
fi

if (( hit_count > 0 )); then
  log "$hit_count 条命中写入批次 $BATCH_FILE （总积压 $backlog 条）→ 触发研判卡"
  exit 10
fi
exit 0
