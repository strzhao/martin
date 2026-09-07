#!/usr/bin/env bash
# =============================================================================
# s1-one-command-suite.acceptance.sh — 场景 1：一条命令运行全套件并全绿
#   （存在性 + 可运行性 + 维度覆盖 + 负对照 + git 追踪）
# 覆盖谓词：1.P1[real-process] 1.P2[det-machine] 1.P3[det-machine] 1.P4[det-machine]
# 依据：state.md `## 验收场景`（预注册 SSOT，优先于自行推导）+ `## 契约规约`
# 红队纪律：只依据设计文档编写，未读任何实现代码；无宽容跳过；
#           任一硬断言失败 → 立即非零退出。
# 产物：/tmp/autopilot-artifacts/s1-p{1,2,3,4}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
j(){ printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用（契约规定 jq 用真身，launchd 极简 PATH 场景由套件自寻）"
[ -f "$SUITE/run.sh" ] || die "env" "套件入口缺失: $SUITE/run.sh"

# -----------------------------------------------------------------------------
# 1.P1 [real-process] driver: bash scripts/contrib/tests/run.sh
# assert: exit==0 且 .failed==0 且 .total>=1 且四维度各 >=1
# -----------------------------------------------------------------------------
P="1.P1"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s1-p1.out" 2>&1
RC=$?
eq "$RC" 0 "$P 套件入口 exit"
LAST="$(jlast "$ART/s1-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON 摘要: [$LAST]"
j "$LAST" '.failed==0'                      || die "$P" ".failed!=0: $LAST"
j "$LAST" '.total>=1'                       || die "$P" ".total<1: $LAST"
j "$LAST" '.dims.unit>=1'                   || die "$P" ".dims.unit<1: $LAST"
j "$LAST" '.dims.contract>=1'               || die "$P" ".dims.contract<1: $LAST"
j "$LAST" '.dims.e2e>=1'                    || die "$P" ".dims.e2e<1: $LAST"
j "$LAST" '.dims.static>=1'                 || die "$P" ".dims.static<1: $LAST"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 1.P2 [det-machine] driver: bash scripts/contrib/tests/run.sh（第二次）
# assert: exit==0 且 .failed==0 且 .total 与 s1-p1.out 的 .total 相等（幂等）
# -----------------------------------------------------------------------------
P="1.P2"
[ -s "$ART/s1-p1.out" ] || die "$P" "前置产物缺失: $ART/s1-p1.out（1.P1 未先执行）"
TOTAL1="$(jlast "$ART/s1-p1.out" | jq -r '.total')"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s1-p2.out" 2>&1
RC=$?
eq "$RC" 0 "$P 第二次执行 exit"
LAST="$(jlast "$ART/s1-p2.out")"
j "$LAST" '.failed==0' || die "$P" "第二次执行 .failed!=0: $LAST"
TOTAL2="$(printf '%s' "$LAST" | jq -r '.total')"
eq "$TOTAL2" "$TOTAL1" "$P .total 幂等（两次执行 total 相同）"
echo "PASS ${P}（total=$TOTAL2 两次一致）"

# -----------------------------------------------------------------------------
# 1.P3 [det-machine] 负对照（杀恒绿空壳）
# driver: CONTRIB_TEST_TARGET=<空 mktemp> bash scripts/contrib/tests/run.sh
# negate/assert: exit!=0（套件必须对空被测目录报红，否则即恒绿空壳）
# 反 No-op：若 CONTRIB_TEST_TARGET 是空操作（被套件无视），本断言必 FAIL
# -----------------------------------------------------------------------------
P="1.P3"
EMPTY_TARGET="$(mktemp -d "${TMPDIR:-/tmp}/acc-s1-empty.XXXXXX")"
( cd "$REPO_ROOT" && CONTRIB_TEST_TARGET="$EMPTY_TARGET" bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s1-p3.out" 2>&1
RC=$?
rm -rf "$EMPTY_TARGET"
ne "$RC" 0 "$P 负对照失败：CONTRIB_TEST_TARGET 指向空目录时套件竟然 exit 0（恒绿空壳）"
echo "PASS ${P}（空目标负对照：exit=$RC != 0）"

# -----------------------------------------------------------------------------
# 1.P4 [det-machine] driver: git ls-files scripts/contrib/tests
# assert: 行数>=3（套件已被 git 追踪，非空文件集）
# 前提：蓝队实现计划步骤 11 已把 scripts/contrib（含 tests/）纳入版本管理
# -----------------------------------------------------------------------------
P="1.P4"
( cd "$REPO_ROOT" && git ls-files scripts/contrib/tests </dev/null ) >"$ART/s1-p4.out" 2>&1
N="$(wc -l < "$ART/s1-p4.out" | tr -d ' ')"
ge "$N" 3 "$P git 追踪的套件文件数"
echo "PASS ${P}（tracked=${N}）"

echo "s1: ALL PASS（1.P1 1.P2 1.P3 1.P4）"
exit 0
