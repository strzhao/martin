#!/bin/bash
# contrib-watch 邮件闸门（无 LLM）：拉 GitHub 通知未读 → 域内过滤 → 预取正文节选落盘
# 设计依据：context 经济是 KPI（harness 原则④）——零新邮件不开 LLM；与 scan_gate 同构
#
# 用法:
#   mail_gate.sh                  正常检查（读游标增量；首启只定位不回灌存量未读）
#   mail_gate.sh --commit-cursor  AI 研判成功后由 run-watch 调：把 pending 里最大 id 写进游标
#                                 （研判失败轮次不调，pending 下轮重研判）
#   mail_gate.sh --drain          人工兜底：清空 pending 不动游标
#
# exit code: 0=无新邮件  10=有新邮件待研判  其他=出错
#
# 只读红线：全程只用 envelope list / message read -p（preview 不置已读），
# 绝不 mark/move/delete/send。私有邮件不碰（from github.com 过滤 + to/主题双分流）。
# 采集权威=游标，不是 unseen（09-09 实证 8750-8755 被外部 IMAP/POP3 客户端拉取即置
# 已读：gate 26h「未读=55 新邮件=0」完美错过 6 封，靠人工回扫才捞回）。所以查询
# 不带 flag unseen，列最新页后纯客户端按 id>cursor 过滤——seen 状态在我们控制外，
# 不可作为采集信号。幂等不靠 seen：cursor 只当下界 + notify.sh event --key 去重。
# QQ IMAP 坑（实测）：查询严禁带日期条件（服务端 SEARCH 超时 >90s）；stderr 有
# imap_codec WARN 需丢弃；id 是 IMAP 序列号、expunge 后漂移——游标只当下界，
# 幂等靠 notify.sh event --key（message-id/日期组合）。
set -euo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
DATA="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
CURSOR="$DATA/mail-cursor.json"
PENDING="$DATA/mail-pending.json"
# 命令 seam（默认=现状硬编码；测试套件经此注入 stub，生产语义零改变）
HIMAIL="${HIMALAYA_BIN:-himalaya}"
# 采集窗口：未读候选上限（QQ IMAP 服务端 SEARCH 全量后客户端截取，单次 1.2s 实测）
FETCH_SIZE=100
# 每封正文节选上限（研判够用即可，context 经济）
PREVIEW_BYTES=3000
LOGDIR="$DATA/logs"
mkdir -p "$LOGDIR" "$DATA/briefs"
TS=$(date +%Y-%m-%dT%H%M)
LOG="$LOGDIR/mail-gate.log"

log() { echo "[$TS] $*" >>"$LOG"; }

if [[ "${1:-}" == "--drain" ]]; then
  printf '[]\n' > "$PENDING"
  log "pending 人工清空（--drain）"
  echo "pending drained"
  exit 0
fi

if [[ "${1:-}" == "--commit-cursor" ]]; then
  if [[ -s "$PENDING" ]]; then
    max_id="$(jq -r '[.[].id | tonumber] | max // 0' "$PENDING" 2>/dev/null || echo 0)"
    if (( max_id > 0 )); then
      jq -n --argjson n "$max_id" --arg d "$(date -u +%FT%TZ)" '{last_id: $n, committed: $d}' > "$CURSOR"
      log "cursor --commit-cursor 拨到 #${max_id}（研判成功）"
      echo "cursor committed at #${max_id}"
    fi
    # 消费闭环：成稿已判、游标已拨，pending 清空——否则遗留检查会让下轮永远 exit 10
    printf '[]\n' > "$PENDING"
  else
    echo "pending 为空，无游标可提交"
  fi
  exit 0
fi

# ── 采集：GitHub 通知（近 FETCH_SIZE 封，服务端只过滤 from；日期条件严禁）──
# 不带 flag unseen：外部客户端会把信拉取置已读（09-09 实证），seen 不可靠；
# 新旧由 id>cursor 客户端判定（下见 cursor 段）。FETCH_SIZE 是采集窗口上限，
# 单轮新邮件逼近该值=窗口饱和，下轮日志会告警（每小时一跑，正常远够）。
raw="$("$HIMAIL" envelope list -o json -f INBOX -s "$FETCH_SIZE" "from github.com" 2>/dev/null || echo "[]")"
jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1 || raw="[]"

# 客户端双分流（From 显示名是真实评论者，只认地址与主题）：
#   上游通知 = to 是 hermes-agent@noreply.github.com 或主题带 [owner/repo] 前缀
#   排除 = [GitHub] 前缀的账号类通知（不研判）
upstream=$(jq -c '
  [.[] | select(
      ((.to.addr // "") | test("hermes-agent@noreply\\.github\\.com"))
      or ((.subject // "") | test("^\\[[^]]+\\]"))
    ) | select((.subject // "") | test("^\\[GitHub\\]") | not)
]' <<<"$raw")

# ── 首启：无游标只定位不回灌（存量邮件不研判，防首轮 token 爆炸）──
if [[ ! -s "$CURSOR" ]]; then
  max_id="$(jq -r '[.[].id | tonumber] | max // 0' <<<"$upstream")"
  if (( max_id == 0 )); then
    log "首启但无上游通知，不写 cursor"
    exit 0
  fi
  jq -n --argjson n "$max_id" --arg d "$(date -u +%FT%TZ)" '{last_id: $n, initialized: $d}' > "$CURSOR"
  log "首启：cursor 定位到 #${max_id}，存量 $(jq 'length' <<<"$upstream") 封不回灌"
  echo "mail cursor initialized at #${max_id} (backlog skipped)"
  exit 0
fi

last="$(jq -r '.last_id // 0' "$CURSOR" 2>/dev/null || echo 0)"
new_items="$(jq -c "[.[] | select((.id | tonumber) > $last)]" <<<"$upstream")"
new_count="$(jq 'length' <<<"$new_items")"
log "cursor=#$last GitHub通知近页=$(jq 'length' <<<"$upstream") 新邮件=$new_count"
if (( new_count >= FETCH_SIZE )); then
  log "告警：新邮件=$new_count 达采集窗口上限 FETCH_SIZE=$FETCH_SIZE 可能截尾——人工核查 IMAP"
  # 截尾=潜在永久丢信（下轮 --commit-cursor 拨到最新 id 后窗口外旧信跳过），
  # 除日志外必须走事件通道（本仓规范：流水线异常→events.jsonl→AI digest）
  "$MARTIN/scripts/contrib/notify.sh" event mail-window-saturated --key "mail-sat-$(date +%F)" >/dev/null 2>&1 || true
fi

if (( new_count == 0 )); then
  # 无新邮件，但上轮研判失败的遗留 pending 仍待消费——不能 exit 0 卡死它
  leftover="$(jq 'length' "$PENDING" 2>/dev/null || echo 0)"
  if (( leftover > 0 )); then
    log "无新邮件，pending 遗留 $leftover 条待研判（上轮未 commit）"
    exit 10
  fi
  exit 0
fi

# ── 预取正文节选（read -p 不置已读；一次拿头部 Message-ID + 正文前段）──
# bash 3.2 无 mapfile 关联数组展开花活，逐封循环（每小时最多几十封，串行可控）
# 注意 jq -c '[.[]|...]' 输出整个数组为一行——循环须用 '.[]' 逐元素展开成行
payload="[]"
while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  mid="$(jq -r '.id' <<<"$row")"
  full="$("$HIMAIL" message read "$mid" -p 2>/dev/null | head -c "$PREVIEW_BYTES" || true)"
  # himalaya -p 渲染体只有 From/To/Cc/Subject 四个头，无 Message-ID 头——ID 只在
  # GitHub 正文页脚（"Message ID: <...>" 无连字符；body>PREVIEW_BYTES 截尾时会丢，容忍空值）。
  # grep no-match 若不兜底会被 set -e+pipefail 杀脚本（09-08 实证：10 封邮件连续 10 轮 rc=1）
  msg_id="$(grep -iE '^message-? ?id:' <<<"$full" | head -1 | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^message-? ?id:[[:space:]]*//' | tr -d '<>' || true)"
  body="$(printf '%s' "$full" | awk 'p; /^$/{p=1}' | head -c "$PREVIEW_BYTES")"
  payload="$(jq -cn --argjson acc "$payload" --argjson item \
    "$(jq -c --arg body "$body" --arg msg_id "$msg_id" \
        '. + {message_id: $msg_id, preview: $body}' <<<"$row")" \
    '$acc + [$item]')"
done < <(jq -c '.[]' <<<"$new_items")

# 合并进 pending（去重按 id，截尾防无限增长）
if [[ -s "$PENDING" ]] && jq -e 'type == "array"' "$PENDING" >/dev/null 2>&1; then
  jq --argjson new "$payload" '. + $new | unique_by(.id) | sort_by(.id | tonumber)' \
    "$PENDING" > "$PENDING.tmp" && mv "$PENDING.tmp" "$PENDING"
elif (( $(jq 'length' <<<"$payload") > 0 )); then
  printf '%s\n' "$payload" > "$PENDING"
fi

# exit 10 = pending 非空（本轮新增 **或上轮研判失败遗留**）——否则遗留项会被
# 「无新邮件 exit 0」永久卡住不被研判。消费闭环：研判成功后 run-watch 调
# --commit-cursor（推进游标 + 清空 pending）。
total="$(jq 'length' "$PENDING" 2>/dev/null || echo 0)"
log "新邮件=$new_count pending 累计 $total 条 → 触发 LLM 研判"
if (( total > 0 )); then
  exit 10
fi
exit 0
