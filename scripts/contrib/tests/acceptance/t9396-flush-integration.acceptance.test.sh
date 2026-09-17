#!/usr/bin/env bash
# =============================================================================
# t9396-flush-integration.acceptance.test.sh — 卡 t_9396bbf3 红队验收（文件 3/5）
#   flush 周槽挂载集成（产物3 集成面）：S4.P1 挂载与 stamp 门槛在场 /
#   S4.P2 stub 沙箱 flush 三契约（恒 exit 0 + stdout ≤2 行）/ S4.P3 同周第二次执行
#   不重跑（stamp 门）/ S4.P4 零新 cron/plist/crontab / S4.P5 det 代理（挂载形态）/
#   S8.P2 scan 失败态下 flush 仍 exit 0。
# 谓词来源：state.md `## 验收场景` SSOT + `## 设计文档` §4.5/§4.7/§5 契约 1。
# 红队纪律：未读实现；测试专属 stub（CONTRIB_TEST_STUBS 注入，共享 stub 零改动）；
#   沙箱 HOME 链路 $SB_HOME/workspace/martin→SB_ROOT；每断言硬失败；无宽容跳过。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT:-}" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析: ${SELF_DIR}" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
BASELINE_SHA="b6c38ce"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/assert.sh
source "$TESTS_ROOT/lib/assert.sh"
# shellcheck source=../lib/sandbox.sh
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "$T_FILE"

FLUSH_REL="scripts/contrib/contrib-flush.sh"
FLUSH_F="$REPO_ROOT/$FLUSH_REL"
TODAY="2026-09-17"

# ---------------- 测试专属 stub 工厂（与文件 2 同源；共享 stub 零改动） ----------------
make_my_stubs() { # <dir>
  local d="$1"
  mkdir -p "$d"
  cp "$TESTS_ROOT/stubs/"* "$d/" 2>/dev/null || true
  cat > "$d/gh" <<'STUB'
#!/bin/bash
# t9396 测试专属 gh stub：scan 形态拦截 + fixture 供数；其余 exec 共享 stub。
set -u
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -z "$LOG_DIR" ]]; then echo "stub gh: STUB_LOG_DIR 未设置" >&2; exit 97; fi
SHARED="${STUB_GH_SHARED:-}"
FIX="${STUB_SCAN_FIXTURE:-}"
is_scan=0; sub=""; page=""; ppage=""; jqexpr=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "--jq" ]]; then jqexpr="$a"; fi
  case "$a" in
    graphql) sub="graphql" ;;
    search/issues) sub="search" ;;
    page=*) page="${a#page=}" ;;
    per_page=*) ppage="${a#per_page=}" ;;
  esac
  prev="$a"
done
if [[ "$sub" == "graphql" || "$sub" == "search" ]]; then
  is_scan=1
fi
if [[ "$is_scan" -eq 1 && -n "$FIX" ]]; then
  n=$(( $(cat "$LOG_DIR/.seq-gh" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$LOG_DIR/.seq-gh"
  line="gh|$PWD|"; first=1
  for a in "$@"; do
    if [[ $first -eq 0 ]]; then line="$line "; fi
    line="$line$a"
    first=0
  done
  printf '%s\n' "$line" >> "$LOG_DIR/calls.log"
  if [[ "${STUB_SCAN_FAIL:-}" == "1" ]]; then
    echo "gh: request failed (t9396-stub-network-down)" >&2
    exit 1
  fi
  resp=""
  if [[ "$sub" == "graphql" ]]; then
    gseq=$(( $(cat "$FIX/.gseq" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$gseq" > "$FIX/.gseq"
    [[ -f "$FIX/graphql-$gseq.out" ]] && resp="$FIX/graphql-$gseq.out"
    [[ -z "$resp" && -f "$FIX/graphql-default.out" ]] && resp="$FIX/graphql-default.out"
  else
    if [[ "$ppage" == "1" ]]; then
      [[ -f "$FIX/total.out" ]] && resp="$FIX/total.out"
    else
      [[ "$page" == "" ]] && page=1
      [[ -f "$FIX/page-$page.out" ]] && resp="$FIX/page-$page.out"
    fi
  fi
  if [[ -z "$resp" ]]; then exit 0; fi
  if [[ -n "$jqexpr" ]]; then
    jq -r "$jqexpr" "$resp" 2>/dev/null || exit 3
  else
    cat "$resp"
  fi
  exit 0
fi
if [[ -n "$SHARED" && -x "$SHARED" ]]; then
  exec "$SHARED" "$@"
fi
echo "stub gh: STUB_GH_SHARED 未设置且非 scan 形态调用" >&2
exit 97
STUB
  chmod +x "$d/gh"
  cat > "$d/date" <<'STUB'
#!/bin/bash
# t9396 测试专属 date stub：共享语义 + '+%F %T' 冻结。
set -u
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -z "$LOG_DIR" ]]; then echo "stub date: STUB_LOG_DIR 未设置" >&2; exit 97; fi
if [[ -n "${STUB_DATE_TODAY:-}" ]]; then
  case "${1:-}" in
    '+%F') printf '%s\n' "$STUB_DATE_TODAY"; exit 0 ;;
    '+%H') printf '%s\n' "${STUB_DATE_HOUR:-00}"; exit 0 ;;
    '+%F %T') printf '%s %s:00:00\n' "$STUB_DATE_TODAY" "${STUB_DATE_HOUR:-00}"; exit 0 ;;
  esac
fi
exec /bin/date "$@"
STUB
  chmod +x "$d/date"
}

build_fixture_main() { # <dir> 主链有货 fixture（与文件 2 同源）
  local d="$1"
  mkdir -p "$d"
  printf '{"total_count":3}\n' > "$d/total.out"
  cat > "$d/page-1.out" <<'JSON'
{"items":[
 {"number":105,"updated_at":"2026-09-10T00:00:00Z"},
 {"number":106,"updated_at":"2026-09-05T00:00:00Z"},
 {"number":104,"updated_at":"2026-09-02T00:00:00Z"},
 {"number":103,"updated_at":"2026-09-01T12:00:00Z"},
 {"number":102,"updated_at":"2026-08-20T09:30:00Z"},
 {"number":101,"updated_at":"2026-08-01T08:00:00Z"}
]}
JSON
  local body300
  body300="$(printf 'x%.0s' {1..300})"
  # 09-17 收口修复（instrument repair）：GraphQL 响应必须带 repository 包裹层——脚本查询与
  # 真实 GitHub 响应均为 {data:{repository:{a1:…}}}，缺层时 .data.repository=null，
  # run_batch 的 to_entries 报错 → tick 恒走 FAILED 假红（与文件 2 同源修复）。
  jq -n --arg long "$body300" '{data:{repository:{
    a0:{number:103,title:"chore: stale three",updatedAt:"2026-09-01T12:00:00Z",mergeable:"MERGEABLE",changedFiles:5,isDraft:false,url:"u103",author:{login:"devThree"},labels:{nodes:[]},latestReviews:{nodes:[]}},
    a1:{number:102,title:"fix: stale two",updatedAt:"2026-08-20T09:30:00Z",mergeable:"CONFLICTING",changedFiles:3,isDraft:true,url:"u102",author:{login:"devTwo"},labels:{nodes:[{name:"sweeper:stale"},{name:"bug"}]},latestReviews:{nodes:[{author:{login:"OutThisLife"},state:"APPROVED",body:"lgtm",submittedAt:"2026-08-21T00:00:00Z"}]}},
    a2:{number:101,title:"feat: stale one",updatedAt:"2026-08-01T08:00:00Z",mergeable:"MERGEABLE",changedFiles:12,isDraft:false,url:"u101",author:{login:"devOne"},labels:{nodes:[{name:"sweeper:salvage-candidate"}]},latestReviews:{nodes:[{author:{login:"teknium1"},state:"CHANGES_REQUESTED",body:("R:"+$long),submittedAt:"2026-08-15T00:00:00Z"}]}}
  }}}' > "$d/graphql-1.out"
}

flush_run() { # [K=V ...] -- ：沙箱内跑 contrib-flush.sh
  # 09-17 收口修复（instrument repair，与文件 2 scan_run 同款）：每个 K=V 必须带 -e 前缀——
  # 裸 K=V 会被 sb_run 参数循环误当 snippet（bash -c "K=V" 纯赋值静默 exit 0），真 snippet 被丢弃。
  local envs=()
  while [[ "${1:-}" != "--" ]]; do
    envs[${#envs[@]}]="-e"
    envs[${#envs[@]}]="$1"
    shift
  done
  shift
  sb_run -e "STUB_SCAN_FIXTURE=$SB_ROOT/tmp/fixture" -e "STUB_GH_SHARED=$TESTS_ROOT/stubs/gh" \
    -e "STUB_DATE_TODAY=$TODAY" ${envs[@]+"${envs[@]}"} \
    'bash "$MARTIN_DIR/scripts/contrib/contrib-flush.sh"'
}

assert_ge() { # <actual> <min> [label]（assert 库无 ge，本地实现）
  if [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ && "$1" -ge "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual=[$1] 期望 >= $2"
  fi
}

stdout_lines() { # <text> → 行数（尾无换行的单行记 1）
  if [[ -z "$1" ]]; then
    printf '0'
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}

t_case "env 前置：contrib-flush.sh 在位 + watch-due-patrol.sh 在位（同一 tick 面前提）"
[[ -f "$FLUSH_F" ]] && _pass "contrib-flush.sh 在位" || _fail "env" "缺失: $FLUSH_F"
[[ -f "$REPO_ROOT/scripts/contrib/watch-due-patrol.sh" ]] && _pass "watch-due-patrol.sh 在位" || _fail "env" "watch-due-patrol.sh 缺失"

# =============================================================================
# S4.P1 [det-machine] flush 含 stale-pr-scan 挂载与 stamp 门槛（fs-grep ≥1 处）
# =============================================================================
t_case "S4.P1 挂载在场：stale-pr-scan.sh 引用 + --tick 调用 + 头注释回退说明"
_n="$(grep -c 'stale-pr-scan' "$FLUSH_F" || true)"
assert_ge "$_n" "1" "flush 引用 stale-pr-scan >=1 处"
_n="$(grep -c -- '--tick' "$FLUSH_F" || true)"
assert_ge "$_n" "1" "flush 以 --tick（stamp 门槛模式）调用 >=1 处"
_n="$(head -n 30 "$FLUSH_F" | grep -c 'stale-pr' || true)"
assert_ge "$_n" "1" "头注释区（前 30 行）含 stale-pr 回退说明（§4.7 回退说明同步）"

t_case "S4.P1 挂载位置：patrol 两行之后、末尾 exit 0 之前（同一确定性 tick 面）"
# 09-17 收口修复（instrument repair）：取「最后」一处 stale-pr-scan 引用为挂载锚——头注释
# 回退说明（§4.7 同步要求）也引用该名，head -1 会命中注释行而非挂载块。
_p="$(grep -n 'watch-due-patrol' "$FLUSH_F" | tail -n 1 | cut -d: -f1)"
_s="$(grep -n 'stale-pr-scan' "$FLUSH_F" | tail -n 1 | cut -d: -f1)"
_e="$(grep -n '^exit 0' "$FLUSH_F" | tail -n 1 | cut -d: -f1)"
if [[ -n "$_p" && -n "$_s" && -n "$_e" ]]; then
  if [[ "$_s" -gt "$_p" && "$_s" -lt "$_e" ]]; then
    _pass "挂载序 patrol(L${_p}) < stale(L${_s}) < exit0(L${_e})"
  else
    _fail "挂载位置" "patrol=L${_p} stale=L${_s} exit0=L${_e}（应 patrol < stale < exit 0）"
  fi
else
  _fail "挂载位置" "锚行缺失: patrol=[$_p] stale=[$_s] exit0=[$_e]"
fi

# =============================================================================
# S4.P5 det 代理（本体 ai-judge 留 QA）：flush diff=挂载形态，主链零改动
# =============================================================================
t_case "S4.P5-det flush diff 形态：主链零删除 + 新增行全落头注释/挂载块"
_d="$(git -C "$REPO_ROOT" diff "${BASELINE_SHA}" -- "$FLUSH_REL" 2>/dev/null || true)"
_del="$(printf '%s\n' "$_d" | grep '^-' | grep -v '^---' || true)"
_add="$(printf '%s\n' "$_d" | grep '^+' | grep -v '^+++' || true)"
# 09-17 收口修复（对齐设计 §4.7 口径，非放宽）：§4.7 明令「回退说明同步」——头注释回退行
# 「两行→四行」与条目 5 句号变分号（为插入条目 6）是设计要求的编辑，属注释层；
# 判据收敛为：**非注释删除行==0**（主链零改动）+ **新增行要么是注释行要么含 stale**（挂载块）。
_del_code="$(printf '%s\n' "$_del" | grep -v '^-#' | grep -c . || true)"
assert_eq "$_del_code" "0" "flush 主链零删除行（非注释删除==0；余: $(printf '%s' "$_del" | head -n 2))"
_bad_add="$(printf '%s\n' "$_add" | grep -v '^[+]#' | grep -vE '^[+][[:space:]]*$' | grep -vic 'stale' || true)"
assert_eq "$_bad_add" "0" "新增行全落头注释/挂载块（非注释行须含 stale；非 0 行: $(printf '%s' "$_add" | grep -v '^[+]#' | grep -vi 'stale' | head -n 2))"

# =============================================================================
# S4.P2 [det-machine] stub 沙箱执行 flush：stdout ≤2 行 ∧ exit==0（含 flush ok）
# =============================================================================
t_case "S4.P2 沙箱 flush 合跑：恒 exit 0 + stdout ≤2 行 + 含 flush ok"
MY_STUBS="$(mktemp -d "${TMPDIR:-/tmp}/t9396-stubs-c.XXXXXX")"
make_my_stubs "$MY_STUBS"
export CONTRIB_TEST_STUBS="$MY_STUBS"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
build_fixture_main "$SB_ROOT/tmp/fixture"
JSONF="$SB_ROOT/contrib-data/stale-pr-scan.json"
out="$(flush_run --)"; rc=$?
assert_exit 0 "$rc" "flush 恒 exit 0（cron harness 契约）"
_n="$(stdout_lines "$out")"
if [[ "$_n" -le 2 ]]; then
  _pass "stdout ≤2 行（实得 ${_n}）"
else
  _fail "stdout 预算" "stdout $_n 行 > 2 行预算: $out"
fi
assert_contains "$out" "flush ok" "stdout 含 flush ok"
assert_ge "$(grep -c 'stale-pr-scan ok' "$SB_ROOT/contrib-data/logs/stale-pr-scan.log" 2>/dev/null || echo 0)" "1" "首轮挂载真跑（stamp 缺失→执行，log ok 行）"
[[ -s "$JSONF" ]] && _pass "首轮 tick 产出 scan JSON" || _fail "首轮 tick" "stamp 缺失应真跑并落 JSON"

# =============================================================================
# S4.P3 [det-machine] 同周第二次执行：scan 产物不重跑（stamp 门）
# =============================================================================
t_case "S4.P3 同周二次执行：JSON 字节不变 + mtime 不变 + scan 日志零新增"
cp "$JSONF" "$SB_ROOT/tmp/before-2nd.json"
_m1="$(stat -f %m "$JSONF" 2>/dev/null || true)"
_l1="$(wc -l < "$SB_ROOT/contrib-data/logs/stale-pr-scan.log" | tr -d ' ')"
out="$(flush_run --)"; rc=$?
assert_exit 0 "$rc" "二次 flush 恒 exit 0"
_n="$(stdout_lines "$out")"
if [[ "$_n" -le 2 ]]; then
  _pass "二次 stdout ≤2 行（实得 ${_n}）"
else
  _fail "二次 stdout 预算" "stdout $_n 行 > 2: $out"
fi
if cmp -s "$SB_ROOT/tmp/before-2nd.json" "$JSONF"; then
  _pass "scan 产物字节不变（stamp 门未重跑）"
else
  _fail "stamp 门" "同周二次执行竟重写了 scan JSON"
fi
_m2="$(stat -f %m "$JSONF" 2>/dev/null || true)"
assert_eq "$_m2" "$_m1" "JSON mtime 不变"
_l2="$(wc -l < "$SB_ROOT/contrib-data/logs/stale-pr-scan.log" | tr -d ' ')"
assert_eq "$_l2" "$_l1" "scan 日志零新增行（tick skip 零噪音）"

# =============================================================================
# S8.P2 [det-machine] scan 失败态下 flush 仍 exit==0 且 stdout ≤2 行
# =============================================================================
t_case "S8.P2 scan 失败态：flush 恒 exit 0 + stdout ≤2 行 + scan FAILED 有账"
# 09-17 收口修复（instrument repair）：重播种过期 stamp——P3 跑后 stamp=今日，tick 会命中
# skip 态短路失败路径（零 gh 调用零日志），「scan 失败不传染」语义需 stamp 已到期才可达。
printf '[2026-09-10 08:00:00] stale-pr-scan ok prev-window-expired\n' > "$SB_ROOT/contrib-data/logs/stale-pr-scan.log"
out="$(flush_run "STUB_SCAN_FAIL=1" --)"; rc=$?
assert_exit 0 "$rc" "scan 失败下 flush 仍 exit 0"
_n="$(stdout_lines "$out")"
if [[ "$_n" -le 2 ]]; then
  _pass "失败态 stdout ≤2 行（实得 ${_n}）"
else
  _fail "失败态 stdout 预算" "stdout $_n 行 > 2: $out"
fi
assert_contains "$out" "flush ok" "失败态 flush 主链仍 ok（scan 失败不传染）"
assert_ge "$(grep -c 'stale-pr-scan FAILED' "$SB_ROOT/contrib-data/logs/stale-pr-scan.log" 2>/dev/null || echo 0)" "1" "scan FAILED 行落日志（不静默）"
sb_cleanup

# =============================================================================
# S4.P4 [det-machine] 改动文件集 ∩ {**/*.plist, **/crontab*, **/cron/**} == ∅
# =============================================================================
t_case "S4.P4 匹配器自证（正向对照：合成违例名必须咬中）"
_forbid_match() { # <path> → 0=命中禁区
  # 09-17 收口修复（instrument repair）：原模式 */cron/* 咬不中 cron.d/、cron.daily/ 等调度目录
  # 形态（S4.P4 的禁区语义是「零新调度面」），放宽为 *cron*/*；负例锚 stale-pr-scan.sh 不含
  # 「cron」子串，不误咬。
  case "$1" in
    *.plist|*crontab*|*cron*/*) return 0 ;;
    *) return 1 ;;
  esac
}
if _forbid_match "x/com.example.job.plist"; then _pass "匹配器咬中 plist"; else _fail "匹配器" "plist 形态漏咬（恒绿空壳）"; fi
if _forbid_match "etc/crontab"; then _pass "匹配器咬中 crontab"; else _fail "匹配器" "crontab 形态漏咬"; fi
if _forbid_match "etc/cron.d/job"; then _pass "匹配器咬中 cron 目录"; else _fail "匹配器" "cron 目录形态漏咬"; fi
if _forbid_match "scripts/contrib/stale-pr-scan.sh"; then _fail "匹配器" "正常脚本误咬"; else _pass "正常脚本不误咬"; fi

t_case "S4.P4 改动文件集（基线..工作区 + 未跟踪）∩ 禁区 == ∅"
change_set() {
  { git -C "$REPO_ROOT" diff --name-only "${BASELINE_SHA}" 2>/dev/null || true
    git -C "$REPO_ROOT" status --porcelain 2>/dev/null | cut -c4- || true
  } | sort -u
}
CS="$(change_set)"
_cs_n="$(printf '%s\n' "$CS" | grep -c . || true)"
assert_ge "$_cs_n" "1" "改动集非空（实现应已落地；空集=无改动可检，本断言防空真）"
_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if _forbid_match "$f"; then
    _hits+="$f
"
  fi
done < <(printf '%s\n' "$CS")
assert_eq "$(printf '%s' "$_hits" | grep -c . || true)" "0" "禁区命中==0（命中: $(printf '%s' "$_hits" | tr '\n' ' '))"

t_finish
