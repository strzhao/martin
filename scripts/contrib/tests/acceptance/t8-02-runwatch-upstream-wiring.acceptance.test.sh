#!/usr/bin/env bash
# =============================================================================
# t8-02-runwatch-upstream-wiring.acceptance.test.sh — T8 验收：run-watch.sh 段 2.6 接线静态断言
#   （验收场景 P5；对既有 run-watch.sh 文件 grep 设计契约字面——是对设计契约的断言，
#   不是读实现：全部期望值取自契约规约 6 的逐字字面）
#   W1  run-watch.sh 存在（被接线宿主）
#   W2  既有六段标记零变化：# --- 1. / 1.5 / 2. / 2.5 / 3. / 4. 各 >= 1（契约6 五段骨架+
#       快车道；t6-04 断言骨架锚）
#   W3  既有 own_pr_watch 引用零变化（t6-04/t7-08 口径：grep -c >= 1）
#   W4  新增段形态四件套（取 own_pr_watch 段标记与 # --- 3. 之间切片）：
#       ① 引用 coder_upstream_gate.sh 字面
#       ② coder_upstream_gate 字面出现 >= 2 次（脚本引用 + 日志行字面，契约6）
#       ③ -x 守卫字面（契约6）
#       ④ run_phase 120 zsh 包裹字面（契约6）
#   W5  位置契约：首个 coder_upstream_gate 引用行号严格落在 own_pr_watch 段标记之后、
#       # --- 3. 标记之前（契约6：own_pr_watch 之后、通知层之前）
#   W6  接线指向真实文件：scripts/contrib/coder_upstream_gate.sh 存在（防接线指向空路径的
#       纸面满足；该文件即 t8-01 黑盒被测对象）
# 依据：kanban 卡 t_6827c2a4 契约规约 6（SSOT）+ 验收场景 P5
# CONTRACT_AMBIGUOUS：无
# 红队纪律：黑盒静态 grep（未读蓝队对 run-watch.sh 的新增段内容/未看 git diff）；每断言硬失败；
#   无 skip；只读既有文件，零沙箱零外发。
# Mental Mutation：段 2.6 整体漏接→W4 五断言全红；位置插错（3 通知层之后）→W5 红；-x 守卫
#   丢（gate 缺失时炸整轮）→W4③ 红；run_phase 超时包裹丢→W4④ 红；日志行字面丢→W4② 红；
#   顺手删既有段标记/own_pr_watch 引用→W2/W3 红；接线指向不存在路径→W6 红。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"

t_init "$T_FILE"

RW="$REPO_ROOT/scripts/contrib/run-watch.sh"
GATE="$REPO_ROOT/scripts/contrib/coder_upstream_gate.sh"

occ() { # <haystack> <needle> → 出现次数（非行数）
  printf '%s\n' "$1" | grep -oF -- "$2" 2>/dev/null | wc -l | tr -d ' '
}
line_no() { # <file> <regex> → 首个命中行号（无命中=空）
  grep -n "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1
}

# =============================================================================
t_case "W1/W6 接线宿主与被指文件存在"
[ -f "$RW" ] && _pass "W1 run-watch.sh 存在" || _fail "W1 run-watch.sh 存在" "$RW 缺失"
[ -f "$GATE" ] && _pass "W6 coder_upstream_gate.sh 存在（接线指向真实文件）" || _fail "W6 coder_upstream_gate.sh 存在" "$GATE 缺失（接线纸面满足）"

# =============================================================================
t_case "W2/W3 既有骨架零变化：六段标记 + own_pr_watch 引用"
M_MARKS=1
for m in '# --- 1.' '# --- 1.5' '# --- 2.' '# --- 2.5' '# --- 3.' '# --- 4.'; do
  n="$(grep -cF -- "$m" "$RW" 2>/dev/null || true)"
  n="${n:-0}"
  case "$n" in
    0) M_MARKS=0; _fail "W2 段标记 $m 存活" "run-watch.sh 零命中（既有五段骨架被破坏）" ;;
    *) _pass "W2 段标记 $m 存活（${n}）" ;;
  esac
done
[ "$M_MARKS" -eq 1 ] && _pass "W2 六段标记整体零变化" || _fail "W2 六段标记整体零变化" "存在缺失标记"
OWN_N="$(grep -c 'own_pr_watch' "$RW" 2>/dev/null || true)"
OWN_N="${OWN_N:-0}"
case "$OWN_N" in
  0) _fail "W3 own_pr_watch 引用保持 >= 1" "既有 own-PR 盯梢段引用丢失（t6-04 骨架被破坏）" ;;
  *) _pass "W3 own_pr_watch 引用保持 >= 1（命中 ${OWN_N}）" ;;
esac

# =============================================================================
t_case "W4 新增段形态四件套（own_pr_watch 段与 # --- 3. 之间切片）"
SLICE="$(sed -n '/^# --- 2\.5/,/^# --- 3\./p' "$RW" 2>/dev/null)"
[ -n "$SLICE" ] && _pass "W4 切片非空（2.5 段与 3. 通知层之间有内容）" || _fail "W4 切片非空" "切片为空（段标记或内容缺失）"
assert_contains "$SLICE" "coder_upstream_gate.sh" "W4① 切片引用 coder_upstream_gate.sh 字面（契约6）"
OCC_N="$(occ "$SLICE" 'coder_upstream_gate')"
case "$OCC_N" in
  ''|*[!0-9]*) _fail "W4② coder_upstream_gate 字面 >= 2 次" "非数值 [$OCC_N]" ;;
  *) [ "$OCC_N" -ge 2 ] && _pass "W4② coder_upstream_gate 字面出现 $OCC_N 次（>=2：脚本引用+日志行字面）" \
       || _fail "W4② coder_upstream_gate 字面 >= 2 次" "实得 $OCC_N < 2（缺脚本引用或日志行字面，契约6）" ;;
esac
assert_contains "$SLICE" "-x" "W4③ 切片含 -x 守卫字面（gate 缺失不炸整轮，契约6）"
assert_contains "$SLICE" "run_phase 120 zsh" "W4④ 切片含 run_phase 120 zsh 包裹字面（契约6）"

# =============================================================================
t_case "W5 位置契约：gate 引用行号 ∈（own_pr_watch 段标记，# --- 3. 标记）开区间"
L25="$(line_no '^# --- 2\.5' "$RW")"
L3="$(line_no '^# --- 3\.' "$RW")"
LREF="$(line_no 'coder_upstream_gate' "$RW")"
POS_OK=0
case "$L25" in ''|*[!0-9]*) _fail "W5 前置" "own_pr_watch 段标记行号不可解析 [$L25]" ;;
*)
  case "$L3" in ''|*[!0-9]*) _fail "W5 前置" "# --- 3. 标记行号不可解析 [$L3]" ;;
  *)
    case "$LREF" in ''|*[!0-9]*) _fail "W5 coder_upstream_gate 引用存在" "run-watch.sh 零引用（段 2.6 未接线）" ;;
    *)
      if [ "$L25" -lt "$LREF" ] && [ "$LREF" -lt "$L3" ]; then
        POS_OK=1
      fi
      [ "$POS_OK" -eq 1 ] && _pass "W5 位置 ${L25} < ${LREF} < ${L3}（own_pr_watch 之后、通知层之前）" \
        || _fail "W5 位置契约" "行号关系不满足：2.5标记=${L25} 首引用=${LREF} 3标记=${L3}（须 ${L25} < ${LREF} < ${L3}）"
      ;;
    esac
  ;;
esac
;;
esac

t_finish
