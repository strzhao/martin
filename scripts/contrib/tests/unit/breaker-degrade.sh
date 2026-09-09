#!/bin/bash
# breaker-degrade.sh — Tier U：断路器语义收窄 + hermes 健康探测（T2）stub 测试矩阵
# 覆盖：
#   ① kanban_card.sh healthcheck 矩阵：exit 闭集 {0,1,3} / down 计数（连续无成功口径，成功即清零）
#     / -hermes-down 事件幂等 / create 前置 gate 读法 a / create stdout 闭集保护 / 超时注入
#   ② run-watch QC×建卡矩阵（经 zsh 镜像生产）：QC 开→建卡照常 + fallback 被 QC 挡（不调 claude）
#     + 幂等 event；QC 闭→claude 原语义回归
#   ③ quota_circuit.sh 零改动自证：.quota-circuit epoch 格式 byte 级不变 + 四子命令行为锚定
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN/GH_BIN stub 沙箱隔离，零真实 hermes/gh/claude 调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "breaker-degrade.sh"

DOWN_FILE_NAME=".hermes-down"

# last_hermes_line → calls.log 中最后一条 hermes 调用行
last_hermes_line() {
  awk -F'|' '$1 == "hermes" { l = $0 } END { if (l != "") print l }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_hermes_arg() { # <子串> → calls.log 中 hermes 行含该子串的次数
  awk -F'|' '$1 == "hermes" && index($0, s) { c++ } END { printf "%d", c + 0 }' s="$1" \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_claude() {
  awk -F'|' '$1 == "claude" { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_claude_scan() { # scan fallback 的 claude 行（notify flush AI 摘要层也调 claude，须按 prompt 锚定）
  awk -F'|' '$1 == "claude" && index($0, "contrib-watch scan") { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
events_grep_count() { # <固定串>
  grep -cF "$1" "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true
}
run_log() { printf '%s' "$SB_ROOT/contrib-data/logs/launchd.log"; }

# gh_issue <number> <title> → 单条 issue JSON（驱动 scan_gate 的 raw 响应）
gh_issue() {
  jq -cn --argjson n "$1" --arg t "$2" \
    '{number:$n,title:$t,labels:[],pull_request:null,user:{login:"someone"},created_at:"2026-09-09T00:00:00Z",comments:0}'
}
# watch_issues <start> — 写两个新 issue 到 gh stub 数据文件
watch_issues() {
  { gh_issue "$1" "a"; gh_issue $((1 + $1)) "b"; } >"$SB_ROOT/gh.rows"
  jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
}
# watch_sb — 每用例新沙箱 + 游标 2000 + 首轮 issue 2001/2002
watch_sb() {
  sb_new >/dev/null 2>&1
  printf '{"last_issue":2000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
  watch_issues 2001
}
# run_watch [K=V ...] — 注入 gh issues 数据源跑一轮 run-watch（zsh，镜像生产）
run_watch() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}
# qc_open_seed — 写未来 epoch 的 .quota-circuit（QC 开闸前置态）
qc_open_seed() {
  printf '%s\n' "$(( $(date +%s) + 3600 ))" >"$SB_ROOT/contrib-data/.quota-circuit"
}
# run_hc [K=V ...] — 沙箱内直跑 kanban_card.sh healthcheck（stdout 捕获，rc 走 $?）
run_hc() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck'
}
# run_create [K=V ...] — 沙箱内直跑 kanban_card.sh create
run_create() {
  local kv extra=() body="$SB_ROOT/tmp-body.md"
  printf '红线段占位 T2-BODY\n' >"$body"
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/tmp-body.md"'
}

# ---------------- ① healthcheck 矩阵 ----------------

t_case "healthcheck: stub 正常 → exit 0 + stdout OK + down 文件清除"
sb_new >/dev/null 2>&1
out="$(run_hc)"
assert_exit 0 $?
assert_eq "$out" "OK" "stdout 一行 OK"
[[ ! -f "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" ]] && _pass "健康 → down 文件不存在（或已清除）" \
  || _fail "健康 → down 文件清除" "down 文件残留: $(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)"

t_case "healthcheck: stub 正常（预置 down=3 脏态）→ exit 0 + down 清零"
sb_new >/dev/null 2>&1
printf '3\n' >"$SB_ROOT/contrib-data/$DOWN_FILE_NAME"
out="$(run_hc)"
assert_exit 0 $?
assert_eq "$out" "OK" "stdout 一行 OK"
[[ ! -f "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" ]] && _pass "任一次成功即清零（连续无成功口径唯一复位点）" \
  || _fail "成功清零" "down=$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME")"

t_case "healthcheck: 失败 1 次 → exit 1 + stdout FAIL* + down=1 + -hermes-down event 恰 1"
sb_new >/dev/null 2>&1
out="$(run_hc STUB_HERMES_FAIL=1)"
assert_exit 1 $?
case "$out" in FAIL*) _pass "stdout FAIL 前缀（${out}）" ;; *) _fail "stdout FAIL 前缀" "实得 [$out]" ;; esac
assert_eq "$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)" "1" "down 计数=1"
assert_eq "$(events_grep_count '"'"$(date +%F)"'-hermes-down"')" "1" "-hermes-down event 入账"

t_case "healthcheck: 连续第 2 次失败 → exit 3 + down=2 + 事件不重复（--key 幂等）"
out="$(run_hc STUB_HERMES_FAIL=1)"
assert_exit 3 $?
case "$out" in FAIL*) _pass "stdout FAIL 前缀" ;; *) _fail "stdout FAIL 前缀" "实得 [$out]" ;; esac
assert_eq "$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)" "2" "down 计数=2"
assert_eq "$(events_grep_count '"'"$(date +%F)"'-hermes-down"')" "1" "事件幂等仍 1 条"

t_case "healthcheck: 跨天口径——预置 down=1（昨日遗留）再败 → 直接 exit 3（不按天衰减，仅成功清零）"
sb_new >/dev/null 2>&1
printf '1\n' >"$SB_ROOT/contrib-data/$DOWN_FILE_NAME"
out="$(run_hc STUB_HERMES_FAIL=1)"
assert_exit 3 $?
assert_eq "$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)" "2" "连续计数跨天累加"
assert_eq "$(events_grep_count 'hermes-down')" "0" "count>=2 不再 emit（仅首败告警）"

t_case "healthcheck: 超时注入（stub delay 2s + HERMES_TIMEOUT=1）→ 视为失败 exit 1 + down=1"
sb_new >/dev/null 2>&1
out="$(run_hc STUB_HERMES_DELAY=2 HERMES_TIMEOUT=1)"
assert_exit 1 $?
case "$out" in FAIL*) _pass "超时归入失败面（{out}）" ;; *) _fail "超时归入失败面" "实得 [$out]" ;; esac
assert_eq "$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)" "1" "超时失败也驱动 down 计数"

t_case "create 前置 gate（读法 a）：down>=2 → exit≠0 + 零 kanban create + stdout 零泄漏"
sb_new >/dev/null 2>&1
printf '2\n' >"$SB_ROOT/contrib-data/$DOWN_FILE_NAME"
out="$(run_create STUB_HERMES_FAIL=1)"
assert_ne $? 0 "down>=2 → 建卡被拒"
assert_eq "$out" "" "create stdout 零输出（gate 输出全部路由 stderr）"
assert_eq "$(count_hermes_arg 'kanban create')" "0" "零 kanban create 调用"

t_case "create 前置 gate（读法 a）：首次失败 exit 1 → 仍继续尝试建卡（验收标准 3）"
sb_new >/dev/null 2>&1
out="$(run_create STUB_HERMES_FAIL_FIRST=1)"
# hc 探测为第 1 次调用（失败）→ gate exit 1 → create 为第 2 次调用（成功）
assert_exit 0 $?
assert_eq "$(count_hermes_arg 'kanban create')" "1" "首败仍尝试建卡"
assert_eq "$(count_hermes_arg 'kanban list')" "1" "gate 探测恰一次"
assert_eq "$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)" "1" "create 失败不写计数、gate 首败写 1"

t_case "create stdout 闭集保护：gate 带脏 down=1 + 健康 stub → stdout 恒一行 {id,status}"
sb_new >/dev/null 2>&1
printf '1\n' >"$SB_ROOT/contrib-data/$DOWN_FILE_NAME"
out="$(run_create)"
assert_exit 0 $?
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "1" "stdout 恰一行"
assert_eq "$(printf '%s' "$out" | jq -cr 'keys | sort | join(",")' 2>/dev/null)" "id,status" "一行 {id,status} JSON 两键闭集"
[[ ! -f "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" ]] && _pass "gate 探测成功顺带清零 down" \
  || _fail "gate 探测清零" "down=$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME")"

t_case "healthcheck: 恢复自动回主路——失败 2 次（down=2）→ stub 正常 → exit 0 + down 清除 + create 恢复"
sb_new >/dev/null 2>&1
run_hc STUB_HERMES_FAIL=1 >/dev/null 2>&1
run_hc STUB_HERMES_FAIL=1 >/dev/null 2>&1
assert_eq "$(cat "$SB_ROOT/contrib-data/$DOWN_FILE_NAME" 2>/dev/null)" "2" "前置 down=2"
out="$(run_hc)"
assert_exit 0 $?
assert_eq "$out" "OK" "恢复探测 OK"
out="$(run_create)"
assert_exit 0 $?
assert_eq "$(count_hermes_arg 'kanban create')" "1" "恢复后 create 正常发起"

# ---------------- ② run-watch QC×建卡矩阵 ----------------

t_case "QC 开 + 命中 → 建卡照常发起（QC 不再挡建卡）+ 零 claude + flight 登记"
watch_sb
qc_open_seed
flag_before="$(cat "$SB_ROOT/contrib-data/.quota-circuit")"
run_watch
assert_exit 0 $?
assert_eq "$(count_hermes_arg 'kanban create')" "1" "QC 开闸建卡照常发起"
assert_eq "$(count_claude_scan)" "0" "QC 开 + 主路成功零 claude"
assert_eq "$(jq -r '.kind // empty' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)" "scan" "flight 正常登记"
assert_eq "$(cat "$SB_ROOT/contrib-data/.quota-circuit")" "$flag_before" "check 只读，.quota-circuit byte 级不变"
assert_eq "$(events_grep_count 'pipeline-failure')" "0" "健康主路零告警"

t_case "QC 开 + 建卡失败 → fallback 入口被调但 claude 不被调 + 语义日志行 + -scan-fallback-skipped 幂等"
watch_sb
qc_open_seed
run_watch "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(count_hermes_arg 'kanban create')" "1" "建卡仍照常发起（注毒才失败）"
assert_eq "$(count_claude_scan)" "0" "QC 开 → fallback 跳过、claude 零调用"
assert_file_contains "$(run_log)" "断路器仅挡兜底路" "语义日志行"
assert_eq "$(events_grep_count '"'"$(date +%F)"'-scan-fallback-skipped"')" "1" "-scan-fallback-skipped 入账"
# 重跑（新命中）→ 幂等 key 仍 1 条
watch_issues 2003
run_watch "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(events_grep_count '"'"$(date +%F)"'-scan-fallback-skipped"')" "1" "同日重跑事件仍 1 条（幂等）"
assert_eq "$(count_claude_scan)" "0" "重跑依旧零 claude"

t_case "QC 闭 + 建卡失败 → claude 兜底被调（原语义回归）"
watch_sb
run_watch "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(count_claude_scan)" "1" "QC 闭 → fallback claude 原样兜底"
assert_eq "$(events_grep_count 'scan-fallback-skipped')" "0" "QC 闭无 skip 事件"

# ---------------- ③ quota_circuit.sh 零改动自证 ----------------

t_case "quota_circuit: epoch 格式 byte 级不变——check 打开不改文件 / clear 清除 / trip 写单整数"
sb_new >/dev/null 2>&1
qc_open_seed
flag="$SB_ROOT/contrib-data/.quota-circuit"
before="$(cat "$flag")"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" check' >/dev/null 2>&1
assert_ne $? 0 "check 打开期 exit 1"
assert_eq "$(cat "$flag")" "$before" "check 后文件 byte 级不变"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" clear' >/dev/null 2>&1
assert_exit 0 $?
[[ ! -f "$flag" ]] && _pass "clear 清除旗标" || _fail "clear 清除旗标" "文件残留"
printf 'Request rejected (429)\n' >"$SB_ROOT/fake-claude.log"
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/quota_circuit.sh" trip "$MARTIN_DIR/fake-claude.log"' >/dev/null 2>&1
assert_exit 0 $?
trip_val=""
trip_val="$(cat "$flag" 2>/dev/null || true)"
case "$trip_val" in
  ''|*[!0-9]*) _fail "trip 写单整数 epoch" "实得 [$trip_val]" ;;
  *) _pass "trip 写单整数 epoch（${trip_val}）" ;;
esac

t_finish
