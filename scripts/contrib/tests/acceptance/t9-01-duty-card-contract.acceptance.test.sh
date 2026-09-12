#!/usr/bin/env bash
# =============================================================================
# t9-01-duty-card-contract.acceptance.test.sh — contrib 值班环验收（沙箱黑盒功能面）
# 被测：scripts/contrib/duty_card.sh（create / harvest / apply 三子命令）+ run-watch 值班段接线
# 全部经 CONTRIB_TEST_TARGET + lib/sandbox.sh + stub hermes 沙箱执行，绝不读写真实
# contrib-data/真实板/真实 worker/真实 hermes（场景7.P3 同源红线）。
#
# 用例 → 验收谓词映射（SSOT = state.md「## 验收场景」，真库谓词的沙箱等价面）：
#   E1  场景1.P1/P2/P3（create exit 0 + 卡入库 + body 内嵌 brief 全文锚点与行数）+ C2/C5/C8 契约
#       （建卡 flag 面 / flight-duty 三键 / brief 原样内嵌 / 五段 body / env -u 剥离 / 跨系统数据流：
#        flight.card_id == stub 建卡 id；幂等键与 body 文件名同源）
#   E2  C1 board pin 面（KANBAN_BOARD=contrib → --board 插在 kanban 与子命令之间；空=不 pin）
#   E3  场景1.P4 沙箱等价（节流窗口内二次 create → exit 10 且不新建卡）+ DUTY_INTERVAL_SECS
#       缺省 7200 与 --force 跳过（BRIEFING 交付一.三）
#   E4  create 在飞互斥（flight 在途 → 10 保留；终态/查无/坏 JSON → 清登记继续）
#   E5  建卡锁 mkdir 语义（被占 → 10；>3h 残留强清 → 放行；BRIEFING 交付一.一 / C6）
#   E6  create 失败路径一：brief 取不到（rc≠0 / 空 / 缺「伤情判定」→ exit 1 + -duty-brief-fail 事件
#       + 零建卡 + 零节流戳）（场景7.P2 第⑦类 / BRIEFING 交付一.四）
#   E7  create 失败路径二：建卡失败 → exit 1 + -duty-card-fail 事件 + 零登记零戳
#   E8  场景8.P1/P2 沙箱等价：harvest 幂等恒 0 矩阵（done/archived/cancelled 清、running 保留、
#       查无清、坏 JSON 保留、查询失败保留、无登记空转）
#   E9  场景3.P1/P3 沙箱等价：apply 对合格 archive-request 代行归档（archive 调用 + 台账 executed 行
#       含判据与 decisionReason）+ 幂等（二次 apply 零重复执行）
#   E10 apply 幂等预置形（已有 executed 行 → 零 archive 调用）（场景7.P2 第⑥类）
#   E11 apply 复核矩阵（场景7.P2 第⑤类）：龄 ≤24h / running / rq awaiting-approval / 查无 → 只跳过
#       不归档（skipped 行）；gave_up 与 rq-已死项 → 归档
#   E12 场景4.P1/P2 沙箱等价：apply --dry-run 与 DUTY_APPLY_DRY_RUN=1 → exit 0、命中清单打印、
#       零 archive 调用、台账零写入
#   E13 apply fail-soft 恒 0（hermes 全败 → 0 且无 executed 行；archive 执行失败 → 0 且不伪造 executed）
#   E14 场景9.P1/P2：沙箱真跑 run-watch.sh（值班段已接线）→ exit 0 + 日志 duty 三连记录 +
#       同一节流窗口二跑值班卡计数增量 == 0
# CONTRACT_AMBIGUOUS（以契约字面最严口径断言并在用例内注明）：
#   - 台账 executed 行「判据含龄」的数值表示法未钉死 → 只断言含状态字面（blocked）
#   - apply 对「查询失败」轮是否写 skipped 行未钉死 → 只断言零 executed（任何解释下都须成立）
#   - created_at 形态锚定工具源码（hermes kanban_db.py:682 created_at 为 int epoch 秒），夹具注入 epoch
# 红队纪律：黑盒（未读 duty_card.sh / duty-cardify.sh / SKILL.md 新段 / run-watch 新段）；
#   每断言硬失败；无 try/catch 吞错；无 skip。Mental Mutation：duty_card.sh 整体缺失 → E1 起
#   全挂；create 退化为恒 0 → E3/E4/E5 exit 断言挂；body 删 brief 内嵌 → E1 锚点挂；flight 漏写
#   → E1 flight 断言挂；harvest 变成有副作用非恒 0 → E8 挂；apply 对不合格目标归档 → E11 挂；
#   apply 幂等丢失 → E9/E10 archive 计数挂；dry-run 落写 → E12 台账比对挂；值班段未接线 →
#   E14 日志三连挂。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

# ---- 本文件专用装具（全部只作用于沙箱 ${SB_ROOT} 内，零生产触达） ----

CONTRIB_DIR=""
DUTY_FLIGHT=""
DUTY_STAMP=""
DUTY_LEDGER=""
DUTY_LOCK=""
DUTY_BODIES=""
RW_LOG=""
CARD_STORE=""

sb_paths() { # sb_new 之后解析沙箱内契约路径（BRIEFING 交付一：CONTRIB 数据目录下各面）
  CONTRIB_DIR="$SB_ROOT/contrib-data"
  DUTY_FLIGHT="$CONTRIB_DIR/kanban-flight-duty.json"
  DUTY_STAMP="$CONTRIB_DIR/.duty-last-create"
  DUTY_LEDGER="$CONTRIB_DIR/duty-ledger.md"
  DUTY_LOCK="$CONTRIB_DIR/locks/duty-card.lock"
  DUTY_BODIES="$CONTRIB_DIR/card-bodies"
  RW_LOG="$CONTRIB_DIR/logs/launchd.log"
  CARD_STORE="$SB_ROOT/stublog/kanban-cards.jsonl"
}

install_state_brief_stub() { # 沙箱内替换被测脚本副本 state_brief.sh（行为旋钮 STUB_STATE_BRIEF）
  cat > "$SB_ROOT/scripts/contrib/state_brief.sh" <<'STUBEOF'
#!/bin/bash
# 测试装具：state_brief stub（红队验收专用）——duty_card.sh 的 brief 供给面夹具
case "${STUB_STATE_BRIEF:-ok}" in
  fail) echo "stub state_brief: 模拟六源采集崩溃" >&2; exit 1 ;;
  empty) exit 0 ;;
  noanchor)
    printf '%s\n' "## 1) contrib board 非终态全景"
    printf '%s\n' "（本模式缺该判定行——负面夹具，全文不含任何四值判定措辞）"
    exit 0
    ;;
  *) cat <<'BRIEF'
SBRIEF-MARKER-头部锚（原样内嵌不截断断言用 v1）
# contrib state brief（沙箱验收夹具）
生成时刻：1970-01-01 00:00:00 +08:00（夹具时间，非真实钟）

## 1) contrib board 非终态全景
- 在飞登记：kanban-flight-duty.json 夹具态；lock 面 clean
- 伤情判定：正常 —— 六源采集全部成功（夹具第 1 节）

## 2) 主 board 非终态全景
- 主 board 采样 3 项非终态（夹具）
- 伤情判定：正常 —— 主 board 采集成功（夹具第 2 节）

## 3) ready-queue 深检链全景
- 队列项 rq-20260909-0001 停留 deep-check 超 6h（夹具演示）
- 伤情判定：注意 —— 存在停留项，建议观察（夹具第 3 节）

## 4) budget 预算全景
- deep 日预算 used 与 limit 处于高位（夹具演示）
- 伤情判定：告警 —— 使用率超阈值，按白名单处理或升级事件（夹具第 4 节）

## 5) flight 登记全景
- 某登记源本轮不可读，本节降级采样（夹具演示降级路径）
- 伤情判定：degraded —— 记台账并在 summary 报告缺源（夹具第 5 节）

## 6) events 告警全景
- 近 24h events.jsonl 无 pipeline-failure 新增（夹具）
- 伤情判定：正常 —— 告警面安静（夹具第 6 节）

附注一：本 brief 为沙箱夹具，仅供验收断言锚定，六行判定覆盖四值闭集 正常|注意|告警|degraded。
附注二：脚注行用于撑起 40 行量级的全文内嵌断言（行 30）。
附注三：脚注行用于撑起 40 行量级的全文内嵌断言（行 31）。
附注四：脚注行用于撑起 40 行量级的全文内嵌断言（行 32）。
附注五：脚注行用于撑起 40 行量级的全文内嵌断言（行 33）。
附注六：脚注行用于撑起 40 行量级的全文内嵌断言（行 34）。
附注七：脚注行用于撑起 40 行量级的全文内嵌断言（行 35）。
附注八：脚注行用于撑起 40 行量级的全文内嵌断言（行 36）。
附注九：脚注行用于撑起 40 行量级的全文内嵌断言（行 37）。
附注十：脚注行用于撑起 40 行量级的全文内嵌断言（行 38）。
附注十一：脚注行用于撑起 40 行量级的全文内嵌断言（行 39）。
附注十二：脚注行用于撑起 40 行量级的全文内嵌断言（行 40）。
附注十三：脚注行用于撑起 40 行量级的全文内嵌断言（行 41）。
SBRIEF-MARKER-尾部锚（不截断断言用 v1）
BRIEF
    ;;
esac
STUBEOF
  chmod +x "$SB_ROOT/scripts/contrib/state_brief.sh"
}

install_hermes_task_injector() { # 包装 stub hermes：list/show 注入 title/body/created_at 夹具 + archive 失败旋钮
  mv "$SB_ROOT/bin/hermes" "$SB_ROOT/bin/hermes-base"
  cat > "$SB_ROOT/bin/hermes" <<'WRAPHEAD'
#!/bin/bash
# 测试装具：hermes 包装器（红队验收专用）——透传 stub hermes 本体（调用照常入 calls.log），并按需：
#   STUB_TASK_FIX=<json id→字段>  向 list/show 输出注入 title/body/created_at 夹具字段
#   STUB_KANBAN_ARCHIVE_FAIL=1   对 kanban archive 子命令返回失败（执行失败路径驱动）
set -u
BASE="__HERMES_BASE__"
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -z "$LOG_DIR" ]]; then
  echo "hermes wrapper: STUB_LOG_DIR 未设置（拒绝在沙箱外运行）" >&2
  exit 97
fi
_sub=""
_id=""
if [[ "${1:-}" == "kanban" ]]; then
  if [[ "${2:-}" == "--board" ]]; then
    _sub="${4:-}"
    _id="${6:-}"
  else
    _sub="${2:-}"
    _id="${3:-}"
  fi
fi
_out="$(bash "$BASE" "$@")"
_rc=$?
if [[ "$_sub" == "archive" && "${STUB_KANBAN_ARCHIVE_FAIL:-}" == "1" ]]; then
  printf '%s\n' '{"success":false,"error":"stub-archive-fail"}'
  exit 1
fi
if [[ "$_rc" -eq 0 && -n "${STUB_TASK_FIX:-}" ]]; then
  case "$_sub" in
    show)
      _out="$(printf '%s' "$_out" | jq -c --argjson fix "$STUB_TASK_FIX" --arg id "$_id" '.task += ($fix[$id] // {})' 2>/dev/null)"
      ;;
    list)
      _out="$(printf '%s' "$_out" | jq -c --argjson fix "$STUB_TASK_FIX" 'map(. += ($fix[.id] // {}))' 2>/dev/null)"
      ;;
  esac
fi
printf '%s\n' "$_out"
exit "$_rc"
WRAPHEAD
  sed -i '' "s|__HERMES_BASE__|$SB_ROOT/bin/hermes-base|" "$SB_ROOT/bin/hermes"
  chmod +x "$SB_ROOT/bin/hermes"
}

install_fake_date() { # 沙箱 date 影子：仅劫持裸 +%H（run-watch radar 窗口消除），其余透传（t4-01 同款）
  mkdir -p "$SB_HOME/.local/bin"
  cat > "$SB_HOME/.local/bin/date" <<'DATEEOF'
#!/bin/bash
if [[ "${1:-}" == "+%H" && "$#" -eq 1 ]]; then
  printf '%s\n' "${STUB_DATE_HOUR:-14}"
  exit 0
fi
exec /bin/date "$@"
DATEEOF
  chmod +x "$SB_HOME/.local/bin/date"
}

quiet_sb() { # 新沙箱 + 全套装具 + 既有段静默数据
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  sb_paths
  install_state_brief_stub
  install_hermes_task_injector
  install_fake_date
  mkdir -p "$SB_ROOT/mailstub"
  printf '[]\n' >"$SB_ROOT/mailstub/envelopes.json"
  printf '[]\n' >"$SB_ROOT/gh-issues.json"
  printf '{"last_issue":9000}\n' >"$CONTRIB_DIR/scan-cursor.json"
  printf '[]\n' >"$CONTRIB_DIR/pending-hits.json"
}

duty() { # [-e K=V]... <duty args...> → 沙箱内真跑 duty_card.sh（rc 经 sb_run 返回，stdout 透传）
  local -a envs=()
  while [[ "${1:-}" == "-e" ]]; do
    envs[${#envs[@]}]="-e"
    envs[${#envs[@]}]="$2"
    shift 2
  done
  local args="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    args="$args$(printf '%q ' "$a")"
    shift
  done
  sb_run ${envs[@]+"${envs[@]}"} "bash \"\$MARTIN_DIR/scripts/contrib/duty_card.sh\" $args"
}

watch_run() { # 沙箱内真跑 run-watch.sh（场景9 驱动形态，同既有验收 run_watch 口径）
  sb_run -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" \
    -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"'
}

# ---- 观测助手 ----
assert_grep() { # <haystack> <ERE> [label]
  if printf '%s' "$1" | grep -qE -- "$2"; then _pass "${3:-}"; else _fail "${3:-}" "未匹配 /$2/"; fi
}
assert_not_grep() { # <haystack> <ERE> [label]
  if printf '%s' "$1" | grep -qE -- "$2"; then _fail "${3:-}" "不应匹配却匹配 /$2/"; else _pass "${3:-}"; fi
}
assert_file_grep() { # <file> <ERE> [label]
  if [[ ! -f "$1" ]]; then _fail "${3:-}" "文件缺失: $1"; return 0; fi
  if grep -qE -- "$2" "$1"; then _pass "${3:-}"; else _fail "${3:-}" "文件未匹配 /$2/"; fi
}
assert_count_ge() { # <count> <min> [label]
  case "$1" in
    ''|*[!0-9]*) _fail "${3:-}" "计数非数值 [$1]" ;;
    *) if [ "$1" -ge "$2" ]; then _pass "${3:-}"; else _fail "${3:-}" "实得 $1 < 期望下限 $2"; fi ;;
  esac
}
assert_epoch_gt0() { # <value> [label]
  case "$1" in
    ''|*[!0-9]*) _fail "${2:-}" "非正整数 [$1]" ;;
    *) if [ "$1" -gt 0 ]; then _pass "${2:-}"; else _fail "${2:-}" "实得 $1 非正"; fi ;;
  esac
}
hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
count_duty_create() { # contrib 值班卡 的 kanban create 调用次数（兼容有无 --board 两种 argv 形态）
  hermes_lines | awk 'match($0, /kanban( --board [^ ]+)? create/) && index($0, "contrib 值班卡") { c++ } END { printf "%d", c + 0 }'
}
duty_create_line() { hermes_lines | grep -E 'kanban( --board [^ ]+)? create' | grep 'contrib 值班卡' | tail -1; }
archive_calls_for() { # <card_id> → kanban archive <id> 调用次数
  hermes_lines | awk -v id="$1" 'index($0, " archive ") && index($0, id) { c++ } END { printf "%d", c + 0 }'
}
anthropic_env_log() { cat "$SB_ROOT/stublog/anthropic-env.log" 2>/dev/null || true; }
ev_key_count() { # <key 后缀>（endswith 口径，日期段不钉死）
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$CONTRIB_DIR/events.jsonl" 2>/dev/null || echo 0
}
store_last_id() { tail -1 "$CARD_STORE" 2>/dev/null | jq -r '.id // empty' 2>/dev/null || true; }
body_copy_of() { # 幂等键 duty- 建卡调用的 --body 副本路径（stub 契约 bodies/hermes-<seq>.txt）
  local n
  n="$(awk -F'|' '$1 == "hermes" { c++; if (index($0, "--idempotency-key duty-")) seq = c } END { printf "%d", seq + 0 }' \
    "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
  if [[ -n "$n" && "$n" -gt 0 && -f "$SB_ROOT/stublog/bodies/hermes-$n.txt" ]]; then
    printf '%s/stublog/bodies/hermes-%s.txt' "$SB_ROOT" "$n"
  fi
  return 0
}
local_body_file() { ls "$DUTY_BODIES"/duty-*.body.md 2>/dev/null | head -1 || true; }
seed_duty_flight() { # <card_id> [epoch]
  jq -n --arg id "$1" --argjson e "${2:-$(date +%s)}" '{kind:"duty",card_id:$id,created_epoch:$e}' >"$DUTY_FLIGHT"
}
seed_card() { # <id> <status> → 追加进 stub 有状态卡库
  printf '{"id":"%s","status":"%s","assignee":"contrib","priority":0}\n' "$1" "$2" >>"$CARD_STORE"
}
status_map() { # <id:status>... → STUB_KANBAN_STATUS_MAP json
  local pair out="{" first=1
  for pair in "$@"; do
    if [[ $first -eq 0 ]]; then out="$out,"; fi
    first=0
    out="$out\"${pair%%:*}\":\"${pair#*:}\""
  done
  printf '%s}\n' "$out"
}
ledger_init() {
  printf '# duty-ledger（沙箱夹具）——贡献域值班台账\n\n| 时间 | 动作 | 对象 | 状态 | 判据 | decisionReason |\n|---|---|---|---|---|---|\n' >"$DUTY_LEDGER"
}
ledger_request() { # <card_id> → C10 六列 archive-request 行
  printf '| 2026-09-13 08:00 | archive-request | %s | pending | 判据：blocked 卡龄超 24h（夹具） | decisionReason：worker 声明（沙箱夹具） |\n' "$1" >>"$DUTY_LEDGER"
}
ledger_executed() { # <card_id> → 预置 archive executed 行
  printf '| 2026-09-13 08:00 | archive | %s | executed | 判据：预置（夹具） | decisionReason：预置（夹具） |\n' "$1" >>"$DUTY_LEDGER"
}
ledger_rows() { # [action] [id] [status] → 台账行计数（awk -F'|' 分列 + trim，容空格差异）
  awk -F'|' -v a="${1:-}" -v i="${2:-}" -v s="${3:-}" '
    {
      for (n = 1; n <= NF; n++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $n) }
      if (a != "" && $3 != a) next
      if (i != "" && $4 != i) next
      if (s != "" && $5 != s) next
      c++
    } END { printf "%d", c + 0 }' "$DUTY_LEDGER" 2>/dev/null
}
stamp_value() { cat "$DUTY_STAMP" 2>/dev/null || true; }
log_duty_hits() { # <子命令字面> → run-watch 日志中 duty 邻近该子命令的行数（日志缺失=0）
  if [[ ! -f "$RW_LOG" ]]; then printf '0'; return 0; fi
  grep -E "(duty.{0,60}$1)|($1.{0,60}duty)" "$RW_LOG" 2>/dev/null | wc -l | tr -d ' '
}

# =============================================================================
t_case "E1 create 主路: exit 0 + 卡入库 + body 五段内嵌 brief 全文 + flight 三键 + env 剥离 + 数据流同源（场景1.P1/P2/P3 沙箱等价）"
quiet_sb
duty create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E1 恰 1 次 contrib 值班卡建卡（P1 已建卡）"
assert_grep "$(duty_create_line)" 'kanban create contrib 值班卡 [0-9]{8}-[0-9]{4}( |$)' "E1 卡标题 contrib 值班卡 <YYYYMMDD-HHMM>（P2 标题开头）"
assert_grep "$(duty_create_line)" '--assignee contrib' "E1 C2 建卡带 --assignee contrib"
assert_grep "$(duty_create_line)" '--idempotency-key duty-[0-9]{8}-[0-9]{6}' "E1 C2 幂等键 duty-<YYYYMMDD-HHMMSS>"
assert_grep "$(duty_create_line)" '--max-retries 2' "E1 C2 建卡带 --max-retries 2"
assert_grep "$(duty_create_line)" '--json' "E1 C2 建卡带 --json"
assert_not_contains "$(duty_create_line)" "--board" "E1 KANBAN_BOARD 未 pin（缺省回退态零 --board）"
assert_not_contains "$(anthropic_env_log)" "present" "E1 C1 env -u 剥离三 ANTHROPIC_*（stub 子进程视角全 absent）"
assert_eq "$(store_last_id | grep -c '^t_stub_' || true)" "1" "E1 stub 卡库入库新卡（P2 卡存在）"
FLIGHT_KIND="$(jq -r '.kind // empty' "$DUTY_FLIGHT" 2>/dev/null)"
FLIGHT_CID="$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)"
FLIGHT_EP="$(jq -r '.created_epoch // 0' "$DUTY_FLIGHT" 2>/dev/null)"
assert_eq "$FLIGHT_KIND" "duty" "E1 C5 flight.kind=duty"
assert_eq "$FLIGHT_CID" "$(store_last_id)" "E1 跨系统数据流: flight.card_id == stub 建卡返回 id（同一张卡）"
assert_epoch_gt0 "$FLIGHT_EP" "E1 flight.created_epoch > 0"
assert_eq "$(jq -r 'keys | join(",")' "$DUTY_FLIGHT" 2>/dev/null)" "card_id,created_epoch,kind" "E1 C5 flight-duty 三键钉死（规格不许四键）"
KEY_MIN="$(duty_create_line | grep -oE 'duty-[0-9]{8}-[0-9]{4}' | head -1)"
LBF="$(local_body_file)"
STEM_MIN=""
if [[ -n "$LBF" && -f "$LBF" ]]; then
  _pass "E1 本地 body 文件落盘 card-bodies/duty-<ts>.body.md"
  STEM_MIN="$(basename "$LBF" .body.md | cut -c1-18)"
else
  _fail "E1 本地 body 文件落盘 card-bodies/duty-<ts>.body.md" "未找到"
fi
assert_eq "$KEY_MIN" "$STEM_MIN" "E1 数据流同源: 幂等键与 body 文件名同一 duty-<YYYYMMDD-HHMM> 前缀"
if [[ -n "$LBF" && -f "$LBF" ]]; then
  NLINES="$(wc -l <"$LBF" | tr -d ' ')"
  assert_count_ge "$NLINES" 41 "E1 body 行数 > 40（P3，实得 ${NLINES}）"
  assert_file_contains "$LBF" "## 1) contrib board 非终态全景" "E1 P3 body 内嵌 brief 锚一（全景节标题原文）"
  assert_file_contains "$LBF" "伤情判定" "E1 P3 body 内嵌 brief 锚二（伤情判定字样）"
  assert_file_contains "$LBF" "SBRIEF-MARKER-头部锚（原样内嵌不截断断言用 v1）" "E1 brief 原样内嵌：首行逐字在（不截断头）"
  assert_file_contains "$LBF" "SBRIEF-MARKER-尾部锚（不截断断言用 v1）" "E1 brief 原样内嵌：末行逐字在（不截断尾）"
  assert_file_contains "$LBF" "伤情判定：degraded" "E1 四值闭集 degraded 行随 brief 内嵌"
  assert_file_contains "$LBF" "## state brief 全文" "E1 body 段二标题（state brief 全文）"
  assert_file_contains "$LBF" "## 行动手册（worker 契约，白名单与红线原文）" "E1 body 段三标题（行动手册，BRIEFING 钉死段名）"
  assert_file_contains "$LBF" "## 深入阅读指针" "E1 body 段四标题（深入阅读指针）"
  assert_file_contains "$LBF" "## 收尾要求" "E1 body 段五标题（收尾要求）"
  assert_file_contains "$LBF" "kanban-flight" "E1 行动手册载白名单一（清 kanban-flight 陈旧登记）"
  assert_file_contains "$LBF" "rq.sh set" "E1 行动手册载白名单二（rq.sh set expired）"
  assert_file_contains "$LBF" "budget refund" "E1 行动手册载白名单三（budget refund 防双退）"
  assert_file_contains "$LBF" "archive-request" "E1 行动手册载 archive 只声明不执行"
  assert_file_contains "$LBF" "duty-ledger.md" "E1 行动手册载台账路径"
  assert_file_contains "$LBF" "HERMES_DELEGATED_CHILD_CONTEXT" "E1 行动手册载框架 fence 理由（禁绕过原文）"
  assert_file_contains "$LBF" "push" "E1 红线：push 禁令随手册内嵌"
  assert_file_contains "$LBF" "微信" "E1 红线：微信外发禁令随手册内嵌"
  assert_file_contains "$LBF" "approved" "E1 红线：awaiting-approval/approved 保护随手册内嵌"
  assert_file_contains "$LBF" "pipeline-failure" "E1 升级通道 notify event pipeline-failure 随手册内嵌"
  assert_file_contains "$LBF" "kanban_complete" "E1 收尾：kanban_complete 双传要求"
  assert_file_contains "$LBF" "三段式" "E1 收尾：summary 三段式要求"
  assert_file_grep "$LBF" "SKILL.md" "E1 深入阅读指针指向 SKILL.md 模式七"
  assert_file_contains "$LBF" "贡献域值班卡" "E1 首段卡型说明（贡献域值班卡）"
  assert_file_contains "$LBF" "节流" "E1 首段节流与在飞语义一句"
else
  _fail "E1 body 五段与 brief 内嵌断言簇" "body 文件缺失，整簇前置不成立"
fi
BODY_COPY="$(body_copy_of)"
if [[ -n "$BODY_COPY" && -f "$BODY_COPY" ]]; then
  _pass "E1 stub --body 副本可捕获"
  assert_file_contains "$BODY_COPY" "## 1) contrib board 非终态全景" "E1 真正发出的卡 body 同样内嵌 brief（--body 面与本地文件一致锚）"
  assert_file_contains "$BODY_COPY" "伤情判定" "E1 发出卡 body 含伤情判定"
else
  _fail "E1 stub --body 副本可捕获" "hermes stub 未捕获建卡 --body（未带 body 建卡？）"
fi
STAMP_VAL="$(stamp_value)"
case "$STAMP_VAL" in
  ''|*[!0-9]*) _fail "E1 节流戳写盘为 epoch 整数" "实得 [$STAMP_VAL]" ;;
  *) if [ "$STAMP_VAL" -gt 0 ]; then _pass "E1 节流戳写盘成功（epoch 整数）"; else _fail "E1 节流戳写盘成功" "实得 $STAMP_VAL"; fi ;;
esac
assert_eq "$(ev_key_count '-duty-brief-fail')" "0" "E1 成功路零 brief-fail 事件"
assert_eq "$(ev_key_count '-duty-card-fail')" "0" "E1 成功路零 card-fail 事件"
sb_cleanup

# =============================================================================
t_case "E2 board pin 面: KANBAN_BOARD=contrib → --board 插在 kanban 与 create 之间；空=不 pin（C1/C2 父级 flag 位置）"
quiet_sb
duty -e "KANBAN_BOARD=contrib" create
assert_exit 0 $?
assert_grep "$(duty_create_line)" 'kanban --board contrib create' "E2 --board contrib 紧跟 kanban、位于子命令 create 之前（尾部追加形态即挂）"
rm -f "$DUTY_STAMP" "$DUTY_FLIGHT"
duty create
assert_exit 0 $?
assert_not_contains "$(duty_create_line)" "--board" "E2 KANBAN_BOARD 空串=不 pin（回退态零 --board）"
sb_cleanup

# =============================================================================
t_case "E3 节流: 窗口内 create → exit 10 且零建卡零登记、戳不被改写（场景1.P4 沙箱等价）"
quiet_sb
printf '%s\n' "$(( $(date +%s) - 3600 ))" >"$DUTY_STAMP"
STAMP_BEFORE="$(stamp_value)"
duty create
assert_exit 10 $?
assert_eq "$(count_duty_create)" "0" "E3 节流窗口内零建卡（不新建卡）"
if [[ -f "$DUTY_FLIGHT" ]]; then _fail "E3 节流跳过不写在飞登记" "flight 残留"; else _pass "E3 节流跳过不写在飞登记"; fi
assert_eq "$(stamp_value)" "$STAMP_BEFORE" "E3 戳不被改写（仍为原 3600s 前值）"
assert_eq "$(ev_key_count '-duty-card-fail')" "0" "E3 跳过非失败：零 card-fail 事件"
sb_cleanup

t_case "E3b 节流边界: 戳龄 7000s < 缺省 7200 → 10"
quiet_sb
printf '%s\n' "$(( $(date +%s) - 7000 ))" >"$DUTY_STAMP"
duty create
assert_exit 10 $?
assert_eq "$(count_duty_create)" "0" "E3b 7200 缺省窗口内零建卡"
sb_cleanup

t_case "E3c 节流窗口外: 戳龄 8000s 不小于缺省 7200 → 放行建卡"
quiet_sb
printf '%s\n' "$(( $(date +%s) - 8000 ))" >"$DUTY_STAMP"
duty create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E3c 窗口外放行 1 次建卡"
sb_cleanup

t_case "E3d --force 跳过节流（仅人工/测试用）: 新戳 + --force → exit 0"
quiet_sb
printf '%s\n' "$(date +%s)" >"$DUTY_STAMP"
duty create --force
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E3d --force 绕过节流建卡"
sb_cleanup

t_case "E3e DUTY_INTERVAL_SECS seam: 缺省 7200 可被覆盖（=60、戳龄 120s → 放行）"
quiet_sb
printf '%s\n' "$(( $(date +%s) - 120 ))" >"$DUTY_STAMP"
duty -e "DUTY_INTERVAL_SECS=60" create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E3e seam 生效放行建卡"
sb_cleanup

# =============================================================================
t_case "E4 在飞互斥: flight-duty 在途（登记卡 running）→ exit 10 + 零第二张 + 登记保留"
quiet_sb
seed_card "t_old" "running"
seed_duty_flight "t_old"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_old:running")" create
assert_exit 10 $?
assert_eq "$(count_duty_create)" "0" "E4 同时刻仅一张值班卡在飞：零第二张"
assert_eq "$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)" "t_old" "E4 在途登记保留"
sb_cleanup

t_case "E4b 登记卡终态 done → 清登记继续建卡（flight 换绑）"
quiet_sb
seed_card "t_old" "done"
seed_duty_flight "t_old"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_old:done")" create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E4b 终态登记不阻塞新卡"
assert_eq "$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)" "$(store_last_id)" "E4b 登记已换绑新卡 id"
assert_ne "$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)" "t_old" "E4b 旧登记已清（换绑非残留）"
sb_cleanup

t_case "E4c flight 坏 JSON → create 清登记继续（不 10 不 1）"
quiet_sb
printf 'not-a-json{{{' >"$DUTY_FLIGHT"
duty create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E4c 坏登记清后照常建卡"
assert_eq "$(jq -r '.kind // empty' "$DUTY_FLIGHT" 2>/dev/null)" "duty" "E4c 登记已重写为合法 duty 三键"
sb_cleanup

t_case "E4d 登记卡查无 → 视同可清，放行建卡"
quiet_sb
seed_duty_flight "t_ghost"
duty create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E4d 查无放行建卡"
assert_eq "$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)" "$(store_last_id)" "E4d 登记换绑新卡"
sb_cleanup

# =============================================================================
t_case "E5 建卡锁: 锁被占 → exit 10 零建卡；被占锁不被误删（C6 mkdir 语义）"
quiet_sb
mkdir -p "$DUTY_LOCK"
duty create
assert_exit 10 $?
assert_eq "$(count_duty_create)" "0" "E5 锁被占零建卡"
if [[ -d "$DUTY_LOCK" ]]; then _pass "E5 被占锁不被误删"; else _fail "E5 被占锁不被误删" "锁目录消失"; fi
sb_cleanup

t_case "E5b 陈旧锁（mtime 远超 3h）→ 强清并放行建卡"
quiet_sb
mkdir -p "$DUTY_LOCK"
touch -t 202001010000 "$DUTY_LOCK"
duty create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E5b 陈旧锁强清后放行"
sb_cleanup

# =============================================================================
t_case "E6 brief 失败一: state_brief rc≠0 → exit 1 + -duty-brief-fail 事件 + 零建卡零戳"
quiet_sb
duty -e "STUB_STATE_BRIEF=fail" create
assert_exit 1 $?
assert_eq "$(count_duty_create)" "0" "E6 brief 失败零建卡"
if [[ -f "$DUTY_STAMP" ]]; then _fail "E6 失败路零节流戳" "戳残留"; else _pass "E6 失败路零节流戳（写盘成功才计入）"; fi
assert_eq "$(ev_key_count '-duty-brief-fail')" "1" "E6 -duty-brief-fail 事件入账"
sb_cleanup

t_case "E6b brief 失败二: 输出为空 → exit 1 + 事件"
quiet_sb
duty -e "STUB_STATE_BRIEF=empty" create
assert_exit 1 $?
assert_eq "$(count_duty_create)" "0" "E6b 空 brief 零建卡"
assert_eq "$(ev_key_count '-duty-brief-fail')" "1" "E6b -duty-brief-fail 事件入账"
sb_cleanup

t_case "E6c brief 失败三: 输出缺「伤情判定」→ exit 1 + 事件（内容门非仅 rc 门）"
quiet_sb
duty -e "STUB_STATE_BRIEF=noanchor" create
assert_exit 1 $?
assert_eq "$(count_duty_create)" "0" "E6c 缺判定字样零建卡"
assert_eq "$(ev_key_count '-duty-brief-fail')" "1" "E6c -duty-brief-fail 事件入账"
sb_cleanup

# =============================================================================
t_case "E7 建卡失败: hermes create 失败 → exit 1 + -duty-card-fail 事件 + 零登记零戳"
quiet_sb
duty -e "STUB_HERMES_FAIL=1" create
assert_exit 1 $?
assert_eq "$(ev_key_count '-duty-card-fail')" "1" "E7 -duty-card-fail 事件入账"
if [[ -f "$DUTY_FLIGHT" ]]; then _fail "E7 建卡失败不写登记" "flight 残留"; else _pass "E7 建卡失败不写登记"; fi
if [[ -f "$DUTY_STAMP" ]]; then _fail "E7 建卡失败不写节流戳" "戳残留"; else _pass "E7 建卡失败不写节流戳"; fi
sb_cleanup

# =============================================================================
t_case "E8 harvest done → 清登记 + exit 0（场景8.P1 沙箱等价）"
quiet_sb
seed_card "t_old" "done"
seed_duty_flight "t_old"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_old:done")" harvest
assert_exit 0 $?
if [[ -f "$DUTY_FLIGHT" ]]; then _fail "E8 done 登记已清" "残留"; else _pass "E8 done 登记已清"; fi
sb_cleanup

t_case "E8b harvest archived → 清登记 + exit 0（终态闭集）"
quiet_sb
seed_card "t_old" "archived"
seed_duty_flight "t_old"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_old:archived")" harvest
assert_exit 0 $?
if [[ -f "$DUTY_FLIGHT" ]]; then _fail "E8b archived 登记已清" "残留"; else _pass "E8b archived 登记已清"; fi
sb_cleanup

t_case "E8c harvest cancelled → 清登记 + exit 0（终态闭集）"
quiet_sb
seed_card "t_old" "cancelled"
seed_duty_flight "t_old"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_old:cancelled")" harvest
assert_exit 0 $?
if [[ -f "$DUTY_FLIGHT" ]]; then _fail "E8c cancelled 登记已清" "残留"; else _pass "E8c cancelled 登记已清"; fi
sb_cleanup

t_case "E8d harvest 在途 running → 保留登记 + exit 0"
quiet_sb
seed_card "t_old" "running"
seed_duty_flight "t_old"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_old:running")" harvest
assert_exit 0 $?
assert_eq "$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)" "t_old" "E8d 在途登记保留"
sb_cleanup

t_case "E8e harvest 登记卡查无 → 清登记 + exit 0"
quiet_sb
seed_duty_flight "t_ghost"
duty harvest
assert_exit 0 $?
if [[ -f "$DUTY_FLIGHT" ]]; then _fail "E8e 查无登记已清" "残留"; else _pass "E8e 查无登记已清"; fi
sb_cleanup

t_case "E8f harvest 坏 JSON → 保留登记 + exit 0（与 create 的清登记语义相区分）"
quiet_sb
printf 'broken{{{' >"$DUTY_FLIGHT"
duty harvest
assert_exit 0 $?
if [[ -f "$DUTY_FLIGHT" ]]; then _pass "E8f 坏 JSON 保留（交下轮，不误清）"; else _fail "E8f 坏 JSON 保留" "被清"; fi
sb_cleanup

t_case "E8g harvest 查询失败（hermes 全败）→ 保留登记 + exit 0（fail-soft 恒 0）"
quiet_sb
seed_duty_flight "t_old"
duty -e "STUB_HERMES_FAIL=1" harvest
assert_exit 0 $?
assert_eq "$(jq -r '.card_id // empty' "$DUTY_FLIGHT" 2>/dev/null)" "t_old" "E8g 查询失败登记保留"
sb_cleanup

t_case "E8h harvest 幂等: 无登记空转连续两次恒 exit 0（场景8.P2 沙箱等价）"
quiet_sb
duty harvest
assert_exit 0 $?
duty harvest
assert_exit 0 $?
assert_eq "$(ev_key_count '-duty-card-fail')" "0" "E8h 空转零失败事件"
sb_cleanup

# =============================================================================
t_case "E9 apply 主路: 合格 archive-request → 归档调用 + 台账 executed 行（判据+decisionReason）+ 幂等（场景3.P1/P3 沙箱等价）"
quiet_sb
seed_card "t_orphan1" "blocked"
ledger_init
ledger_request "t_orphan1"
duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_orphan1:blocked")" \
  -e "STUB_TASK_FIX={\"t_orphan1\":{\"title\":\"孤儿卡复核（无 rq 引用）\",\"body\":\"无 rq\",\"created_at\":$(( $(date +%s) - 172800 ))}}" \
  apply >/dev/null
assert_exit 0 $?
assert_eq "$(archive_calls_for "t_orphan1")" "1" "E9 恰 1 次 kanban archive t_orphan1（P3 归档发生）"
assert_eq "$(ledger_rows "archive" "t_orphan1" "executed")" "1" "E9 台账恰 1 行 archive executed（P3 留痕）"
assert_grep "$(cat "$DUTY_LEDGER" 2>/dev/null)" '判据' "E9 executed 行含判据列"
assert_grep "$(cat "$DUTY_LEDGER" 2>/dev/null)" 'decisionReason' "E9 executed 行含 decisionReason 列"
assert_grep "$(cat "$DUTY_LEDGER" 2>/dev/null)" '编排层代行' "E9 decisionReason 载编排层代行裁决（worker 被 fence）"
assert_grep "$(cat "$DUTY_LEDGER" 2>/dev/null)" 'blocked' "E9 判据含复核后状态字面"
duty apply >/dev/null
assert_exit 0 $?
assert_eq "$(archive_calls_for "t_orphan1")" "1" "E9 幂等：二次 apply 零重复归档"
assert_eq "$(ledger_rows "archive" "t_orphan1" "executed")" "1" "E9 幂等：executed 行不重复追加"
sb_cleanup

t_case "E10 apply 幂等预置形: 已有 executed 行 → 直接跳过零归档（场景7.P2 第⑥类）"
quiet_sb
ledger_init
ledger_request "t_orphan2"
ledger_executed "t_orphan2"
duty apply
assert_exit 0 $?
assert_eq "$(archive_calls_for "t_orphan2")" "0" "E10 已 executed 目标零归档调用"
sb_cleanup

# =============================================================================
t_case "E11 apply 复核矩阵: 龄不大于24h/running/rq-awaiting/查无 只跳过不归档；gave_up 与 rq-已死 照归档（场景7.P2 第⑤类）"
quiet_sb
NOW="$(date +%s)"
seed_card "t_young" "blocked"
seed_card "t_running" "running"
seed_card "t_gaveup" "gave_up"
seed_card "t_rqlock" "blocked"
seed_card "t_rqdead" "blocked"
sb_seed_queue_item "rq-20260912-812574" 812574 deep awaiting-approval 40
sb_seed_queue_item "rq-20260909-0001" 1 deep failed 40
ledger_init
ledger_request "t_young"
ledger_request "t_running"
ledger_request "t_gaveup"
ledger_request "t_rqlock"
ledger_request "t_rqdead"
ledger_request "t_missing"
MAP="$(status_map "t_young:blocked" "t_running:running" "t_gaveup:gave_up" "t_rqlock:blocked" "t_rqdead:blocked")"
FIX="$(printf '{"t_young":{"created_at":%s,"title":"young 夹具","body":""},"t_gaveup":{"created_at":%s,"title":"gaveup 夹具","body":""},"t_rqlock":{"created_at":%s,"title":"孤儿卡 rq-20260912-812574 复核","body":"见 rq-20260912-812574"},"t_rqdead":{"created_at":%s,"title":"孤儿卡 rq-20260909-0001 复核","body":"见 rq-20260909-0001"}}' "$(( NOW - 3600 ))" "$(( NOW - 172800 ))" "$(( NOW - 172800 ))" "$(( NOW - 172800 ))")"
duty -e "STUB_KANBAN_STATUS_MAP=$MAP" -e "STUB_TASK_FIX=$FIX" apply
assert_exit 0 $?
assert_eq "$(archive_calls_for "t_young")" "0" "E11 龄不大于 24h 零归档（复核不过）"
assert_eq "$(archive_calls_for "t_running")" "0" "E11 running 零归档（blocked/gave_up 闭集之外）"
assert_eq "$(archive_calls_for "t_rqlock")" "0" "E11 rq 处 awaiting-approval 零归档（红线保护面）"
assert_eq "$(archive_calls_for "t_missing")" "0" "E11 目标卡查无零归档（存在性复核）"
assert_eq "$(archive_calls_for "t_gaveup")" "1" "E11 gave_up 属复核闭集 → 归档"
assert_eq "$(archive_calls_for "t_rqdead")" "1" "E11 rq 已 failed（非 awaiting/approved）→ 归档放行"
assert_eq "$(ledger_rows "archive" "t_young" "skipped")" "1" "E11 跳过亦留台账 skipped 行（young）"
assert_eq "$(ledger_rows "archive" "t_running" "skipped")" "1" "E11 skipped 行（running）"
assert_eq "$(ledger_rows "archive" "t_rqlock" "skipped")" "1" "E11 skipped 行（rq-awaiting）"
assert_eq "$(ledger_rows "archive" "t_missing" "skipped")" "1" "E11 skipped 行（查无）"
assert_eq "$(ledger_rows "archive" "t_gaveup" "executed")" "1" "E11 executed 行（gave_up）"
assert_eq "$(ledger_rows "archive" "t_rqdead" "executed")" "1" "E11 executed 行（rq-已死）"
assert_eq "$(ledger_rows "archive" "t_rqlock" "executed")" "0" "E11 红线面：awaiting-approval 关联卡零 executed"
sb_cleanup

# =============================================================================
t_case "E12 --dry-run: exit 0 + 命中清单打印 + 零归档零台账写入（场景4.P1/P2 沙箱等价）"
quiet_sb
seed_card "t_orphan1" "blocked"
ledger_init
ledger_request "t_orphan1"
DRY_OUT="$(duty -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_orphan1:blocked")" \
  -e "STUB_TASK_FIX={\"t_orphan1\":{\"title\":\"夹具\",\"body\":\"\",\"created_at\":$(( $(date +%s) - 172800 ))}}" \
  apply --dry-run)"
assert_exit 0 $?
assert_contains "$DRY_OUT" "t_orphan1" "E12 清单打印命中合格目标"
assert_eq "$(archive_calls_for "t_orphan1")" "0" "E12 dry-run 零归档调用（P2 归档未发生）"
assert_eq "$(ledger_rows "archive" "" "")" "0" "E12 dry-run 零台账写入（连 skipped 行也不写）"
sb_cleanup

t_case "E12b DUTY_APPLY_DRY_RUN=1 env 形态: 与 --dry-run 同语义（零写入）"
quiet_sb
seed_card "t_orphan1" "blocked"
ledger_init
ledger_request "t_orphan1"
duty -e "DUTY_APPLY_DRY_RUN=1" \
  -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_orphan1:blocked")" \
  -e "STUB_TASK_FIX={\"t_orphan1\":{\"created_at\":$(( $(date +%s) - 172800 ))}}" \
  apply >/dev/null
assert_exit 0 $?
assert_eq "$(archive_calls_for "t_orphan1")" "0" "E12b env dry-run 零归档调用"
assert_eq "$(ledger_rows "archive" "" "")" "0" "E12b env dry-run 零台账写入"
sb_cleanup

# =============================================================================
t_case "E13 apply fail-soft: hermes 全败 → 恒 exit 0 且零 executed（不伪造）"
quiet_sb
ledger_init
ledger_request "t_orphan1"
duty -e "STUB_HERMES_FAIL=1" apply
assert_exit 0 $?
assert_eq "$(ledger_rows "archive" "t_orphan1" "executed")" "0" "E13 查询全败零 executed 行（下轮重试语义）"
sb_cleanup

t_case "E13b archive 执行失败: 恒 exit 0 且不写 executed（失败不得记成已执行）"
quiet_sb
seed_card "t_orphan1" "blocked"
ledger_init
ledger_request "t_orphan1"
duty -e "STUB_KANBAN_ARCHIVE_FAIL=1" \
  -e "STUB_KANBAN_STATUS_MAP=$(status_map "t_orphan1:blocked")" \
  -e "STUB_TASK_FIX={\"t_orphan1\":{\"created_at\":$(( $(date +%s) - 172800 ))}}" \
  apply >/dev/null
assert_exit 0 $?
assert_eq "$(archive_calls_for "t_orphan1")" "1" "E13b 复核通过确实发起了归档调用"
assert_eq "$(ledger_rows "archive" "t_orphan1" "executed")" "0" "E13b 归档失败零 executed（禁把未发生写成已发生）"
sb_cleanup

# =============================================================================
t_case "E14 run-watch 值班段沙箱冒烟: 真跑 exit 0 + 日志 duty 三连记录（场景9.P1）"
quiet_sb
# 夹具补种（红队例外条款留痕：值班段板库守卫=无板环境惰性面，本沙箱预置 contrib 板库空文件以放行 create；
# 同 duty-cardify ⑧ 类口径——守卫语义由本测试 W13 试跑缺口驱动蓝队落定，本夹具写于该裁决之前）
mkdir -p "$SB_ROOT/home/.hermes/kanban/boards/contrib"
: > "$SB_ROOT/home/.hermes/kanban/boards/contrib/kanban.db"
watch_run
assert_exit 0 $?
assert_count_ge "$(log_duty_hits harvest)" 1 "E14 日志含 duty harvest 记录"
assert_count_ge "$(log_duty_hits create)" 1 "E14 日志含 duty create 记录（rc 记日志不打断主链）"
assert_count_ge "$(log_duty_hits apply)" 1 "E14 日志含 duty apply 记录"
assert_eq "$(count_duty_create)" "1" "E14 首轮值班段建 1 张值班卡"

t_case "E14b 同一节流窗口二跑: exit 0 保持 + 值班卡计数增量 == 0（场景9.P2）"
watch_run
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "E14b 节流下值班卡计数增量 == 0（1 仍为 1）"
assert_count_ge "$(log_duty_hits harvest)" 2 "E14b 二跑 harvest 记录累计"
assert_count_ge "$(log_duty_hits create)" 2 "E14b 二跑 create 记录累计（rc=10 fail-soft 留痕）"
assert_count_ge "$(log_duty_hits apply)" 2 "E14b 二跑 apply 记录累计"
sb_cleanup

t_finish
