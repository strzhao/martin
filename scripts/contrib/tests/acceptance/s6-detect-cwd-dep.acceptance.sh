#!/usr/bin/env bash
# =============================================================================
# s6-detect-cwd-dep.acceptance.sh — 场景 6：捕获② launchd cwd 依赖缺失 → 确定性 FAIL
#   （历史 Bug#2：run-deepcheck.sh 缺 `cd "$MARTIN"`，launchd cwd=/ 下 claude 找不到项目 skill）
# 覆盖谓词：6.P1 6.P2（det-machine）
# 依据：state.md `## 验收场景` + 前置契约 4；契约锚点：run-deepcheck.sh cwd 契约
#   （调用 claude 子进程时 $PWD == MARTIN 根）。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s6-p{1,2}.out
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

# -----------------------------------------------------------------------------
# 6.P1 [det-machine] driver: bash scripts/contrib/tests/detect/run.sh cwd-dep
# assert: exit==0 且 .cases 数>=1 且 全部 pristine_exit==0 / mutated_exit!=0 /
#         diff_lines>=1
# 反 No-op：cwd-dep 类若无真实注入（mutated 与 pristine 行为一致），
#   mutated_exit==0 的 case 会被上式抓住；harness 若整体假绿则 exit 断言抓住。
# -----------------------------------------------------------------------------
P="6.P1"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/detect/run.sh cwd-dep </dev/null ) >"$ART/s6-p1.out" 2>&1
RC=$?
eq "$RC" 0 "$P detect cwd-dep exit"
LAST="$(jlast "$ART/s6-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
j "$LAST" "(.cases|length)>=1"                              || die "$P" ".cases 数<1: $LAST"
j "$LAST" '[.cases[]|select(.pristine_exit!=0)]|length==0'  || die "$P" "存在 pristine_exit!=0 的 case: $LAST"
j "$LAST" '[.cases[]|select(.mutated_exit==0)]|length==0'   || die "$P" "存在 mutated_exit==0 的 case（cwd 缺陷未被捕获）: $LAST"
j "$LAST" '[.cases[]|select((.diff_lines//0)<1)]|length==0' || die "$P" "存在 diff_lines<1 的 case: $LAST"
echo "PASS ${P}（cases=$(printf '%s' "$LAST" | jq -r '.cases|length')）"

# -----------------------------------------------------------------------------
# 6.P2 [det-machine] driver: fs-grep s6-p1.out
# assert: mutation_desc 长度>=1 且 (mutation_desc+case 名) 含
#         cwd/PWD/DIR/path/workdir 至少其一
# -----------------------------------------------------------------------------
P="6.P2"
[ -s "$ART/s6-p1.out" ] || die "$P" "前置产物缺失: $ART/s6-p1.out"
MDESC="$(jlast "$ART/s6-p1.out" | jq -r '.mutation_desc // empty')"
NAMES="$(jlast "$ART/s6-p1.out" | jq -r '[.cases[].name]|join(" ")')"
[ -n "$MDESC" ] || die "$P" "mutation_desc 为空"
STR="$MDESC $NAMES"
printf '%s' "$STR" | grep -qiE 'cwd|pwd|dir|path|workdir' \
  || die "$P" "cwd/路径解析层关键词未命中（cwd/PWD/DIR/path/workdir）: [$STR]"
{
  echo "mutation_desc: $MDESC"
  echo "case names: $NAMES"
} > "$ART/s6-p2.out"
echo "PASS $P"

echo "s6: ALL PASS（6.P1 6.P2）"
exit 0
