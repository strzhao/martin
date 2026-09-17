#!/usr/bin/env bash
# =============================================================================
# t9396-gate-and-constraints.acceptance.test.sh — 卡 t_9396bbf3 红队验收（文件 4/5）
#   入库门回归（验收③）：S5.P1 gate.sh PASS / S5.P2 run.sh failed=0 且 total>=1190 /
#   S5.P3 production-writers.tsv 登记 >=2 / S5.P4 测试在案且 total>1190；
#   约束面全检：S7.P1 机械层零触碰 / S7.P2 零 .github / S7.P3 单命令可回滚+对照表 /
#   S7.P4 零 push + gh 只读 / S7.P5 det 代理（改动面收在五类）。
# 谓词来源：state.md `## 验收场景` SSOT + `## 设计文档` §5 契约 7/9。
# 红队纪律：未读实现；本文件真跑 gate.sh 与 run.sh（无网络面）；每断言硬失败。
# 说明：S7.P1/P2/P4 按 SSOT 以「改动文件集 = git diff b6c38ce（工作区含未提交）∪
#   未跟踪」求值，比字面 `git diff b6c38ce..HEAD` 更强（蓝队未 commit 也不空真）。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT:-}" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析: ${SELF_DIR}" >&2
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
assert_ge() { # <actual> <min> [label]（assert 库无 ge，本地实现——与 t9396-stale-scan-offline 同款；
              #   2026-09-18 收口修复：此前未定义，S5.P4 两条断言静默不求值 = instrument hole）
  if [[ "${1:-}" =~ ^[0-9]+$ && "${2:-}" =~ ^[0-9]+$ && "$1" -ge "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual=[$1] 期望 >= $2"
  fi
}
t_init "$T_FILE"

change_set() {
  { git -C "$REPO_ROOT" diff --name-only "${BASELINE_SHA}" 2>/dev/null || true
    git -C "$REPO_ROOT" status --porcelain 2>/dev/null | cut -c4- || true
  } | sort -u
}
nlines() { # <text> → 非空行数
  printf '%s\n' "$1" | grep -c . || true
}

# =============================================================================
# S7.P1 [det-machine] 改动集 ∩ 机械层保护面 == ∅
# =============================================================================
t_case "S7.P1 改动文件集非空（防空真）+ 机械层零触碰"
CS="$(change_set)"
assert_ge "$(nlines "$CS")" "1" "改动文件集非空（实现应已落地；空集=约束检查空真，按 TDD 判红）"
_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    scripts/contrib/l2_ledger.sh|scripts/contrib/rq.sh|scripts/contrib/notify.sh|scripts/approval/*)
      _hits+="$f
" ;;
  esac
done < <(printf '%s\n' "$CS")
assert_eq "$(nlines "$_hits")" "0" "机械层保护面命中==0（命中: $(printf '%s' "$_hits" | tr '\n' ' '))"

# =============================================================================
# S7.P2 [det-machine] 改动集 ∩ .github/** == ∅
# =============================================================================
t_case "S7.P2 .github 零触碰"
_hits=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    .github/*|*/.github/*) _hits+="$f
" ;;
  esac
done < <(printf '%s\n' "$CS")
assert_eq "$(nlines "$_hits")" "0" ".github 命中==0"

# =============================================================================
# S7.P4 [det-machine] 零 push ∧ gh 调用全只读
# =============================================================================
t_case "S7.P4 零 push：含 HEAD 的远端分支必须同时含基线（无新提交上推）"
_rh="$(git -C "$REPO_ROOT" branch -r --contains HEAD 2>/dev/null || true)"
_rb="$(git -C "$REPO_ROOT" branch -r --contains "${BASELINE_SHA}" 2>/dev/null || true)"
if [[ -z "$_rh" ]]; then
  _pass "零远端分支含 HEAD（零 push；含基线的远端分支=[$_rb]）"
else
  _bad=""
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    if ! printf '%s\n' "$_rb" | grep -qFx -- "$b"; then
      _bad+="$b
"
    fi
  done < <(printf '%s\n' "$_rh")
  assert_eq "$(nlines "$_bad")" "0" "远端分支越出基线==0（越界: $(printf '%s' "$_bad" | tr '\n' ' '))"
fi

t_case "S7.P4 gh 写动作零出现（正向对照：匹配器对 gh pr create 必须咬中）"
_ctrl="$(printf 'gh pr create --title x\ngh api -X POST /x\ngh issue comment 1 -b y\n' | grep -cE '(-X|--method) +(POST|PUT|PATCH|DELETE)|gh +(pr|issue|release|repo) +(create|edit|comment|close|delete|merge|lock|pin)' || true)"
assert_ge "$_ctrl" "1" "匹配器对写动作语料命中>=1（非空转）"
_ghbad=0
for f in "$REPO_ROOT/scripts/contrib/stale-pr-scan.sh" "$REPO_ROOT/scripts/contrib/contrib-flush.sh"; do
  [[ -f "$f" ]] || continue
  _n="$(grep -cE '(-X|--method) +(POST|PUT|PATCH|DELETE)|gh +(pr|issue|release|repo) +(create|edit|comment|close|delete|merge|lock|pin)' "$f" || true)"
  _ghbad=$((_ghbad + _n))
done
assert_eq "$_ghbad" "0" "新增/改写脚本 gh 写动作==0"

# =============================================================================
# S7.P5 det 代理（本体 ai-judge 留 QA）：改动面收在设计五类 + 验收测试 + card-notes
# =============================================================================
t_case "S7.P5-det 改动文件集 ⊆ 设计面（7 文件 + acceptance/* + card-notes.md）"
_stray=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    hermes-contribution.md|deploy/contrib-operator/SKILL.md|scripts/contrib/stale-pr-scan.sh|scripts/contrib/contrib-flush.sh|scripts/contrib/tests/lib/production-writers.tsv|scripts/contrib/tests/unit/write-attribution.sh|scripts/contrib/tests/unit/stale-pr-scan.sh|scripts/contrib/tests/acceptance/*|card-notes.md) : ;;
    *) _stray+="$f
" ;;
  esac
done < <(printf '%s\n' "$CS")
assert_eq "$(nlines "$_stray")" "0" "设计面之外改动==0（越界: $(printf '%s' "$_stray" | tr '\n' ' '))"

# =============================================================================
# S7.P3 [det-machine] 全部改动单命令可回滚（对照表在 card-notes.md）
# =============================================================================
t_case "S7.P3 card-notes.md 对照表：在案 + 含基线锚 + 覆盖改动文件"
CARDNOTES=""
for c in "$TASK_DIR/card-notes.md" "$REPO_ROOT/card-notes.md"; do
  [[ -f "$c" && -s "$c" ]] && { CARDNOTES="$c"; break; }
done
if [[ -n "$CARDNOTES" ]]; then
  _pass "对照表在案: $CARDNOTES"
else
  _fail "S7.P3 对照表" "card-notes.md 缺失（找过 $TASK_DIR/card-notes.md 与仓根 card-notes.md）"
fi
if [[ -n "$CARDNOTES" ]]; then
  assert_ge "$(grep -c 'b6c38ce' "$CARDNOTES" || true)" "1" "对照表含基线锚 b6c38ce（回滚命令可一行执行）"
  assert_ge "$(grep -c 'stale-pr-scan' "$CARDNOTES" || true)" "1" "对照表覆盖 stale-pr-scan 交付物"
  _uncov=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in
      scripts/contrib/tests/acceptance/*|card-notes.md) continue ;;
    esac
    _base="$(basename "$f")"
    if ! grep -qF -- "$_base" "$CARDNOTES"; then
      _uncov+="$f
"
    fi
  done < <(printf '%s\n' "$CS")
  assert_eq "$(nlines "$_uncov")" "0" "每个改动文件都被对照表覆盖（未覆盖: $(printf '%s' "$_uncov" | tr '\n' ' '))"
fi

# =============================================================================
# S5.P3 [det-machine] production-writers.tsv 含 stale-pr-scan 条目 >=2（json+log 两面）
# =============================================================================
t_case "S5.P3 写点归属登记：stale-pr-scan 两面（json + log）入表"
TSV="$TESTS_ROOT/lib/production-writers.tsv"
[[ -s "$TSV" ]] && _pass "清单在案且非空: lib/production-writers.tsv" || _fail "S5.P3 清单" "production-writers.tsv 缺失或为空"
assert_ge "$(awk -F'\t' 'NF>=3 && $0 !~ /^#/' "$TSV" | wc -l | tr -d ' ')" "5" "正向对照：清单既有登记行>=5（解析面非空转）"
_rows="$(awk -F'\t' '$2=="stale-pr-scan" && $0 !~ /^#/' "$TSV" || true)"
assert_ge "$(nlines "$_rows")" "2" "stale-pr-scan 登记行>=2"
assert_ge "$(printf '%s\n' "$_rows" | grep -c 'stale-pr-scan\.json' || true)" "1" "JSON 产物面登记在案"
assert_ge "$(printf '%s\n' "$_rows" | grep -c 'logs/stale-pr-scan\.log' || true)" "1" "日志面登记在案"

# =============================================================================
# S5.P1 [det-machine] gate.sh exit==0 且 PASS（N files, 0 findings）
# =============================================================================
t_case "S5.P1 gate.sh 四关全绿"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/gate.sh ) > "$ART/t9396-gate.out" 2>&1
_rc=$?
assert_exit 0 "$_rc" "gate.sh exit==0"
assert_ge "$(grep -cE '^GATE: PASS \([0-9]+ files, 0 findings\)' "$ART/t9396-gate.out" || true)" "1" "gate 末行含 PASS (N files, 0 findings)（明细: $ART/t9396-gate.out）"

# =============================================================================
# S5.P2/S5.P4 [det-machine] run.sh exit==0、failed=0、total>=1190；测试在案且 total>1190
# =============================================================================
t_case "S5.P2 run.sh 全绿：exit==0 ∧ failed==0 ∧ total>=1190（真跑全套件，需数分钟）"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh ) > "$ART/t9396-run.out" 2>&1
_rc=$?
assert_exit 0 "$_rc" "run.sh exit==0"
_LAST="$(tail -n 1 "$ART/t9396-run.out" || true)"
printf '%s\n' "$_LAST" | jq -e . >/dev/null 2>&1 && _pass "末行为合法 JSON 摘要" || _fail "run.sh 末行" "非 JSON: $_LAST"
assert_ge "$(printf '%s' "$_LAST" | jq -r '.total' 2>/dev/null || echo 0)" "1190" "total>=1190（基线不缩水）"
assert_eq "$(printf '%s' "$_LAST" | jq -r '.failed' 2>/dev/null || echo '?')" "0" "failed==0"

t_case "S5.P4 stale-pr-scan 测试在案 ∧ total 严格大于基线 1190"
assert_ge "$(grep -rl 'stale-pr-scan' "$TESTS_ROOT" 2>/dev/null | wc -l | tr -d ' ')" "1" "存在引用 stale-pr-scan 的测试文件"
assert_ge "$(printf '%s' "$_LAST" | jq -r '.total' 2>/dev/null || echo 0)" "1191" "run.sh 总 case 数 > 基线 1190（新单测使 total 上升）"
echo "run.sh 末行: $_LAST"

t_finish
