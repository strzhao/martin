#!/bin/zsh
# coder_upstream_gate.sh — coder 卡 → 上游回馈评估闸门（09-11 洞察6；零 LLM 机械回扫）
#
# 零 LLM 回扫 default board done coder 卡：workspace_path 落 hermes-agent worktree 且本地
# 领先 origin/main 的修复卡 → contrib board 建「上游回馈评估」卡（contrib worker 异步研判
# verdict→forge/L2 或 justified-expired）。本机制绝不自动 push；不动 hermes-agent 源码；
# 不动 scripts/approval/execute.sh 与 approve 链。
#
# 条件链（fail-closed）：a(workspace_path) → b(目录存在 ∧ 领先 origin/main) → c(events.jsonl
# 无该 key) → d(未已投递：候选领先 commit 逐个 patch-id 与同仓 refs/heads/contrib/* ∪
# refs/remotes/fork/* 各 ref 头 commit 的 patch-id 比对；命中 ⇒ 零建卡、记
# coder-upstream-delivered 事件（与建卡同 key 保幂等）、游标由收尾统一推进；判重不可用/
# 单项不可得/空 diff ⇒ 跳过留痕保守放行——唯一 fail-open 例外）。判重新增 git 子命令闭集：
# {log --format=%H origin/main..HEAD, show <oid>, patch-id --stable, for-each-ref
# refs/heads/contrib refs/remotes/fork}，全只读零网络。
# 建卡调用以 env -u HERMES_KANBAN_DB 发起（D2）：剥离 worker 会话上下文注入的
# HERMES_KANBAN_DB（其解析优先级高于 --board），使 KANBAN_BOARD=contrib pin 在任何调用
# 上下文落到 contrib board；kanban_card.sh 语义零改动。
#
# 用法: coder_upstream_gate.sh   （单发无参数；带任何参数=用法错误）
#
# exit code: 0=正常完成（含零候选/全部被过滤） 1=查询失败或建卡/事件链失败（fail-closed，
#            零游标越前推进） 2=用法错误
#
# 数据: 状态游标 $CONTRIB/coder-upstream-cursor.json（schema 恰为 {"last_checked_epoch": <int>}，
#       原子写 tmp+mv；缺失/损坏视同 2026-07-01 00:00:00 本地时区 epoch——只首轮回扫存量，损坏
#       重建无害：事件 key 幂等挡重复卡）。评估卡 body $CONTRIB/card-bodies/
#       coder-upstream-<task_id>.body.md + 建卡回执 .card.json。自有日志 $CONTRIB/logs/
#       coder-upstream-gate.log；stdout 一行摘要。events.jsonl 唯一入账出口 = notify.sh event。
#       kanban.db 只读：python3 sqlite3 mode=ro URI（本机 sqlite3 -readonly 不可用 error 14）。
# seam: MARTIN_DIR（缺省 $HOME/workspace/martin）/ CONTRIB_DATA_DIR（缺省 $MARTIN/contrib-data）/
#       KANBAN_DB（缺省 $HOME/.hermes/kanban.db）/ KANBAN_BOARD（缺省 contrib，评估卡必须落
#       contrib board；测试可显式覆盖）
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
KANBAN_DB="${KANBAN_DB:-$HOME/.hermes/kanban.db}"
# 评估卡必须落 contrib board：seam 由调用环境透传 kanban_card.sh，缺省钉 contrib（测试可显式覆盖）
KANBAN_BOARD="${KANBAN_BOARD:-contrib}"
export KANBAN_BOARD
CURSOR="$CONTRIB/coder-upstream-cursor.json"
EVENTS="$CONTRIB/events.jsonl"
BODIES="$CONTRIB/card-bodies"
LOGDIR="$CONTRIB/logs"
LOG="$LOGDIR/coder-upstream-gate.log"
KANBAN_CARD="$MARTIN/scripts/contrib/kanban_card.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"

if [[ $# -gt 0 ]]; then
  echo "用法: coder_upstream_gate.sh（单发无参数；多余参数无效）" >&2
  exit 2
fi

mkdir -p "$LOGDIR"
TS="$(date +%Y-%m-%dT%H%M)"
log() { echo "[${TS}] $*" >>"$LOG"; }

# ---------- 游标读数（缺失/损坏 → init 2026-07-01 本地时区 epoch；内存基线不落盘，首个推进点才写） ----------
read_cursor() {
  local v=""
  if [[ -f "$CURSOR" ]]; then
    v="$(jq -r '.last_checked_epoch // empty' "$CURSOR" 2>/dev/null || true)"
  fi
  case "$v" in
    ''|*[!0-9]*)
      python3 -c 'import datetime; print(int(datetime.datetime(2026, 7, 1, 0, 0, 0).timestamp()))'
      ;;
    *) printf '%s' "$v" ;;
  esac
}

# ---------- 游标原子推进（tmp+mv） ----------
advance_cursor() { # <epoch>
  local tmp="${CURSOR}.tmp"
  jq -n --argjson e "$1" '{last_checked_epoch: $e}' >"$tmp" 2>>"$LOG" \
    && mv "$tmp" "$CURSOR" 2>>"$LOG"
}

CURSOR_EPOCH="$(read_cursor)"

# ---------- stage-1：kanban.db 只读查询（唯一允许的 sqlite 形态；失败 fail-closed） ----------
rows="$(python3 - "$KANBAN_DB" "$CURSOR_EPOCH" <<'PYEOF'
import json, sqlite3, sys

db_path, cursor = sys.argv[1], int(sys.argv[2])
try:
    conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
except sqlite3.Error as exc:
    print("db-open-failed: %s" % exc, file=sys.stderr)
    sys.exit(1)
try:
    cur = conn.execute(
        "SELECT id, title, completed_at, workspace_path FROM tasks"
        " WHERE assignee='coder' AND status='done' AND completed_at > ?"
        " ORDER BY completed_at ASC",
        (cursor,),
    )
    for row in cur.fetchall():
        print(json.dumps({"id": row[0], "title": row[1],
                          "completed_at": row[2], "workspace_path": row[3]},
                         ensure_ascii=False))
except sqlite3.Error as exc:
    print("query-failed: %s" % exc, file=sys.stderr)
    sys.exit(1)
finally:
    conn.close()
PYEOF
)" || {
  log "kanban.db 只读查询失败（db=${KANBAN_DB}）——本轮中止：零游标写零建卡"
  exit 1
}

# ---------- D1 patch-id 判重地基（条件 d；契约 8-10） ----------
# 跨候选缓存：DEDUP_OID_PID 缓存已换算的 ref 头 oid→patch-id；缓存键 = 判重 ref 清单整体
# （refname+oid 序列，for-each-ref 输出）——清单相同 ⇒ 头 commit oid 相同 ⇒ patch-id 相同，
# 语义自洽（生产所有候选同仓 ⇒ 每轮至多一次全量 ref 头换算；流式比对 first-hit 早退）。
DEDUP_OK=1
DEDUP_KEY=""
DEDUP_REFS=""
DUP_PID=""
typeset -A DEDUP_OID_PID

# dedup_item_pid <ws> <oid> → 全局 DUP_PID=patch-id 首列（空=空 diff/不可得）；rc=git 管道 rc
dedup_item_pid() {
  local out rc=0
  out="$(git -C "$1" show "$2" 2>>"$LOG" | git patch-id --stable 2>>"$LOG")" || rc=$?
  DUP_PID="${out%% *}"
  return "$rc"
}

# dedup_hit_ref <tid> <ws> → stdout 命中 ref 短名（无命中/不可判 = 空输出）
dedup_hit_ref() {
  local tid="$1" ws="$2"
  local reflist shas refline refname oid csha short
  reflist="$(git -C "$ws" for-each-ref refs/heads/contrib refs/remotes/fork 2>>"$LOG")" || {
    log "判重 ref 清单获取失败（放行留痕）: task=${tid}"
    reflist=""
  }
  if [[ "$reflist" != "$DEDUP_KEY" ]]; then
    DEDUP_KEY="$reflist"
    DEDUP_REFS="$reflist"
    DEDUP_OID_PID=()
  fi
  # 先算候选 patch-id 集（先集后流式比对；单项 git show 失败/对象缺失/空 diff ⇒ 跳过留痕）
  local -A cids
  cids=()
  shas="$(git -C "$ws" log --format=%H origin/main..HEAD 2>>"$LOG")" || shas=""
  while IFS= read -r csha; do
    [[ -n "$csha" ]] || continue
    if ! dedup_item_pid "$ws" "$csha"; then
      log "判重单项跳过（git show 失败/对象缺失）: task=${tid} sha=${csha}"
      continue
    fi
    if [[ -z "$DUP_PID" ]]; then
      log "判重单项跳过（空 diff 空 patch-id）: task=${tid} sha=${csha}"
      continue
    fi
    cids[$DUP_PID]=1
  done <<<"$shas"
  (( ${#cids[@]} > 0 )) || return 0
  # 流式比对 ref 头 patch-id（first-hit 早退；oid 级缓存跨候选复用）
  while IFS= read -r refline; do
    [[ -n "$refline" ]] || continue
    oid="${refline%% *}"
    refname="${refline#*$'\t'}"
    if [[ -n "${DEDUP_OID_PID[$oid]:-}" ]]; then
      DUP_PID="${DEDUP_OID_PID[$oid]}"
    else
      if ! dedup_item_pid "$ws" "$oid"; then
        log "判重 ref 头跳过（git show 失败/对象缺失）: task=${tid} ref=${refname} oid=${oid}"
        continue
      fi
      if [[ -z "$DUP_PID" ]]; then
        log "判重 ref 头跳过（空 diff 空 patch-id）: task=${tid} ref=${refname} oid=${oid}"
        continue
      fi
      DEDUP_OID_PID[$oid]="$DUP_PID"
    fi
    if [[ -n "${cids[$DUP_PID]:-}" ]]; then
      short="$refname"
      short="${short#refs/heads/}"
      short="${short#refs/remotes/}"
      printf '%s' "$short"
      return 0
    fi
  done <<<"$DEDUP_REFS"
  return 0
}

# patch-id 可用性探测（整轮一次性；rc≠0 ⇒ 本轮判重退化放行——契约 10 唯一 fail-open 例外）
if ! git patch-id --stable </dev/null >>"$LOG" 2>&1; then
  DEDUP_OK=0
  log "patch-id 探测失败——判重退化放行留痕：本轮全部候选仅按条件 a/b/c 过滤"
fi

# ---------- stage-2：升序逐卡过滤 + 命中处理（任一步失败即止本轮 = fail-closed） ----------
max_seen=""
scanned=0
hits=0
delivered=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  tid="$(jq -r '.id // ""' <<<"$row")"
  title="$(jq -r '.title // ""' <<<"$row")"
  done_at="$(jq -r '.completed_at // ""' <<<"$row")"
  ws="$(jq -r '.workspace_path // ""' <<<"$row")"
  [[ -n "$tid" && -n "$done_at" ]] || continue
  case "$done_at" in ''|*[!0-9]*) continue ;; esac
  scanned=$((scanned + 1))
  max_seen="$done_at"   # 行按 completed_at 升序 → 末次赋值即本轮 max

  # 条件 a：workspace_path 含 /hermes-agent/.worktrees/
  case "$ws" in
    */hermes-agent/.worktrees/*) : ;;
    *) continue ;;
  esac
  # 条件 b：目录存在 且 git log origin/main..HEAD 非空（git 失败视同不命中，进日志）
  if [[ ! -d "$ws" ]]; then
    log "过滤（worktree 目录缺失）: task=${tid}"
    continue
  fi
  ahead="$(git -C "$ws" log origin/main..HEAD --oneline 2>>"$LOG")" || {
    log "过滤（git 失败，视同不命中）: task=${tid} ws=${ws}"
    continue
  }
  ahead_n="$(printf '%s\n' "$ahead" | grep -c . || true)"
  if (( ahead_n < 1 )); then
    log "过滤（零领先 commit）: task=${tid}"
    continue
  fi
  # 条件 c：events.jsonl 无 coder-upstream-<tid>（notify.sh cmd_event 同款双格式 grep；
  # 文件不存在视同无 key）
  if grep -qF "\"key\":\"coder-upstream-${tid}\"" "$EVENTS" 2>/dev/null \
     || grep -qF "\"key\": \"coder-upstream-${tid}\"" "$EVENTS" 2>/dev/null; then
    log "过滤（事件 key 已在账，幂等跳过）: task=${tid}"
    continue
  fi
  # 条件 d：未已投递（D1 patch-id 判重；DEDUP_OK=0 时整轮退化放行——契约 8/10）
  title_flat="$(printf '%s' "$title" | tr '\n\t' '  ')"
  if (( DEDUP_OK )); then
    hit_ref="$(dedup_hit_ref "$tid" "$ws")"
    if [[ -n "$hit_ref" ]]; then
      # 命中已投递：零 body 零建卡；记 delivered 事件（与建卡同 key 保幂等），游标由收尾统一推进
      summary="coder 卡 ${tid}「${title_flat}」领先 origin/main ${ahead_n} commit，改动已投递上游（已投递 ref=${hit_ref}），不重复建评估卡"
      nrc=0
      bash "$NOTIFY" event coder-upstream-delivered \
        --key "coder-upstream-${tid}" \
        --summary "$summary" >>"$LOG" 2>&1 || nrc=$?
      if (( nrc != 0 )); then
        log "事件入账失败（task=${tid} rc=${nrc}）——游标不推（下轮重扫），本轮中止"
        exit 1
      fi
      delivered=$((delivered + 1))
      log "已投递跳过建卡: task=${tid} ahead=${ahead_n} ref=${hit_ref}（游标由收尾统一推进）"
      continue
    fi
  fi

  # ---- 命中：写 body → 建评估卡 → 事件入账 → 游标推进（顺序铁律） ----
  mkdir -p "$BODIES"
  body_file="$BODIES/coder-upstream-${tid}.body.md"
  card_json="$BODIES/coder-upstream-${tid}.card.json"
  wrc=0
  {
    printf '# contrib 上游回馈评估卡（coder_upstream_gate 自动生成）\n\n'
    printf '## 源卡信息\n'
    printf -- '- 源卡 id: %s\n' "$tid"
    printf -- '- 源卡标题: %s\n' "$title_flat"
    printf -- '- worktree 路径: %s\n' "$ws"
    printf -- '- contrib board 卡生成时间: %s\n' "$(date '+%F %T')"
    printf -- '- 领先 origin/main 的本地 commit（git log origin/main..HEAD --oneline）:\n'
    printf '%s\n' "$(printf '%s' "$ahead" | sed 's/^/  /')"
    printf '\n## 任务（上游回馈评估）\n\n'
    printf '按 %s/hermes-contribution.md 口径研判这份本地修复是否值得回馈上游：\n' "$MARTIN"
    printf -- '- 域契合：改动是否属于上游 hermes-agent 的核心域\n'
    printf -- '- 单关注点可剥离：commit 是否单一关注点、可独立成 PR\n'
    printf -- '- 上游空间占用：gh 实查上游是否已有同题在飞 PR/issue（只读检索）\n'
    printf -- '- 干净 cherry-pick：基于上游 current main 可否干净重放\n'
    printf '\n## verdict 分支\n'
    printf -- '- verdict=值得 → 走既有 forge/L2 链：rq.sh 入队 awaiting-approval，L2 批后才 push/开 PR。\n'
    printf '  本机制绝不允许自动 push，L2 闸门不豁免。\n'
    printf -- '- verdict=不值得 → rq 记录理由，终态 expired/shelved。\n'
    printf '\n## 红线（必须遵守）\n'
    printf -- '- gh 只读：零 issue/PR 写、零评论、零 push\n'
    printf -- '- rq.sh 只允许本地渠道动作\n'
    printf -- '- -q 模式禁脚本形态：python -c / jq -e / * -e 一律不可用\n'
    printf '\n## 收尾要求\n'
    printf -- '- 完成调 kanban_complete 时必须同时传 summary 与 result\n'
  } >"$body_file" 2>>"$LOG" || wrc=$?
  if (( wrc != 0 )); then
    log "body 写盘失败（task=${tid}）——本轮中止（fail-closed）"
    exit 1
  fi

  crc=0
  # D2 board pin：env -u 剥离 worker 会话注入的 HERMES_KANBAN_DB（解析优先级高于 --board），
  # 使 KANBAN_BOARD=contrib pin 在任何调用上下文落到 contrib board（契约 11）
  env -u HERMES_KANBAN_DB bash "$KANBAN_CARD" create --kind upstream \
    --title "contrib 上游回馈评估 ${tid}" \
    --body-file "$body_file" \
    --idempotency-key "coder-upstream-${tid}" \
    --json-out "$card_json" >>"$LOG" 2>&1 || crc=$?
  if (( crc != 0 )); then
    log "建卡失败（task=${tid} rc=${crc}）——不发事件不推游标，本轮中止（fail-closed）"
    exit 1
  fi

  summary="coder 卡 ${tid}「${title_flat}」领先 origin/main ${ahead_n} commit，待上游回馈评估"
  nrc=0
  bash "$NOTIFY" event coder-upstream-candidate \
    --key "coder-upstream-${tid}" \
    --summary "$summary" >>"$LOG" 2>&1 || nrc=$?
  if (( nrc != 0 )); then
    log "事件入账失败（task=${tid} rc=${nrc}）——游标不推（下轮重扫，建卡幂等键防重复卡），本轮中止"
    exit 1
  fi

  if ! advance_cursor "$done_at"; then
    log "游标推进失败（task=${tid}）——本轮中止（fail-closed）"
    exit 1
  fi
  hits=$((hits + 1))
  log "评估卡已建 coder-upstream-${tid}（ahead=${ahead_n} done_at=${done_at}），游标已推进"
done <<<"$rows"

# ---------- 收尾：无候选/全部被过滤 → 游标推进到本轮 max(completed_at)；零行不写 ----------
if [[ -n "$max_seen" ]] && (( max_seen > CURSOR_EPOCH )); then
  if ! advance_cursor "$max_seen"; then
    log "游标收尾推进失败——本轮中止（fail-closed）"
    exit 1
  fi
fi
log "回扫完成: scanned=${scanned} hits=${hits} delivered=${delivered}"
echo "coder-upstream-gate: scanned=${scanned} hits=${hits} delivered=${delivered}"
exit 0
