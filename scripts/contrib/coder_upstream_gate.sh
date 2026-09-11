#!/bin/zsh
# coder_upstream_gate.sh — coder 卡 → 上游回馈评估闸门（09-11 洞察6；零 LLM 机械回扫）
#
# 零 LLM 回扫 default board done coder 卡：workspace_path 落 hermes-agent worktree 且本地
# 领先 origin/main 的修复卡 → contrib board 建「上游回馈评估」卡（contrib worker 异步研判
# verdict→forge/L2 或 justified-expired）。本机制绝不自动 push；不动 hermes-agent 源码；
# 不动 scripts/approval/execute.sh 与 approve 链。
#
# 条件链（fail-closed）：a(workspace_path) → b(目录存在 ∧ 领先 origin/main) → c(events.jsonl
# 无该 key) → d(未已投递：候选领先 commit 逐个 patch-id 与 own-PR 判重面比对——面由
# own_pr_watch snapshot 界定（D4，替代第二段全量 refs/heads/contrib ∪ refs/remotes/fork 扫描）：
# headRefName 派生精确 refname（refs/heads/<name> ∪ refs/remotes/fork/<name>）本地解析命中项
# + headRefOid 直项，面项 ≤ DEDUP_FACE_MAX_REFS=400；命中 ⇒ 零建卡、记 coder-upstream-delivered
# 事件（与建卡同 key 保幂等）、游标由收尾统一推进；判重不可用/单项不可得/空 diff ⇒ 跳过留痕
# 保守放行；snapshot 缺失/损坏/为空 ⇒ 逐候选留痕 fail-open 放行（绝不回退全量 fork refs 扫描））。
# 判重 git 子命令闭集：{log --format=%H origin/main..HEAD, show <oid>, patch-id --stable,
# for-each-ref <snapshot 派生精确 refname 闭集，禁裸家族参数/通配，硬上界 400>}，全只读零网络。
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
# stderr 落自有日志（D4：db-open-failed/query-failed 附带 WAL 三件套诊断 hint，供排障）
rows="$(python3 - "$KANBAN_DB" "$CURSOR_EPOCH" 2>>"$LOG" <<'PYEOF'
import json, sqlite3, sys

db_path, cursor = sys.argv[1], int(sys.argv[2])
RO_HINT = ("hint: kanban.db 为 WAL 模式，mode=ro 只读打开需 kanban.db-wal / kanban.db-shm"
           " 在场（三件套齐拷）或 db 路径不可读")
try:
    conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
except sqlite3.Error as exc:
    print("db-open-failed: %s" % exc, file=sys.stderr)
    if "unable to open database file" in str(exc):
        print(RO_HINT, file=sys.stderr)
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
    if "unable to open database file" in str(exc):
        print(RO_HINT, file=sys.stderr)
    sys.exit(1)
finally:
    conn.close()
PYEOF
)" || {
  log "kanban.db 只读查询失败（db=${KANBAN_DB}）——本轮中止：零游标写零建卡"
  exit 1
}

# ---------- D4 patch-id 判重地基（条件 d；判重面 = own-PR snapshot own-PR 面） ----------
# 跨候选缓存：DEDUP_OID_PID 缓存已换算的面项 oid→patch-id；缓存键 = snapshot 文件原文
# （本轮不变 ⇒ 判重面只建一次；流式比对 first-hit 早退）。生产所有候选同仓 ⇒ 每轮至多一次
# 精确 refname 解析与面项 patch-id 换算（面项 ≤ DEDUP_FACE_MAX_REFS=400，亚秒级）。
DEDUP_OK=1
DEDUP_KEY="__face_uninit__"
SNAP="$CONTRIB/own-pr-watch-snapshot.json"
DEDUP_FACE_MAX_REFS=400
FACE_ST=""
FACE_LINES=""
DUP_PID=""
typeset -A DEDUP_OID_PID

# dedup_item_pid <ws> <oid> → 全局 DUP_PID=patch-id 首列（空=空 diff/不可得）；rc=git 管道 rc
dedup_item_pid() {
  local out rc=0
  out="$(git -C "$1" show "$2" 2>>"$LOG" | git patch-id --stable 2>>"$LOG")" || rc=$?
  DUP_PID="${out%% *}"
  return "$rc"
}

# dedup_oid_valid <oid> → rc 0 = 40..64 位小写十六进制全长 commit oid（方可作 snapshot 直项）
dedup_oid_valid() {
  local rest
  case "$1" in ''|[!0-9a-f]*) return 1 ;; esac
  rest="${1//[0-9a-f]/}"
  [[ -z "$rest" ]] || return 1
  (( ${#1} >= 40 && ${#1} <= 64 ))
}

# build_dedup_face <ws> → 全局 FACE_ST（""=面可用 / missing / corrupt）+ FACE_LINES
# （每行 display<TAB>oid）。面由 snapshot PR 列表界定（不按分支前缀猜 own-PR 面）：
# headRefName 派生精确 refname refs/heads/<name> + refs/remotes/fork/<name> 批量单次解析，
# 解析命中 ⇒ 面项 display = 剥 refs/heads/ / refs/remotes/ 前缀短名；headRefOid 形态合法
# ⇒ 直接口项（display = headRefName 非空取 headRefName，否则 PR #<number>）；二者皆缺
# ⇒ 条目跳过零面项。面项顺序：每 PR 内 heads 解析项 → fork 解析项 → oid 直项，PR 按
# snapshot 键序。missing/corrupt ⇒ 面不可用（调用方逐候选 fail-open 放行，绝不回退全量
# fork refs 扫描）。
build_dedup_face() { # <ws>
  local ws="$1" entries key hoid hname pre rn line oid rlout ncut=0
  local -a refnames
  local -A refseen RESOLVED
  FACE_ST=""
  FACE_LINES=""
  refnames=()
  refseen=()
  RESOLVED=()
  if [[ ! -f "$SNAP" ]]; then
    FACE_ST="missing"
    return 0
  fi
  if ! jq -e 'type=="object" and (.prs|type=="object")' "$SNAP" >/dev/null 2>&1; then
    FACE_ST="corrupt"
    return 0
  fi
  entries="$(jq -r '.prs | to_entries[] | [.key, (.value.headRefOid // ""), (.value.headRefName // "")] | @tsv' "$SNAP" 2>>"$LOG")" || {
    FACE_ST="corrupt"
    return 0
  }
  # 第一遍：snapshot 派生精确 refname 收集（去重；硬上界截断留痕——禁裸家族参数/通配的
  # 前提下，面宽度仍需有界）。切分用手动参数展开而非 IFS read：连续 tab 会被 IFS 折叠、
  # 空 headRefOid 字段被吞（name-only 条目整条失格，t8-04 S12 锚）。
  split_entry() { # <line> → 全局 E_KEY/E_HOID/E_HNAME（空字段保留）
    E_KEY="${1%%$'\t'*}"
    local rest="${1#*$'\t'}"
    E_HOID="${rest%%$'\t'*}"
    E_HNAME="${rest#*$'\t'}"
  }
  while IFS= read -r entry_line; do
    [[ -n "$entry_line" ]] || continue
    split_entry "$entry_line"
    key="$E_KEY" hoid="$E_HOID" hname="$E_HNAME"
    [[ -n "$hname" ]] || continue
    for pre in refs/heads refs/remotes/fork; do
      rn="${pre}/${hname}"
      [[ -n "${refseen[$rn]:-}" ]] && continue
      if (( ${#refnames[@]} >= DEDUP_FACE_MAX_REFS )); then
        ncut=$((ncut + 1))
        continue
      fi
      refseen[$rn]=1
      refnames+=("$rn")
    done
  done <<<"$entries"
  if (( ncut > 0 )); then
    log "判重面 refname 超硬上界 ${DEDUP_FACE_MAX_REFS}（截断 ${ncut} 个，留痕）"
  fi
  # 批量单次解析（读命令闭集内；失败按未解析处理，面相应收窄）
  if (( ${#refnames[@]} > 0 )); then
    rlout="$(git -C "$ws" for-each-ref "${refnames[@]}" 2>>"$LOG")" || {
      log "判重面 ref 解析失败（for-each-ref rc 非 0，按未解析处理）"
      rlout=""
    }
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      oid="${line%% *}"
      rn="${line##*$'\t'}"
      RESOLVED[$rn]="$oid"
    done <<<"$rlout"
  fi
  # 第二遍：按 PR 键序构造面项（heads 解析项 → fork 解析项 → oid 直项；同第一遍用
  # split_entry 手动切分保空字段）
  while IFS= read -r entry_line; do
    [[ -n "$entry_line" ]] || continue
    split_entry "$entry_line"
    key="$E_KEY" hoid="$E_HOID" hname="$E_HNAME"
    if [[ -n "$hname" ]]; then
      rn="refs/heads/${hname}"
      if [[ -n "${RESOLVED[$rn]:-}" ]]; then
        FACE_LINES="${FACE_LINES}${hname}"$'\t'"${RESOLVED[$rn]}"$'\n'
      fi
      rn="refs/remotes/fork/${hname}"
      if [[ -n "${RESOLVED[$rn]:-}" ]]; then
        FACE_LINES="${FACE_LINES}fork/${hname}"$'\t'"${RESOLVED[$rn]}"$'\n'
      fi
    fi
    if dedup_oid_valid "$hoid"; then
      if [[ -n "$hname" ]]; then
        FACE_LINES="${FACE_LINES}${hname}"$'\t'"${hoid}"$'\n'
      else
        FACE_LINES="${FACE_LINES}PR #${key}"$'\t'"${hoid}"$'\n'
      fi
    fi
  done <<<"$entries"
  return 0
}

# dedup_hit_ref <tid> <ws> → stdout 命中面项 display（无命中/不可判 = 空输出）
# D4：迭代 own-PR snapshot 判重面（FACE_LINES）替代原 for-each-ref 全量清单；
# snapshot 缺失/损坏/为空 ⇒ 逐候选留痕 fail-open 放行（跳过条件 d，绝不回退全量扫描）
dedup_hit_ref() {
  local tid="$1" ws="$2"
  local snap_raw shas csha faceline display oid
  snap_raw="$(cat "$SNAP" 2>>"$LOG" || true)"
  if [[ "$snap_raw" != "$DEDUP_KEY" ]]; then
    DEDUP_KEY="$snap_raw"
    DEDUP_OID_PID=()
    build_dedup_face "$ws"
  fi
  if [[ -n "$FACE_ST" || -z "$FACE_LINES" ]]; then
    log "判重跳过（own-PR snapshot 缺失/损坏/为空，fail-open 放行）: task=${tid}"
    return 0
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
  # 流式比对面项 patch-id（first-hit 早退；oid 级缓存跨候选复用）
  while IFS= read -r faceline; do
    [[ -n "$faceline" ]] || continue
    display="${faceline%%$'\t'*}"
    oid="${faceline##*$'\t'}"
    if [[ -n "${DEDUP_OID_PID[$oid]:-}" ]]; then
      DUP_PID="${DEDUP_OID_PID[$oid]}"
    else
      if ! dedup_item_pid "$ws" "$oid"; then
        log "判重 ref 头跳过（git show 失败/对象缺失）: task=${tid} ref=${display} oid=${oid}"
        continue
      fi
      if [[ -z "$DUP_PID" ]]; then
        log "判重 ref 头跳过（空 diff 空 patch-id）: task=${tid} ref=${display} oid=${oid}"
        continue
      fi
      DEDUP_OID_PID[$oid]="$DUP_PID"
    fi
    if [[ -n "${cids[$DUP_PID]:-}" ]]; then
      printf '%s' "$display"
      return 0
    fi
  done <<<"$FACE_LINES"
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
