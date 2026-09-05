#!/bin/bash
# contrib-watch 廉价闸门（无 LLM）：增量拉新 issue → 域内粗滤 → 有命中才值得唤起 LLM 研判
# 设计依据：context 经济是 KPI（harness 原则④）——每小时跑一次，零命中时不开 LLM
#
# 用法:
#   scan_gate.sh          正常扫描（读游标，增量粗滤，命中写 pending-hits.json，exit 10）
#   scan_gate.sh --init   游标拨到当前最新 issue 号（首次部署/重置用，不产生命中）
#   scan_gate.sh --drain  人工确认已消费后清空 pending（claude 研判完会自动清，此为手动兜底）
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
PENDING_CAP=40
LOGDIR="$DATA/logs"
mkdir -p "$LOGDIR" "$DATA/briefs" "$DATA/radar" "$DATA/runs"
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

# 粗滤（09-04 反转为黑名单）：只排除已知零契合域（desktop/kanban/dashboard 等我方零部署面），
# 其余全部放行给 LLM rubric——rubric 首维「领域契合 0」自动 skip，不会产生队列噪音。
# 依据：用户拍板 token 充裕 + 扩大 issue 范围；排除 duplicate/invalid；只看 issue（pull_request==null）
hits=$(jq -c '
  def excluded:
    (([.labels[].name] | join(",")) | test("comp/desktop|comp/kanban|comp/dashboard"))
      or (.title | test("desktop|kanban|dashboard|hosted rooms?|local model|wake word|sherpa|bot marketplace|bot mode"; "i"));
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
  if [[ -s "$PENDING" ]] && jq -e 'type == "array"' "$PENDING" >/dev/null 2>&1; then
    jq --argjson new "$hits" '. + $new | unique_by(.number) | sort_by(.number) | .[-'"$PENDING_CAP"':]' \
      "$PENDING" > "$PENDING.tmp" && mv "$PENDING.tmp" "$PENDING"
  else
    printf '%s\n' "$hits" > "$PENDING"
  fi
fi

jq --argjson m "$max_seen" --arg d "$(date -u +%FT%TZ)" \
  '.last_issue = $m | .last_scan = $d' "$CURSOR" > "$CURSOR.tmp" && mv "$CURSOR.tmp" "$CURSOR"

if (( hit_count > 0 )); then
  log "$hit_count 条命中写入 pending（累计 $(jq 'length' "$PENDING") 条）→ 触发 LLM 研判"
  exit 10
fi
exit 0
