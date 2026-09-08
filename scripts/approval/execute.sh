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
# tunnel CLI 装在 nvm node bin（launchd PATH 极简找不到——09-06 装载后实证 rc=127）：
# env seam 优先 → PATH 查找 → nvm 布局探测（同 collect.sh；被 collect 调起时继承其 export）
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
# 剥离头部 `<!-- ... -->` 注释块（可多块，块间空行一并跳过），其余行逐字输出（C8）；
# 并截掉「## 内部备注」起的尾部段（09-06 投递事故复盘：103568 草稿含内部备注段，
# 若不截断会随评论外泄——与审批页 payload 口径一致）
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
    /^## 内部备注/ { exit }
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
  # 09-06 语义修正：占坑检查只对 own-PR/probe-salvage 有意义（别人在建=我不建）；
  # review-evidence 的 PR 引用恰恰是评论对象/背景（「出现竞品→改判 review-evidence」既定打法），
  # 否则 teknium salvage 竞品这种最优解会被误判 premise 死亡（104067b 误杀实证）
  local prs own="${ITEM_PR}" foreign="" p
  if [[ "${DISPOSITION:-}" == "review-evidence" ]]; then
    prs=""
  else
  prs="$(GH_REPO="$REPO" "$GH_BIN" pr list --search "${ISSUE} in:body" --state open --json number 2>>"$LOG" \
    | jq -r 'if type == "array" then ([.[].number | tostring] | join(","))
             elif (type == "object") and has("items") then ([.items[]?.number | tostring] | join(","))
             else "SHAPE_ERROR" end' 2>/dev/null)"
  if [[ "$prs" == "SHAPE_ERROR" ]]; then
    TTL_FAIL_REASON="issue #${ISSUE} gh pr list 响应形状异常（复验失败不放行）"
    return 1
  fi
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
    # 落点（09-06 事故修复）：review-evidence 的载荷是 PR 评审，须落 item.pr（占坑车作者
    # 才会收到）；无 pr 锚（probe-salvage 等）才落 issue。TTL 复验仍锚 issue（premise 源）。
    local TARGET_NUM="${ITEM_PR:-$ISSUE}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] gh api -X POST repos/${REPO}/issues/${TARGET_NUM}/comments -F body=@${BODY_FILE}"
      URL="dryrun://comment/${ID}"
    else
      # 投递走 -F @file（gh 官方语义：-F 的 @路径=读文件；`-f body=-` 会把字面量 "-" 当正文——
      # 09-06 实证：-f 是 string field 不读 stdin，读 stdin 的 `-` 语义只属于 -F）
      local resp rc_gh
      resp="$("$GH_BIN" api -X POST "repos/${REPO}/issues/${TARGET_NUM}/comments" -F body=@"$BODY_FILE" 2>>"$LOG")" \
        && rc_gh=0 || rc_gh=$?
      (( rc_gh != 0 )) && { fail "gh 投递失败（#${TARGET_NUM}，rc=${rc_gh}）"; return 0; }
      URL="$(jq -r 'if (type == "object") and ((.html_url? // "") | length > 0) then .html_url else "" end' <<<"$resp" 2>/dev/null)"
      if [[ -z "$URL" ]]; then
        # 形状容错：正常 gh 必回 html_url；异常形状以 issue 锚点兜底并显式标注未确认（不伪造评论锚）
        URL="https://github.com/${REPO}/issues/${ISSUE}#issuecomment-unconfirmed（gh 响应未含 html_url）"
        log "警告: issue #${ISSUE} POST 响应缺 html_url（$(printf '%s' "$resp" | tr -d '\n' | head -c 80)），台账以 issue 锚点兜底"
      fi
    fi
  fi

  # approved.log 追加（5 列不变；drill 跳过）
  # 批准方式列随渠道区分：EXEC_CHANNEL=auto（deep-check 自动批准路）→ L2-auto 标记，供审计区分人工/自动
  local channel_label="L2-A tunnel 短码批准（slug=${SLUG}）"
  local receipt_verb="已按短码批准投递"
  if [[ "${EXEC_CHANNEL:-}" == "auto" ]]; then
    channel_label="L2-auto AI 高置信自动批准（auto-gate 放行）"
    receipt_verb="已自动批准并投递（AI 高置信，详见 runs/deep-check/${ID}/verdict.json）"
  fi
  if (( IS_DRILL == 0 )); then
    local line
    line="$(date "+%Y-%m-%dT%H:%M:%S%z") | hermes-contrib | issue #${ISSUE} ${DISP_CN}（${channel_label}执行，rq ${ID}） | ${channel_label} | ${URL}"
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
    echo "[dry-run] notify.sh receipt ${ID} --summary ${receipt_verb} ${URL}"
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
  "$NOTIFY" receipt "$ID" --summary "${receipt_verb} ${URL}" >>"$LOG" 2>&1 \
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

# own-PR 项不在确定性执行器范围（push 需分支/worktree 上下文）。
# 2026-09-08 lane 改造：contrib-cc 下线，own-PR 执行改走 coder lane 全自动——
#   allow_own_pr_push=false（急停总开关）→ approved 保留 + approval-manual-required 事件（人工路，不建卡）
#   =true → 探测 runs/*-issue<ISSUE>/BRANCH.md 分流建 coder 卡（dispatcher spawn worker 驱动 claude -p 执行）：
#     mode=push-only      BRANCH.md 存在且 worktree 校验通过 → --workspace dir:<worktree> --max-runtime 45m
#     mode=build-and-push 无 build 产物/校验失败回退    → --workspace worktree:<hermes-agent 仓> --branch fix/... --max-runtime 4h
#   rq 状态推进（set executed）由 worker 收尾执行，claude 不碰 martin 仓。建卡失败只记日志、不阻断事件链。
if [[ "$DISPOSITION" == "own-PR" && "$VERDICT" == "approved" && "$IS_DRILL" == "0" ]]; then
  log "own-PR ${ID}: 确定性执行器不投递，交 coder lane（allow_own_pr_push 闸门）"
  ALLOW_PUSH="$(cfg '.allow_own_pr_push' 'false')"
  if [[ "$ALLOW_PUSH" != "true" ]]; then
    log "own-PR ${ID}: allow_own_pr_push=false（急停），保留 approved 交会话路人工执行"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] notify.sh event approval-manual-required --key own-pr-${ID}-$(date +%F) --summary own-PR ${ID} 已批，allow_own_pr_push=false（急停），请会话路执行"
    else
      "$NOTIFY" event approval-manual-required --key "own-pr-${ID}-$(date +%F)" \
        --summary "own-PR ${ID} 短码已批，allow_own_pr_push=false（急停），请会话路执行" >>"$LOG" 2>&1 || true
    fi
    exit 0
  fi
  # 闸开：探测 build 产物定模式（dir: 对缺失路径会 mkdir 空目录——kanban_db.py 空目录陷阱，
  # 故必须 -d + git rev-parse 双校验，不满足回退 build-and-push）
  BRANCH_MD="$(ls -t "$CONTRIB"/runs/*-issue"${ISSUE}"/BRANCH.md 2>/dev/null | head -1 || true)"
  MODE="build-and-push"; WT_DIR=""; BRANCH_NAME=""
  if [[ -n "$BRANCH_MD" ]]; then
    WT_DIR="$(grep -m1 'worktree：`' "$BRANCH_MD" 2>/dev/null | sed -E 's/.*worktree：`([^`]+)`.*/\1/' || true)"
    BRANCH_NAME="$(head -n1 "$BRANCH_MD" 2>/dev/null | sed -E 's/^#[[:space:]]*BRANCH[[:space:]]*—[[:space:]]*//' || true)"
    case "$WT_DIR" in "~"*) WT_DIR="${HOME}/${WT_DIR#\~/}" ;; esac
    if [[ -z "$WT_DIR" || -z "$BRANCH_NAME" || ! -d "$WT_DIR" ]] \
      || ! git -C "$WT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      log "own-PR ${ID}: BRANCH.md 存在但 worktree 校验失败（${WT_DIR:-空}），回退 build-and-push"
      MODE="build-and-push"; WT_DIR=""; BRANCH_NAME=""
    else
      MODE="push-only"
    fi
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$MODE" == "push-only" ]]; then
      echo "[dry-run] hermes kanban create --assignee coder --idempotency-key ${ID} --max-runtime 45m --workspace dir:${WT_DIR}（own-PR ${ID} push-only 卡，分支 ${BRANCH_NAME}）"
    else
      echo "[dry-run] hermes kanban create --assignee coder --idempotency-key ${ID} --max-runtime 4h --workspace worktree:${HERMES_REPO_DIR:-$HOME/workspace/hermes-agent} --branch fix/issue${ISSUE}（own-PR ${ID} build-and-push 卡）"
    fi
    exit 0
  fi
  # HERMES_BIN 解析：env seam → PATH → ~/.local/bin（launchd PATH 极简）
  HERMES_BIN="${HERMES_BIN:-}"
  if [[ -z "$HERMES_BIN" ]]; then
    HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
  fi
  if [[ -z "$HERMES_BIN" && -x "$HOME/.local/bin/hermes" ]]; then
    HERMES_BIN="$HOME/.local/bin/hermes"
  fi
  if [[ -z "$HERMES_BIN" ]]; then
    log "own-PR ${ID}: hermes CLI 不可达（PATH 与 ~/.local/bin 均无），跳过建卡，事件链保留"
    "$NOTIFY" event approval-manual-required --key "own-pr-${ID}-$(date +%F)" \
      --summary "own-PR ${ID} 短码已批，但 hermes CLI 不可达无法建 coder 卡，请会话路执行" >>"$LOG" 2>&1 || true
    exit 0
  fi
  # 组卡 body（claude/worker 的唯一世界观，要素缺一 worker 即 block）
  BODY_LINES="类型: own-PR 执行（coder lane）
mode: ${MODE}
rq-id: ${ID} | issue: #${ISSUE} | pr: ${ITEM_PR:--} | disposition: ${DISPOSITION}
成稿（逐字投递载荷，启动 claude 前拷入 workspace）: ${DRAFT}"
  if [[ "$MODE" == "push-only" ]]; then
    BODY_LINES+="
分支档案: ${BRANCH_MD}
worktree: ${WT_DIR} | 分支: ${BRANCH_NAME} | push remote: fork（strzhao/hermes-agent；origin 是上游，push 必 403）
PR 锚点: gh pr create --repo NousResearch/hermes-agent --base main --head strzhao:${BRANCH_NAME}
timeout_budget: 1200"
  else
    BODY_LINES+="
worktree: 由 kanban 物化（\${HERMES_KANBAN_WORKSPACE}）| 分支: fix/issue${ISSUE} | push remote: fork（strzhao/hermes-agent；origin 是上游，push 必 403）
PR 锚点: gh pr create --repo NousResearch/hermes-agent --base main --head strzhao:fix/issue${ISSUE}
构建基线: 先 git fetch origin && git log 确认 origin/main 未触碰本次改动域（过老则 rebase 到最新 main 再构建）"
  fi
  BODY_LINES+="
红线: ① commit 一律不带 Co-Authored-By（上游惯例）② push 前 approved.log 近 20 行查 ${ID} 去重 + gh pr list --head <分支> 双重去重，已有 PR 则只收尾绝不重 push ③ 完成后由 worker（不是 claude）执行 rq.sh set ${ID} executed --note <pr_url>（按实际结果也可 revise/failed；claude 不碰 martin 仓）④ 失败按 claude-run SKILL 失败矩阵，重试 ≤2"
  KANBAN_ARGS=(kanban create "执行 own-PR: ${ID}（#${ITEM_PR:-issue ${ISSUE}}）"
    --assignee coder --idempotency-key "${ID}" --body "$BODY_LINES")
  if [[ "$MODE" == "push-only" ]]; then
    KANBAN_ARGS+=(--max-runtime 45m --workspace "dir:${WT_DIR}")
  else
    KANBAN_ARGS+=(--max-runtime 4h --workspace "worktree:${HERMES_REPO_DIR:-$HOME/workspace/hermes-agent}" --branch "fix/issue${ISSUE}")
  fi
  CARD_ID="$("$HERMES_BIN" "${KANBAN_ARGS[@]}" 2>>"$LOG" | grep -oE 't_[0-9a-f]+' | head -1 || true)"
  if [[ -n "${CARD_ID:-}" ]]; then
    log "own-PR ${ID}: coder 卡已建 ${CARD_ID}（mode=${MODE}，idempotency-key=${ID}）"
  else
    log "own-PR ${ID}: coder 卡创建失败（hermes CLI rc 非 0 或无卡 id），事件链保留"
    "$NOTIFY" event approval-manual-required --key "own-pr-${ID}-$(date +%F)" \
      --summary "own-PR ${ID} 短码已批，coder 卡创建失败，请会话路执行" >>"$LOG" 2>&1 || true
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
