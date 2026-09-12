#!/usr/bin/env bash
# state_brief.sh — contrib 域值班卡单一 state brief 生成器（零 LLM 零网络）
#
# 问题：contrib 域值班卡需要人肉跨六源拼状态（contrib board、主 board、ready-queue、
# budget、flight 登记、events.jsonl），漏看任一源就会漏掉孤儿卡/深检单飞槽死锁/
# gave_up 秒崩循环/预算撞顶这类伤情（设计文档 contrib-ops-ai-native-design.md §3-C1）。
#
# 方案：单文件 bash 聚合六源只读采集，产出单一 state brief（md，stdout）——每节
# 带机器锚定的「伤情判定」行（正常/注意/告警/degraded），值班卡按节直接行动。
# 采集面任何失败不产生非零 exit：源不可用只降级本节（标 [degraded]），不中断不静默。
#
# 用法：
#   state_brief.sh [--out <file>] [--selftest]
#     --out <file>   额外落一份与 stdout 完全一致的 md 文件（落盘失败 exit 2）
#     --selftest     内嵌 fixture 自测（mktemp 树，绝不触生产六源）
#   exit 闭集：0=成功（brief 含 degraded 亦 0；selftest 全绿亦 0）
#             2=用法错误（未知 flag、--out 缺参、--out 落盘失败）
#
# seam（selftest 注入用，生产缺省不设）：
#   STATE_BRIEF_CONTRIB_DB  contrib board sqlite（缺省 ~/.hermes/kanban/boards/contrib/kanban.db）
#   STATE_BRIEF_MAIN_DB     主 board sqlite（缺省 ~/.hermes/kanban.db）
#   CONTRIB_DATA_DIR        数据目录（缺省 ${MARTIN_DIR:-$HOME/workspace/martin}/contrib-data）
#
# 实现要点：
#   - bash 3.2 兼容（禁关联数组/mapfile/${var,,}）；set -uo pipefail 不设 -e。
#   - 只读红线：ro_sqlite 是唯一 sqlite 入口；写面仅 mktemp 与 --out 显式路径。
#   - ro_sqlite 先 file:<db>?mode=ro，非零退出优雅回退 file:<db>?mode=ro&immutable=1，
#     同一函数内回退、不因此标 degraded；两形态皆败才由调用方降级本节。
#     immutable=1 按文件快照读、忽略 WAL——主 board WAL 头但无 -shm/-wal，
#     mode=ro 报 error 14（patterns.md 2026-09-11 + 2026-09-13 实测复现），immutable 恰配。
#   - sqlite3 -json 空结果集输出空串（3.51.0 实测）→ 归一化为 []。
#   - events.jsonl 双序列化形态并存（jq 紧凑 vs python json.dumps 带空格）：
#     必须 jq -R 'fromjson?' 归一化（不带 -R 时 jq 自动解析对象，fromjson? 会
#     静默吞掉一切——patterns.md 2026-09-09 + 2026-09-13 实测复现），禁单形态 grep。
#   - 变量一律 ${var} 花括号形态（gate 全角 regex 门：$var 紧跟全角标点即中招）。
set -uo pipefail

# ---------- 常量与 seam ----------
SCRIPT_PATH="${BASH_SOURCE[0]}"
case "${SCRIPT_PATH}" in
  /*) ;;
  *) SCRIPT_PATH="$(pwd)/${SCRIPT_PATH}" ;;
esac

CONTRIB_DB="${STATE_BRIEF_CONTRIB_DB:-$HOME/.hermes/kanban/boards/contrib/kanban.db}"
MAIN_DB="${STATE_BRIEF_MAIN_DB:-$HOME/.hermes/kanban.db}"
CONTRIB_DATA="${CONTRIB_DATA_DIR:-${MARTIN_DIR:-$HOME/workspace/martin}/contrib-data}"
RQ_FILE="${CONTRIB_DATA}/ready-queue.json"
BUDGET_FILE="${CONTRIB_DATA}/budget.json"
EVENTS_FILE="${CONTRIB_DATA}/events.jsonl"
FLIGHT_DEEPCHECK_FILE="${CONTRIB_DATA}/kanban-flight-deepcheck.json"

# 终态闭集（contrib board 实证：done/archived/cancelled）
TERMINAL_SQL="'done','archived','cancelled'"
# rq 终态闭集（ready-queue 实证；孤儿判定用）
RQ_TERMINAL_RE='^(executed|expired|rejected|shelved)$'

OUT_FILE=""
SELFTEST=0

WORK_DIR=""
ST_TREE=""
cleanup() {
  [[ -n "${WORK_DIR:-}" ]] && rm -rf "${WORK_DIR}"
  [[ -n "${ST_TREE:-}" ]] && rm -rf "${ST_TREE}"
  return 0
}
trap cleanup EXIT

# ---------- 用法 / exit 2 ----------
usage_die() { # <原因>
  printf '用法错误: %s\n' "$1" >&2
  printf '用法: state_brief.sh [--out <file>] [--selftest]\n' >&2
  exit 2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out)
        [[ $# -ge 2 ]] || usage_die "--out 缺参数"
        OUT_FILE="$2"
        shift 2
        ;;
      --selftest)
        SELFTEST=1
        shift
        ;;
      *)
        usage_die "未知 flag: $1"
        ;;
    esac
  done
}

# ---------- 公共件 ----------
HAVE_SQLITE3=0
HAVE_JQ=0
NOW=0
TODAY=""
WEEKKEY=""

init_env() {
  command -v sqlite3 >/dev/null 2>&1 && HAVE_SQLITE3=1
  command -v jq >/dev/null 2>&1 && HAVE_JQ=1
  NOW="$(date +%s)"
  TODAY="$(date +%F)"
  # ISO 周键 BSD date %G-W%V（2026-09-13→2026-W37，与 budget 账本键一致，实测）
  WEEKKEY="$(date +%G-W%V)"
  return 0
}

# parse_iso_ts <ts> → epoch；失败输出空。
# BSD date %z 不认 +08:00 带冒号形态（实测 Failed conversion），先去掉时区冒号。
parse_iso_ts() {
  local ts="${1:-}"
  [[ -n "${ts}" ]] || return 1
  if [[ "${ts}" =~ [+-][0-9][0-9]:[0-9][0-9]$ ]]; then
    local len=${#ts}
    ts="${ts:0:len-3}${ts:len-2}"   # …+08:00 → …+0800
  fi
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "${ts}" +%s 2>/dev/null
}

# hours_fmt <秒> → "XhYYm"
hours_fmt() {
  local s="${1:-0}"
  case "${s}" in ''|*[!0-9]*) s=0 ;; esac
  (( s < 0 )) && s=0
  printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

# ro_sqlite <db> <sql> → stdout JSON 数组；成功 rc 0，双形态皆败 rc 1（输出 []）。
# 唯一 sqlite 入口，只读；先 mode=ro，非零退出优雅回退 immutable=1（函数内回退
# 不因此标 degraded——主 board 本就只有 immutable 能开，回退是常态不是伤情）。
ro_sqlite() {
  local db="$1" sql="$2" out rc
  if [[ "${HAVE_SQLITE3}" != "1" ]]; then
    printf '[]'
    return 1
  fi
  out="$(sqlite3 "file:${db}?mode=ro" -json "${sql}" 2>/dev/null)"
  rc=$?
  if (( rc == 0 )); then
    # sqlite3 -json 空结果集输出空串（3.51.0 实测）→ 归一化 []
    [[ -n "${out}" ]] || out='[]'
    printf '%s' "${out}"
    return 0
  fi
  # immutable=1 回退：按文件快照读、忽略 WAL；主 board WAL 头无 -shm/-wal 专属形态
  out="$(sqlite3 "file:${db}?mode=ro&immutable=1" -json "${sql}" 2>/dev/null)"
  rc=$?
  if (( rc == 0 )); then
    [[ -n "${out}" ]] || out='[]'
    printf '%s' "${out}"
    return 0
  fi
  printf '[]'
  return 1
}

# sql_esc <字符串> → 单引号翻倍，防 SQL 破坏（id 来自 flight 登记文件，不可信）
sql_esc() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# card_status <db> <card_id> → stdout status（找不到输出空串）；查询失败 rc 1
card_status() {
  local db="$1" cid="$2" esc arr st
  esc="$(sql_esc "${cid}")"
  arr="$(ro_sqlite "${db}" "SELECT status FROM tasks WHERE id='${esc}'")" || return 1
  st="$(jq -r '.[0].status // ""' <<<"${arr}" 2>/dev/null)" || return 1
  printf '%s' "${st}"
  return 0
}

# ---------- 渲染管线 ----------
SECTIONS_FILE=""

emit() { # <行> → append 进节内容文件
  printf '%s\n' "$1" >> "${SECTIONS_FILE}"
}

# ---------- S1 contrib board 非终态全景 ----------
# 判据：告警=孤儿卡（§0 病例②）∨ deepcheck 登记卡 blocked/gave_up 占槽
#       （§0 病例① 本义=blocked 病理卡占槽死锁；健康在飞 ready/running 不触发，仅入清单）
#       ∨ 非终态卡龄 >24h（§3-B3 dead_letter_after_hours 默认 24）；
#       注意=有非终态卡未触发上述；正常=零非终态。
V_S1="正常"

collect_s1() {
  local all_json nt_json total terminal nonterminal rc
  local term_bd="" nterm_bd="" st c
  emit ""
  emit "## 1) contrib board 非终态全景"
  if [[ "${HAVE_SQLITE3}" != "1" || "${HAVE_JQ}" != "1" ]]; then
    V_S1="degraded"
    emit "- [degraded] sqlite3/jq 缺失，S1 依赖方节降级（降级矩阵）"
    emit "- 伤情判定：degraded —— sqlite3/jq 缺失，fail-closed 降级（不炸不静默）"
    return 0
  fi
  all_json="$(ro_sqlite "${CONTRIB_DB}" "SELECT status, count(*) AS c FROM tasks GROUP BY status")"
  rc=$?
  if (( rc != 0 )); then
    V_S1="degraded"
    emit "- [degraded] contrib board 不可读（mode=ro 与 immutable=1 双形态皆败）"
    emit "- 伤情判定：degraded —— contrib board 双形态只读皆败，fail-closed 降级（降级矩阵）"
    return 0
  fi
  total="$(jq -r 'map(.c) | add // 0' <<<"${all_json}")"
  terminal="$(jq -r 'map(select((.status == "done") or (.status == "archived") or (.status == "cancelled")) | .c) | add // 0' <<<"${all_json}")"
  nonterminal=$(( total - terminal ))
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    st="$(jq -r '.[0]' <<<"${row}")"
    c="$(jq -r '.[1]' <<<"${row}")"
    case "${st}" in
      done|archived|cancelled) term_bd="${term_bd}${st}×${c} " ;;
      *) nterm_bd="${nterm_bd}${st}×${c} " ;;
    esac
  done < <(jq -c '.[] | [.status, .c]' <<<"${all_json}")
  emit "- 计数：总 ${total}｜终态 ${terminal}（${term_bd% }）｜非终态 ${nonterminal}（${nterm_bd% }）"

  # rq 账本载入：缺/坏不整节降级，只注明孤儿检测未执行（降级矩阵）
  local rq_ok=1
  rq_load || rq_ok=0

  # deepcheck flight 登记卡状态（§0 病例①）：登记卡 status=blocked/gave_up → 告警。
  # 病例①本义=blocked 病理卡占槽死锁（编排裁决 2026-09-13 收敛，与 S5 同判据对齐）；
  # 健康在飞 ready/running 是常态，不触发告警，照常在上方非终态清单列出。
  local dc_card="" dc_status="" dc_alarm=0
  if [[ -r "${FLIGHT_DEEPCHECK_FILE}" ]]; then
    dc_card="$(jq -r '.card_id // ""' "${FLIGHT_DEEPCHECK_FILE}" 2>/dev/null)"
  fi
  if [[ -n "${dc_card}" ]]; then
    if dc_status="$(card_status "${CONTRIB_DB}" "${dc_card}")"; then
      if [[ "${dc_status}" == "blocked" || "${dc_status}" == "gave_up" ]]; then
        dc_alarm=1
      fi
    fi
  fi

  # 非终态卡清单（最近事件 = task_events MAX(created_at)）
  nt_json="$(ro_sqlite "${CONTRIB_DB}" "SELECT t.id, t.status, coalesce(t.assignee,'') AS assignee, t.created_at, coalesce(t.title,'') AS title, (SELECT e.kind FROM task_events e WHERE e.task_id = t.id ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS last_kind, (SELECT e.created_at FROM task_events e WHERE e.task_id = t.id ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS last_at, coalesce(t.body,'') AS body FROM tasks t WHERE t.status NOT IN (${TERMINAL_SQL}) ORDER BY t.created_at ASC")"
  rc=$?
  if (( rc != 0 )); then
    V_S1="degraded"
    emit "- [degraded] contrib board 不可读（mode=ro 与 immutable=1 双形态皆败）"
    emit "- 伤情判定：degraded —— contrib board 双形态只读皆败，fail-closed 降级（降级矩阵）"
    return 0
  fi

  local any_orphan=0 any_aged=0 n_list=0
  local row cid cst cass ccr ctitle lk la cbody age_s lk_disp suffix mentions rqid stt orphan
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    cid="$(jq -r '.[0]' <<<"${row}")"
    cst="$(jq -r '.[1]' <<<"${row}")"
    cass="$(jq -r '.[2]' <<<"${row}")"
    ccr="$(jq -r '.[3]' <<<"${row}")"
    ctitle="$(jq -r '.[4]' <<<"${row}")"
    lk="$(jq -r '.[5] // "-"' <<<"${row}")"
    la="$(jq -r '.[6] // 0' <<<"${row}")"
    cbody="$(jq -r '.[7] // ""' <<<"${row}")"
    case "${ccr}" in ''|*[!0-9]*) ccr=0 ;; esac
    age_s=$(( NOW - ccr ))
    (( age_s < 0 )) && age_s=0
    lk_disp="-"
    if [[ "${la}" != "0" && -n "${la}" && "${la}" != "null" ]]; then
      lk_disp="$(date -r "${la}" '+%m-%d %H:%M' 2>/dev/null)"
    fi
    ctitle="${ctitle//$'\t'/ }"
    ctitle="${ctitle//$'\n'/ }"
    suffix=""
    # 孤儿检测（§0 病例②）：卡所提 rq 全部终态且至少提及 1 个 → 孤儿
    orphan=0
    if (( rq_ok == 1 )); then
      mentions="$(printf '%s\n%s\n' "${ctitle}" "${cbody}" | grep -oE 'rq-[0-9]{8}-[0-9a-z]+' | sort -u)"
      if [[ -n "${mentions}" ]]; then
        orphan=1
        while IFS= read -r rqid; do
          [[ -z "${rqid}" ]] && continue
          stt="$(rq_state "${rqid}")"
          if ! printf '%s' "${stt}" | grep -qE "${RQ_TERMINAL_RE}"; then
            orphan=0
            break
          fi
        done <<<"${mentions}"
      fi
    fi
    if (( orphan == 1 )); then
      any_orphan=1
      suffix="｜孤儿（所提 rq 全部终态，§0 病例②）"
    fi
    if (( age_s > 86400 )); then
      any_aged=1
      suffix="${suffix}｜超龄（>24h，§3-B3）"
    fi
    emit "- ${cid}｜${cst}｜${cass:-…}｜龄 $(hours_fmt "${age_s}")｜最近事件 ${lk}@${lk_disp}｜${ctitle}${suffix}"
    n_list=$(( n_list + 1 ))
  done < <(jq -c '.[] | [(.id // ""),(.status // ""),(.assignee // ""),((.created_at // 0)|tostring),(.title // ""),(.last_kind // ""),((.last_at // 0)|tostring),(.body // "")]' <<<"${nt_json}")
  if (( n_list == 0 )); then
    emit "- 非终态卡：无"
  fi
  if (( rq_ok == 0 )); then
    # 降级矩阵：ready-queue 缺/坏 → S1 注明孤儿检测未执行（S1 不整节降级）
    emit "- 注：rq 账本不可用，孤儿检测未执行"
  fi

  # 判定（优先级：告警 > 注意 > 正常；源败已提前 return degraded）
  local reasons=""
  if (( any_orphan == 1 )); then
    reasons="${reasons}存在孤儿卡（§0 病例②）；"
  fi
  if (( dc_alarm == 1 )); then
    reasons="${reasons}deepcheck 登记卡 ${dc_card} status=${dc_status} 占槽（§0 病例① blocked/gave_up 病理占用，健康在飞不触发）；"
  fi
  if (( any_aged == 1 )); then
    reasons="${reasons}存在非终态卡龄 >24h（§3-B3 dead_letter_after_hours 默认 24）；"
  fi
  if [[ -n "${reasons}" ]]; then
    V_S1="告警"
    emit "- 伤情判定：告警 —— ${reasons%'；'}"
  elif (( nonterminal > 0 )); then
    V_S1="注意"
    emit "- 伤情判定：注意 —— 有非终态卡 ${nonterminal} 张，未触发孤儿/深检槽/超龄任一（§3-B3 阈值 24h）"
  else
    V_S1="正常"
    emit "- 伤情判定：正常 —— 零非终态卡（contrib board 全景 GROUP BY status）"
  fi
  return 0
}

# ---------- S2 主 board contrib/coder 非终态卡 ----------
# gave_up 按 task_events 统计而非 status（t_92c903b0 status=ready 但有 gave_up
# 事件，只按 status 漏判）。判据：告警=某卡 gave_up ≥2（§0 病例③ 秒崩循环）
# ∨ gave_up/blocked 卡龄 >24h（§3-B3 默认）；注意=存在 gave_up=1 非终态卡；
# 正常=零 gave_up ∧ 无 blocked 超龄。
V_S2="正常"

collect_s2() {
  local all_json nt_json gu_json total terminal nonterminal rc
  emit ""
  emit "## 2) 主 board contrib/coder 非终态卡"
  if [[ "${HAVE_SQLITE3}" != "1" || "${HAVE_JQ}" != "1" ]]; then
    V_S2="degraded"
    emit "- [degraded] sqlite3/jq 缺失，S2 依赖方节降级（降级矩阵）"
    emit "- 伤情判定：degraded —— sqlite3/jq 缺失，fail-closed 降级（不炸不静默）"
    return 0
  fi
  all_json="$(ro_sqlite "${MAIN_DB}" "SELECT status, count(*) AS c FROM tasks WHERE assignee IN ('contrib','coder') GROUP BY status")"
  rc=$?
  if (( rc != 0 )); then
    V_S2="degraded"
    emit "- [degraded] 主 board 不可读（mode=ro 与 immutable=1 双形态皆败）"
    emit "- 伤情判定：degraded —— 主 board 双形态只读皆败，fail-closed 降级（降级矩阵）"
    return 0
  fi
  total="$(jq -r 'map(.c) | add // 0' <<<"${all_json}")"
  terminal="$(jq -r 'map(select((.status == "done") or (.status == "archived") or (.status == "cancelled")) | .c) | add // 0' <<<"${all_json}")"
  nonterminal=$(( total - terminal ))
  emit "- 计数：总 ${total}｜终态 ${terminal}｜非终态 ${nonterminal}（assignee IN (contrib,coder)）"

  # gave_up 统计（按事件不按 status——t_92c903b0 教训）
  gu_json="$(ro_sqlite "${MAIN_DB}" "SELECT task_id, count(*) AS c, max(created_at) AS last_at FROM task_events WHERE kind = 'gave_up' GROUP BY task_id")"
  rc=$?
  if (( rc != 0 )); then
    V_S2="degraded"
    emit "- [degraded] 主 board 不可读（mode=ro 与 immutable=1 双形态皆败）"
    emit "- 伤情判定：degraded —— 主 board 双形态只读皆败，fail-closed 降级（降级矩阵）"
    return 0
  fi

  nt_json="$(ro_sqlite "${MAIN_DB}" "SELECT t.id, t.status, coalesce(t.assignee,'') AS assignee, t.created_at, coalesce(t.title,'') AS title, (SELECT e.kind FROM task_events e WHERE e.task_id = t.id ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS last_kind, (SELECT e.created_at FROM task_events e WHERE e.task_id = t.id ORDER BY e.created_at DESC, e.id DESC LIMIT 1) AS last_at FROM tasks t WHERE t.assignee IN ('contrib','coder') AND t.status NOT IN (${TERMINAL_SQL}) ORDER BY t.created_at ASC")"
  rc=$?
  if (( rc != 0 )); then
    V_S2="degraded"
    emit "- [degraded] 主 board 不可读（mode=ro 与 immutable=1 双形态皆败）"
    emit "- 伤情判定：degraded —— 主 board 双形态只读皆败，fail-closed 降级（降级矩阵）"
    return 0
  fi

  local row cid cst cass ccr ctitle lk la age_s lk_disp
  local gu_cnt gu_at
  emit "- 全部非终态卡："
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    cid="$(jq -r '.[0]' <<<"${row}")"
    cst="$(jq -r '.[1]' <<<"${row}")"
    cass="$(jq -r '.[2]' <<<"${row}")"
    ccr="$(jq -r '.[3]' <<<"${row}")"
    ctitle="$(jq -r '.[4]' <<<"${row}")"
    lk="$(jq -r '.[5] // "-"' <<<"${row}")"
    la="$(jq -r '.[6] // 0' <<<"${row}")"
    case "${ccr}" in ''|*[!0-9]*) ccr=0 ;; esac
    age_s=$(( NOW - ccr ))
    (( age_s < 0 )) && age_s=0
    lk_disp="-"
    if [[ "${la}" != "0" && -n "${la}" && "${la}" != "null" ]]; then
      lk_disp="$(date -r "${la}" '+%m-%d %H:%M' 2>/dev/null)"
    fi
    ctitle="${ctitle//$'\t'/ }"
    ctitle="${ctitle//$'\n'/ }"
    emit "  - ${cid}｜${cst}｜${cass:-…}｜龄 $(hours_fmt "${age_s}")｜最近事件 ${lk}@${lk_disp}｜${ctitle}"
  done < <(jq -c '.[] | [(.id // ""),(.status // ""),(.assignee // ""),((.created_at // 0)|tostring),(.title // ""),(.last_kind // ""),((.last_at // 0)|tostring)]' <<<"${nt_json}")

  # gave_up/blocked 清单：非终态 ∧ (status=blocked/gave_up ∨ 存在 gave_up 事件)
  emit "- gave_up/blocked 清单（gave_up 按 task_events 统计而非 status——t_92c903b0 status=ready 但有 gave_up 事件，只按 status 漏判）："
  local warn2=0 gu_total=0 n_trouble=0
  local reasons2="" why
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    cid="$(jq -r '.[0]' <<<"${row}")"
    cst="$(jq -r '.[1]' <<<"${row}")"
    ccr="$(jq -r '.[3]' <<<"${row}")"
    ctitle="$(jq -r '.[4]' <<<"${row}")"
    gu_cnt="$(jq -r --arg id "${cid}" '[.[] | select(.task_id == $id) | .c] | first // 0' <<<"${gu_json}")"
    gu_at="$(jq -r --arg id "${cid}" '[.[] | select(.task_id == $id) | .last_at] | first // 0' <<<"${gu_json}")"
    case "${gu_cnt}" in ''|*[!0-9]*) gu_cnt=0 ;; esac
    case "${cst}" in
      blocked|gave_up) why=1 ;;
      *) if (( gu_cnt > 0 )); then why=1; else why=0; fi ;;
    esac
    if [[ "${why}" != "1" ]]; then
      continue
    fi
    case "${ccr}" in ''|*[!0-9]*) ccr=0 ;; esac
    age_s=$(( NOW - ccr ))
    (( age_s < 0 )) && age_s=0
    gu_last="-"
    if [[ "${gu_at}" != "0" && -n "${gu_at}" && "${gu_at}" != "null" ]]; then
      gu_last="$(date -r "${gu_at}" '+%m-%d %H:%M' 2>/dev/null)"
    fi
    ctitle="${ctitle//$'\t'/ }"
    ctitle="${ctitle//$'\n'/ }"
    emit "  - ${cid}｜${cst}｜gave_up×${gu_cnt}｜最近 gave_up ${gu_last}｜龄 $(hours_fmt "${age_s}")｜${ctitle}"
    n_trouble=$(( n_trouble + 1 ))
    gu_total=$(( gu_total + gu_cnt ))
    # 判据：gave_up ≥2（§0 病例③ 秒崩循环）
    if (( gu_cnt >= 2 )); then
      reasons2="${reasons2}${cid} gave_up×${gu_cnt}（§0 病例③ 秒崩循环）；"
    fi
    # 判据：gave_up/blocked 卡龄 >24h（§3-B3 默认）
    if (( age_s > 86400 )); then
      reasons2="${reasons2}${cid} 龄 >24h（§3-B3 默认）；"
    fi
    # 判据：存在 gave_up=1 非终态卡 → 注意
    if (( gu_cnt == 1 )); then
      warn2=1
    fi
  done < <(jq -c '.[] | [(.id // ""),(.status // ""),(.assignee // ""),((.created_at // 0)|tostring),(.title // "")]' <<<"${nt_json}")
  if (( n_trouble == 0 )); then
    emit "  - 无"
  fi

  if [[ -n "${reasons2}" ]]; then
    V_S2="告警"
    emit "- 伤情判定：告警 —— ${reasons2%'；'}"
  elif (( warn2 == 1 )); then
    V_S2="注意"
    emit "- 伤情判定：注意 —— 存在 gave_up=1 的非终态卡（重试窗口内，观察再崩）"
  else
    V_S2="正常"
    emit "- 伤情判定：正常 —— 零 gave_up ∧ 无 blocked 超龄（§3-B3 默认 24h）"
  fi
  return 0
}

# ---------- ready-queue 载入与查询（S1 孤儿 / S3 共用） ----------
RQ_JSON=""

rq_load() {
  # 成功 rc 0（RQ_JSON 就绪）；缺/坏 rc 1（调用方 S3 降级、S1 注明）
  local rc
  RQ_JSON=""
  [[ -r "${RQ_FILE}" ]] || return 1
  RQ_JSON="$(cat "${RQ_FILE}" 2>/dev/null)" || return 1
  printf '%s' "${RQ_JSON}" | jq -e '(.items | type) == "array"' >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    RQ_JSON=""
    return 1
  fi
  return 0
}

# rq_state <rq_id> → state（不存在输出空）
rq_state() {
  jq -r --arg id "$1" '[.items[] | select(.id == $id) | .state] | first // ""' <<<"${RQ_JSON}" 2>/dev/null
}

# ---------- S3 ready-queue 悬空项 ----------
# 悬空 = state=approved ∨ state 前缀 awaiting。判据：告警=任一悬空 >24h（§3-B3）；
# 注意=悬空 ≥1；正常=零悬空。
V_S3="正常"

collect_s3() {
  emit ""
  emit "## 3) ready-queue 悬空项"
  if [[ "${HAVE_JQ}" != "1" ]]; then
    V_S3="degraded"
    emit "- [degraded] jq 缺失，S3 依赖方节降级（降级矩阵）"
    emit "- 伤情判定：degraded —— jq 缺失，fail-closed 降级（不炸不静默）"
    return 0
  fi
  if ! rq_load; then
    V_S3="degraded"
    emit "- [degraded] ready-queue.json 缺失或损坏"
    emit "- 伤情判定：degraded —— rq 账本缺/坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  local rows row rc
  rows="$(jq -c '.items[] | select((.state == "approved") or (((.state // "") | startswith("awaiting")))) | [(.id // ""),(.issue // ""),(.state // ""),(.awaiting_at // ""),(.awaiting_epoch // 0)]' <<<"${RQ_JSON}" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    V_S3="degraded"
    emit "- [degraded] ready-queue.json 解析失败"
    emit "- 伤情判定：degraded —— rq 账本坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  local n_dangle=0 max_dangle=0
  local rid rissue rstate rat rep dur dur_s
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    rid="$(jq -r '.[0]' <<<"${row}")"
    rissue="$(jq -r '.[1]' <<<"${row}")"
    rstate="$(jq -r '.[2]' <<<"${row}")"
    rat="$(jq -r '.[3]' <<<"${row}")"
    rep="$(jq -r '.[4]' <<<"${row}")"
    dur="时长未知"
    dur_s=-1
    # 时长优先 awaiting_epoch，缺则解析 awaiting_at，再缺记「时长未知」
    if [[ "${rep}" =~ ^[0-9]+$ ]] && (( rep > 0 )); then
      dur_s=$(( NOW - rep ))
    elif [[ -n "${rat}" ]]; then
      rep="$(parse_iso_ts "${rat}")"
      if [[ -n "${rep}" ]]; then
        dur_s=$(( NOW - rep ))
      fi
    fi
    if (( dur_s >= 0 )); then
      (( dur_s < 0 )) && dur_s=0
      dur="$(hours_fmt "${dur_s}")"
      if (( dur_s > max_dangle )); then
        max_dangle=${dur_s}
      fi
    fi
    emit "- ${rid}｜${rissue}｜${rstate}｜${rat}｜悬空 ${dur}"
    n_dangle=$(( n_dangle + 1 ))
  done <<<"${rows}"
  if (( n_dangle == 0 )); then
    emit "- 悬空项：无（approved ∨ awaiting 前缀均零）"
    V_S3="正常"
    emit "- 伤情判定：正常 —— 零悬空（ready-queue state 闭集过滤）"
  elif (( max_dangle > 86400 )); then
    V_S3="告警"
    emit "- 伤情判定：告警 —— 任一悬空 >24h（§3-B3 dead_letter_after_hours 默认 24）"
  else
    V_S3="注意"
    emit "- 伤情判定：注意 —— 悬空 ${n_dangle} 项（≤24h）"
  fi
  return 0
}

# ---------- S4 budget 余量 ----------
# 判据：告警=当日或本周 used ≥ limit（§5 预算硬顶 + 09-13 budget-out 停线实录）；
# 注意=余量 ≤20%×limit；正常=其余。无条目=0；probe 无上限 → 余量 n/a。
V_S4="正常"

collect_s4() {
  emit ""
  emit "## 4) budget 余量"
  if [[ "${HAVE_JQ}" != "1" ]]; then
    V_S4="degraded"
    emit "- [degraded] jq 缺失，S4 依赖方节降级（降级矩阵）"
    emit "- 伤情判定：degraded —— jq 缺失，fail-closed 降级（不炸不静默）"
    return 0
  fi
  local rc raw
  if [[ ! -r "${BUDGET_FILE}" ]]; then
    V_S4="degraded"
    emit "- [degraded] budget.json 缺失"
    emit "- 伤情判定：degraded —— 账本缺/坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  jq -e '(.limits | type) == "object"' "${BUDGET_FILE}" >/dev/null 2>&1
  rc=$?
  if (( rc != 0 )); then
    V_S4="degraded"
    emit "- [degraded] budget.json 损坏（limits 缺失或 JSON 坏）"
    emit "- 伤情判定：degraded —— 账本缺/坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  raw="$(jq -c --arg d "${TODAY}" --arg w "${WEEKKEY}" '{day_used: (.days[$d].used // 0), day_items: (.days[$d].items // [] | length), week_used: (.weeks[$w].used // 0), week_items: (.weeks[$w].items // [] | length), probe_used: (.probes[$d].used // 0), day_limit: (.limits.day // 0), week_limit: (.limits.week // 0)}' "${BUDGET_FILE}" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    V_S4="degraded"
    emit "- [degraded] budget.json 解析失败"
    emit "- 伤情判定：degraded —— 账本缺/坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  local day_used day_limit week_used week_limit probe_used
  day_used="$(jq -r '.day_used' <<<"${raw}")";  case "${day_used}"  in ''|*[!0-9]*) day_used=0 ;; esac
  day_limit="$(jq -r '.day_limit' <<<"${raw}")"; case "${day_limit}" in ''|*[!0-9]*) day_limit=0 ;; esac
  week_used="$(jq -r '.week_used' <<<"${raw}")"; case "${week_used}" in ''|*[!0-9]*) week_used=0 ;; esac
  week_limit="$(jq -r '.week_limit' <<<"${raw}")"; case "${week_limit}" in ''|*[!0-9]*) week_limit=0 ;; esac
  probe_used="$(jq -r '.probe_used' <<<"${raw}")"; case "${probe_used}" in ''|*[!0-9]*) probe_used=0 ;; esac

  local alarm=0 warn=0 reasons=""
  # 当日余量行
  if (( day_limit > 0 )); then
    emit "- 当日 ${day_used}/${day_limit}（余 $(( day_limit - day_used ))）"
    if (( day_used >= day_limit )); then
      alarm=1
      reasons="${reasons}当日 ${day_used}/${day_limit} 撞顶（§5 预算硬顶 + 09-13 budget-out 停线实录）；"
    elif (( day_used * 5 >= day_limit * 4 )); then
      warn=1
    fi
  else
    emit "- 当日 ${day_used}（无上限）"
  fi
  # 本周余量行
  if (( week_limit > 0 )); then
    emit "- 本周 ${week_used}/${week_limit}（余 $(( week_limit - week_used ))）"
    if (( week_used >= week_limit )); then
      alarm=1
      reasons="${reasons}本周 ${week_used}/${week_limit} 撞顶（§5 预算硬顶 + 09-13 budget-out 停线实录）；"
    elif (( week_used * 5 >= week_limit * 4 )); then
      warn=1
    fi
  else
    emit "- 本周 ${week_used}（无上限）"
  fi
  # probe 无上限 → 余量 n/a
  emit "- probe 今日 ${probe_used}（无上限，余 n/a）"

  if (( alarm == 1 )); then
    V_S4="告警"
    emit "- 伤情判定：告警 —— ${reasons%'；'}"
  elif (( warn == 1 )); then
    V_S4="注意"
    emit "- 伤情判定：注意 —— 当日或本周余量 ≤20%×limit（余量告警线）"
  else
    V_S4="正常"
    emit "- 伤情判定：正常 —— 当日/本周余量均 >20%（无条目按 used 0 计）"
  fi
  return 0
}

# ---------- S5 flight 残留登记 ----------
# kanban-flight-*.json 逐文件核对其登记卡在 contrib board 的状态：
# 卡不存在→flight 泄漏(卡已不在板)；卡终态→flight 泄漏(登记未清)；非终态→在途正常，
# kind=deepcheck ∧ 卡 blocked → 深检单飞槽被占 Xh（§0 病例①）。
# 判据：告警=泄漏 ≥1 ∨ 深检槽被占；正常=其余。单文件坏 JSON→行级 [degraded]。
V_S5="正常"

collect_s5() {
  emit ""
  emit "## 5) flight 残留登记"
  if [[ "${HAVE_JQ}" != "1" || "${HAVE_SQLITE3}" != "1" ]]; then
    V_S5="degraded"
    emit "- [degraded] sqlite3/jq 缺失，S5 依赖方节降级（降级矩阵）"
    emit "- 伤情判定：degraded —— sqlite3/jq 缺失，fail-closed 降级（不炸不静默）"
    return 0
  fi
  local f found=0 n_files=0
  local alarm=0 reasons="" leak=0
  local row kind cid rid cep rc st age_s
  # glob 空集 → 「无登记」正常（不是降级）
  for f in "${CONTRIB_DATA}"/kanban-flight-*.json; do
    [[ -e "${f}" ]] || continue
    found=1
    n_files=$(( n_files + 1 ))
    if [[ ! -r "${f}" ]]; then
      emit "- $(basename "${f}")｜[degraded] 文件不可读"
      continue
    fi
    row="$(jq -c '[(.kind // "?"),(.card_id // ""),(.rq_id // "-"),((.created_epoch // 0)|tostring)]' "${f}" 2>/dev/null)"
    rc=$?
    if (( rc != 0 )) || [[ -z "${row}" ]]; then
      # 单文件坏 JSON → 行级 [degraded]（降级矩阵）
      emit "- $(basename "${f}")｜[degraded] 坏 JSON，无法读取登记"
      continue
    fi
    kind="$(jq -r '.[0]' <<<"${row}")"
    cid="$(jq -r '.[1]' <<<"${row}")"
    rid="$(jq -r '.[2]' <<<"${row}")"
    cep="$(jq -r '.[3]' <<<"${row}")"
    case "${cep}" in ''|*[!0-9]*) cep=0 ;; esac
    age_s=$(( NOW - cep ))
    (( age_s < 0 )) && age_s=0
    if ! st="$(card_status "${CONTRIB_DB}" "${cid}")"; then
      V_S5="degraded"
      emit "- [degraded] contrib board 不可读，登记卡状态无法核对"
      emit "- 伤情判定：degraded —— contrib board 双形态只读皆败，fail-closed 降级（降级矩阵）"
      return 0
    fi
    if [[ -z "${st}" ]]; then
      leak=$(( leak + 1 ))
      alarm=1
      reasons="${reasons}flight 泄漏(卡已不在板)：$(basename "${f}") card=${cid}；"
      emit "- $(basename "${f}")｜kind=${kind}｜card=${cid}｜rq=${rid}｜登记龄 $(hours_fmt "${age_s}")｜flight 泄漏(卡已不在板)"
    else
      local terminal=0
      case "${st}" in
        done|archived|cancelled) terminal=1 ;;
      esac
      if (( terminal == 1 )); then
        leak=$(( leak + 1 ))
        alarm=1
        reasons="${reasons}flight 泄漏(登记未清)：$(basename "${f}") card=${cid}（终态 ${st}）；"
        emit "- $(basename "${f}")｜kind=${kind}｜card=${cid}｜rq=${rid}｜登记龄 $(hours_fmt "${age_s}")｜flight 泄漏(登记未清)（卡终态 ${st}）"
      else
        # 非终态 → 在途正常；kind=deepcheck ∧ 卡 blocked → 深检单飞槽被占（§0 病例①）
        if [[ "${kind}" == "deepcheck" && "${st}" == "blocked" ]]; then
          alarm=1
          reasons="${reasons}深检单飞槽被占 $(hours_fmt "${age_s}")（card=${cid}，§0 病例① 深检单飞槽死锁）；"
          emit "- $(basename "${f}")｜kind=${kind}｜card=${cid}｜rq=${rid}｜登记龄 $(hours_fmt "${age_s}")｜在途（${st}）｜深检单飞槽被占 $(hours_fmt "${age_s}")（§0 病例①）"
        else
          emit "- $(basename "${f}")｜kind=${kind}｜card=${cid}｜rq=${rid}｜登记龄 $(hours_fmt "${age_s}")｜在途（${st}）正常"
        fi
      fi
    fi
  done
  if (( found == 0 )); then
    emit "- 无登记（kanban-flight-*.json 空集）"
    V_S5="正常"
    emit "- 伤情判定：正常 —— 无登记（空集）"
    return 0
  fi
  if [[ -n "${reasons}" ]]; then
    V_S5="告警"
    emit "- 伤情判定：告警 —— ${reasons%'；'}"
  else
    V_S5="正常"
    emit "- 伤情判定：正常 —— 登记全部在途（${n_files} 个文件，无泄漏无槽占）"
  fi
  return 0
}

# ---------- S6 events.jsonl 近 24h ----------
# class ∈ {pipeline-failure, premise-dead} 且 ts ≥ now-86400。
# 判据：告警=premise-dead ≥1（§0 幽灵 slug 4125 次教训）∨ pipeline-failure ≥3；
# 注意=pipeline-failure 1–2；正常=皆 0。
V_S6="正常"

collect_s6() {
  emit ""
  emit "## 6) events.jsonl 近 24h"
  if [[ "${HAVE_JQ}" != "1" ]]; then
    V_S6="degraded"
    emit "- [degraded] jq 缺失，S6 依赖方节降级（降级矩阵）"
    emit "- 伤情判定：degraded —— jq 缺失，fail-closed 降级（不炸不静默）"
    return 0
  fi
  if [[ ! -r "${EVENTS_FILE}" ]]; then
    V_S6="degraded"
    emit "- [degraded] events.jsonl 缺失或不可读"
    emit "- 伤情判定：degraded —— 事件流缺/坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  local rc bad_count rel
  # 坏行计数：jq -R 逐行 try fromjson catch（容坏行；-R 必需，否则 jq 自动解析
  # 对象后 fromjson? 静默吞行——2026-09-13 实测）
  bad_count="$(jq -Rr 'try fromjson catch "__BAD_LINE__"' "${EVENTS_FILE}" 2>/dev/null | grep -c '__BAD_LINE__')"
  bad_count="${bad_count:-0}"
  # 相关事件取出行（双序列化形态由 fromjson 归一化）
  rel="$(jq -Rr 'fromjson? | select((.class == "pipeline-failure") or (.class == "premise-dead")) | [(.ts // ""),(.class // ""),(.key // ""),(.summary // "")] | @json' "${EVENTS_FILE}" 2>/dev/null)"
  rc=$?
  if (( rc != 0 )); then
    V_S6="degraded"
    emit "- [degraded] events.jsonl 读取失败"
    emit "- 伤情判定：degraded —— 事件流缺/坏，fail-closed 降级（降级矩阵）"
    return 0
  fi
  local cutoff=$(( NOW - 86400 ))
  local c_pf=0 c_pd=0 c_unparsed=0
  local last_ep=-1 last_disp="" row ts cls ekey summ ep
  while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    ts="$(jq -r '.[0]' <<<"${row}")"
    cls="$(jq -r '.[1]' <<<"${row}")"
    ekey="$(jq -r '.[2]' <<<"${row}")"
    summ="$(jq -r '.[3]' <<<"${row}")"
    ep="$(parse_iso_ts "${ts}")"
    if [[ -z "${ep}" ]]; then
      # ts 不可解析 → 保守计入（宁多勿漏），并注明
      c_unparsed=$(( c_unparsed + 1 ))
      continue
    fi
    if (( ep < cutoff )); then
      continue
    fi
    case "${cls}" in
      pipeline-failure) c_pf=$(( c_pf + 1 )) ;;
      premise-dead) c_pd=$(( c_pd + 1 )) ;;
    esac
    if (( ep > last_ep )); then
      last_ep=${ep}
      summ="${summ//$'\t'/ }"
      summ="${summ//$'\n'/ }"
      last_disp="${cls}｜${ekey}｜${summ}"
    fi
  done <<<"${rel}"
  local note=""
  if (( bad_count > 0 )); then
    note="（坏行 ${bad_count} 行已跳过并注明）"
  fi
  emit "- 近 24h 计数：pipeline-failure×${c_pf} premise-dead×${c_pd}${note}"
  if [[ -n "${last_disp}" ]]; then
    emit "- 最近一条：${last_disp}"
  fi
  if (( c_unparsed > 0 )); then
    emit "- 注：${c_unparsed} 条相关事件 ts 不可解析，保守计入总数外（未参与 24h 过滤）"
  fi
  if (( c_pd >= 1 )); then
    V_S6="告警"
    emit "- 伤情判定：告警 —— premise-dead ≥1（§0 幽灵 slug 4125 次教训）"
  elif (( c_pf >= 3 )); then
    V_S6="告警"
    emit "- 伤情判定：告警 —— pipeline-failure ≥3（24h 内 ${c_pf} 次）"
  elif (( c_pf >= 1 )); then
    V_S6="注意"
    emit "- 伤情判定：注意 —— pipeline-failure 1–2（24h 内 ${c_pf} 次）"
  else
    V_S6="正常"
    emit "- 伤情判定：正常 —— 近 24h 两者皆 0"
  fi
  return 0
}

# ---------- 主流程（生产模式） ----------
run_brief() {
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/state_brief.XXXXXX")" || {
    printf 'state_brief: mktemp 失败\n' >&2
    exit 2
  }
  SECTIONS_FILE="${WORK_DIR}/sections.md"
  local final_file="${WORK_DIR}/brief.md"
  : > "${SECTIONS_FILE}"

  collect_s1
  collect_s2
  collect_s3
  collect_s4
  collect_s5
  collect_s6

  # 总览行：`总伤情：告警×N 注意×M 正常×K`（degraded 节以 ` degraded×D` 尾缀，D=0 省略）
  local na=0 nw=0 nk=0 nd=0 v
  for v in "${V_S1}" "${V_S2}" "${V_S3}" "${V_S4}" "${V_S5}" "${V_S6}"; do
    case "${v}" in
      告警) na=$(( na + 1 )) ;;
      注意) nw=$(( nw + 1 )) ;;
      正常) nk=$(( nk + 1 )) ;;
      degraded) nd=$(( nd + 1 )) ;;
    esac
  done
  local overall="总伤情：告警×${na} 注意×${nw} 正常×${nk}"
  if (( nd > 0 )); then
    overall="${overall} degraded×${nd}"
  fi
  {
    printf '# state brief — contrib 域\n'
    printf '生成：%s（零 LLM 零网络只读聚合）\n' "$(date '+%F %T')"
    printf '\n'
    printf '%s\n' "${overall}"
    cat "${SECTIONS_FILE}"
  } > "${final_file}"

  # stdout 唯一产物 md
  cat "${final_file}"

  # --out 额外落同款内容文件（内容与 stdout 一致）；落盘失败 exit 2
  if [[ -n "${OUT_FILE}" ]]; then
    if ! cp "${final_file}" "${OUT_FILE}"; then
      printf '用法错误: --out 落盘失败: %s\n' "${OUT_FILE}" >&2
      exit 2
    fi
  fi
  return 0
}

# ---------- --selftest ----------
# fixture 自建（mktemp 树，trap 清理），经 env seams 注入，绝不触生产六源。
# 八病例断言 + --out 一致性断言；断言行 `- [PASS] <名>` / `- [FAIL] <名>`，
# 收尾 `--selftest 全绿`；任一 FAIL exit 1。
SELFTEST_FAIL=0
ST_OUT=""
ST_RC=0

st_assert() { # <名> <0=pass 1=fail>
  if [[ "$2" == "0" ]]; then
    printf -- '- [PASS] %s\n' "$1"
  else
    printf -- '- [FAIL] %s\n' "$1"
    SELFTEST_FAIL=$(( SELFTEST_FAIL + 1 ))
  fi
  return 0
}

st_run() { # <额外参数...>：以 fixture seams 跑子进程，捕获 stdout 到 ST_OUT / rc 到 ST_RC
  ST_OUT="$(STATE_BRIEF_CONTRIB_DB="${ST_CDB}" STATE_BRIEF_MAIN_DB="${ST_MDB}" CONTRIB_DATA_DIR="${ST_TREE}" bash "${SCRIPT_PATH}" "$@")"
  ST_RC=$?
  return 0
}

st_sec() { # <节号> → 从 ST_OUT 抽取该节文本（## N) 起、下一节止）
  printf '%s\n' "${ST_OUT}" | awk -v s="## $1)" 'index($0, s) == 1 { f = 1; next } /^## [0-9]\)/ { f = 0 } f'
  return 0
}

run_selftest() {
  local now iso_10m_ago iso_1h_ago iso_2h_ago ep_1h ep_2h
  ST_TREE="$(mktemp -d "${TMPDIR:-/tmp}/state_brief_selftest.XXXXXX")" || {
    printf 'selftest: mktemp 失败\n' >&2
    return 1
  }
  local ST_CDB="${ST_TREE}/contrib.db"
  local ST_MDB="${ST_TREE}/main.db"
  now="$(date +%s)"
  ep_1h=$(( now - 3600 ))
  ep_2h=$(( now - 7200 ))
  iso_10m_ago="$(date -v-10M '+%Y-%m-%dT%H:%M:%S%z')"
  iso_1h_ago="$(date -j -f %s "${ep_1h}" '+%Y-%m-%dT%H:%M:%S%z')"
  iso_2h_ago="$(date -j -f %s "${ep_2h}" '+%Y-%m-%dT%H:%M:%S%z')"

  # --- contrib.db fixture（列名与真实同源：tasks/task_events/kind） ---
  sqlite3 "${ST_CDB}" <<SQLEOF
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT,
  status TEXT NOT NULL, created_at INTEGER NOT NULL, completed_at INTEGER
);
CREATE TABLE task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL,
  kind TEXT NOT NULL, payload TEXT, created_at INTEGER NOT NULL
);
INSERT INTO tasks VALUES('t_aaa','孤儿病例卡','处理 rq-20260901-abc123 的上游回填','contrib','blocked',${ep_2h},NULL);
INSERT INTO tasks VALUES('t_bbb','scan 病例卡','','contrib','done',${ep_2h},${ep_1h});
INSERT INTO tasks VALUES('t_ccc','深检病例卡','深检 rq-20260901-abc123','contrib','blocked',${ep_2h},NULL);
INSERT INTO task_events (task_id, kind, created_at) VALUES('t_aaa','blocked',${ep_1h});
INSERT INTO task_events (task_id, kind, created_at) VALUES('t_bbb','completed',${ep_1h});
INSERT INTO task_events (task_id, kind, created_at) VALUES('t_ccc','blocked',${ep_1h});
SQLEOF

  # --- main.db fixture（病例1：status=ready 卡带 gave_up 事件） ---
  sqlite3 "${ST_MDB}" <<SQLEOF
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT, assignee TEXT,
  status TEXT NOT NULL, created_at INTEGER NOT NULL, completed_at INTEGER
);
CREATE TABLE task_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL,
  kind TEXT NOT NULL, payload TEXT, created_at INTEGER NOT NULL
);
INSERT INTO tasks VALUES('t_ddd','gave_up 病例卡','','contrib','ready',${ep_1h},NULL);
INSERT INTO task_events (task_id, kind, created_at) VALUES('t_ddd','gave_up',${ep_1h});
SQLEOF

  # --- ready-queue.json fixture（病例2/5：executed 终态 + awaiting-approval + approved） ---
  cat > "${ST_TREE}/ready-queue.json" <<JSONEOF
{"version":1,"updated":"${iso_1h_ago}","items":[
 {"id":"rq-20260901-abc123","state":"executed","issue":"12","title":"已执行项"},
 {"id":"rq-20260902-await1","state":"awaiting-approval","issue":"13","title":"待批项","awaiting_at":"${iso_1h_ago}","awaiting_epoch":${ep_1h}},
 {"id":"rq-20260902-appr2","state":"approved","issue":"14","title":"已批未取项","awaiting_at":"${iso_2h_ago}","awaiting_epoch":${ep_2h}}
]}
JSONEOF

  # --- budget.json fixture（病例6：当日 28/30 → 余 2 ≤20% → 注意；本周 10/30） ---
  cat > "${ST_TREE}/budget.json" <<JSONEOF
{"version":1,"limits":{"day":30,"week":30},
 "days":{"${TODAY}":{"used":28,"items":["rq-x"]}},
 "weeks":{"${WEEKKEY}":{"used":10,"items":["rq-x"]}},
 "probes":{"${TODAY}":{"used":1,"items":["rq-x"]}}}
JSONEOF

  # --- flight 登记 fixture（病例3：scan 登记卡已 done → 泄漏；病例4：deepcheck 登记卡 blocked → 槽占） ---
  cat > "${ST_TREE}/kanban-flight-scan.json" <<JSONEOF
{"kind":"scan","card_id":"t_bbb","created_epoch":${ep_2h}}
JSONEOF
  cat > "${ST_TREE}/kanban-flight-deepcheck.json" <<JSONEOF
{"kind":"deepcheck","card_id":"t_ccc","rq_id":"rq-20260901-abc123","created_epoch":${ep_2h}}
JSONEOF

  # --- events.jsonl fixture（病例7：紧凑 pipeline-failure + 带空格 premise-dead + 1 坏行） ---
  cat > "${ST_TREE}/events.jsonl" <<JSONEOF
{"ts":"${iso_10m_ago}","class":"pipeline-failure","key":"k1","summary":"紧凑形态事件","pushed":true,"attempts":0}
{ "ts": "${iso_10m_ago}", "class": "premise-dead", "key": "k2", "summary": "带空格形态事件", "pushed": true, "attempts": 0 }
this-line-is-not-json
JSONEOF

  # --- 子进程跑一次全绿 fixture（seam 全指向 mktemp 树） ---
  st_run --out "${ST_TREE}/out.md"
  local s1 s2 s3 s4 s5 s6

  # 病例1：main.db status=ready 卡带 gave_up 事件 → S2 清单命中该卡
  s2="$(st_sec 2)"
  local ok1=1
  printf '%s' "${s2}" | grep -q 't_ddd' || ok1=1
  if printf '%s' "${s2}" | grep -q 't_ddd' && printf '%s' "${s2}" | grep -q 'gave_up×1'; then ok1=0; fi
  st_assert "1-main-board-ready卡带gave_up事件入S2清单" "${ok1}"

  # 病例2：contrib.db blocked 卡提及 rq state=executed → 「孤儿」命中
  s1="$(st_sec 1)"
  local ok2=1
  if printf '%s' "${s1}" | grep -q '孤儿'; then ok2=0; fi
  st_assert "2-孤儿命中(所提rq全部终态)" "${ok2}"

  # 病例3：flight scan 登记卡已 done → 「flight 泄漏」命中
  s5="$(st_sec 5)"
  local ok3=1
  if printf '%s' "${s5}" | grep -q 'flight 泄漏'; then ok3=0; fi
  st_assert "3-flight泄漏命中(登记卡已终态)" "${ok3}"

  # 病例4：flight deepcheck 登记卡 blocked → 「深检单飞槽」命中
  local ok4=1
  if printf '%s' "${s5}" | grep -q '深检单飞槽'; then ok4=0; fi
  st_assert "4-深检单飞槽被占命中(deepcheck登记卡blocked)" "${ok4}"

  # 病例5：ready-queue 含 awaiting-approval 与 approved 各一项 → 两类都进 S3
  s3="$(st_sec 3)"
  local ok5=1
  if printf '%s' "${s3}" | grep -q 'rq-20260902-await1' \
     && printf '%s' "${s3}" | grep -q 'awaiting-approval' \
     && printf '%s' "${s3}" | grep -q 'rq-20260902-appr2' \
     && printf '%s' "${s3}" | grep -q 'approved'; then ok5=0; fi
  st_assert "5-awaiting与approved两类悬空都进S3" "${ok5}"

  # 病例6：budget 当日 28/30 → 余量行数值正确，且 ≤20% → 注意
  s4="$(st_sec 4)"
  local ok6=1
  if printf '%s' "${s4}" | grep -q '当日 28/30（余 2）' \
     && printf '%s' "${s4}" | grep -q '伤情判定：注意'; then ok6=0; fi
  st_assert "6-budget余量数值与20%注意线" "${ok6}"

  # 病例7：events 双形态各一 + 1 坏行 → 计数正确且坏行注明
  s6="$(st_sec 6)"
  local ok7=1
  if printf '%s' "${s6}" | grep -q 'pipeline-failure×1' \
     && printf '%s' "${s6}" | grep -q 'premise-dead×1' \
     && printf '%s' "${s6}" | grep -q '坏行 1'; then ok7=0; fi
  st_assert "7-events双形态计数与坏行注明" "${ok7}"

  # 另断言：--out 文件与 stdout 一致
  local ok9=1
  if [[ "${ST_RC}" == "0" ]] && [[ "${ST_OUT}" == "$(cat "${ST_TREE}/out.md")" ]]; then ok9=0; fi
  st_assert "9---out文件与stdout一致" "${ok9}"

  # 病例10：deepcheck 登记卡健康在飞（ready）→ S1 不触发病例①（占槽告警收敛回归）
  local ok10=1
  sqlite3 "${ST_CDB}" "INSERT INTO tasks VALUES('t_eee','健康在飞深检卡','','contrib','ready',${ep_1h},NULL);"
  cat > "${ST_TREE}/kanban-flight-deepcheck.json" <<JSONEOF
{"kind":"deepcheck","card_id":"t_eee","created_epoch":${ep_1h}}
JSONEOF
  st_run
  local s1c
  s1c="$(st_sec 1)"
  if [[ "${ST_RC}" == "0" ]] \
     && printf '%s' "${s1c}" | grep -q 't_eee' \
     && printf '%s' "${s1c}" | grep -q '伤情判定：' \
     && ! printf '%s' "${s1c}" | grep -q '病例①'; then ok10=0; fi
  st_assert "10-deepcheck健康在飞不触发S1病例①占槽告警" "${ok10}"

  # 病例8：坏库（截断 sqlite 文件头 bytes）经 seam → 对应节 [degraded] 且整体 exit=0
  local ok8=1
  head -c 10 "${ST_CDB}" > "${ST_CDB}.trunc" && mv "${ST_CDB}.trunc" "${ST_CDB}"
  st_run
  local s1b
  s1b="$(st_sec 1)"
  if [[ "${ST_RC}" == "0" ]] \
     && printf '%s' "${s1b}" | grep -q '伤情判定：degraded' \
     && printf '%s' "${ST_OUT}" | grep -q '\[degraded\]'; then ok8=0; fi
  st_assert "8-坏库对应节degraded且exit0" "${ok8}"

  if (( SELFTEST_FAIL == 0 )); then
    printf -- '--selftest 全绿\n'
    return 0
  fi
  printf 'selftest: %d 项 FAIL\n' "${SELFTEST_FAIL}" >&2
  return 1
}

# ---------- 入口 ----------
parse_args "$@"
init_env
if (( SELFTEST == 1 )); then
  run_selftest
  exit $?
fi
run_brief
exit 0
