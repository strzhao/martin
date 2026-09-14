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
#   own-PR approved 且分流为 refresh-branch（分支档案声明 refresh: yes + config allow_own_pr_refresh）
#   → 本执行器就地刷新既有 PR 的分支（fetch origin → rebase origin/main → 复推自家 fork）；
#     每次复推仍逐条 rq 批准（09-14 用户授权 L2-B，见 do_refresh_branch 注释）
#
# 环境变量 seam（沙箱测试用，生产缺省=真值）:
#   CONTRIB_DATA_DIR / MARTIN_DIR / TUNNEL_BIN / GH_BIN / GIT_BIN / APPROVAL_DRY_RUN / APPROVED_LOG / NOTIFY_DRY_RUN
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
QUEUE="$CONTRIB/ready-queue.json"
CONFIG="$CONTRIB/config.json"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
APPROVED_LOG="${APPROVED_LOG:-$MARTIN/approved.log}"
GH_BIN="${GH_BIN:-gh}"
# git 同 l2_ledger.sh 口径（env seam → 缺省真值）；refresh-branch 是唯一调用 git 的分支
GIT_BIN="${GIT_BIN:-git}"
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

# ── stalled-occupier 豁免（卡 t_b8ef4f58，2026-09-12）────────────────────────────
# 与 scripts/contrib/notify.sh 的 occ_all_stalled 同源（孪生实现），必须同步演进：改一处必改另一处。
# 语义：占用 PR 全部停摆 >21 天 → rc=0 豁免放行；任一活跃（≤21 天）→ rc=1 走原判死文案；
#       gh 取证失败/形状异常/无锚可算 → rc=2 fail-closed（TTL_FAIL_REASON 落可诊断原因，维持拦截）。
# ⚠️ 锚口径设计偏差（卡 body 定稿 updatedAt 实证不可用，全文见 worktree state.md 设计方案节）：
#   #84087 的 updatedAt=2026-09-10 是我方 evidence review 评论顶起来的，按 updatedAt 判停摆恒
#   「活跃」、豁免永不触发。故锚 =「占坑者自身最后动作」= max(commits[].committedDate ∪
#   本人评论 createdAt)；第三方评论只顶 updatedAt（仅日志留痕），不作锚。
# 零 LLM / 零新依赖 / gh 只读（每占用 PR 一次 pr view）；日期解析 macOS BSD date -j -f（仓内惯例）。
occ_all_stalled() { # <repo> <foreign_pr_csv> → rc 0=全部停摆放行 | 1=活跃占坑 | 2=fail-closed
  local repo="$1" csv="$2" p view_out rc_v calc anchor_iso up_iso anchor_ep days
  local now cutoff old_ifs
  now="$(date +%s)"
  cutoff=$(( 21 * 86400 ))
  old_ifs="$IFS"
  IFS=","
  for p in $csv; do
    view_out="$(GH_REPO="$repo" "$GH_BIN" pr view "$p" --json commits,author,comments,updatedAt 2>>"$LOG")" \
      && rc_v=0 || rc_v=$?
    if (( rc_v != 0 )) || [[ -z "${view_out//[[:space:]]/}" ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 取证失败（rc=${rc_v}），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    calc="$(jq -r '(.author.login // "") as $a |
      {anchor: (([.commits[]?.committedDate]
        + [.comments[]? | select((.author.login // "") == $a) | .createdAt | select(. != null)]) | max // ""),
        updatedAt: (.updatedAt // "")}' <<<"$view_out" 2>>"$LOG")"
    if [[ -z "$calc" ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 响应形状异常（jq 解析失败），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    anchor_iso="$(jq -r '.anchor // ""' <<<"$calc")"
    up_iso="$(jq -r '.updatedAt // ""' <<<"$calc")"
    if [[ -z "$anchor_iso" ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 既无 commit 也无作者评论（停摆锚不可算），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    anchor_ep="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$anchor_iso" "+%s" 2>/dev/null)" || true
    if [[ ! "${anchor_ep:-}" =~ ^[0-9]+$ ]]; then
      TTL_FAIL_REASON="gh pr view ${p} 停摆锚日期不可解析（anchor=${anchor_iso}），占坑判定 fail-closed"
      IFS="$old_ifs"
      return 2
    fi
    if (( now - anchor_ep > cutoff )); then
      days=$(( (now - anchor_ep) / 86400 ))
      log "stalled-occupier 豁免：#${p} 停摆 ${days} 天（anchor=${anchor_iso}，updatedAt=${up_iso}）"
    else
      IFS="$old_ifs"
      return 1
    fi
  done
  IFS="$old_ifs"
  return 0
}

# 占坑粒度收窄（卡 t_3f9b2a1c）：同伞形 issue 的兄弟腿不构成占坑。
# 现网缺口：占坑判定按「body 里提到该 issue 号的开放 PR」一刀切 ⇒ 伞形 issue 下的兄弟腿车
# （各自修**不同文件**、不同根因，如 #110728 的 5 腿）会把新开车误判 premise 死亡；而
# `rq.sh` 的 rejected 是终态且 id 含日期 ⇒ 误拦一次即烧掉当天该 issue 的提案槽。
# 判据（与 notify.sh 发卡前占坑闸孪生面同步演进，改一处必改另一处）：引用 PR 的变更文件集
# ∩ 我方待推分支的变更文件集 非空 ⇒ 真占坑（保留进判定）；空 ⇒ 兄弟腿，剔除。
# fail-closed：BRANCH.md/worktree 不可用、git 取证失败、或某 PR 的 files 取证失败 ⇒ 该项原样保留。
occ_overlap_filter() { # <repo> <pr_csv> <worktree> → stdout: 过滤后仍需按占坑判定的 csv
  local repo="$1" csv="$2" wt="$3" p pfiles out="" old_ifs ours_f pr_f
  ours_f="$(mktemp -t occ-ours.XXXXXX 2>/dev/null)" || { printf '%s' "$csv"; return 0; }
  pr_f="$(mktemp -t occ-pr.XXXXXX 2>/dev/null)" || { rm -f "$ours_f"; printf '%s' "$csv"; return 0; }
  if [[ -z "$wt" || ! -d "$wt" ]] \
    || ! "${GIT_BIN:-git}" -C "$wt" diff --name-only origin/main >"$ours_f" 2>/dev/null \
    || [[ ! -s "$ours_f" ]]; then
    rm -f "$ours_f" "$pr_f"; printf '%s' "$csv"; return 0
  fi
  old_ifs="$IFS"; IFS=","
  for p in $csv; do
    [[ -z "$p" ]] && continue
    pfiles="$(GH_REPO="$repo" "$GH_BIN" pr view "$p" --json files --jq '.files[].path' 2>/dev/null)" || pfiles=""
    if [[ -z "$pfiles" ]]; then
      out="${out}${out:+,}$p"; continue
    fi
    printf '%s\n' "$pfiles" >"$pr_f"
    if grep -Fxq -f "$ours_f" "$pr_f" 2>/dev/null; then
      out="${out}${out:+,}$p"
    fi
  done
  IFS="$old_ifs"
  rm -f "$ours_f" "$pr_f"
  printf '%s' "$out"
}

# TTL 复验四项（gh 只读；任一不过 → 不执行；机械筛选口径，语义级复核留给会话路）
# 形状容错口径（09-06 红队验收）：gh 空响应/非 JSON/缺字段一律归「复验失败」并给明确原因，
# 绝不误报成「非 OPEN」也绝不放行投递；仓库经 GH_REPO env 传递（argv 不带 repo 名，
# 兼容 gh 官方用法，也消除调用账/下游按 argv 分派的字符碰撞面）
# 第 2 项占坑判定带 stalled-occupier 豁免（occ_all_stalled，卡 t_b8ef4f58）：停摆 >21 天放行
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
  # ── own-PR refresh 路豁免（卡 t_fc3f1e9f）────────────────────────────────────
  # refresh 路（下方 MODE=refresh-branch）的动作对象就是 item.pr 自身 ⇒「该 issue 被别的车
  # 引用 / 被 salvage」恰是健康态，按占坑判死会误拦。与 notify.sh 发卡前占坑闸同谓词
  # （孪生面，改一处必改另一处）：item.pr 非空 + config allow_own_pr_refresh=true +
  # 该 issue 的 BRANCH.md 有独立行 refresh: yes；任一不满足 ⇒ 逐字节等价走原占坑判定。
  if [[ -n "$own" && "$own" != "null" && "$(cfg '.allow_own_pr_refresh' 'false')" == "true" ]]; then
    local bmd
    bmd="$(ls -t "$CONTRIB"/runs/*-issue"${ISSUE}"/BRANCH.md 2>/dev/null | head -1 || true)"
    if [[ -n "$bmd" ]] && grep -qE '^[[:space:]]*-?[[:space:]]*refresh:[[:space:]]*yes[[:space:]]*$' "$bmd" 2>/dev/null; then
      log "TTL 占坑复验：refresh 路豁免占坑检查（own-PR #$own 即动作对象，档案声明 refresh: yes）"
      prs=""
    fi
  fi
  # ── 占坑粒度收窄（卡 t_3f9b2a1c）：同伞形 issue 的兄弟腿（变更文件无交集）不构成占坑 ──
  # 前提 = 该 issue 有 BRANCH.md 且其 worktree 可用（我方待推分支的文件集可读）；
  # 不满足 ⇒ $prs 原样保留（fail-closed，与旧行为逐字节等价）。
  if [[ -n "$prs" ]]; then
    local bmd_ov wt_ov prs_before
    bmd_ov="$(ls -t "$CONTRIB"/runs/*-issue"${ISSUE}"/BRANCH.md 2>/dev/null | head -1 || true)"
    wt_ov=""
    [[ -n "$bmd_ov" ]] && wt_ov="$(grep -m1 'worktree：`' "$bmd_ov" 2>/dev/null | sed -E 's/.*worktree：`([^`]+)`.*/\1/' || true)"
    case "$wt_ov" in "~"*) wt_ov="$HOME/${wt_ov#\~/}" ;; esac
    if [[ -n "$wt_ov" && -d "$wt_ov" ]]; then
      prs_before="$prs"
      prs="$(occ_overlap_filter "$REPO" "$prs" "$wt_ov")"
      [[ "$prs" == "$prs_before" ]] || log "TTL 占坑复验：粒度收窄（兄弟腿剔除）$prs_before → ${prs:-空}"
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
      # 停摆豁免（卡 t_b8ef4f58）：占用 PR 全部停摆 >21 天 → 不判 premise 死亡，放行并留痕，
      # 但只跳过占坑判死，第 3/4 项（premises 抽验/评论否决信号）照走；
      # rc=2（gh 取证失败/锚不可算）时 TTL_FAIL_REASON 已带可诊断原因，直接 fail-closed 拦截。
      local occ_rc=0
      occ_all_stalled "$REPO" "${foreign// /}" || occ_rc=$?
      if (( occ_rc == 2 )); then
        return 1
      elif (( occ_rc != 0 )); then
        TTL_FAIL_REASON="issue #${ISSUE} 已有在途 PR（${foreign} ）占坑"
        return 1
      fi
      log "TTL 占坑复验：issue #${ISSUE} 占用 PR 全部停摆超限，stalled-occupier 豁免放行"
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
  # 4) 近 5 评论否决/重复信号——两层判读（09-10 rq-107156 两连误报沉淀）：
  #    层1 机械哨兵（零 LLM）：关键词字面命中 → 层2 AI 语义判读（ttl_comment_judge.sh，
  #    hermes -z 主判 + claude -p 备胎）：窗口内有无后续撤销/改判/反驳，PASS=放行。
  #    判读者不可用（exit 3）→ 回退机械结果 fail-closed，绝不因判读层缺失放行。
  #    快照契约：判读者只看评论原文，不给 issue 其他上下文（防幻觉扩张）。
  local hits verdict
  hits="$(GH_REPO="$REPO" "$GH_BIN" api "repos/${REPO}/issues/${ISSUE}/comments?per_page=5" 2>>"$LOG" \
    | jq -r '[.[]? | ((.body? // "") | tostring) |
        test("not planned|wontfix|won.t fix|closing as|closed as|duplicate of"; "i")] | any' 2>/dev/null)"
  if [[ "$hits" == "true" ]]; then
    if JUDGE_BIN="${JUDGE_BIN:-}" REPO="$REPO" ISSUE="$ISSUE" GH_BIN="$GH_BIN" LOG="$LOG" \
      bash "$MARTIN/scripts/approval/ttl_comment_judge.sh" >>"$LOG" 2>&1; then
      verdict="$(tail -1 "$LOG" | grep -Eo 'PASS|BLOCK' | tail -1)"
      if [[ "$verdict" == "PASS" ]]; then
        log "TTL 否决信号机械命中但语义判读 PASS（窗口内已撤销/改判），放行 issue #${ISSUE}"
        return 0
      elif [[ "$verdict" == "BLOCK" ]]; then
        TTL_FAIL_REASON="issue #${ISSUE} 语义判读 BLOCK（否决信号成立且无撤销）"
        return 1
      fi
    fi
    # 判读层不可用（exit 3 或输出无法解析）→ 机械结果兜底（fail-closed）
    TTL_FAIL_REASON="issue #${ISSUE} 近 5 评论出现否决/重复信号（语义判读不可用，机械兜底拦截）"
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

do_release_gate() { # release-gate approved：hm release approve 回验 → token 签发 → 链式 submit
  # hm CLI 解析：env seam → PATH → nvm 布局探测（同 hermes/tunnel 先例；launchd PATH 极简）
  HM_BIN="${HM_BIN:-}"
  if [[ -z "$HM_BIN" ]]; then
    HM_BIN="$(command -v hm 2>/dev/null || true)"
  fi
  if [[ -z "$HM_BIN" && -x "$HOME/.local/bin/hm" ]]; then
    HM_BIN="$HOME/.local/bin/hm"
  fi
  if [[ -z "$HM_BIN" ]]; then
    _hm_cand="$(ls -t "$HOME"/.nvm/versions/node/*/bin/hm 2>/dev/null | head -1 || true)"
    [[ -n "$_hm_cand" ]] && HM_BIN="$_hm_cand"
  fi
  if [[ -z "$HM_BIN" ]]; then
    fail "hm CLI 不可达（HM_BIN/PATH/nvm 布局均未命中），release-gate 无法链式提审"
    return 0
  fi
  # launchd 运行环境（B3）：显式 export PATH（nvm bin）与 HM_CREDENTIALS。
  # 凭据文件磁盘实名是 ~/.hm/private.json（AGC Service Account 导出名）；credentials.json
  # 是历史假设名——09-12 实证两者不一致时静默缺凭据 → hm release approve 必败，两处都探。
  if [[ -n "${HM_NVM_BIN_DIR:-}" ]]; then
    PATH="${HM_NVM_BIN_DIR}:${PATH}"; export PATH
  fi
  if [[ -z "${HM_CREDENTIALS:-}" ]]; then
    if [[ -f "$HOME/.hm/private.json" ]]; then
      export HM_CREDENTIALS="$HOME/.hm/private.json"
    elif [[ -f "$HOME/.hm/credentials.json" ]]; then
      export HM_CREDENTIALS="$HOME/.hm/credentials.json"
    fi
  fi
  # 队列路径显式传递（approve 回验读 HM_RQ_QUEUE；不依赖 CONTRIB_DATA_DIR 透传链）
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] HM_RQ_QUEUE=${QUEUE} HM_CREDENTIALS=${HM_CREDENTIALS:-<unset>} ${HM_BIN} release approve --gate ${ID}"
    echo "[dry-run] rq.sh set ${ID} executed --note gate-token-issued-submit-chained"
    [[ -n "$SLUG" ]] && { echo "[dry-run] tunnel rm ${SLUG}"; echo "[dry-run] rq.sh tunnel-removed ${ID}"; }
    echo "[dry-run] notify.sh receipt ${ID} --summary 发版门已批，链式提审完成"
    return 0
  fi
  log "release-gate ${ID}: 调 hm release approve（回验 + token + 链式 submit）"
  if ! HM_RQ_QUEUE="$QUEUE" "$HM_BIN" release approve --gate "$ID" >>"$LOG" 2>&1; then
    fail "hm release approve 失败（回验拒签或链式提审失败，详见 ${LOG}）"
    return 0
  fi
  log "release-gate ${ID}: approve 成功（token 已消费），推进 executed"
  "$RQ" set "$ID" executed --note "发版门已批：gate token 签发 + 链式提审完成" >>"$LOG" 2>&1 \
    || { fail "rq set executed 失败"; return 0; }
  # approved.log 台账（与 own-PR 审计口径一致；issue 列 = 合成号，标注 release-gate 语境）
  local line
  line="$(date "+%Y-%m-%dT%H:%M:%S%z") | hermes-contrib | issue #${ISSUE} 发版提审门（release-gate，L2-A tunnel 短码批准 slug=${SLUG}） | release-gate | hm-release-approve"
  printf '%s\n' "$line" >> "$APPROVED_LOG" 2>/dev/null || log "approved.log 写入失败（路径/权限异常：${APPROVED_LOG}）"
  if [[ -n "$SLUG" ]]; then
    if "$TUNNEL_BIN" rm "$SLUG" >>"$LOG" 2>&1; then
      "$RQ" tunnel-removed "$ID" >>"$LOG" 2>&1 || true
    else
      log "tunnel rm ${SLUG} 失败（7 天 sweep 兜底）"
    fi
  fi
  "$NOTIFY" receipt "$ID" --summary "发版门已批：hm release approve 链式提审完成（token 单次消费）" >>"$LOG" 2>&1 \
    || log "receipt ${ID} 发送失败（记账与状态推进不受影响）"
  log "executed ${ID}（release-gate 全链完成）"
  return 0
}

# ── refresh-branch：刷新我方既有 PR 的分支（09-14 用户授权 L2-B；approved.log pr=65100 锚）─────
# 授权原文（用户 2026-09-14 11:36 会话内明示，已挂 approved.log）：「放宽自家 fork force-push
#   边界——允许对 6 辆 CONFLICTING PR 做 rebase + 复推（只打自家 fork，不碰上游仓）。此为本次
#   动作类的原则性首批；之后每次实际复推仍逐条走微信批准（L2 纪律不变）。」
# ⇒ 本模式**不豁免审批**、execute.sh **不自批**：只由 tunnel 短码批准（L2-A）或会话内明示
#   （L2-B）驱动的 execute.sh 调用触达；own-PR 恒 L2-A/L2-B，永不 L2-auto。
# 三重闸（任一不满足即与今日行为逐字节等价）：主闸 allow_own_pr_push=true（上方已判，急停优先）
#   + config allow_own_pr_refresh=true（缺省 false）+ 分支档案声明 refresh: yes。
# 形态（全文件唯一 push 形态；falsify 锚 = 本文件含 force 字样的行恒 =1）：
#   fetch origin → rebase origin/main → push 只打自家 fork（禁 push 上游仓、禁裸 force、
#   禁 gh pr create、禁 main/master —— 后两条由「不调 gh pr create」+「只推 BRANCH.md 声明的功能分支」保证）。
# 失败姿态：不回滚 rebase、不改 worktree（现场保留供重试）；rq → failed + pipeline-failure 事件。
do_refresh_branch() {
  local FORK_REMOTE="fork" url="" cur="" pr_url="" line=""
  local -a REFRESH_PUSH_ARGS
  REFRESH_PUSH_ARGS=(push --force-with-lease "$FORK_REMOTE" "$BRANCH_NAME")
  if [[ -z "$ITEM_PR" ]]; then
    fail "refresh-branch 缺 PR 锚（item.pr 为空）：本模式只刷新既有 PR 的分支"
    return 1
  fi
  pr_url="https://github.com/${REPO}/pull/${ITEM_PR}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] git -C ${WT_DIR} fetch origin"
    echo "[dry-run] git -C ${WT_DIR} rebase origin/main"
    echo "[dry-run] git -C ${WT_DIR} ${REFRESH_PUSH_ARGS[*]}"
    echo "[dry-run] rq.sh set ${ID} executed --note ${pr_url}"
    [[ -n "$SLUG" ]] && { echo "[dry-run] tunnel rm ${SLUG}"; echo "[dry-run] rq.sh tunnel-removed ${ID}"; }
    echo "[dry-run] notify.sh receipt ${ID} --summary 已按短码批准刷新既有 PR 分支"
    return 0
  fi
  # ① 远端校验：必须存在且**不指向上游仓**（URL 含 NousResearch/ 即拒；同 l2_ledger.sh 口径）
  url="$("$GIT_BIN" -C "$WT_DIR" remote get-url "$FORK_REMOTE" 2>/dev/null)" || url=""
  if [[ -z "$url" ]]; then
    fail "refresh-branch: worktree ${WT_DIR} 无 ${FORK_REMOTE} 远端（复推必须打自家 fork）"
    return 1
  fi
  case "$url" in
    *NousResearch/*) fail "refresh-branch: ${FORK_REMOTE} 指向上游仓（${url}），拒绝复推（只打自家 fork）" ; return 1 ;;
  esac
  # ② 分支一致 + 工作区干净（防 rebase 打到别的分支 / 带脏改动起 rebase）
  cur="$("$GIT_BIN" -C "$WT_DIR" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [[ "$cur" != "$BRANCH_NAME" ]]; then
    fail "refresh-branch: worktree HEAD=${cur:-detached} 与分支档案声明的分支=${BRANCH_NAME} 不一致"
    return 1
  fi
  if [[ -n "$("$GIT_BIN" -C "$WT_DIR" status --porcelain 2>/dev/null)" ]]; then
    fail "refresh-branch: worktree 有未提交改动，拒绝 refresh（现场保留）"
    return 1
  fi
  log "refresh-branch ${ID}: 刷新 PR #${ITEM_PR} 分支 ${BRANCH_NAME}（worktree=${WT_DIR}，push 只打 ${FORK_REMOTE}）"
  # ③ fetch origin（只读上游）→ rebase origin/main；冲突/脏树不干净即 abort，worktree 回原状
  if ! "$GIT_BIN" -C "$WT_DIR" fetch origin >>"$LOG" 2>&1; then
    fail "refresh-branch: git fetch origin 失败（现场保留）"
    return 1
  fi
  if ! "$GIT_BIN" -C "$WT_DIR" rebase origin/main >>"$LOG" 2>&1; then
    "$GIT_BIN" -C "$WT_DIR" rebase --abort >>"$LOG" 2>&1 || true
    fail "refresh-branch: rebase origin/main 未干净通过（已 abort，worktree 回到原状）"
    return 1
  fi
  # ④ 复推（唯一形态，见 REFRESH_PUSH_ARGS）；失败不回滚，rebased 现场保留供重试
  if ! "$GIT_BIN" -C "$WT_DIR" "${REFRESH_PUSH_ARGS[@]}" >>"$LOG" 2>&1; then
    fail "refresh-branch: 复推 ${FORK_REMOTE}/${BRANCH_NAME} 失败（rebased 现场保留，未回滚）"
    return 1
  fi
  # ⑤ 台账 + 状态推进 + 回执（台账 5 列口径与 do_approved 一致；渠道标签恒 L2-A 人工批准）
  line="$(date "+%Y-%m-%dT%H:%M:%S%z") | hermes-contrib | issue #${ISSUE} PR #${ITEM_PR} 分支刷新（refresh-branch，L2-A tunnel 短码批准（slug=${SLUG}）执行，rq ${ID}） | refresh-branch | ${pr_url}"
  printf '%s\n' "$line" >> "$APPROVED_LOG" 2>/dev/null || { fail "approved.log 写入失败（路径/权限异常：${APPROVED_LOG}）"; return 1; }
  log "approved.log + ${ID}（refresh-branch，pr=#${ITEM_PR}）"
  "$RQ" set "$ID" executed --note "$pr_url" >>"$LOG" 2>&1 || { fail "rq set executed 失败"; return 1; }
  if [[ -n "$SLUG" ]]; then
    if "$TUNNEL_BIN" rm "$SLUG" >>"$LOG" 2>&1; then
      "$RQ" tunnel-removed "$ID" >>"$LOG" 2>&1 || true
    else
      log "tunnel rm ${SLUG} 失败（7 天 sweep 兜底）"
    fi
  fi
  "$NOTIFY" receipt "$ID" --summary "已按短码批准刷新既有 PR 分支并复推自家 fork：${pr_url}" >>"$LOG" 2>&1 \
    || log "receipt ${ID} 发送失败（记账与状态推进不受影响）"
  log "executed ${ID}（verdict=approved，mode=refresh-branch，pr=#${ITEM_PR}，worktree 未回滚）"
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
  # refresh-branch 闸门（09-14 用户授权）：config 缺键/false 或分支档案未声明 refresh: yes
  # ⇒ 走原路（对既有 push-only/build-and-push 路径逐字节等价）
  ALLOW_REFRESH="$(cfg '.allow_own_pr_refresh' 'false')"
  # 声明形态宽容：行首（可带列表符 `- `）`refresh: yes` 独立一行即认；其它值/缺失 ⇒ 不启用
  REFRESH_DECL=""
  if [[ -n "$BRANCH_MD" ]] && grep -qE '^[[:space:]]*-?[[:space:]]*refresh:[[:space:]]*yes[[:space:]]*$' "$BRANCH_MD" 2>/dev/null; then
    REFRESH_DECL="yes"
  fi
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
      if [[ "$REFRESH_DECL" == "yes" && "$ALLOW_REFRESH" == "true" ]]; then
        MODE="refresh-branch"
        log "own-PR ${ID}: 档案声明 refresh: yes + allow_own_pr_refresh=true → mode=refresh-branch（就地刷新既有 PR 分支）"
      else
        MODE="push-only"
      fi
    fi
  fi
  if [[ "$MODE" == "refresh-branch" ]]; then
    do_refresh_branch
    exit $?
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

# release-gate 分支（2026-09-09，hm release 发版批准门，research/15 D4）：
# 插在 draft 检查后、ttl_verify 之前——issue 为 appId 合成号，gh TTL 复验（issue OPEN/占坑/
# premises 抽验/评论信号）不适用；分流退出防合成号进 gh 查询。drill 件落 do_approved 的
# drill 路（跳过 gh 链，状态推进照常）。rejected/revise 沿通用路（rq 状态机 + receipt）。
if [[ "$DISPOSITION" == "release-gate" && "$VERDICT" == "approved" && "$IS_DRILL" == "0" ]]; then
  do_release_gate
  exit $?
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
