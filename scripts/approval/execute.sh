#!/bin/bash
# execute.sh — L2-A 短码审批执行器（确定性 bash，不依赖 LLM；collect.sh 消费后调用）
#
# 用法:
#   execute.sh <id> <verdict> [comment]
#     <id>      rq id（须已是 state=approved —— collect.sh 的消费标记是幂等 SSOT）
#     <verdict> approved | rejected | revise（tunnel drops decision 按 C1 映射）
#     [comment] 审批页 comment 栏原文（revise 时入 rq note）
#
# 职责（设计 T5 / 契约 C8）:
#   approved: TTL 复验四项（gh 只读）→ gh api 投递 draft 剥离头部注释块后的逐字正文
#             → approved.log 追加（5 列，批准方式列=L2-A tunnel 短码批准（slug=<slug>））
#             → rq set executed + tunnel rm + rq tunnel-removed + notify receipt
#   rejected: rq set rejected + tunnel rm + receipt（不进 approved.log，沿 hermes-contrib-l2 skill 语义）
#   revise:   rq set revise --note "<comment>" + receipt
#   任一步失败: rq set failed（approved→failed 合法迁移）+ pipeline-failure 事件，不隐藏
#
# drill 件（id 以 -drill 结尾）: 跳过 gh 读写与 approved.log（rq budget drill 不计额同款先例），
#   只落 run 记录；状态推进/回收/回执照常。
#
# 环境变量 seam（沙箱测试用，生产缺省=真值）:
#   CONTRIB_DATA_DIR / MARTIN_DIR / TUNNEL_BIN / GH_BIN / APPROVAL_DRY_RUN / APPROVED_LOG / NOTIFY_DRY_RUN
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
QUEUE="$CONTRIB/ready-queue.json"
CONFIG="$CONTRIB/config.json"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
APPROVED_LOG="${APPROVED_LOG:-$MARTIN/approved.log}"
GH_BIN="${GH_BIN:-gh}"
TUNNEL_BIN="${TUNNEL_BIN:-tunnel}"
# DRY_RUN=true → 一切写路径只打印（C7）；默认 false
DRY_RUN="${APPROVAL_DRY_RUN:-false}"
LOG_DIR="$CONTRIB/logs"
LOG="$LOG_DIR/approval-execute.log"

REPO="NousResearch/hermes-agent"

log() { echo "[$(date '+%F %T')] approval-execute: $*" >> "$LOG"; }

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

# item 字段读取（统一走一个 jq 入口，防各处路径漂移）
jf() { # <jq 片段，内含 .id 占位由 --arg id 提供>
  jq -r --arg id "$ID" ".items[] | select(.id == \$id) | ${1}" "$QUEUE" 2>/dev/null
}

TTL_FAIL_REASON=""
fail() { # <原因> → 置 failed（仅当前态允许时）+ pipeline-failure 事件 + exit 1
  local reason="$1"
  log "execute ${ID} 失败: ${reason}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] rq.sh set ${ID} failed --note ${reason}"
    echo "[dry-run] notify.sh event pipeline-failure --key execute-fail-${ID}-$(date +%F) --summary execute ${ID} 失败: ${reason}"
    exit 1
  fi
  local cur
  cur="$(jf '.state')"
  if [[ "$cur" == "approved" ]]; then
    "$RQ" set "$ID" failed --note "$reason" >>"$LOG" 2>&1 || true
  fi
  "$NOTIFY" event pipeline-failure --key "execute-fail-${ID}-$(date +%F)" \
    --summary "execute ${ID}（verdict=${VERDICT}）失败: ${reason}" >>"$LOG" 2>&1 || true
  exit 1
}

# strip_leading_comments <file> → stdout
# 剥离头部 `<!-- ... -->` 注释块（可多块，块间空行一并跳过），其余行逐字输出（C8）
strip_leading_comments() {
  awk '
    BEGIN { scanning = 1; inblock = 0 }
    scanning {
      if ($0 ~ /^[[:space:]]*$/) next
      if (inblock) { if ($0 ~ /-->/) { inblock = 0 }; next }
      if ($0 ~ /^[[:space:]]*<!--/) {
        if ($0 ~ /-->/) next
        inblock = 1; next
      }
      scanning = 0
    }
    { print }
  ' "$1"
}

# TTL 复验四项（gh 只读；任一不过 → 不执行；机械筛选口径，语义级复核留给会话路）
# 形状容错口径（09-06 红队验收）：gh 空响应/非 JSON/缺字段一律归「复验失败」并给明确原因，
# 绝不误报成「非 OPEN」也绝不放行投递；仓库经 GH_REPO env 传递（argv 不带 repo 名，
# 兼容 gh 官方用法，也消除调用账/下游按 argv 分派的字符碰撞面）
ttl_verify() {
  # 1) issue 仍 OPEN
  local gh_out="" rc_gh=0 st=""
  gh_out="$(GH_REPO="$REPO" "$GH_BIN" issue view "$ISSUE" --json state 2>>"$LOG")" && rc_gh=0 || rc_gh=$?
  if (( rc_gh != 0 )); then
    TTL_FAIL_REASON="issue #${ISSUE} gh 查询失败（rc=${rc_gh}，网络/权限/仓库不可达？）"
    return 1
  fi
  if [[ -z "${gh_out//[[:space:]]/}" ]]; then
    TTL_FAIL_REASON="issue #${ISSUE} gh 空响应（复验失败，不放行）"
    return 1
  fi
  st="$(jq -r 'if (type == "object") and has("state") and (.state != null) then .state
                elif (type == "object") and has("state") then "STATE_NULL"
                else "SHAPE_ERROR" end' <<<"$gh_out" 2>/dev/null)"
  if [[ "$st" == "SHAPE_ERROR" || "$st" == "STATE_NULL" || -z "$st" || "$st" == "null" ]]; then
    TTL_FAIL_REASON="issue #${ISSUE} gh 响应形状异常（无 state 字段，复验失败不放行）：$(printf '%s' "$gh_out" | tr -d '\n' | head -c 80)"
    return 1
  fi
  if [[ "$st" != "OPEN" ]]; then
    TTL_FAIL_REASON="issue #${ISSUE} 状态=${st}（非 OPEN）"
    return 1
  fi
  # 2) in-body 无新占坑 PR（自身 item.pr 豁免；数组形=gh pr list 现状，items 包裹形=搜索 API 兼容）
  local prs own="${ITEM_PR}" foreign="" p
  prs="$(GH_REPO="$REPO" "$GH_BIN" pr list --search "${ISSUE} in:body" --state open --json number 2>>"$LOG" \
    | jq -r 'if type == "array" then ([.[].number | tostring] | join(","))
             elif (type == "object") and has("items") then ([.items[]?.number | tostring] | join(","))
             else "SHAPE_ERROR" end' 2>/dev/null)"
  if [[ "$prs" == "SHAPE_ERROR" ]]; then
    TTL_FAIL_REASON="issue #${ISSUE} gh pr list 响应形状异常（复验失败不放行）"
    return 1
  fi
  if [[ -n "$prs" ]]; then
    local old_ifs="$IFS"
    IFS=","
    for p in $prs; do
      [[ "$p" == "$own" ]] || foreign="${foreign}${foreign:+,} $p"
    done
    IFS="$old_ifs"
    if [[ -n "${foreign// /}" ]]; then
      TTL_FAIL_REASON="issue #${ISSUE} 已有在途 PR（${foreign} ）占坑"
      return 1
    fi
  fi
  # 3) premises 抽验（机械筛选：dead / claim / evidence 空缺即失败）
  local dead
  dead="$(jq -r --arg id "$ID" '
    [.items[] | select(.id == $id) | .premises[]? |
      select((.status // "alive") == "dead" or ((.claim // "") == "") or ((.evidence // "") == ""))] | length' \
    "$QUEUE" 2>/dev/null)"
  [[ "$dead" =~ ^[0-9]+$ ]] || dead=0
  if (( dead > 0 )); then
    TTL_FAIL_REASON="premises 抽验失败 ${dead} 条（dead/claim/evidence 空缺）"
    return 1
  fi
  # 4) 近 5 评论否决/重复信号（机械关键词筛选；.[]?/.body? 双形状容错，解析失败=不拦）
  local hits
  hits="$("$GH_BIN" api "repos/${REPO}/issues/${ISSUE}/comments?per_page=5" 2>>"$LOG" \
    | jq -r '[.[]? | ((.body? // "") | tostring) |
        test("not planned|wontfix|won.t fix|closing as|closed as|duplicate of"; "i")] | any' 2>/dev/null)"
  if [[ "$hits" == "true" ]]; then
    TTL_FAIL_REASON="issue #${ISSUE} 近 5 评论出现否决/重复信号"
    return 1
  fi
  return 0
}

do_approved() {
  # drill 件：跳过 gh 链与 approved.log（run 记录取代）；状态推进照常
  if (( IS_DRILL == 1 )); then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] drill 件：跳过 TTL 复验 / gh 投递 / approved.log（gh api -X POST repos/${REPO}/issues/${ISSUE}/comments）"
    else
      log "drill 件 ${ID}: 跳过 gh 链与 approved.log（run 记录取代，正文 $(wc -c <"$BODY_FILE" | tr -d ' ') 字节）"
    fi
    URL="drill://no-delivery/${ID}"
  else
    if ! ttl_verify; then
      fail "TTL 复验未过: ${TTL_FAIL_REASON}"
      return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] gh api -X POST repos/${REPO}/issues/${ISSUE}/comments -f body=- < ${BODY_FILE}"
      URL="dryrun://comment/${ID}"
    else
      # 投递走 stdin 字段（gh 官方语义：field 值 `-` = 从标准输入读），字节逐字、无 ARG_MAX 上限
      local resp rc_gh
      resp="$(cat "$BODY_FILE" | "$GH_BIN" api -X POST "repos/${REPO}/issues/${ISSUE}/comments" -f body=- 2>>"$LOG")" \
        && rc_gh=0 || rc_gh=$?
      (( rc_gh != 0 )) && { fail "gh 投递失败（issue #${ISSUE}，rc=${rc_gh}）"; return 0; }
      URL="$(jq -r 'if (type == "object") and ((.html_url? // "") | length > 0) then .html_url else "" end' <<<"$resp" 2>/dev/null)"
      if [[ -z "$URL" ]]; then
        # 形状容错：正常 gh 必回 html_url；异常形状以 issue 锚点兜底并显式标注未确认（不伪造评论锚）
        URL="https://github.com/${REPO}/issues/${ISSUE}#issuecomment-unconfirmed（gh 响应未含 html_url）"
        log "警告: issue #${ISSUE} POST 响应缺 html_url（$(printf '%s' "$resp" | tr -d '\n' | head -c 80)），台账以 issue 锚点兜底"
      fi
    fi
  fi

  # approved.log 追加（5 列不变；drill 跳过）
  if (( IS_DRILL == 0 )); then
    local line
    line="$(date "+%Y-%m-%dT%H:%M:%S%z") | hermes-contrib | issue #${ISSUE} ${DISP_CN}（tunnel 短码批准执行，rq ${ID}） | L2-A tunnel 短码批准（slug=${SLUG}） | ${URL}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] approved.log += ${line}"
    else
      printf '%s\n' "$line" >> "$APPROVED_LOG" 2>/dev/null || fail "approved.log 写入失败（路径/权限异常：${APPROVED_LOG}）"
      log "approved.log + ${ID}"
    fi
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] rq.sh set ${ID} executed --note ${URL}"
    [[ -n "$SLUG" ]] && { echo "[dry-run] tunnel rm ${SLUG}"; echo "[dry-run] rq.sh tunnel-removed ${ID}"; }
    echo "[dry-run] notify.sh receipt ${ID} --summary 已按短码批准投递 ${URL}"
    return 0
  fi
  "$RQ" set "$ID" executed --note "$URL" >>"$LOG" 2>&1 || { fail "rq set executed 失败"; return 0; }
  if [[ -n "$SLUG" ]]; then
    if "$TUNNEL_BIN" rm "$SLUG" >>"$LOG" 2>&1; then
      "$RQ" tunnel-removed "$ID" >>"$LOG" 2>&1 || true
    else
      log "tunnel rm ${SLUG} 失败（7 天 sweep 兜底）"
    fi
  fi
  "$NOTIFY" receipt "$ID" --summary "已按短码批准投递 ${URL}" >>"$LOG" 2>&1 \
    || log "receipt ${ID} 发送失败（记账与状态推进不受影响）"
  log "executed ${ID}（verdict=approved，drill=${IS_DRILL}，url=${URL}）"
  return 0
}

do_rejected() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] rq.sh set ${ID} rejected --note tunnel 短码否决"
    [[ -n "$SLUG" ]] && { echo "[dry-run] tunnel rm ${SLUG}"; echo "[dry-run] rq.sh tunnel-removed ${ID}"; }
    echo "[dry-run] notify.sh receipt ${ID} --summary 已否决（未执行，不进 approved.log）"
    return 0
  fi
  "$RQ" set "$ID" rejected --note "tunnel 短码否决${COMMENT:+: ${COMMENT}}" >>"$LOG" 2>&1 \
    || { fail "rq set rejected 失败"; return 0; }
  if [[ -n "$SLUG" ]]; then
    "$TUNNEL_BIN" rm "$SLUG" >>"$LOG" 2>&1 || log "tunnel rm ${SLUG} 失败（7 天 sweep 兜底）"
    "$RQ" tunnel-removed "$ID" >>"$LOG" 2>&1 || true
  fi
  "$NOTIFY" receipt "$ID" --summary "已否决（tunnel 短码批准页），未执行、不入账" >>"$LOG" 2>&1 \
    || log "receipt ${ID} 发送失败（不受影响）"
  log "rejected ${ID}（不进 approved.log）"
  return 0
}

do_revise() {
  local note="${COMMENT:-需修改（未附意见）}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] rq.sh set ${ID} revise --note ${note}"
    echo "[dry-run] notify.sh receipt ${ID} --summary 已记录修改意见，下轮重写"
    return 0
  fi
  "$RQ" set "$ID" revise --note "$note" >>"$LOG" 2>&1 || { fail "rq set revise 失败"; return 0; }
  "$NOTIFY" receipt "$ID" --summary "已记录修改意见，下轮深检窗口重写" >>"$LOG" 2>&1 \
    || log "receipt ${ID} 发送失败（不受影响）"
  log "revise ${ID}（意见已入 rq note；审批页留待 rq sweep/7 天强删兜底回收）"
  return 0
}

# ---------------- 入口 ----------------
ID="${1:-}"
VERDICT="${2:-}"
COMMENT="${3:-}"
[[ -n "$ID" && -n "$VERDICT" ]] || { echo "用法: execute.sh <id> <approved|rejected|revise> [comment]" >&2; exit 2; }
case "$VERDICT" in
  approved|rejected|revise) ;;
  *) echo "execute.sh: verdict 必须是 approved|rejected|revise（收到 ${VERDICT}）" >&2; exit 2 ;;
esac
[[ -f "$QUEUE" ]] || { echo "execute.sh: 队列不存在 ${QUEUE}" >&2; exit 2; }
mkdir -p "$LOG_DIR"

cur_state="$(jf '.state')"
[[ "$cur_state" == "approved" ]] || {
  echo "execute.sh: ${ID} 状态=${cur_state:-缺失}（须为 approved —— 消费标记由 collect.sh 置）" >&2
  exit 2
}

ISSUE="$(jf '.issue')"
ITEM_PR="$(jf '.pr // ""')"
[[ "$ITEM_PR" == "null" ]] && ITEM_PR=""
DRAFT="$(jf '.draft // ""')"
SLUG="$(jf '.tunnel.slug // ""')"
DISPOSITION="$(jf '.disposition')"
case "$DISPOSITION" in
  own-PR)          DISP_CN="own-PR 推进" ;;
  review-evidence) DISP_CN="evidence 评审" ;;
  probe-salvage)   DISP_CN="probe 取证" ;;
  *)               DISP_CN="$DISPOSITION" ;;
esac
IS_DRILL=0
[[ "$ID" == *-drill ]] && IS_DRILL=1

if [[ -z "$DRAFT" || ! -f "$DRAFT" ]]; then
  fail "草稿不存在（${DRAFT:-未登记}）"
  exit 1
fi

# own-PR 项不在确定性执行器范围（push 需 allow_own_pr_push 闸门 + 分支/worktree 上下文）：
# 保留 approved 态 + 事件，交回会话路人工执行（不 set failed——项本身没问题，是执行通道不匹配）
if [[ "$DISPOSITION" == "own-PR" && "$VERDICT" == "approved" && "$IS_DRILL" == "0" ]]; then
  log "own-PR ${ID}: 确定性执行器不投递，保留 approved 交回会话路（push 闸门+分支上下文需人工）"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] notify.sh event approval-manual-required --key own-pr-${ID} --summary own-PR ${ID} 已批，需会话路执行（push 闸门）"
  else
    "$NOTIFY" event approval-manual-required --key "own-pr-${ID}-$(date +%F)" \
      --summary "own-PR ${ID} 短码已批，确定性执行器不投递（push 闸门+分支上下文），请会话路执行" >>"$LOG" 2>&1 || true
  fi
  exit 0
fi

# 临时正文文件：macOS/BSD mktemp 要求 X 串在模板末尾（带 .md 后缀会 mkstemp 失败 →
# BODY_FILE 为空 → 09-06 红队实证投递链整体断裂），故后缀只留在进程内语义、不进模板
BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/contrib-exec-body-${ID}.XXXXXX")"
# B-3（QA 审查）：draft 正文是敏感临时件，任何退出路径都要清掉（fail() 各分支含在内）
trap 'rm -f "${BODY_FILE:-}" 2>/dev/null' EXIT
if [[ -z "$BODY_FILE" || ! -f "$BODY_FILE" ]]; then
  fail "临时正文文件创建失败（mktemp）"
  exit 1
fi
strip_leading_comments "$DRAFT" > "$BODY_FILE"

case "$VERDICT" in
  approved) do_approved ;;
  rejected) do_rejected ;;
  revise)   do_revise ;;
esac
rc=$?
rm -f "$BODY_FILE"
exit "$rc"
