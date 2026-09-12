#!/usr/bin/env bash
# =============================================================================
# t9-02-duty-wiring-faces.acceptance.test.sh — contrib 值班环验收（静态面 + git 面）
# 被测：当前工作树产物形态（SKILL.md 模式七 / run-watch.sh 尾部值班段 / duty_card.sh /
# duty-cardify.sh / duty-ledger gitignore 面 / gate 与 run 全量门）。黑盒：只 grep 设计契约
# 字面（全部取自 state.md「## 验收场景」assert: 字段与「## 契约规约」C9/C11/C13 逐字字面），
# 不读任何新增实现段的内容语义。
#
# 用例 → 验收谓词映射（SSOT = state.md「## 验收场景」）：
#   W1  交付物存在面（duty_card.sh / duty-cardify.sh / SKILL.md / run-watch.sh）
#   W2  场景5.P1：SKILL.md contains 模式七 && duty；P2：kanban-flight/rq.sh set/budget refund/degraded；
#       P3：push/微信/approved/pipeline-failure；P4：archive-request/duty-ledger.md/三段式
#       （另加模式七切片级锚 + 位置契约：模式六 < 模式七 < 异常处理）
#   W3  C11 frontmatter 最小改写：description 追加 duty 且六种模式→七种模式；argument-hint mail 后插 | duty
#   W4  既有六模式零删除（模式一..六 标题存活）
#   W5  场景5.P5：SKILL.md 删除行仅限 frontmatter 两处锚点改写（≤2 且全部 ^description:/^argument-hint:）
#   W6  场景6.P1：contains duty_card.sh harvest/create/apply && line(harvest)<line(create)<line(apply)
#       && 值班段整体位于末行 run-watch done 日志之前（C9 插入点）
#   W7  C9/BRIEFING §4：值班段 fail-soft 形态（|| 计数 ≥3）+ 注释语义三锚（2h / fail-soft / 编排层）
#   W8  场景6.P2：run-watch.sh 删除行数 == 0；既有段标记与 own_pr_watch 引用零变化
#   W9  场景11.P1 工作树形态：全 diff 删除行总数 == 2 且全部为 SKILL.md frontmatter 两锚
#       （C11/场景5.P5 口径：SKILL 两处最小改写豁免）；run-watch.sh 删除列 == 0（严格无豁免）；
#       duty_card.sh/duty-cardify.sh 交付物在位
#   W10 场景11.P4 diff 面：diff 文件集不含 ready-queue.json/approved.log 与六源
#       （state_brief/kanban_card/deepcheck_card/rq/notify 既有脚本零触碰）
#   W11 场景10.P0/P1/P2：duty-ledger.md 存在非空（前置=场景2.P3/3.P3 先行，求值序注意）+
#       git check-ignore rc==0 + git status --porcelain 零出现
#   W12 场景7.P1：gate.sh 末行 GATE: PASS 且 exit 0
#   W13 场景7.P2/P3：run.sh 末行 failed:0 + duty-cardify.sh 用例节计数 ≥7 + 测试源含
#       CONTRIB_TEST_TARGET 与「绝不读写真实」（零生产触达声明）
# 求值时点注：W11.P0 依赖真库台账先行产出；W12/W13 为全量门（分钟级）。其余断言对
#   「基线 f19edc0 → 工作树」恒可求值（提交前后皆成立）。
# CONTRACT_AMBIGUOUS：
#   - 场景11.P1 冻结字面的「变更文件集 == 4 文件」与本红队套件自身落仓后的文件集冲突
#     （验收测试亦为新增文件）→ 按 P1 的可判定内核断言（删除行总数==0 + 四交付物面），
#     全集等值断言留 QA 编排器在仅含蓝队交付的 diff 上求值
#   - 场景11.P2（ls-remote）/P3（单 commit、无 Co-Authored-By）为 commit 后事实 → 留 QA 编排器
# 红队纪律：黑盒静态 grep + git 面（未读蓝队新增段内容语义）；每断言硬失败；无 skip。
# Mental Mutation：模式七漏写 → W2 全挂；写错位置（异常处理之后）→ W2 位置断言挂；
#   frontmatter 未改 → W3 挂；顺手删既有模式 → W4 挂；值班段漏接 → W6 挂；顺序颠倒 →
#   W6 行序挂；fail-soft 丢（rc 上抛改主链退出码）→ W7 挂；删既有段 → W8 挂；改六源 →
#   W10 挂；台账被误入库 → W11 挂；gate/run 红 → W12/W13 挂。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
BASELINE="f19edc0"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"

t_init "$T_FILE"

SKILL="$REPO_ROOT/.claude/skills/contrib-watch/SKILL.md"
RW="$REPO_ROOT/scripts/contrib/run-watch.sh"
DUTY="$REPO_ROOT/scripts/contrib/duty_card.sh"
DC_UNIT="$TESTS_ROOT/unit/duty-cardify.sh"
LEDGER="$REPO_ROOT/contrib-data/duty-ledger.md"
# W11.P0 求值根回退：台账是 gitignore 运行时产物（不入库），worktree 检出面没有它属设计常态；
# 缺失时回退编排层同源 seam MARTIN_DIR 的真实 contrib-data（与 duty_card.sh:39 同源），
# 使断言对真库台账求值（合并进主仓后 REPO_ROOT 即运行时根，本回退不触发，行为不变）
[[ -s "$LEDGER" ]] || LEDGER="${MARTIN_DIR:-$HOME/workspace/martin}/contrib-data/duty-ledger.md"

assert_count_ge() { # <count> <min> [label]
  case "$1" in
    ''|*[!0-9]*) _fail "${3:-}" "计数非数值 [$1]" ;;
    *) if [ "$1" -ge "$2" ]; then _pass "${3:-}"; else _fail "${3:-}" "实得 $1 < 期望下限 $2"; fi ;;
  esac
}
assert_count_eq() { # <count> <expect> [label]
  case "$1" in
    ''|*[!0-9]*) _fail "${3:-}" "计数非数值 [$1]" ;;
    *) if [ "$1" -eq "$2" ]; then _pass "${3:-}"; else _fail "${3:-}" "实得 $1 != 期望 $2"; fi ;;
  esac
}
assert_file_contains() { # <file> <needle literal> [label]
  if [[ ! -f "$1" ]]; then _fail "${3:-}" "文件缺失: $1"; return 0; fi
  if grep -qF -- "$2" "$1"; then _pass "${3:-}"; else _fail "${3:-}" "文件未包含 [$2]"; fi
}
line_no() { # <file> <ERE> → 首个命中行号（无命中=空）
  grep -n "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1
}
deleted_lines_of() { # <repo 相对路径> → git diff 基线..工作树 的删除内容行（^- 开头且非 --- 头）
  git -C "$REPO_ROOT" diff "$BASELINE" -- "$1" 2>/dev/null | grep -E '^-[^-]' || true
}
diff_name_has() { # <子串> → 变更文件集（diff 基线..工作树 ∪ 未跟踪）中含该子串的条数
  {
    git -C "$REPO_ROOT" diff "$BASELINE" --name-only 2>/dev/null
    git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null
  } | grep -cF -- "$1" || true
}

# =============================================================================
t_case "W1 交付物存在面：四件套宿主与被测文件在位"
for f in "$SKILL" "$RW" "$DUTY" "$DC_UNIT"; do
  if [[ -s "$f" ]]; then
    _pass "W1 交付物存在且非空: $(basename "$f")"
  else
    _fail "W1 交付物存在且非空: $(basename "$f")" "$f 缺失或为空"
  fi
done
# contrib-data/ 为运行时目录（真库验收时产生），不在此做静态存在性断言；
# duty-ledger 入库面归 W11（场景10），求值序须在真库场景 2/3 之后。

# =============================================================================
t_case "W2 场景5.P1-P4：SKILL.md 模式七（duty）七点契约锚 + 位置契约"
SLICE="$(sed -n '/^## 模式七/,/^## 异常处理/p' "$SKILL" 2>/dev/null)"
if [[ -n "$SLICE" ]]; then
  _pass "W2 模式七切片非空（模式七节至异常处理之间有正文）"
else
  _fail "W2 模式七切片非空" "模式七节缺失或位置在异常处理之后"
fi
L_M6="$(line_no "$SKILL" '^## 模式六')"
L_M7="$(line_no "$SKILL" '^## 模式七')"
L_EX="$(line_no "$SKILL" '^## 异常处理')"
POS_OK=0
case "$L_M6" in ''|*[!0-9]*) _fail "W2 位置前置" "模式六标题行号不可解析 [$L_M6]" ;;
  *)
    case "$L_M7" in ''|*[!0-9]*) _fail "W2 位置契约" "模式七标题缺失（[$L_M7]）" ;;
      *)
        case "$L_EX" in ''|*[!0-9]*) _fail "W2 位置前置" "异常处理标题行号不可解析 [$L_EX]" ;;
          *) if [ "$L_M6" -lt "$L_M7" ] && [ "$L_M7" -lt "$L_EX" ]; then POS_OK=1; fi ;;
        esac
      ;;
    esac
  ;;
esac
if [ "$POS_OK" -eq 1 ]; then
  _pass "W2 位置契约：模式六(${L_M6}) < 模式七(${L_M7}) < 异常处理(${L_EX})（插于 digest 之后、异常处理之前）"
else
  _fail "W2 位置契约" "行号关系不满足：模式六=${L_M6} 模式七=${L_M7} 异常处理=${L_EX}"
fi
assert_file_contains "$SKILL" "模式七" "W2 场景5.P1 contains 模式七"
assert_file_contains "$SKILL" "duty" "W2 场景5.P1 contains duty"
assert_contains "$SLICE" "kanban-flight" "W2 场景5.P2 白名单一 kanban-flight（切片级）"
assert_contains "$SLICE" "rq.sh set" "W2 场景5.P2 白名单二 rq.sh set（切片级）"
assert_contains "$SLICE" "budget refund" "W2 场景5.P2 白名单三 budget refund（切片级）"
assert_contains "$SLICE" "degraded" "W2 场景5.P2 伤情四值 degraded（切片级）"
assert_file_contains "$SKILL" "kanban-flight" "W2 场景5.P2 文件级 contains kanban-flight"
assert_file_contains "$SKILL" "rq.sh set" "W2 场景5.P2 文件级 contains rq.sh set"
assert_file_contains "$SKILL" "budget refund" "W2 场景5.P2 文件级 contains budget refund"
assert_file_contains "$SKILL" "degraded" "W2 场景5.P2 文件级 contains degraded"
assert_file_contains "$SKILL" "push" "W2 场景5.P3 红线 contains push"
assert_file_contains "$SKILL" "微信" "W2 场景5.P3 红线 contains 微信"
assert_file_contains "$SKILL" "approved" "W2 场景5.P3 红线 contains approved"
assert_file_contains "$SKILL" "pipeline-failure" "W2 场景5.P3 升级通道 contains pipeline-failure"
assert_contains "$SLICE" "pipeline-failure" "W2 升级通道在模式七切片内（切片级）"
assert_file_contains "$SKILL" "archive-request" "W2 场景5.P4 archive 只声明 contains archive-request"
assert_file_contains "$SKILL" "duty-ledger.md" "W2 场景5.P4 台账路径 contains duty-ledger.md"
assert_file_contains "$SKILL" "三段式" "W2 场景5.P4 收尾 contains 三段式"
assert_contains "$SLICE" "archive-request" "W2 archive-request 在模式七切片内（切片级）"
assert_contains "$SLICE" "duty-ledger.md" "W2 duty-ledger.md 在模式七切片内（切片级）"
assert_contains "$SLICE" "三段式" "W2 三段式在模式七切片内（切片级）"
assert_contains "$SLICE" "HERMES_DELEGATED_CHILD_CONTEXT" "W2 fence 理由（HERMES_DELEGATED_CHILD_CONTEXT，设计点三）"
assert_contains "$SLICE" "伤情判定" "W2 伤情判定行动面（设计点一）"

# =============================================================================
t_case "W3 C11 frontmatter 最小改写：description 追加 duty 且七种模式；argument-hint mail 后插 | duty"
FM="$(sed -n '1,/^---$/p' "$SKILL" 2>/dev/null | head -20)"
assert_contains "$FM" "duty" "W3 description 追加 duty 枚举"
assert_contains "$FM" "七种模式" "W3 description 六种模式改写为七种模式"
assert_contains "$FM" "| duty" "W3 argument-hint mail 后插入 | duty"
assert_contains "$FM" "mail" "W3 argument-hint 既有 mail 枚举保留（追加不删）"
assert_contains "$FM" "scan" "W3 argument-hint 既有 scan 枚举保留"

# =============================================================================
t_case "W4 既有六模式零删除：模式一..六标题全部存活"
for m in "模式一" "模式二" "模式三" "模式四" "模式五" "模式六"; do
  N="$(grep -c "^## $m" "$SKILL" 2>/dev/null)"
  assert_count_ge "${N:-0}" 1 "W4 标题「## ${m}」存活"
done

# =============================================================================
t_case "W5 场景5.P5：SKILL.md 删除行仅限 frontmatter 两处锚点改写（≤2 且全为 description/argument-hint）"
DEL_SKILL="$(deleted_lines_of ".claude/skills/contrib-watch/SKILL.md")"
DEL_SKILL_N="$(printf '%s\n' "$DEL_SKILL" | grep -c . || true)"
assert_count_ge "$DEL_SKILL_N" 0 "W5 删除行计数可解析"
if [ "$DEL_SKILL_N" -eq 0 ]; then
  _pass "W5 SKILL.md 零删除行（纯追加形态）"
else
  assert_count_eq "$DEL_SKILL_N" 2 "W5 SKILL.md 删除行数 == 2（frontmatter 两处最小改写上限）"
  BAD=""
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    case "$l" in
      "-description:"*|"-argument-hint:"*) : ;;
      *) BAD="$BAD|$l" ;;
    esac
  done <<<"$DEL_SKILL"
  if [[ -z "$BAD" ]]; then
    _pass "W5 全部删除行均落在 description/argument-hint 两处锚点（模式节区间删除行数 == 0）"
  else
    _fail "W5 全部删除行均落在 frontmatter 两锚点" "越界删除行:$BAD"
  fi
fi

# =============================================================================
t_case "W6 场景6.P1：run-watch 值班段三连字面 + 依次行序 + 位于末行 done 日志之前（C9 插入点）"
assert_file_contains "$RW" "duty_card.sh harvest" "W6 contains duty_card.sh harvest"
assert_file_contains "$RW" "duty_card.sh create" "W6 contains duty_card.sh create"
assert_file_contains "$RW" "duty_card.sh apply" "W6 contains duty_card.sh apply"
L_H="$(line_no "$RW" 'duty_card\.sh harvest')"
L_C="$(line_no "$RW" 'duty_card\.sh create')"
L_A="$(line_no "$RW" 'duty_card\.sh apply')"
L_DONE="$(line_no "$RW" 'run-watch done')"
ORD_OK=0
case "$L_H" in ''|*[!0-9]*) _fail "W6 行序前置" "harvest 调用行不可解析 [$L_H]" ;;
  *)
    case "$L_C" in ''|*[!0-9]*) _fail "W6 行序" "create 调用行不可解析 [$L_C]" ;;
      *)
        case "$L_A" in ''|*[!0-9]*) _fail "W6 行序" "apply 调用行不可解析 [$L_A]" ;;
          *) if [ "$L_H" -lt "$L_C" ] && [ "$L_C" -lt "$L_A" ]; then ORD_OK=1; fi ;;
        esac
      ;;
    esac
  ;;
esac
if [ "$ORD_OK" -eq 1 ]; then
  _pass "W6 行序：harvest(${L_H}) < create(${L_C}) < apply(${L_A})"
else
  _fail "W6 行序" "line(harvest) < line(create) < line(apply) 不满足：${L_H}/${L_C}/${L_A}"
fi
case "$L_DONE" in
  ''|*[!0-9]*) _fail "W6 插入点前置" "run-watch done 日志行不可解析 [$L_DONE]" ;;
  *) assert_count_ge "$L_DONE" 1 "W6 done 日志行存在（C9 末行锚）" ;;
esac
if [[ "$L_DONE" =~ ^[0-9]+$ ]] && [[ "$L_A" =~ ^[0-9]+$ ]]; then
  if [ "$L_A" -lt "$L_DONE" ]; then
    _pass "W6 插入点：值班段末调用(${L_A}) 位于 done 日志(${L_DONE}) 之前（纯尾部追加）"
  else
    _fail "W6 插入点" "apply(${L_A}) 未落在 done 日志(${L_DONE}) 之前"
  fi
fi

# =============================================================================
t_case "W7 C9/BRIEFING §4：值班段 fail-soft 形态与注释语义三锚"
DUTY_SLICE=""
if [[ "$L_H" =~ ^[0-9]+$ && "$L_DONE" =~ ^[0-9]+$ ]]; then
  SLICE_FROM="$(( L_H - 20 ))"
  if [ "$SLICE_FROM" -lt 1 ]; then SLICE_FROM=1; fi
  DUTY_SLICE="$(sed -n "1,${L_DONE}p" "$RW" | tail -n +"${SLICE_FROM}")"
fi
if [[ -n "$DUTY_SLICE" ]]; then
  _pass "W7 值班段切片可得（自首个调用行上溯 20 行至 done 日志，覆盖段首语义注释）"
  ORFC_N="$(printf '%s\n' "$DUTY_SLICE" | grep -cF -- '||' || true)"
  assert_count_ge "${ORFC_N:-0}" 3 "W7 段内 fail-soft 接管字面（||）出现 ≥3 次（三条调用各自接管）"
  assert_contains "$DUTY_SLICE" "2h" "W7 注释语义一：节流缺省每 2h 一轮"
  assert_contains "$DUTY_SLICE" "fail-soft" "W7 注释语义二：段内 fail-soft 不拖死主链"
  assert_contains "$DUTY_SLICE" "编排层" "W7 注释语义三：apply 为编排层代行特权动作"
else
  _fail "W7 值班段切片可得" "切片为空（值班段未接线或行号解析失败）"
fi

# =============================================================================
t_case "W8 场景6.P2：run-watch.sh 删除行数 == 0；既有段标记与 own_pr_watch 引用零变化"
DEL_RW="$(deleted_lines_of "scripts/contrib/run-watch.sh")"
DEL_RW_N="$(printf '%s\n' "$DEL_RW" | grep -c . || true)"
assert_count_eq "${DEL_RW_N:-0}" 0 "W8 run-watch.sh git diff 删除行数 == 0（纯尾部追加）"
for m in '# --- 1.' '# --- 1.5' '# --- 2.' '# --- 2.5' '# --- 3.' '# --- 4.'; do
  N="$(grep -cF -- "$m" "$RW" 2>/dev/null)"
  assert_count_ge "${N:-0}" 1 "W8 既有段标记 $m 存活"
done
OWN_N="$(grep -c 'own_pr_watch' "$RW" 2>/dev/null)"
assert_count_ge "${OWN_N:-0}" 1 "W8 既有 own_pr_watch 引用保持 ≥1"

# =============================================================================
t_case "W9 场景11.P1 工作树形态：全 diff 删除行仅限 SKILL frontmatter 两锚 + 四交付物变更面"
ALL_DEL="$(git -C "$REPO_ROOT" diff "$BASELINE" --numstat 2>/dev/null | awk '{ s += $2 } END { printf "%d", s + 0 }')"
assert_count_eq "${ALL_DEL:-0}" 2 "W9 基线→工作树删除行总数 == 2（仅 SKILL.md frontmatter 两处锚点改写，C11/场景5.P5 口径）"
SKILL_STAT="$(git -C "$REPO_ROOT" diff "$BASELINE" --numstat 2>/dev/null | awk '$3 == ".claude/skills/contrib-watch/SKILL.md" { print $1"/"$2 }')"
if [[ -n "$SKILL_STAT" ]]; then
  _pass "W9 SKILL.md 在变更集（${SKILL_STAT}）"
  SKILL_DEL="$(printf '%s' "$SKILL_STAT" | cut -d/ -f2)"
  assert_count_eq "${SKILL_DEL:-0}" 2 "W9 SKILL.md numstat 删除列 == 2（且经 W5 验证全部落在 description/argument-hint 两锚点）"
else
  _fail "W9 SKILL.md 在变更集" "SKILL.md 未出现在基线 diff（frontmatter 未改写）"
fi
RW_STAT="$(git -C "$REPO_ROOT" diff "$BASELINE" --numstat 2>/dev/null | awk '$3 == "scripts/contrib/run-watch.sh" { print $1"/"$2 }')"
if [[ -n "$RW_STAT" ]]; then
  _pass "W9 run-watch.sh 在变更集（${RW_STAT}）"
  RW_DEL="$(printf '%s' "$RW_STAT" | cut -d/ -f2)"
  assert_count_eq "${RW_DEL:-0}" 0 "W9 run-watch.sh numstat 删除列 == 0（严格纯尾部追加，无豁免）"
else
  _fail "W9 run-watch.sh 在变更集" "run-watch.sh 未出现在基线 diff（值班段未追加）"
fi
if [[ -s "$DUTY" ]]; then
  _pass "W9 新增交付 duty_card.sh 在位（新增文件以存在性断言，未跟踪态 numstat 不可见）"
else
  _fail "W9 新增交付 duty_card.sh 在位" "$DUTY 缺失"
fi
if [[ -s "$DC_UNIT" ]]; then
  _pass "W9 新增交付 tests/unit/duty-cardify.sh 在位"
else
  _fail "W9 新增交付 tests/unit/duty-cardify.sh 在位" "$DC_UNIT 缺失"
fi

# =============================================================================
t_case "W10 场景11.P4 diff 面：红线保护文件与六源既有脚本零触碰"
assert_count_eq "$(diff_name_has 'ready-queue.json')" 0 "W10 变更文件集不含 ready-queue.json"
assert_count_eq "$(diff_name_has 'approved.log')" 0 "W10 变更文件集不含 approved.log"
for s in state_brief.sh kanban_card.sh deepcheck_card.sh rq.sh notify.sh; do
  assert_count_eq "$(diff_name_has "$s")" 0 "W10 既有脚本零触碰: $s 不在变更文件集"
done

# =============================================================================
t_case "W11 场景10：duty-ledger.md 运行时产物不入库（P0 前置=场景2.P3/3.P3 先行保证）"
if [[ -s "$LEDGER" ]]; then
  _pass "W11 场景10.P0 duty-ledger.md 存在且非空"
else
  _fail "W11 场景10.P0 duty-ledger.md 存在且非空" "$LEDGER 缺失或空（求值序：须在真库场景2/3 之后）"
fi
git -C "$REPO_ROOT" check-ignore -q "$REPO_ROOT/contrib-data/duty-ledger.md" 2>/dev/null
assert_exit 0 $? "W11 场景10.P1 git check-ignore contrib-data/duty-ledger.md rc == 0"
PORC_N="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | grep -c 'duty-ledger' || true)"
assert_count_eq "${PORC_N:-0}" 0 "W11 场景10.P2 git status --porcelain 零 duty-ledger 行"

# =============================================================================
t_case "W12 场景7.P1：全量门禁 gate.sh 末行 GATE: PASS 且 exit 0"
GATE_OUT="$(bash "$TESTS_ROOT/gate.sh" 2>/dev/null)"
GATE_RC=$?
GATE_LAST="$(printf '%s\n' "$GATE_OUT" | tail -1)"
assert_exit 0 $GATE_RC
assert_contains "$GATE_LAST" "GATE: PASS" "W12 gate.sh 末行 contains GATE: PASS（实得末行: ${GATE_LAST}）"

# =============================================================================
t_case "W13 场景7.P2/P3：run.sh failed:0 + duty-cardify 用例节计数 ≥7 + 零生产触达声明"
RUN_OUT="$(bash "$TESTS_ROOT/run.sh" 2>/dev/null)"
RUN_RC=$?
RUN_LAST="$(printf '%s\n' "$RUN_OUT" | tail -1)"
assert_exit 0 $RUN_RC
assert_contains "$RUN_LAST" '"failed":0' "W13 run.sh 末行聚合 failed:0（实得末行: ${RUN_LAST}）"
TC_N="$(grep -c '^t_case ' "$DC_UNIT" 2>/dev/null)"
assert_count_ge "${TC_N:-0}" 7 "W13 场景7.P2 duty-cardify.sh 用例节计数 ≥7（实得 ${TC_N:-?}）"
assert_file_contains "$DC_UNIT" "CONTRIB_TEST_TARGET" "W13 场景7.P3 测试源声明 CONTRIB_TEST_TARGET"
assert_file_contains "$DC_UNIT" "绝不读写真实" "W13 场景7.P3 测试源载零生产触达红线声明"

t_finish
