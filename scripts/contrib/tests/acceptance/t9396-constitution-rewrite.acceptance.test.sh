#!/usr/bin/env bash
# =============================================================================
# t9396-constitution-rewrite.acceptance.test.sh — 卡 t_9396bbf3 红队验收（文件 1/5）
#   宪法改写面：S1 判例式改写（产物1）/ S2 review 目的式 + offer 即 PR（产物2）/
#   S6 残留清点零静默（验收①）/ S9 SKILL.md AI 判断面（产物3 宪法面）
# 谓词来源：state.md `## 验收场景`（预注册 SSOT）+ `## 设计文档` §2/§3/§4.9/§3e。
# 红队纪律：只依据设计文档编写，未读任何蓝队实现；每断言硬失败；无宽容跳过。
# 零谓词正向对照铁律：S1.P1/P2、S6.P1、S9.P2 每条零断言附正向对照
#   （pattern 对 b6c38ce 基线或 SSOT 自证语料命中 >=1，否则 INCONCLUSIVE->FAIL）；
#   S2.P3 两字面量按 SSOT 头注豁免规则以「SSOT 目标段 + BRIEFING.md:18」为对照源。
# ai-judge 谓词（S1.P5/S2.P4/S6.P3/S9.P3）不在此自动化，留 QA 人核；
#   本文件对 S1.P5 附 det 结构代理断言（判例三段/五要素字面量在场）。
# 基线锚：b6c38ce（编排器冻结）。运行期经 git show/git diff 取基线，禁读实现工作区
#   之外的任何现场态；本文件自身不写 contrib-data。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT:-}" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析（非 git 仓库 / git 不可用）: ${SELF_DIR}" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
BASELINE_SHA="b6c38ce"

TASK_DIR="${T9396_TASK_DIR:-/Users/stringzhao/.hermes/kanban/workspaces/t_9396bbf3/.autopilot/runtime/sessions/t_9396bbf3/requirements/20260917-目标-在-martin-仓-worktree}"
ART="${T9396_ART_DIR:-$TASK_DIR/artifacts}"
if ! mkdir -p "$ART" 2>/dev/null; then
  ART="/tmp/autopilot-artifacts"
  mkdir -p "$ART"
fi

export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/assert.sh
source "$TESTS_ROOT/lib/assert.sh"
t_init "$T_FILE"

CONTRIB_REL="hermes-contribution.md"
SKILL_REL="deploy/contrib-operator/SKILL.md"
CONTRIB_F="$REPO_ROOT/$CONTRIB_REL"
SKILL_F="$REPO_ROOT/$SKILL_REL"

# ---------------- 基础取数 ----------------
base_show() { # <relpath> → 基线文件全文（stdout）
  git -C "$REPO_ROOT" show "${BASELINE_SHA}:$1" 2>/dev/null
}

slice() { # <start_re> <end_re>，stdin→stdout：[start 行, end 行之前]
  awk -v sre="$1" -v ere="$2" 'BEGIN{f=0} { if (f && $0 ~ ere) exit; if (!f && $0 ~ sre) { f=1 } ; if (f) print }'
}

count_in() { # <text> <needle> → 字面量出现次数
  printf '%s\n' "$1" | grep -cF -- "$2"
}

nonempty_lines() { # <text> → 非空行数
  printf '%s\n' "$1" | grep -c .
}

CONTRIB_BASE="$(base_show "$CONTRIB_REL")"
CONTRIB_HEAD=""
SKILL_BASE="$(base_show "$SKILL_REL")"
SKILL_HEAD=""
if [[ ! -s "$CONTRIB_F" || ! -s "$SKILL_F" ]]; then
  t_case "env 前置"
  _fail "env" "宪法文件缺失: $CONTRIB_F / $SKILL_F"
  t_finish
fi
CONTRIB_HEAD="$(cat "$CONTRIB_F")"
SKILL_HEAD="$(cat "$SKILL_F")"
CONTRIB_S11_BASE="$(printf '%s\n' "$CONTRIB_BASE" | slice '^## 11[.]' '^## 相关记忆')"
CONTRIB_S11_HEAD="$(printf '%s\n' "$CONTRIB_HEAD" | slice '^## 11[.]' '^## 相关记忆')"
SKILL_S34_BASE="$(printf '%s\n' "$SKILL_BASE" | slice '^### 3[.]4' '^### 3[.]5')"
SKILL_S34_HEAD="$(printf '%s\n' "$SKILL_HEAD" | slice '^### 3[.]4' '^### 3[.]5')"
SKILL_S14_HEAD="$(printf '%s\n' "$SKILL_HEAD" | slice '^## 1[.]' '^## 4[.]')"

t_case "env 前置：基线可达 + 目标区块可定位（防空区块真空真）"
assert_eq "$(count_in "$CONTRIB_BASE" '当日 8 个抢坑 PR 零合入')" "1" "基线锚点可达（正向对照源自证）"
_ne=0
_ne="$(nonempty_lines "$CONTRIB_S11_BASE")"
assert_ge() { # 内联：>= 断言（assert 库无 ge，本地实现）
  if [[ "${1:-}" =~ ^[0-9]+$ && "$1" -ge "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual=[$1] 期望 >= $2"
  fi
}
assert_ge "$_ne" "1" "基线 hermes-contribution.md §11 区块可定位（非空）"
_ne="$(nonempty_lines "$CONTRIB_S11_HEAD")"
assert_ge "$_ne" "1" "HEAD §11 区块可定位（非空——被改写不可删节）"
_ne="$(nonempty_lines "$SKILL_S34_BASE")"
assert_ge "$_ne" "1" "基线 SKILL.md §3.4 区块可定位（非空）"
_ne="$(nonempty_lines "$SKILL_S34_HEAD")"
assert_ge "$_ne" "1" "HEAD SKILL.md §3.4 区块可定位（非空）"
_ne="$(nonempty_lines "$SKILL_S14_HEAD")"
assert_ge "$_ne" "1" "HEAD SKILL.md §1-§4 相关段可定位（非空，S6 目标区块）"

# =============================================================================
# S1.P1 [det-machine] §11 count("分钟级占坑竞速不参与")==0（fs-grep）
# =============================================================================
t_case "S1.P1 判决句零残留：§11 count(分钟级占坑竞速不参与)==0"
_ctrl="$(count_in "$CONTRIB_S11_BASE" '分钟级占坑竞速不参与')"
assert_ge "$_ctrl" "1" "正向对照：pattern 对 b6c38ce §11 命中>=1（非空转）"
_n="$(count_in "$CONTRIB_S11_HEAD" '分钟级占坑竞速不参与')"
assert_eq "$_n" "0" "零残留：HEAD §11 命中==0"

# =============================================================================
# S1.P2 [det-machine] SKILL §3.4 count("不参与分钟竞速")==0（fs-grep）
# =============================================================================
t_case "S1.P2 判决句零残留：SKILL §3.4 count(不参与分钟竞速)==0"
_ctrl="$(count_in "$SKILL_S34_BASE" '不参与分钟竞速')"
assert_ge "$_ctrl" "1" "正向对照：pattern 对 b6c38ce §3.4 命中>=1（非空转）"
_n="$(count_in "$SKILL_S34_HEAD" '不参与分钟竞速')"
assert_eq "$_n" "0" "零残留：HEAD §3.4 命中==0"

# =============================================================================
# S1.P3 [det-machine] 事实锚存续（证据链未删；整行替换后锚随行迁移）
#   正向对照先行：每锚对 b6c38ce 基线 count>=1
# =============================================================================
diff_texts() { # <relpath> <mode: del|add> → 基线..工作区 diff 的删除/新增行集合
  local d
  d="$(git -C "$REPO_ROOT" diff "${BASELINE_SHA}" -- "$1" 2>/dev/null || true)"
  if [[ "$2" == "del" ]]; then
    printf '%s\n' "$d" | grep '^-' | grep -v '^---' || true
  else
    printf '%s\n' "$d" | grep '^+' | grep -v '^+++' || true
  fi
}

anchor_triple() { # <label> <basetext> <headtext> <addtxt> <anchor>
  local label="$1" basetext="$2" headtext="$3" addtxt="$4" anchor="$5"
  assert_ge "$(count_in "$basetext" "$anchor")" "1" "${label} 正向对照：锚在 b6c38ce 基线在场（非空转）"
  assert_ge "$(count_in "$headtext" "$anchor")" "1" "${label} 锚在 HEAD 在场（证据链未删）"
  assert_ge "$(count_in "$addtxt" "$anchor")" "1" "${label} 锚随整行迁移进 diff 新增行（不许消失）"
}

t_case "S1.P3 事实锚存续（hermes-contribution.md 证据链 4 锚）"
_c_del="$(diff_texts "$CONTRIB_REL" del)"
_c_add="$(diff_texts "$CONTRIB_REL" add)"
anchor_triple "S1.P3" "$CONTRIB_BASE" "$CONTRIB_HEAD" "$_c_add" '当日 8 个抢坑 PR 零合入'
anchor_triple "S1.P3" "$CONTRIB_BASE" "$CONTRIB_HEAD" "$_c_add" '7 OPEN + 1 CLOSED'
anchor_triple "S1.P3" "$CONTRIB_BASE" "$CONTRIB_HEAD" "$_c_add" 'anchor ≠ merge'
anchor_triple "S1.P3" "$CONTRIB_BASE" "$CONTRIB_HEAD" "$_c_add" '瓶颈=维护者注意力+质量+证据'

t_case "S1.P3 事实锚存续（SKILL.md 2 锚）"
_s_del="$(diff_texts "$SKILL_REL" del)"
_s_add="$(diff_texts "$SKILL_REL" add)"
anchor_triple "S1.P3-skill" "$SKILL_BASE" "$SKILL_HEAD" "$_s_add" 'anchor ≠ merge'
anchor_triple "S1.P3-skill" "$SKILL_BASE" "$SKILL_HEAD" "$_s_add" '8 个当日抢坑 PR 零合入实证'

# =============================================================================
# S1.P4 [det-machine] HEAD §11 五要素字面量在场
# =============================================================================
t_case "S1.P4 判例式新文本五字面量在场（首车即终态/能则抢/不能则 pass/抢 3 单后复盘/品牌信号）"
assert_ge "$(count_in "$CONTRIB_S11_HEAD" '首车即终态')" "1" "「首车即终态」>=1"
assert_ge "$(count_in "$CONTRIB_S11_HEAD" '能则抢')" "1" "「能则抢」>=1"
assert_ge "$(count_in "$CONTRIB_S11_HEAD" '不能则 pass')" "1" "「不能则 pass」>=1"
assert_ge "$(count_in "$CONTRIB_S11_HEAD" '抢 3 单后复盘')" "1" "「抢 3 单后复盘」>=1"
assert_ge "$(count_in "$CONTRIB_S11_HEAD" '品牌信号')" "1" "「品牌信号」>=1"

# =============================================================================
# S1.P5 [ai-judge] det 结构代理：两改写段判例三段结构 + 意图五要素可指认
#   （ai-judge 本体留 QA；此处只锁设计文档 §2a/§2b 声明的结构字面量）
# =============================================================================
t_case "S1.P5-det-proxy 判例三段/五要素字面量（hermes-contribution.md §11 + SKILL §3.4）"
for lit in '当时事实' '当时判断' '复检活问题' '复现' 'mutation 自证' '无从差异'; do
  assert_ge "$(count_in "$CONTRIB_S11_HEAD" "$lit")" "1" "§11 含判例结构字面量「${lit}」"
done
for lit in '当时判断' '复检活问题' '复现' 'mutation 自证' '测试' '无从差异' '首车即终态'; do
  assert_ge "$(count_in "$SKILL_S34_HEAD" "$lit")" "1" "§3.4 含判例结构字面量「${lit}」"
done

# =============================================================================
# S2.P1 [det-machine] §11 头部+三腿分工表区域五字面量
# =============================================================================
t_case "S2.P1 review 目的式五字面量（稀缺品/差异化根基/频率由 AI 判断/质量红线由 AI 自己守/无数字指标）"
for lit in '稀缺品' '差异化根基' '频率由 AI 判断' '质量红线由 AI 自己守' '无数字指标'; do
  assert_ge "$(count_in "$CONTRIB_S11_HEAD" "$lit")" "1" "§11 含「${lit}」>=1"
done

# =============================================================================
# S2.P2 [det-machine] 逐字保留区零漂移（§3e 清单 + 证据链其余 bullet）
#   以基线 b6c38ce 原文全句为精确锚：HEAD 在场（全行精确匹配）∧ diff 删除行交集==空
# =============================================================================
preserved_violations() { # <base> <head> <del> <range...> → 违例清单（空=通过）
  local base="$1" headt="$2" del="$3"; shift 3
  local r n line out=""
  for r in "$@"; do
    n="$(printf '%s\n' "$base" | sed -n "${r}p" | grep -c . || true)"
    if [[ "$n" -eq 0 ]]; then
      out+="RANGE-EMPTY ${r}\n"
      continue
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if ! printf '%s\n' "$headt" | grep -qFx -- "$line"; then
        out+="MISSING-IN-HEAD [L${r}] ${line:0:80}\n"
      fi
      if printf '%s\n' "$del" | grep -qFx -- "$line"; then
        out+="DELETED [L${r}] ${line:0:80}\n"
      fi
    done < <(printf '%s\n' "$base" | sed -n "${r}p")
  done
  printf '%b' "$out"
}

t_case "S2.P2 逐字保留区零漂移（hermes-contribution.md：证据链其余 bullet + §3e 六区块）"
_vio="$(preserved_violations "$CONTRIB_BASE" "$CONTRIB_HEAD" "$_c_del" \
  180,180 182,183 \
  195,199 202,207 208,208 209,209 211,222 247,256)"
printf '%s\n' "$_vio" > "$ART/t9396-preserved-contribution.txt"
assert_eq "$(printf '%s\n' "$_vio" | grep -c . )" "0" "保留区违例==0（明细: $ART/t9396-preserved-contribution.txt）"

t_case "S2.P2 逐字保留区零漂移（SKILL.md：L25/L31/§7 红线速查/§12 机械层）"
_vio="$(preserved_violations "$SKILL_BASE" "$SKILL_HEAD" "$_s_del" \
  25,25 31,31 235,239 395,427)"
printf '%s\n' "$_vio" > "$ART/t9396-preserved-skill.txt"
assert_eq "$(printf '%s\n' "$_vio" | grep -c . )" "0" "保留区违例==0（明细: $ART/t9396-preserved-skill.txt）"

t_case "S2.P2 锚注入点守卫：「不免费优化对手」边界字面量在 HEAD 在场"
assert_ge "$(count_in "$CONTRIB_HEAD" '不免费优化对手')" "1" "「不免费优化对手」>=1（§11.1a 边界未被削）"

# =============================================================================
# S2.P3 [det-machine] 库存滞留语义废除 + 生命周期新语义在场
#   豁免规则：两字面量为装饰性零断言（基线与 HEAD 均不存在），
#   对照源 = SSOT 头注指定 BRIEFING.md:18（含字面量本体，证可被匹配）
# =============================================================================
t_case "S2.P3 正向对照：字面量本体在 SSOT 指定对照源 BRIEFING.md 可匹配"
BRIEFING="$REPO_ROOT/BRIEFING.md"
if [[ -s "$BRIEFING" ]]; then
  assert_ge "$(count_in "$(cat "$BRIEFING")" '等 offer 时机')" "1" "对照源含「等 offer 时机」（pattern 非空转）"
  assert_ge "$(count_in "$(cat "$BRIEFING")" 'ready 待 offer')" "1" "对照源含「ready 待 offer」（pattern 非空转）"
else
  _fail "S2.P3 对照源" "BRIEFING.md 缺失: ${BRIEFING}（SSOT 指定对照源不可达）"
fi

t_case "S2.P3 滞留语义零残留 + 生命周期新语义在场（§11）"
assert_eq "$(count_in "$CONTRIB_S11_HEAD" '等 offer 时机')" "0" "§11 count(等 offer 时机)==0"
# SSOT 张力注记：设计 §3c 声明的新增文本本身含「无长期 ready 待 offer 滞留态」（否定式提及），
# 谓词 S2.P3 的 count==0 按意图读作「声明式否定形态之外零残留」——
# 先剥离设计逐字声明的否定形态，再对余文求零。
_s11_wo_decl="$(printf '%s\n' "$CONTRIB_S11_HEAD" | sed 's/无长期 ready 待 offer 滞留态//g')"
assert_eq "$(count_in "$_s11_wo_decl" 'ready 待 offer')" "0" "§11 count(ready 待 offer)==0（剔除 §3c 声明式否定形态后）"
assert_ge "$(count_in "$CONTRIB_S11_HEAD" '造→发→盯收敛')" "1" "「造→发→盯收敛」>=1"
_d1="$(count_in "$CONTRIB_S11_HEAD" '立即开我方 PR')"
_d2="$(count_in "$CONTRIB_S11_HEAD" '邀对方 cherry-pick')"
if [[ "$_d1" -ge 1 || "$_d2" -ge 1 ]]; then
  _pass "S2.P3 （立即开我方 PR >=1 或 邀对方 cherry-pick >=1）实得 $_d1/$_d2"
else
  _fail "S2.P3 分发链" "「立即开我方 PR」与「邀对方 cherry-pick」均 0 命中"
fi

# =============================================================================
# S6.P1/P2 [det-machine] 判决类 pattern 残留清点零静默
#   目标区块 = hermes-contribution.md §11 ∪ SKILL.md §1-§4 相关段；
#   分类判据 = 命中行与 b6c38ce 基线逐字一致（预存机械报警/预算/测量仪器条目）；
#   范围外命中只记 artifact（SSOT：范围外命中记 card-notes，不判红）。
# =============================================================================
S6PAT='不参与|至少 ?[0-9]+ ?次|≥ ?[0-9]+ ?才|≥ ?[0-9]+ ?次'
S6_CTRL_CORPUS='分钟级占坑竞速不参与（SSOT S1.P1 例）
至少 3 次（S6 形态自证：至少 ?[0-9]+ ?次）
≥ 5 才（S6 形态自证：≥ ?[0-9]+ ?才）
连续 ≥3 次 none（SSOT S6.P1 例，基线两文件在场）'

t_case "S6.P1 正向对照：4 pattern 各自命中>=1（基线 ∪ SSOT 自证语料）"
for _pat in '不参与' '至少 ?[0-9]+ ?次' '≥ ?[0-9]+ ?才' '≥ ?[0-9]+ ?次'; do
  _ctrl="$( { printf '%s\n' "$CONTRIB_BASE"; printf '%s\n' "$SKILL_BASE"; printf '%s\n' "$S6_CTRL_CORPUS"; } | grep -cE "$_pat" || true)"
  assert_ge "$_ctrl" "1" "pattern「${_pat}」对照命中>=1（非空转）"
done
assert_ge "$(printf '%s\n' "$CONTRIB_BASE" "$SKILL_BASE" | grep -cE '不参与' || true)" "1" "实基线对照：不参与 在 b6c38ce 两文件命中>=1"
assert_ge "$(printf '%s\n' "$SKILL_BASE" | grep -cE '≥ ?[0-9]+ ?次' || true)" "1" "实基线对照：≥N次 在 b6c38ce SKILL 命中>=1"

CLS="$ART/t9396-s6-classification.txt"
UNEXPLAINED=0
TOTAL_HITS=0
scan_region() { # <label> <head_text> <base_text> → 追写分类清单
  local label="$1" headt="$2" base="$3" h hline lineno content
  printf '== %s ==\n' "$label" >> "$CLS"
  h="$(printf '%s\n' "$headt" | grep -nE "$S6PAT" || true)"
  if [[ -z "$h" ]]; then
    printf '零命中（零残留显式声明形态）\n' >> "$CLS"
    return 0
  fi
  while IFS= read -r hline; do
    [[ -z "$hline" ]] && continue
    lineno="${hline%%:*}"
    content="${hline#*:}"
    TOTAL_HITS=$((TOTAL_HITS + 1))
    if printf '%s\n' "$base" | grep -qFx -- "$content"; then
      printf 'HIT %s:%s 类别=基线逐字未改行（机械报警/预算/测量仪器等预存条目）\n' "$label" "$lineno" >> "$CLS"
    else
      printf 'UNEXPLAINED %s:%s %s\n' "$label" "$lineno" "${content:0:100}" >> "$CLS"
      UNEXPLAINED=$((UNEXPLAINED + 1))
    fi
  done <<< "$h"
}

t_case "S6.P1 目标区块残留清点：命中集 ∖ 基线逐字一致条目==∅（零未解释命中）"
printf 'S6.P2 残留分类清单（判据=命中行与基线逐字一致；底册类别=机械报警/预算/测量仪器/评分刻度/历史事实）\n' > "$CLS"
scan_region "hermes-contribution.md §11" "$CONTRIB_S11_HEAD" "$CONTRIB_S11_BASE"
scan_region "SKILL.md §1-§4 相关段" "$SKILL_S14_HEAD" "$(printf '%s\n' "$SKILL_BASE" | slice '^## 1[.]' '^## 4[.]')"
printf '汇总：total_hits=%d unexplained=%d\n' "$TOTAL_HITS" "$UNEXPLAINED" >> "$CLS"
assert_eq "$UNEXPLAINED" "0" "未解释命中==0（清单: ${CLS}）"

t_case "S6.P2 分类清单存在、非空、覆盖两文件"
[[ -s "$CLS" ]] && _pass "S6.P2 清单非空: $CLS" || _fail "S6.P2 清单" "分类清单缺失或为空: $CLS"
assert_ge "$(count_in "$(cat "$CLS")" 'hermes-contribution.md §11')" "1" "清单覆盖 hermes-contribution.md §11"
assert_ge "$(count_in "$(cat "$CLS")" 'SKILL.md §1-§4 相关段')" "1" "清单覆盖 SKILL.md 相关段"

t_case "S6.P1-范围外 NEW 命中盘点（不判红，落 artifact 供 card-notes）"
_oos_new=0
{ while IFS= read -r hline; do
    [[ -z "$hline" ]] && continue
    content="${hline#*:}"
    if ! printf '%s\n' "$CONTRIB_BASE" | grep -qFx -- "$content"; then
      _oos_new=$((_oos_new + 1))
      printf 'NEW-OUT-OF-SCOPE hermes-contribution.md %s\n' "${content:0:100}"
    fi
  done < <(printf '%s\n' "$CONTRIB_HEAD" | grep -nE "$S6PAT" || true)
  while IFS= read -r hline; do
    [[ -z "$hline" ]] && continue
    content="${hline#*:}"
    if ! printf '%s\n' "$SKILL_BASE" | grep -qFx -- "$content"; then
      _oos_new=$((_oos_new + 1))
      printf 'NEW-OUT-OF-SCOPE SKILL.md %s\n' "${content:0:100}"
    fi
  done < <(printf '%s\n' "$SKILL_HEAD" | grep -nE "$S6PAT" || true)
} > "$ART/t9396-s6-out-of-scope.txt" 2>/dev/null
_oos_new="$(grep -c . "$ART/t9396-s6-out-of-scope.txt" || true)"
echo "S6 范围外新增命中（记 card-notes 候选，不判红）: ${_oos_new} 条 → $ART/t9396-s6-out-of-scope.txt"

# =============================================================================
# S9.P1/P2 [det-machine] SKILL.md §3.7 AI 判断面
#   CONTRACT_AMBIGUOUS: §3.7 标题字面量设计未声明——按设计 §4.9 已声明锚
#   「插在 §3.6 末与 ## 4. 能力用法 之间」+ 节号 3.7 定位（^### 3.7）。
# =============================================================================
t_case "S9.P1 §3.7 新段定位 + 三问锚点在场"
S37_START_RE='^### 3[.]7'
S37_END_RE='^## 4[.]'
_s37_head="$(printf '%s\n' "$SKILL_HEAD" | slice "$S37_START_RE" "$S37_END_RE")"
_s37_lines="$(nonempty_lines "$_s37_head")"
if [[ "$_s37_lines" -ge 1 ]]; then
  _pass "S9.P1 §3.7 区块可定位（非空，${_s37_lines} 非空行）"
else
  _fail "S9.P1 §3.7 定位" "未找到 ^### 3.7 区块（插在 §3.6 末与 ## 4. 能力用法 之间）"
fi
for lit in '哪些值得介入' '介入形态' '节奏'; do
  assert_ge "$(count_in "$_s37_head" "$lit")" "1" "§3.7 三问锚点「${lit}」>=1"
done

t_case "S9.P2 §3.7 区块零阈值零数字（>=|<=|至少|最多|每日N|不低于|不超过）"
S9PAT='≥|≤|至少|最多|每日[0-9]+|不低于|不超过'
_ctrl="$(printf '%s\n' "$SKILL_BASE" | grep -cE "$S9PAT" || true)"
assert_ge "$_ctrl" "1" "正向对照：pattern 对 b6c38ce SKILL 全文命中>=1（非空转）"
_ctrl="$(printf '%s\n' '至少 3 次；≥5；≤20（自证语料）' | grep -cE "$S9PAT" || true)"
assert_ge "$_ctrl" "1" "正向对照：pattern 对自证语料命中>=1（matchable）"
_n="$(printf '%s\n' "$_s37_head" | grep -cE "$S9PAT" || true)"
assert_eq "$_n" "0" "§3.7 区块内阈值/数字形态命中==0"

t_finish
