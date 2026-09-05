#!/usr/bin/env bash
# =============================================================================
# s5-detect-bool-parse.acceptance.sh — 场景 5：捕获① 配置布尔被解析层误读 → 确定性 FAIL
#   （历史 Bug#1：cfg 用 jq `//` 运算符把 notify_dry_run:false 读成默认 true）
# 覆盖谓词：5.P1 5.P2 5.P3（全部 det-machine）
# 依据：state.md `## 验收场景` + 前置契约 4（detect/run.sh JSON 判定形状）
# 5.P3 抗伪机制真实执行：DETECT_KEEP=1 拿到 mutated 副本后，以
#   CONTRIB_TEST_TARGET=<sandbox>/mutated 独立复跑套件——不信任 harness 自述，
#   缺陷必须可第三方复现（exit!=0 且 pristine/mutated diff>=1 行）。
# CONTRACT_AMBIGUOUS: mutated 副本目录布局按预注册 driver 字面取 `<sandbox>/mutated`。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s5-p{1,2,3}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
TARGET="$REPO_ROOT/scripts/contrib"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
j(){ printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }
# detect JSON 三条普适硬断言：cases 数下限 / 全部 pristine 绿 / 全部 mutated 红 / 全部 diff>=1
detect_assert(){
  local pid="$1" json="$2" min="$3"
  j "$json" "(.cases|length)>=$min"                        || die "$pid" ".cases 数<$min: $json"
  j "$json" '[.cases[]|select(.pristine_exit!=0)]|length==0' || die "$pid" "存在 pristine_exit!=0 的 case（pristine 必须绿）: $json"
  j "$json" '[.cases[]|select(.mutated_exit==0)]|length==0'  || die "$pid" "存在 mutated_exit==0 的 case（mutated 必须红）: $json"
  j "$json" '[.cases[]|select((.diff_lines//0)<1)]|length==0' || die "$pid" "存在 diff_lines<1 的 case: $json"
}

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
[ -f "$SUITE/detect/run.sh" ] || die "env" "detect 入口缺失: $SUITE/detect/run.sh"

# -----------------------------------------------------------------------------
# 5.P1 [det-machine] driver: bash scripts/contrib/tests/detect/run.sh bool-parse
# assert: exit==0 且 .cases 数>=2 且 全部 pristine_exit==0 / mutated_exit!=0 /
#         diff_lines>=1
# -----------------------------------------------------------------------------
P="5.P1"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/detect/run.sh bool-parse </dev/null ) >"$ART/s5-p1.out" 2>&1
RC=$?
eq "$RC" 0 "$P detect bool-parse exit"
LAST="$(jlast "$ART/s5-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
detect_assert "$P" "$LAST" 2
echo "PASS ${P}（cases=$(printf '%s' "$LAST" | jq -r '.cases|length')）"

# -----------------------------------------------------------------------------
# 5.P2 [det-machine] driver: fs-grep s5-p1.out
# assert: mutation_desc 长度>=1 且 (mutation_desc+case 名) 含
#         dry/bool/flag/default/fallback 至少其一
# -----------------------------------------------------------------------------
P="5.P2"
[ -s "$ART/s5-p1.out" ] || die "$P" "前置产物缺失: $ART/s5-p1.out"
MDESC="$(jlast "$ART/s5-p1.out" | jq -r '.mutation_desc // empty')"
NAMES="$(jlast "$ART/s5-p1.out" | jq -r '[.cases[].name]|join(" ")')"
[ -n "$MDESC" ] || die "$P" "mutation_desc 为空"
STR="$MDESC $NAMES"
printf '%s' "$STR" | grep -qiE 'dry|bool|flag|default|fallback' \
  || die "$P" "布尔解析层关键词未命中（dry/bool/flag/default/fallback）: [$STR]"
{
  echo "mutation_desc: $MDESC"
  echo "case names: $NAMES"
} > "$ART/s5-p2.out"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 5.P3 [det-machine] 独立复现（第三方不信任 harness 自述）
# driver: DETECT_KEEP=1 detect/run.sh bool-parse
#         → CONTRIB_TEST_TARGET=<sandbox>/mutated bash scripts/contrib/tests/run.sh
# assert: exit!=0 且 pristine/mutated 差异行数>=1
# 反 No-op：若 detect 的缺陷注入是空操作（mutated 与 pristine 同字节），
#           diff 断言 FAIL；若套件守卫是空操作，重跑 exit 断言 FAIL。
# -----------------------------------------------------------------------------
P="5.P3"
( cd "$REPO_ROOT" && DETECT_KEEP=1 bash scripts/contrib/tests/detect/run.sh bool-parse </dev/null ) >"$ART/.s5-p3.detect.out" 2>&1
RC_D=$?
eq "$RC_D" 0 "$P DETECT_KEEP=1 复跑 detect exit"
DETJSON="$(jlast "$ART/.s5-p3.detect.out")"
SB="$(printf '%s' "$DETJSON" | jq -r '.sandbox // empty')"
[ -n "$SB" ] || die "$P" "detect JSON 未报 sandbox 路径: $DETJSON"
[ -d "$SB" ] || die "$P" "DETECT_KEEP 沙箱不存在: $SB"
MUT="$SB/scripts/contrib"
[ -d "$MUT" ] || die "$P" "mutated 副本目录缺失（契约布局 <sandbox>/mutated）: $MUT"

# pristine vs mutated 差异（仅对 7 个生产脚本名求差，避免副本缺 tests/ 造成假差异）
DIFFLINES=0; FOUND=0
for f in notify.sh rq.sh scan_gate.sh deep_check_gate.sh deep-check.sh run-deepcheck.sh run-watch.sh; do
  if [ -f "$TARGET/$f" ] && [ -f "$MUT/$f" ]; then
    FOUND=$((FOUND+1))
    DIFFLINES=$((DIFFLINES + $(/usr/bin/diff "$TARGET/$f" "$MUT/$f" 2>/dev/null | wc -l | tr -d ' ')))
  fi
done
ge "$FOUND" 1 "$P mutated 副本中至少存在一个被注入的生产脚本"
ge "$DIFFLINES" 1 "$P pristine/mutated 差异行数（注入非空操作）"

( cd "$REPO_ROOT" && CONTRIB_TEST_TARGET="$MUT" bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s5-p3.out" 2>&1
RC=$?
ne "$RC" 0 "$P 以 mutated 副本独立复跑套件竟然 exit 0（缺陷不可第三方复现）"
{
  echo "--- detect(DETECT_KEEP=1) JSON: $DETJSON"
  echo "--- mutated 副本: $MUT  diff_lines=$DIFFLINES"
  echo "--- CONTRIB_TEST_TARGET=$MUT 重跑 exit=${RC}（期望非 0）"
} >> "$ART/s5-p3.out"
echo "PASS ${P}（重跑 exit=${RC}，diff=$DIFFLINES 行）"

echo "s5: ALL PASS（5.P1 5.P2 5.P3）"
exit 0
