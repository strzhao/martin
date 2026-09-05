#!/usr/bin/env bash
# =============================================================================
# s7-detect-ledger-vs-delivery.acceptance.sh — 场景 7：捕获③ 账面成功≠实际送达
#   （历史 Bug#1 的另一面：推送全静默 dry-run 还假标「已推送」）
# 覆盖谓词：7.P1 7.P2 7.P3（det-machine + 行为直证）
# 依据：state.md `## 验收场景` + 契约「真发成功判据」：
#   hermes send rc==0 且 输出 JSON .success==true 才算投递成功；仅此时 events 标
#   pushed:true；任一不满足 → 事件保留 + attempts 递增。
# 7.P3 行为直证：注毒 stub 后直接对沙箱账本 jq 计数——成功记录==0 且失败记录>=1。
# CONTRACT_AMBIGUOUS: 沙箱内部账本路径按 `events.jsonl` 文件名在 sandbox 下发现。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s7-p{1,2,3}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
j(){ printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
[ -f "$SUITE/detect/run.sh" ] || die "env" "detect 入口缺失: $SUITE/detect/run.sh"
[ -f "$SUITE/e2e-smoke.sh" ] || die "env" "冒烟入口缺失: $SUITE/e2e-smoke.sh"

# -----------------------------------------------------------------------------
# 7.P1 [det-machine] driver: bash scripts/contrib/tests/detect/run.sh ledger-vs-delivery
# assert: exit==0 且 .cases 数>=2 且 全部 pristine 绿 / mutated 红 / diff>=1
# -----------------------------------------------------------------------------
P="7.P1"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/detect/run.sh ledger-vs-delivery </dev/null ) >"$ART/s7-p1.out" 2>&1
RC=$?
eq "$RC" 0 "$P detect ledger-vs-delivery exit"
LAST="$(jlast "$ART/s7-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
j "$LAST" "(.cases|length)>=2"                              || die "$P" ".cases 数<2: $LAST"
j "$LAST" '[.cases[]|select(.pristine_exit!=0)]|length==0'  || die "$P" "存在 pristine_exit!=0 的 case: $LAST"
j "$LAST" '[.cases[]|select(.mutated_exit==0)]|length==0'   || die "$P" "存在 mutated_exit==0 的 case（账实分离未被捕获）: $LAST"
j "$LAST" '[.cases[]|select((.diff_lines//0)<1)]|length==0' || die "$P" "存在 diff_lines<1 的 case: $LAST"
echo "PASS $P（cases=$(printf '%s' "$LAST" | jq -r '.cases|length')）"

# -----------------------------------------------------------------------------
# 7.P2 [det-machine] driver: fs-grep s7-p1.out（case 名集合语义覆盖）
# assert: .cases 数>=2 且 含组一（fail/exit/error/status）其一
#              且 含组二（receipt/token/evidence/ack）其一
# -----------------------------------------------------------------------------
P="7.P2"
[ -s "$ART/s7-p1.out" ] || die "$P" "前置产物缺失: $ART/s7-p1.out"
NAMES="$(jlast "$ART/s7-p1.out" | jq -r '[.cases[].name]|join(" ")')"
j "$(jlast "$ART/s7-p1.out")" "(.cases|length)>=2" || die "$P" ".cases 数<2"
printf '%s' "$NAMES" | grep -qiE 'fail|exit|error|status' \
  || die "$P" "组一（忽略失败仍记账）关键词未命中: [$NAMES]"
printf '%s' "$NAMES" | grep -qiE 'receipt|token|evidence|ack' \
  || die "$P" "组二（回执未绑定）关键词未命中: [$NAMES]"
echo "$NAMES" > "$ART/s7-p2.out"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 7.P3 [det-machine] 行为直证
# driver: E2E_STUB_FAIL=hermes E2E_KEEP=1 冒烟后对 sandbox 账本 jq 计数
# assert: 成功类型（pushed==true）记录数==0 且 失败类型（pushed==false）记录数>=1
# 反 No-op：若失败传输仍被标 pushed:true（账实分离 bug 本体），第一断言 FAIL
# -----------------------------------------------------------------------------
P="7.P3"
( cd "$REPO_ROOT" && E2E_STUB_FAIL=hermes E2E_KEEP=1 bash scripts/contrib/tests/e2e-smoke.sh </dev/null ) >"$ART/s7-p3.out" 2>&1
RC_SMOKE=$?
LAST="$(jlast "$ART/s7-p3.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
SB="$(printf '%s' "$LAST" | jq -r '.sandbox // empty')"
[ -n "$SB" ] && [ -d "$SB" ] || die "$P" "E2E_KEEP 沙箱缺失: $SB"
LEDGER="$(find "$SB" -type f -name events.jsonl | head -1)"
[ -n "$LEDGER" ] || die "$P" "沙箱内未发现账本 events.jsonl: $SB"
SUCC="$(jq -s '[.[]|select(.pushed==true)]|length' "$LEDGER" 2>/dev/null)"
FAILC="$(jq -s '[.[]|select(.pushed==false)]|length' "$LEDGER" 2>/dev/null)"
eq "$SUCC" 0 "$P 成功类型记录数（stub 非零退出后账本不得出现 pushed:true）"
ge "$FAILC" 1 "$P 失败类型记录数（失败必须留痕）"
{
  echo "--- 注毒冒烟 exit=$RC_SMOKE（预期非 0）"
  echo "--- 沙箱账本: $LEDGER"
  echo "--- pushed:true=$SUCC / pushed:false=$FAILC"
  cat "$LEDGER"
} >> "$ART/s7-p3.out"
echo "PASS $P（成功=0 失败=$FAILC；冒烟 rc=$RC_SMOKE）"

echo "s7: ALL PASS（7.P1 7.P2 7.P3）"
exit 0
