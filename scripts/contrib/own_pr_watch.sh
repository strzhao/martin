#!/bin/bash
# own_pr_watch.sh — own-PR 小时级机械盯梢（零 LLM 机械 diff；run-watch 段 2.5 每小时调用）
#
# 把 strzhao 名下 open PR 的 updatedAt/mergeable/reviewDecision/comments 与上一份机械快照
# 比对，按三级产生事件入既有 events.jsonl 消费链（notify.sh flush 统一渲染/推送）：
#   高级 own-pr-activity（机械模板卡→微信，受子上限 own_pr_alert_per_day，缺省 2/日）：
#     key <PR>-comment-<external_comments>-<日期> / <PR>-merged-<日期> / <PR>-closed-<日期>
#   低级 own-pr-info（叙事类→flush 聚合 digest=简报语义，不受子上限）：
#     key <PR>-mergeable-<日期> / <PR>-stale-<日期>
#   静默：新 PR/首跑建基线、本人评论（external_comments 不增）、任何含 UNKNOWN 的
#         mergeable 翻转、仅 reviewDecision 变化
#
# 用法: own_pr_watch.sh   （单发无子命令；带任何参数=用法错误）
#
# exit code: 0=正常完成（含基线轮/静默吸收/快照损坏重建基线）
#            1=gh 查询失败中止（零快照写零事件；连败计数 $CONTRIB/.ownpr-watch-fail，
#              恰达 2 发 pipeline-failure --key <日期>-ownpr-watch-down，成功即清零）
#            2=用法错误
#
# 数据: 快照 $CONTRIB/own-pr-watch-snapshot.json（本脚本唯一写者，原子写 tmp+mv；条目形态 =
#       updatedAt/mergeable/reviewDecision/comments/external_comments + headRefOid/headRefName
#       ——D4 加性两字段：同一 gh pr list 调用附带（gh 成本零增量），供 coder_upstream_gate
#       own-PR 判重面消费）；
#       永不触碰 assets-snapshot.json（radar LLM 快照）。自有日志 $CONTRIB/logs/own-pr-watch.log。
#       events.jsonl 唯一入账出口 = notify.sh event（其自身同 key 幂等兜底）。
# seam: GH_BIN / CONTRIB_DATA_DIR / MARTIN_DIR / OWN_PR_GH_USER（缺省 strzhao）
set -euo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
SNAP="$CONTRIB/own-pr-watch-snapshot.json"
FAIL_FILE="$CONTRIB/.ownpr-watch-fail"
EVENTS="$CONTRIB/events.jsonl"
CONFIG="$CONTRIB/config.json"
LOGDIR="$CONTRIB/logs"
LOG="$LOGDIR/own-pr-watch.log"
GH_BIN="${GH_BIN:-gh}"
GH_USER="${OWN_PR_GH_USER:-strzhao}"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"

if [[ $# -gt 0 ]]; then
  echo "用法: own_pr_watch.sh（单发无参数；多余参数无效）" >&2
  exit 2
fi

mkdir -p "$LOGDIR"
TS="$(date +%Y-%m-%dT%H%M)"
log() { echo "[${TS}] $*" >>"$LOG"; }

# cfg 读法（notify.sh 先例）：只把 null/缺失当缺省——false/0 是合法配置值（jq `//` falsy 陷阱）
cfg() {
  local v
  v="$(jq -r "$1" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$v" && "$v" != "null" ]]; then
    echo "$v"
  else
    echo "$2"
  fi
}

# 数值旋钮防污（config 写坏时回落缺省，不进算术错误）
int_or() { # <value> <default>
  case "${1:-}" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

GH_REPO="$(cfg '.repo' 'NousResearch/hermes-agent')"
ALERT_MAX="$(int_or "$(cfg '.own_pr_alert_per_day' '2')" '2')"
STALE_DAYS="$(int_or "$(cfg '.stale_pr_days' '10')" '10')"
TODAY="$(date +%F)"
NOW_EPOCH="$(date +%s)"

# 连败计数（kanban_card .hermes-down 先例：单整数，仅成功清零，无 TTL）
fail_count() {
  local c
  c="$(cat "$FAIL_FILE" 2>/dev/null || true)"
  case "$c" in
    ''|*[!0-9]*) c=0 ;;
  esac
  printf '%s' "$c"
}

# gh 失败断路：中止本轮（零快照写零事件）；恰达 2 发 pipeline-failure（key 日级幂等）
gh_fail() {
  local count=$(( $(fail_count) + 1 ))
  printf '%s\n' "$count" >"$FAIL_FILE"
  log "gh 查询失败（连败 ${count}）——本轮中止：零快照写零事件"
  if (( count == 2 )); then
    if [[ -x "$NOTIFY" ]]; then
      bash "$NOTIFY" event pipeline-failure \
        --key "${TODAY}-ownpr-watch-down" \
        --summary "own-PR 盯梢连续 2 轮 gh 查询失败，本轮中止（恢复后自动清零，下轮自动重试）" \
        >>"$LOG" 2>&1 || true
    fi
  fi
  exit 1
}

notify_event() { # <class> <key> <summary> — 唯一入账出口（notify 自身同 key 幂等兜底）
  [[ -x "$NOTIFY" ]] || return 0
  bash "$NOTIFY" event "$1" --key "$2" --summary "$3" >>"$LOG" 2>&1 || true
}

# 当日高级事件已入账数——jq 解析非 grep（账本有 jq 紧凑与 json.dumps 带空格两种形态）；
# 当日口径锚定 key 尾部 -<日期>（本脚本是 own-pr-activity 唯一生产者，key 形态闭集自证）
high_used() {
  if [[ -f "$EVENTS" ]]; then
    jq -s --arg d "$TODAY" \
      '[.[] | select(.class == "own-pr-activity" and ((.key // "") | endswith("-" + $d)))] | length' \
      "$EVENTS" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# stage-1 行 → 快照条目（external_comments = 作者≠strzhao 的评论数；headRefOid/headRefName
# 为 D4 加性映射——stage-1 字段列表已附带，缺省空串，旧快照/旧夹具零破坏）
prs_from_raw() { # <raw_array_json>
  jq -c --arg u "$GH_USER" '
    [.[] | {key: (.number | tostring),
            value: {updatedAt: (.updatedAt // ""),
                  mergeable: (.mergeable // "UNKNOWN"),
                  reviewDecision: (.reviewDecision // ""),
                  comments: ((.comments // []) | length),
                  external_comments: ([.comments[]? | select(((.author // {}).login // "") != $u)] | length),
                  headRefOid: (.headRefOid // ""),
                  headRefName: (.headRefName // "")}}]
    | from_entries' <<<"$1"
}

write_snapshot() { # <prs_obj_json> — 原子写（tmp+mv）
  local tmp="${SNAP}.tmp"
  jq -n --arg ts "$(date -u +%FT%TZ)" --argjson prs "$1" '{generated_at: $ts, prs: $prs}' >"$tmp" \
    && mv "$tmp" "$SNAP"
}

# ---------- stage-1：廉价查询（失败 → 断路中止） ----------
raw="$(GH_REPO="$GH_REPO" "$GH_BIN" pr list --author "$GH_USER" --state open \
  --json number,updatedAt,mergeable,reviewDecision,comments,headRefOid,headRefName 2>>"$LOG")" || gh_fail
if ! jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1; then
  log "stage-1 输出非 JSON 数组，按 gh 失败处理"
  gh_fail
fi

# ---------- 快照读取（损坏 → 重建基线，exit 0 零事件） ----------
CORRUPT=0
if [[ -f "$SNAP" ]]; then
  if jq -e 'type == "object" and (.prs | type == "object")' "$SNAP" >/dev/null 2>&1; then
    OLD_PRS="$(jq -c '.prs' "$SNAP")"
  else
    CORRUPT=1
    OLD_PRS='{}'
  fi
else
  OLD_PRS='{}'
fi
if (( CORRUPT == 1 )); then
  log "快照 corrupt（jq 解析失败）→ rebuild 基线：本轮零事件，静默重建"
fi
BASELINE=0
if (( CORRUPT == 1 )); then
  BASELINE=1
elif [[ ! -f "$SNAP" ]]; then
  BASELINE=1
  log "无快照（首跑）→ 建基线：本轮零事件"
fi
if (( BASELINE == 1 )); then
  NEW_PRS="$(prs_from_raw "$raw")"
  write_snapshot "$NEW_PRS"
  rm -f "$FAIL_FILE"
  log "基线已写（$(jq 'length' <<<"$NEW_PRS") 个 PR），exit 0"
  exit 0
fi

# ---------- 消失 PR：stage-2 终态核实（MERGED/CLOSED→高级事件+剪枝；OPEN→保留） ----------
TERM_KEYS=()
TERM_SUMM=()
NEW_PRS="$(prs_from_raw "$raw")"   # 新快照底座 = 当前 open 集（消失 PR 自然剪枝；OPEN 保留再并回）
vanished="$(comm -23 \
  <(jq -r '.prs | keys[]' "$SNAP" 2>/dev/null | sort) \
  <(jq -r '.[].number | tostring' <<<"$raw" | sort))"
while IFS= read -r vnum; do
  [[ -n "$vnum" ]] || continue
  view_json="$(GH_REPO="$GH_REPO" "$GH_BIN" pr view "$vnum" --json state 2>>"$LOG")" || gh_fail
  if ! jq -e 'type == "object"' <<<"$view_json" >/dev/null 2>&1; then
    log "stage-2 state 输出异常（PR ${vnum}），按 gh 失败处理"
    gh_fail
  fi
  state="$(jq -r '.state // ""' <<<"$view_json")"
  case "$state" in
    MERGED)
      TERM_KEYS+=("${vnum}-merged-${TODAY}")
      TERM_SUMM+=("PR #${vnum} 已合并（MERGED）——收割窗核对署名/被 pick 情况")
      ;;
    CLOSED)
      TERM_KEYS+=("${vnum}-closed-${TODAY}")
      TERM_SUMM+=("PR #${vnum} 已关闭（CLOSED，未合并）——核对 salvage 价值后可清理关注")
      ;;
    *)
      # 瞬时态/未知终态：保守保留快照条目，零事件
      log "PR #${vnum} 从 open 列表消失但 state=${state:-空} → 保留快照条目"
      entry="$(jq -c --arg k "$vnum" '.prs[$k]' "$SNAP")"
      NEW_PRS="$(jq -c --arg k "$vnum" --argjson e "$entry" '. + {($k): $e}' <<<"$NEW_PRS")"
      ;;
  esac
done <<<"$vanished"

# ---------- 现存 PR：评论/mergeable/停滞 diff（评论增才 stage-2 核实口径） ----------
# 行分隔用 `|`（非 IFS 空白字符）：@tsv + IFS=$'\t' 会被 read 折叠连续 tab（reviewDecision
# 为空串时字段整体左移），patterns 09-05 工具链形态类陷阱的同族防御
ALERT_USED="$(high_used)"
HIGH_KEYS=()
HIGH_SUMM=()
LOW_KEYS=()
LOW_SUMM=()
while IFS='|' read -r num upd mergeable reviewdec cmtn extn; do
  [[ -n "$num" ]] || continue
  old="$(jq -c --arg k "$num" '.[$k] // empty' <<<"$OLD_PRS")"
  if ! jq -e 'type == "object"' <<<"$old" >/dev/null 2>&1; then
    continue   # 新 PR → 基线吸收零事件
  fi
  old_comments="$(jq -r '.comments // 0' <<<"$old" 2>/dev/null || echo 0)"
  old_ext="$(jq -r '.external_comments // 0' <<<"$old" 2>/dev/null || echo 0)"
  old_mergeable="$(jq -r '.mergeable // "UNKNOWN"' <<<"$old" 2>/dev/null || echo "UNKNOWN")"
  case "$old_comments" in ''|*[!0-9]*) old_comments=0 ;; esac
  case "$old_ext" in ''|*[!0-9]*) old_ext=0 ;; esac
  # external_comments 权威值=stage-1 行内计算（真实 gh pr list --json comments 是数组、逐作者
  # 计数；qa-reviewer 09-10 实测证伪「标量」旧注——t7 夹具曾以标量形态诱发行值恒 0 假象）。
  # 行值不可用（缺列/非数值）才回落旧值（保底语义，兼容夹具/形态漂移）；外部评论真增时
  # 仍由 stage-2 ext2 覆盖（下方分支）。
  case "$extn" in
    ''|*[!0-9]*) extn="$old_ext" ;;
  esac
  diff_comments=0
  diff_merge=0
  if (( cmtn > old_comments )); then
    diff_comments=1
    # stage-2：核实 external 口径（总数增但全为本人评论 → 静默吸收）
    view_json="$(GH_REPO="$GH_REPO" "$GH_BIN" pr view "$num" --json comments 2>>"$LOG")" || gh_fail
    if ! jq -e 'type == "object"' <<<"$view_json" >/dev/null 2>&1; then
      log "stage-2 comments 输出异常（PR ${num}），按 gh 失败处理"
      gh_fail
    fi
    ext2="$(jq --arg u "$GH_USER" '[.comments[]? | select(((.author // {}).login // "") != $u)] | length' \
      <<<"$view_json" 2>>"$LOG")" || gh_fail
    case "$ext2" in ''|*[!0-9]*) gh_fail ;; esac
    if (( ext2 > old_ext )); then
      HIGH_KEYS+=("${num}-comment-${ext2}-${TODAY}")
      HIGH_SUMM+=("PR #${num} 有新外部评论（外部评论数 ${ext2}）——维护者/他人介入，待查看")
      extn="$ext2"
    else
      log "PR #${num} 评论数增加但均为本人评论（external=${ext2}）→ 静默吸收"
    fi
  fi
  if [[ "$mergeable" != "$old_mergeable" && "$mergeable" != "UNKNOWN" ]]; then
    case "$old_mergeable" in
      MERGEABLE|CONFLICTING)
        case "$mergeable" in
          MERGEABLE|CONFLICTING)
            diff_merge=1
            LOW_KEYS+=("${num}-mergeable-${TODAY}")
            LOW_SUMM+=("PR #${num} mergeable 翻转：${old_mergeable} → ${mergeable}")
            ;;
        esac
        ;;
    esac
    # 含 UNKNOWN（任一侧非具体值）→ 静默吸收
  fi
  if (( diff_comments == 0 && diff_merge == 0 )); then
    upd_epoch="$(printf '%s' "$upd" | jq -R 'if . == "" then empty else (fromdateiso8601? // empty) end' 2>/dev/null || true)"
    case "$upd_epoch" in
      ''|*[!0-9]*) : ;;
      *)
        age_secs=$(( NOW_EPOCH - upd_epoch ))
        if (( age_secs > STALE_DAYS * 86400 )); then
          age_days=$(( age_secs / 86400 ))
          LOW_KEYS+=("${num}-stale-${TODAY}")
          LOW_SUMM+=("PR #${num} 停滞 ${age_days} 天无动静（> 阈值 ${STALE_DAYS} 天），radar 处置建议见简报")
        fi
        ;;
    esac
  fi
  # 快照条目吸收本轮实测值（高级停发也吸收，防永久重检）；D4：与既有条目做对象合并
  # （*. 右侧五字段覆盖、headRefOid/headRefName 等加性字段保续），保证快照条目下轮
  # 自然再生新形态——绝不整条替换（否则加性字段每轮被冲掉，闸门判重面永久 fail-open）
  NEW_PRS="$(jq -c --arg k "$num" --arg upd "$upd" --arg m "$mergeable" --arg r "$reviewdec" \
    --argjson c "$cmtn" --argjson e "$extn" \
    '. + {($k): ((.[$k] // {}) * {updatedAt: $upd, mergeable: $m, reviewDecision: $r, comments: $c, external_comments: $e})}' \
    <<<"$NEW_PRS")"
done < <(jq -r --arg u "$GH_USER" '
  .[] | ([.number, (.updatedAt // ""), (.mergeable // "UNKNOWN"), (.reviewDecision // ""),
        ((.comments // []) | length),
        ([.comments[]? | select(((.author // {}).login // "") != $u)] | length)] | join("|"))' <<<"$raw")

# ---------- 事件出账：高级受子上限（当日口径自查），低级不受限 ----------
i=0
for k in ${TERM_KEYS[@]+"${TERM_KEYS[@]}"}; do
  if (( ALERT_USED >= ALERT_MAX )); then
    log "高级事件停发（当日 own-pr-activity 已 ${ALERT_USED}/${ALERT_MAX}）：${k}"
  else
    notify_event own-pr-activity "$k" "${TERM_SUMM[$i]}"
    ALERT_USED=$(( ALERT_USED + 1 ))
  fi
  i=$(( i + 1 ))
done
i=0
for k in ${HIGH_KEYS[@]+"${HIGH_KEYS[@]}"}; do
  if (( ALERT_USED >= ALERT_MAX )); then
    log "高级事件停发（当日 own-pr-activity 已 ${ALERT_USED}/${ALERT_MAX}）：${k}"
  else
    notify_event own-pr-activity "$k" "${HIGH_SUMM[$i]}"
    ALERT_USED=$(( ALERT_USED + 1 ))
  fi
  i=$(( i + 1 ))
done
i=0
for k in ${LOW_KEYS[@]+"${LOW_KEYS[@]}"}; do
  notify_event own-pr-info "$k" "${LOW_SUMM[$i]}"
  i=$(( i + 1 ))
done

# ---------- 快照原子落盘 + 成功清零 ----------
write_snapshot "$NEW_PRS"
rm -f "$FAIL_FILE"
log "盯梢完成：高级 ${#HIGH_KEYS[@]}+${#TERM_KEYS[@]}（停发按当日 ${ALERT_MAX}）低级 ${#LOW_KEYS[@]}，exit 0"
exit 0
