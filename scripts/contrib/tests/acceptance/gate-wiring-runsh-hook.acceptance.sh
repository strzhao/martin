#!/usr/bin/env bash
# =============================================================================
# gate-wiring-runsh-hook.acceptance.sh — 入库验收门集成接线验收（场景 8/9 + regex 单源契约）
# 覆盖谓词：8.P1 8.P2（run.sh 维度聚合集成）/ 9.P1（fs-grep 接线定义）9.P2（real-process 真实提交冒烟，QA 真机执行）
#           附加契约硬断言：fullwidth regex 单源（gate.sh / gate-fullwidth.sh 双引用 + 零内嵌字符类）
# SSOT：.autopilot/runtime/requirements/20260907-需要，实现这里的验收/state.md `## 验收场景` + `## 契约规约`
# 纪律：黑盒视角；mutation 样本只注入 mktemp 临时树（s8.P2 经 CONTRIB_TEST_TARGET 注入）；
#       s9.P2 真实提交走 git worktree 临时树，绝不污染本仓 git 历史；fail closed 不 skip——
#       hooksPath 未装 / 接线文件缺失一律显式 FAIL。
# 产物：/tmp/autopilot-artifacts/s8.p{1,2}.out s9.p{1,2}*.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
GATE="$REPO_ROOT/scripts/contrib/tests/gate.sh"
FWGATE="$REPO_ROOT/scripts/contrib/tests/static/gate-fullwidth.sh"
PATF="$REPO_ROOT/scripts/contrib/tests/lib/fullwidth-pattern.txt"
HOOK="$REPO_ROOT/.githooks/pre-commit"
INSTALL="$REPO_ROOT/scripts/contrib/tests/install-hooks.sh"
ART="/tmp/autopilot-artifacts"
TMPBASE="${TMPDIR:-/tmp}"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" || die "$3" "stdout 未包含 [$2]"; }
has_file(){ # <file> <needle> <label>
  if [ ! -f "$1" ]; then die "$3" "文件缺失: $1"; fi
  if ! grep -qF -- "$2" "$1"; then die "$3" "文件 [$1] 未包含 [$2]"; fi
}
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then die "$3" "不应包含却包含 [$2]"; fi; }

# ---- 环境前提（fail closed） ----
[ -f "$GATE" ] || die "env" "gate.sh 缺失: $GATE"
[ -f "$FWGATE" ] || die "env" "gate-fullwidth.sh 缺失: $FWGATE"
[ -f "$PATF" ] || die "env" "fullwidth regex 单源缺失: $PATF"
[ -f "$HOOK" ] || die "env" "pre-commit 接线缺失: ${HOOK}（场景 9 契约要求入库）"
[ -x "$HOOK" ] || die "env" "pre-commit 不可执行（缺 x 位，git 不会执行它）"
command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"

FW="$(printf '\357\274\210')"   # 全角左括号 U+FF08
fw_sample(){ printf '#!/bin/bash\nset -u\nname="world"\necho "hello $name%s"\n' "$FW" > "$1"; }

# =============================================================================
# 场景 8：与 run.sh 测试维度体系集成
# =============================================================================
P="8.P1"
S8_OUT="$( ( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh ) 2>&1 )" || S8_RC=$?
S8_RC="${S8_RC:-0}"
printf '%s\n' "$S8_OUT" > "$ART/s8.p1.out"
eq "$S8_RC" 0 "$P 干净仓 run.sh 聚合 exit 0（前置）"
has "$S8_OUT" "gate" "$P run.sh stdout 包含 gate 维度结果行（SSOT 谓词字面量）"
has "$S8_OUT" "gate-fullwidth" "$P run.sh 聚合输出含 gate-fullwidth 维度（No-op：不接新 static 文件必挂）"
LAST="$(printf '%s\n' "$S8_OUT" | tail -n 1)"
printf '%s' "$LAST" | jq -e . >/dev/null 2>&1 || die "$P" "run.sh 末行不是合法 JSON: [$LAST]"
printf '%s' "$LAST" | jq -e '.failed==0' >/dev/null 2>&1 || die "$P" ".failed!=0: $LAST"
printf '%s' "$LAST" | jq -e '.dims.static>=5' >/dev/null 2>&1 || die "$P" ".dims.static<5（4 存量 static + gate-fullwidth）: $LAST"
echo "PASS $P"

P="8.P2"
SB="$(mktemp -d "$TMPBASE/gate-acc-s8.XXXXXX")"
cp -R "$REPO_ROOT/scripts" "$SB/scripts" || die "$P" "scripts 树复制失败"
fw_sample "$SB/scripts/contrib/zz-fullwidth-mutation.sh"
S8B_OUT="$( ( cd "$REPO_ROOT" && CONTRIB_TEST_TARGET="$SB" bash scripts/contrib/tests/run.sh ) 2>&1 )" || S8B_RC=$?
S8B_RC="${S8B_RC:-0}"
printf '%s\n' "$S8B_OUT" > "$ART/s8.p2.out"
rm -rf "$SB"
ne "$S8B_RC" 0 "$P 门 FAIL（mutated 沙箱注入全角样本）时 run.sh 必须聚合失败非零退出"
has "$S8B_OUT" "zz-fullwidth-mutation" "$P 失败归因：stdout 必须指认注入样本（证明非无关维度挂）"
echo "PASS $P"

# =============================================================================
# 场景 9：提交流程触发接入
# -----------------------------------------------------------------------------
# 9.P1 [fs-grep]：接线文件内容断言
# =============================================================================
P="9.P1"
{ echo "===== $HOOK ====="; cat "$HOOK"; echo; echo "===== $INSTALL ====="; cat "$INSTALL" 2>/dev/null || echo "(缺失)"; } > "$ART/s9.p1.out"
has_file "$HOOK" "gate" "$P 接线定义引用 gate"
has_file "$HOOK" "scripts/contrib" "$P 路径守卫含 scripts/contrib"
has_file "$HOOK" "scripts/approval" "$P 路径守卫含 scripts/approval（守卫与覆盖集同口径）"
has_file "$HOOK" "MARTIN_GATE_SKIP" "$P 逃生阀环境变量 MARTIN_GATE_SKIP（契约）"
has_file "$HOOK" "gate-skip.log" "$P 跳过台账 gate-skip.log（契约：runtime 可审计）"
[ -f "$INSTALL" ] || die "$P" "install-hooks.sh 缺失: $INSTALL"
has_file "$INSTALL" "core.hooksPath" "$P install-hooks 引用 core.hooksPath"
has_file "$INSTALL" ".githooks" "$P install-hooks 指向 .githooks"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 9.P2 [real-process]：真实提交流程触发门（进程级冒烟，QA 真机执行）
# 验证法（设计冻结）：git worktree 临时树 + 真实 git commit（hooksPath 已装前提）→
#   ① 干净变更放行 exit 0（artifact s9.p2.out：exists && clean exit == 0）
#   ② 全角缺陷变更被阻止（exit != 0，输出含发现与修复指引，HEAD 不动）
#   ③ MARTIN_GATE_SKIP=1 逃生阀放行 + gate-skip.log 台账落地
# 随后清理 worktree，不污染本仓历史。
# -----------------------------------------------------------------------------
P="9.P2"
WT="$(mktemp -d "$TMPBASE/gate-acc-wt.XXXXXX")"
WT_SCRIPTS="$WT/scripts"
WT_LOG="$WT/.autopilot/runtime/gate-skip.log"
OLD_HP="$(git -C "$REPO_ROOT" config core.hooksPath 2>/dev/null || true)"
HP_CHANGED=0
cleanup(){
  if [ "$HP_CHANGED" = "1" ]; then
    if [ -n "$OLD_HP" ]; then git -C "$REPO_ROOT" config core.hooksPath "$OLD_HP" 2>/dev/null || true
    else git -C "$REPO_ROOT" config --unset core.hooksPath 2>/dev/null || true; fi
  fi
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add --detach "$WT" HEAD >/dev/null 2>&1 || die "$P" "git worktree add 失败"
# 覆盖实现产物进 worktree（HEAD 可能尚未包含未提交的新实现文件）
cp -R "$REPO_ROOT/scripts/." "$WT_SCRIPTS/" || die "$P" "worktree scripts 覆盖失败"
cp -R "$REPO_ROOT/.githooks" "$WT/.githooks" || die "$P" "worktree .githooks 覆盖失败"
mkdir -p "$WT/.autopilot/runtime"

if [ "$OLD_HP" != ".githooks" ]; then
  git -C "$REPO_ROOT" config core.hooksPath .githooks || die "$P" "设置 core.hooksPath 失败"
  HP_CHANGED=1
fi

HEAD0="$(git -C "$REPO_ROOT" rev-parse HEAD)"

# ① 干净变更：放行且确有提交
printf '\n# gate-smoke: clean change (acceptance)\n' >> "$WT_SCRIPTS/contrib/notify.sh"
git -C "$WT" add scripts/contrib/notify.sh || die "$P" "stage 干净变更失败"
CLEAN_RC=0
git -C "$WT" commit -m "gate-acc: clean change" > "$ART/s9.p2.clean.out" 2>&1 || CLEAN_RC=$?
eq "$CLEAN_RC" 0 "$P 真实提交干净变更必须放行（hooksPath 已装时门实际执行且全绿）"
HEAD1="$(git -C "$WT" rev-parse HEAD)"
ne "$HEAD1" "$HEAD0" "$P 干净变更确产生提交"

# ② 缺陷变更：被门阻止，HEAD 不动，输出含发现与修复指引
fw_sample "$WT_SCRIPTS/contrib/zz-gate-defect-sample.sh"
git -C "$WT" add scripts/contrib/zz-gate-defect-sample.sh || die "$P" "stage 缺陷样本失败"
DEF_RC=0
git -C "$WT" commit -m "gate-acc: defect change" > "$ART/s9.p2.defect.out" 2>&1 || DEF_RC=$?
ne "$DEF_RC" 0 "$P 全角缺陷变更必须被 pre-commit 阻止（hook 不跑门/门失效则此处必挂）"
eq "$(git -C "$WT" rev-parse HEAD)" "$HEAD1" "$P 被阻止的提交不得改变 HEAD"
has_file "$ART/s9.p2.defect.out" "全角" "$P 阻止输出含 gate 发现（全角）"
has_file "$ART/s9.p2.defect.out" "gate.sh" "$P 阻止输出修复指引指向 gate.sh（契约）"
has_file "$ART/s9.p2.defect.out" "README" "$P 阻止输出修复指引指向 README（契约）"

# ③ 逃生阀：MARTIN_GATE_SKIP=1 放行 + 台账
SKIP_RC=0
MARTIN_GATE_SKIP=1 git -C "$WT" commit -m "gate-acc: skip valve" > "$ART/s9.p2.skip.out" 2>&1 || SKIP_RC=$?
eq "$SKIP_RC" 0 "$P MARTIN_GATE_SKIP=1 逃生阀必须放行"
[ -f "$WT_LOG" ] || die "$P" "逃生阀未落台账: $WT_LOG"
has_file "$WT_LOG" "zz-gate-defect-sample.sh" "$P 台账记录 staged 文件"
HEAD2="$(git -C "$WT" rev-parse HEAD)"
ne "$HEAD2" "$HEAD1" "$P 逃生阀放行确产生提交"

{
  echo "worktree=$WT"
  echo "clean_exit=$CLEAN_RC defect_exit=$DEF_RC skip_exit=$SKIP_RC"
  echo "head0=$HEAD0 head1=$HEAD1 head2=$HEAD2"
  echo "--- clean commit output ---"; cat "$ART/s9.p2.clean.out"
  echo "--- defect commit output ---"; cat "$ART/s9.p2.defect.out"
  echo "--- skip valve log ---"; cat "$WT_LOG"
} > "$ART/s9.p2.out"
echo "PASS ${P}（clean=0 放行 / defect 阻止 / skip 阀+台账）"

# =============================================================================
# 附加契约硬断言：fullwidth regex 单源（gate.sh 与 gate-fullwidth.sh 同读一源，禁双份定义漂移）
# =============================================================================
P="CX-regex-single-source"
[ -s "$PATF" ] || die "$P" "regex 单源文件为空: $PATF"
grep -q "（" "$PATF" || die "$P" "regex 单源不含全角字符（内容异常）"
grep -qF "fullwidth-pattern.txt" "$GATE" || die "$P" "gate.sh 源码未引用 fullwidth-pattern.txt 路径"
grep -qF "fullwidth-pattern.txt" "$FWGATE" || die "$P" "gate-fullwidth.sh 源码未引用 fullwidth-pattern.txt 路径"
CLS='[（）：；，「」｜。？！【】、·]'
if grep -qF -- "$CLS" "$GATE"; then die "$P" "gate.sh 内嵌全角字符类字面量（违反复单源契约）"; fi
if grep -qF -- "$CLS" "$FWGATE"; then die "$P" "gate-fullwidth.sh 内嵌全角字符类字面量（违反复单源契约）"; fi
echo "PASS $P"

echo "gate-wiring-runsh-hook: ALL PASS（场景 8/9 + regex 单源契约）"
exit 0
