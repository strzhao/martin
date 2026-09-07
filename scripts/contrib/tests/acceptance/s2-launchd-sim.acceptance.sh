#!/usr/bin/env bash
# =============================================================================
# s2-launchd-sim.acceptance.sh — 场景 2：launchd 仿真（cwd=/ + env -i 极简 PATH + 临时 HOME）
# 覆盖谓词：2.P1[real-process] 2.P2[det-machine] 2.P3[det-machine]
# 依据：state.md `## 验收场景`（预注册 SSOT）
# 契约锚点（Bug② 同族）：套件不得依赖调用方 cwd 与用户环境；极简 PATH 下
#   jq/shellcheck/zsh 等按已知前缀（/opt/homebrew/bin、/usr/local/bin、~/.local/bin）自寻。
# CONTRACT_AMBIGUOUS: env -i 下 HOME=<mktemp> 时 hermes 侧 SKILL.md（契约守卫输入）不存在，
#   套件必须容忍其缺失才能绿——该容忍度是实现责任，本测试按谓词原样求值。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s2-p{1,2,3}.out（另 s2-p1.rc 供 2.P3 复核 exit）
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
j(){ printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
[ -f "$SUITE/run.sh" ] || die "env" "套件入口缺失: $SUITE/run.sh"
[ -f "$SUITE/detect/run.sh" ] || die "env" "detect 入口缺失: $SUITE/detect/run.sh"

# -----------------------------------------------------------------------------
# 2.P1 [real-process]
# driver: env -i HOME=<mktemp> TMPDIR=<mktemp> PATH=/usr/bin:/bin:/usr/sbin:/sbin
#         bash <abs>/scripts/contrib/tests/run.sh   （cwd=/）
# assert: exit==0 且 .failed==0 且 .dims.unit>=1 且 .dims.e2e>=1
# -----------------------------------------------------------------------------
P="2.P1"
NEWHOME="$(mktemp -d "${TMPDIR:-/tmp}/acc-s2-home.XXXXXX")"
NEWTMP="$(mktemp -d "${TMPDIR:-/tmp}/acc-s2-tmp.XXXXXX")"
( cd / || exit 97; env -i HOME="$NEWHOME" TMPDIR="$NEWTMP" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    bash "$SUITE/run.sh" </dev/null ) >"$ART/s2-p1.out" 2>&1
RC=$?
[ "$RC" != "97" ] || die "$P" "cd / 失败（launchd cwd 仿真无法建立）"
printf '%s\n' "$RC" > "$ART/s2-p1.rc"
rmdir "$NEWHOME" "$NEWTMP" 2>/dev/null
eq "$RC" 0 "$P launchd 仿真下套件 exit（cwd=/ + env -i 极简 PATH）"
LAST="$(jlast "$ART/s2-p1.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON 摘要: [$LAST]"
j "$LAST" '.failed==0'       || die "$P" ".failed!=0: $LAST"
j "$LAST" '.dims.unit>=1'    || die "$P" ".dims.unit<1: $LAST"
j "$LAST" '.dims.e2e>=1'     || die "$P" ".dims.e2e<1: $LAST"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 2.P2 [det-machine] driver: bash scripts/contrib/tests/detect/run.sh cwd-dep
# assert: exit==0 且 .cases 数>=1 且 .cases[0].pristine_exit==0
# -----------------------------------------------------------------------------
P="2.P2"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/detect/run.sh cwd-dep </dev/null ) >"$ART/s2-p2.out" 2>&1
RC=$?
eq "$RC" 0 "$P detect cwd-dep exit"
LAST="$(jlast "$ART/s2-p2.out")"
printf '%s\n' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "末行不是合法 JSON: [$LAST]"
j "$LAST" '(.cases|length)>=1'          || die "$P" ".cases 数<1: $LAST"
j "$LAST" '.cases[0].pristine_exit==0'  || die "$P" ".cases[0].pristine_exit!=0: $LAST"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 2.P3 [det-machine] driver: fs-grep /tmp/autopilot-artifacts/s2-p1.out
# negate: 输出含 'command not found' 或 'No such file'
# assert: grep -c 'command not found'==0 且 exit==0（复核 s2-p1.rc）
# 反 No-op：若套件在极简 PATH 下静默跳过工具（command not found 被吞），本断言 FAIL
# -----------------------------------------------------------------------------
P="2.P3"
[ -s "$ART/s2-p1.out" ] || die "$P" "前置产物缺失: $ART/s2-p1.out（2.P1 未先执行）"
[ -s "$ART/s2-p1.rc" ]  || die "$P" "前置产物缺失: $ART/s2-p1.rc"
CNF="$(grep -c 'command not found' "$ART/s2-p1.out" || true)"
NSF="$(grep -c 'No such file' "$ART/s2-p1.out" || true)"
eq "$CNF" 0 "$P 'command not found' 出现次数"
eq "$NSF" 0 "$P 'No such file' 出现次数（negate 子句第二模式）"
RC1="$(cat "$ART/s2-p1.rc")"
eq "$RC1" 0 "$P 复核 2.P1 exit code"
echo "PASS ${P}（command not found=0 / No such file=0 / exit=0）"

echo "s2: ALL PASS（2.P1 2.P2 2.P3）"
exit 0
