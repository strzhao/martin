#!/usr/bin/env bash
# =============================================================================
# s3-e2e-smoke.acceptance.sh — 场景 3：端到端沙箱全链路冒烟（六外部命令全 stub）
# 覆盖谓词：3.P1[real-process] 3.P2[det-machine] 3.P3[det-machine]
# 依据：state.md `## 验收场景` + 前置契约 3（e2e-smoke.sh 末行 JSON 形状）
# 反伪机制：3.P3 用 DETECT/E2E_KEEP 保留的沙箱 stub 日志条数与上报 transport_calls
#   互证——stub 日志是第三方可复核的物理证据，上报 JSON 造假即被抓住。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s3-p{1,2,3}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
j(){ printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
[ -f "$SUITE/e2e-smoke.sh" ] || die "env" "冒烟入口缺失: $SUITE/e2e-smoke.sh"

# -----------------------------------------------------------------------------
# 3.P1 [real-process] driver: bash scripts/contrib/tests/e2e-smoke.sh
# assert: exit==0 且 .transport_calls>=1 且 .ledger_appends>=1 且 .queue_transitions>=1
#         且 .prefix_preserved==true 且 .all_lines_valid_json==true
# -----------------------------------------------------------------------------
P="3.P1"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/e2e-smoke.sh </dev/null ) >"$ART/s3-p1.out" 2>&1
RC=$?
eq "$RC" 0 "$P 冒烟 exit"
LAST="$(jlast "$ART/s3-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
j "$LAST" '.transport_calls>=1'    || die "$P" ".transport_calls<1: $LAST"
j "$LAST" '.ledger_appends>=1'     || die "$P" ".ledger_appends<1: $LAST"
j "$LAST" '.queue_transitions>=1'  || die "$P" ".queue_transitions<1: $LAST"
j "$LAST" '.prefix_preserved==true'      || die "$P" ".prefix_preserved!=true: $LAST"
j "$LAST" '.all_lines_valid_json==true'  || die "$P" ".all_lines_valid_json!=true: $LAST"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 3.P2 [det-machine] driver: E2E_STUB_FAIL=hermes bash scripts/contrib/tests/e2e-smoke.sh
# assert: exit!=0（指定传输 stub 非零退出 → 冒烟必须红）
# 反 No-op：若 E2E_STUB_FAIL 是空操作（被无视），冒烟照常绿 → 本断言 FAIL
# -----------------------------------------------------------------------------
P="3.P2"
( cd "$REPO_ROOT" && E2E_STUB_FAIL=hermes bash scripts/contrib/tests/e2e-smoke.sh </dev/null ) >"$ART/s3-p2.out" 2>&1
RC=$?
ne "$RC" 0 "$P E2E_STUB_FAIL=hermes 后冒烟竟然 exit 0"
echo "PASS $P（stub 注毒 → exit=$RC != 0）"

# -----------------------------------------------------------------------------
# 3.P3 [det-machine] driver: E2E_KEEP=1 冒烟后按 JSON stub_log 路径 wc -l
# assert: wc -l == .transport_calls（防伪对照：上报数与物理日志条数互证）
# 说明：按契约 stub 日志一次调用记一行（argv+cwd 编码在单行内），
#       故用 awk 'END{print NR}' 计行（容忍末行无换行符）。
# -----------------------------------------------------------------------------
P="3.P3"
( cd "$REPO_ROOT" && E2E_KEEP=1 bash scripts/contrib/tests/e2e-smoke.sh </dev/null ) >"$ART/s3-p3.out" 2>&1
RC=$?
eq "$RC" 0 "$P E2E_KEEP=1 冒烟 exit"
LAST="$(jlast "$ART/s3-p3.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
STUBLOG="$(printf '%s' "$LAST" | jq -r '.stub_log // empty')"
TC="$(printf '%s' "$LAST" | jq -r '.transport_calls')"
[ -n "$STUBLOG" ] || die "$P" "JSON 未报 stub_log 路径: $LAST"
[ -f "$STUBLOG" ] || die "$P" "上报的 stub_log 文件不存在: $STUBLOG"
LINES="$(awk 'END{print NR}' "$STUBLOG")"
ge "$TC" 1 "$P transport_calls（互证前置：至少一次调用）"
eq "$LINES" "$TC" "$P stub 日志条数($LINES) == 上报 transport_calls($TC) —— 防伪互证失败"
echo "PASS $P（stub_log 条数=$LINES == transport_calls=$TC）"

echo "s3: ALL PASS（3.P1 3.P2 3.P3）"
exit 0
