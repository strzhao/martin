#!/usr/bin/env bash
# =============================================================================
# gate-cli-gates.acceptance.sh — 入库验收门 gate.sh CLI 黑盒验收（场景 1/2/3/4/5/6/7/10）
# 覆盖谓词：1.P1 1.P2 1.P3 / 2.P1 2.P2 2.P3 / 3.P1 3.P2 / 4.P1 4.P2 /
#           5.P1 5.P2 / 6.P1 6.P2 / 7.P1 7.P2 / 10.P1 10.P2 10.P3
# SSOT：.autopilot/runtime/requirements/20260907-需要，实现这里的验收/state.md `## 验收场景`
# 纪律：黑盒视角——只经 `bash scripts/contrib/tests/gate.sh`（含 --target）观察 exit/stdout；
#       缺陷样本一律注入 mktemp 临时树（绝不写仓内 scripts/ 真实树，不断言真实文件含缺陷）；
#       无 warn/skip 宽容，任一硬断言失败立即非零退出。
# 契约锚点：exit 0=全绿 / 1=发现 / 2=依赖缺失；SCAN/COVERAGE/GATE/FAIL 行字面量见契约规约。
# 产物：/tmp/autopilot-artifacts/s{1,2,3,4,5,6,7,10}.p*.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
GATE="$REPO_ROOT/scripts/contrib/tests/gate.sh"
ART="/tmp/autopilot-artifacts"
TMPBASE="${TMPDIR:-/tmp}"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= ${2}）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" || die "$3" "stdout 未包含 [$2]"; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then die "$3" "不应包含却包含 [$2]"; fi; }
has_re(){ printf '%s' "$1" | grep -qE -- "$2" || die "$3" "未匹配正则 [$2]"; }

# ---- 环境前提（fail closed，禁静默 skip） ----
[ -f "$GATE" ] || die "env" "gate.sh 缺失: $GATE"
for t in shellcheck zsh perl git find; do
  command -v "$t" >/dev/null 2>&1 || die "env" "本机缺 ${t}（gate 契约依赖集；验收环境不得缺）"
done

# ---- 样本与临时树工具 ----
FW="$(printf '\357\274\210')"   # 全角左括号 U+FF08（经字节转义构造，避免本测试文件自身命中全角门）

mk_tree(){ # -> 输出临时根路径（含 scripts/contrib + scripts/approval + 1 个干净 approval 样本）
  local r; r="$(mktemp -d "$TMPBASE/gate-acc.XXXXXX")"
  mkdir -p "$r/scripts/contrib" "$r/scripts/approval"
  printf '#!/bin/bash\nexit 0\n' > "$r/scripts/approval/clean-approval.sh"
  printf '%s' "$r"
}
fw_sample(){ printf '#!/bin/bash\nset -u\nname="world"\necho "hello $name%s"\n' "$FW" > "$1"; }
detox_sample(){ printf '#!/bin/bash\nset -u\nname="world"\necho "hello $name(end)"\n' > "$1"; }
syn_sample(){ printf '#!/bin/bash\nif [ -n "$x" ]; then\n  echo hi\n' > "$1"; }
warn_sample(){ printf '#!/bin/bash\nunused_count=42\nexit 0\n' > "$1"; }   # SC2034 = warning 级（实测 0.11.0）
style_sample(){ printf '#!/bin/bash\nfor f in "$@"; do\n  echo $f\ndone\n' > "$1"; }  # SC2086 = info 级（-S warning 放行）
zsh_bad_sample(){ printf '#!/bin/zsh\nif [ -n "x" ]; then\n  echo hi\n' > "$1"; }
pymutation_sample(){ printf 'import os\nmsg = "cost $total%s per item"\n' "$FW" > "$1"; }

run_gate(){ # 经仓根调用 gate.sh（支持 --target 透传）；stdout/stderr 由调用方捕获
  ( cd "$REPO_ROOT" && bash scripts/contrib/tests/gate.sh "$@" )
}
g_run(){ # g_run <errfile> [args...] -> stdout（rc 经 $? 或 || rc=$? 取）
  local ef="$1"; shift
  run_gate "$@" 2>"$ef"
}
art(){ # art <artifact 相对名> <rc> <stdout> <errfile>
  { printf 'exit=%s\n--- stdout ---\n' "$2"; printf '%s\n' "$3"; printf -- '--- stderr ---\n'; cat "$4" 2>/dev/null; } > "$ART/$1"
}
gate_line(){ # 提取 GATE 汇总行
  printf '%s\n' "$1" | grep -E '^GATE: (PASS|FAIL) \([0-9]+ files, [0-9]+ findings\)$' | tail -n 1
}
gate_n(){ printf '%s' "$(gate_line "$1")" | sed -E 's/.*\(([0-9]+) files.*/\1/'; }
gate_m(){ printf '%s' "$(gate_line "$1")" | sed -E 's/.*, ([0-9]+) findings\)/\1/'; }
cleanup_trees(){ for d in "$@"; do [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"; done; }

# 仓内事实（动态计数，不硬编码清单）
FIND_N="$(find "$REPO_ROOT/scripts/contrib" "$REPO_ROOT/scripts/approval" -name '*.sh' -type f | wc -l | tr -d ' ')"
ZSH_N=0
while IFS= read -r f; do
  if head -n 1 "$f" | grep -q zsh; then ZSH_N=$((ZSH_N + 1)); fi
done < <(find "$REPO_ROOT/scripts/contrib" "$REPO_ROOT/scripts/approval" -name '*.sh' -type f)
BASH_N=$((FIND_N - ZSH_N))
TRACKED_N="$(git -C "$REPO_ROOT" ls-files 'scripts/contrib/*.sh' 'scripts/approval/*.sh' | wc -l | tr -d ' ')"

# =============================================================================
# 场景 1：干净仓全绿 — 单命令门对两目录全量 shell 脚本 PASS
# =============================================================================
P="1.P1"
S1_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S1_OUT="$(g_run "$S1_ERR")" || S1_RC=$?
S1_RC="${S1_RC:-0}"
art "s1.p1.out" "$S1_RC" "$S1_OUT" "$S1_ERR"
eq "$S1_RC" 0 "$P 干净仓门 exit（契约：全绿=0）"
if [ -s "$S1_ERR" ]; then die "$P" "干净跑 stderr 应为空（契约：stderr 仅承载意外错误）"; fi
echo "PASS $P"

P="1.P2"
art "s1.p2.out" "$S1_RC" "$S1_OUT" "$S1_ERR"
has "$S1_OUT" "GATE: PASS" "$P 聚合 PASS 字面量"
has "$S1_OUT" "scripts/contrib" "$P 覆盖 contrib 目录字面量"
has "$S1_OUT" "scripts/approval" "$P 覆盖 approval 目录字面量"
has "$S1_OUT" "COVERAGE scripts/contrib scripts/approval" "$P COVERAGE 覆盖面声明行（契约绿跑字面量④）"
has_re "$S1_OUT" '^GATE: PASS \([0-9]+ files, 0 findings\)$' "$P GATE 行格式（0 findings）"
echo "PASS $P"

P="1.P3"
art "s1.p3.out" "$S1_RC" "$S1_OUT" "$S1_ERR"
GN="$(gate_n "$S1_OUT")"
GM="$(gate_m "$S1_OUT")"
ge "$GN" "$TRACKED_N" "$P 扫描文件数 >= git tracked .sh 数（tracked=${TRACKED_N}）"
eq "$GN" "$FIND_N" "$P 扫描文件数 == find 圈定数（find=${FIND_N}；find 圈定无清单维护义务）"
eq "$GM" 0 "$P 干净仓 findings 数"
has "$S1_OUT" "SCAN bash -n: $BASH_N files" "$P SCAN bash -n 汇总行（$BASH_N files）"
has "$S1_OUT" "SCAN zsh -n: $ZSH_N files" "$P SCAN zsh -n 汇总行（$ZSH_N files）"
has "$S1_OUT" "SCAN shellcheck: $BASH_N files" "$P SCAN shellcheck 汇总行（zsh 豁免后 $BASH_N files）"
has "$S1_OUT" "SCAN 全角: $FIND_N files" "$P SCAN 全角汇总行（全量 $FIND_N files）"
echo "PASS ${P}（files=${GN} tracked=${TRACKED_N} zsh=${ZSH_N}）"

# =============================================================================
# 场景 2：全角标点注入样本 FAIL — 门自证杀 No-op mutation（核心红线）
# =============================================================================
P="2.P1"
T_FW="$(mk_tree)"
fw_sample "$T_FW/scripts/contrib/fw-sample.sh"
S2_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S2_OUT="$(g_run "$S2_ERR" --target "$T_FW")" || S2_RC=$?
S2_RC="${S2_RC:-0}"
art "s2.p1.out" "$S2_RC" "$S2_OUT" "$S2_ERR"
ne "$S2_RC" 0 "$P 注入全角样本后门必须非零退出（No-op mutation 若假绿必挂）"
has_re "$S2_OUT" '^GATE: FAIL \(2 files, [0-9]+ findings\)$' "$P GATE FAIL 行（样本树恰 2 个 .sh）"
echo "PASS $P"

P="2.P2"
art "s2.p2.out" "$S2_RC" "$S2_OUT" "$S2_ERR"
has "$S2_OUT" "fw-sample.sh" "$P stdout 指认样本文件路径"
has "$S2_OUT" "全角" "$P fullwidth 类发现行含 全角（契约绿/FAIL 字面量②）"
has "$S2_OUT" "fullwidth" "$P category 枚举字面量 fullwidth"
has_re "$S2_OUT" '^FAIL .*fw-sample\.sh fullwidth .*全角' "$P FAIL 行格式：file + fullwidth + 全角 detail"
cleanup_trees "$T_FW"
echo "PASS $P"

P="2.P3"
T_DX="$(mk_tree)"
detox_sample "$T_DX/scripts/contrib/detox-sample.sh"
S2D_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S2D_OUT="$(g_run "$S2D_ERR" --target "$T_DX")" || S2D_RC=$?
S2D_RC="${S2D_RC:-0}"
art "s2.p3.out" "$S2D_RC" "$S2D_OUT" "$S2D_ERR"
eq "$S2D_RC" 0 "$P 去毒对照样本必须 PASS（仅差全角/半角；证明非误伤面过宽）"
has_re "$S2D_OUT" '^GATE: PASS \(2 files, 0 findings\)$' "$P 对照树 GATE PASS（2 files, 0 findings）"
cleanup_trees "$T_DX"
echo "PASS $P"

# =============================================================================
# 场景 3：bash 语法错误样本 FAIL
# =============================================================================
P="3.P1"
T_SY="$(mk_tree)"
syn_sample "$T_SY/scripts/contrib/syn-sample.sh"
S3_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S3_OUT="$(g_run "$S3_ERR" --target "$T_SY")" || S3_RC=$?
S3_RC="${S3_RC:-0}"
art "s3.p1.out" "$S3_RC" "$S3_OUT" "$S3_ERR"
ne "$S3_RC" 0 "$P 缺 fi 语法非法样本必须非零退出"
has_re "$S3_OUT" '^GATE: FAIL \(2 files, [0-9]+ findings\)$' "$P GATE FAIL 行"
echo "PASS $P"

P="3.P2"
art "s3.p2.out" "$S3_RC" "$S3_OUT" "$S3_ERR"
has "$S3_OUT" "bash -n" "$P 语法类发现行 detail 必含 bash -n（契约字面量①）"
has "$S3_OUT" "syn-sample.sh" "$P 指认样本文件"
has "$S3_OUT" "syntax" "$P category 枚举字面量 syntax"
has_re "$S3_OUT" '^FAIL .*syn-sample\.sh syntax .*bash -n' "$P FAIL 行格式：file + syntax + bash -n"
cleanup_trees "$T_SY"
echo "PASS $P"

# =============================================================================
# 场景 4：shellcheck 阈值双向（-S warning）
# 注：SSOT 样本提示 SC2086，实测 shellcheck 0.11.0 将 SC2086 定级 info（-S warning 放行）；
#     warning 级样本改用 SC2034（实测 warning），SC2086 样本用于 4.P2 style/info 对照。
# =============================================================================
P="4.P1"
T_WN="$(mk_tree)"
warn_sample "$T_WN/scripts/contrib/sc-warn-sample.sh"
S4_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S4_OUT="$(g_run "$S4_ERR" --target "$T_WN")" || S4_RC=$?
S4_RC="${S4_RC:-0}"
art "s4.p1.out" "$S4_RC" "$S4_OUT" "$S4_ERR"
ne "$S4_RC" 0 "$P warning 级（SC2034）发现必须非零退出"
has "$S4_OUT" "shellcheck" "$P category 枚举字面量 shellcheck"
has "$S4_OUT" "sc-warn-sample.sh" "$P 指认样本文件"
has_re "$S4_OUT" '^FAIL .*sc-warn-sample\.sh shellcheck ' "$P FAIL 行格式：file + shellcheck"
cleanup_trees "$T_WN"
echo "PASS $P"

P="4.P2"
T_ST="$(mk_tree)"
style_sample "$T_ST/scripts/contrib/sc-style-sample.sh"
S4B_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S4B_OUT="$(g_run "$S4B_ERR" --target "$T_ST")" || S4B_RC=$?
S4B_RC="${S4B_RC:-0}"
art "s4.p2.out" "$S4B_RC" "$S4B_OUT" "$S4B_ERR"
eq "$S4B_RC" 0 "$P 仅 style/info 级（SC2086）发现必须 PASS（阈值语义：-S warning）"
has_re "$S4B_OUT" '^GATE: PASS \(2 files, 0 findings\)$' "$P 对照树 GATE PASS（info 级不计 findings）"
cleanup_trees "$T_ST"
echo "PASS $P"

# =============================================================================
# 场景 5：zsh 生产脚本走 zsh -n 维度
# =============================================================================
P="5.P1"
S5_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S5_OUT="$(g_run "$S5_ERR")" || S5_RC=$?
S5_RC="${S5_RC:-0}"
art "s5.p1.out" "$S5_RC" "$S5_OUT" "$S5_ERR"
eq "$S5_RC" 0 "$P 干净仓 exit 0（前置）"
has "$S5_OUT" "zsh" "$P stdout 体现 zsh 检查维度"
has "$S5_OUT" "SCAN zsh -n: $ZSH_N files" "$P zsh 维度汇总行（本仓实测 zsh shebang $ZSH_N 个）"
ge "$ZSH_N" 3 "$P zsh 生产脚本数下限（deep-check/run-deepcheck/run-watch）"
echo "PASS ${P}（zsh=${ZSH_N}）"

P="5.P2"
T_ZB="$(mk_tree)"
zsh_bad_sample "$T_ZB/scripts/contrib/zsh-bad-sample.sh"
S5B_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S5B_OUT="$(g_run "$S5B_ERR" --target "$T_ZB")" || S5B_RC=$?
S5B_RC="${S5B_RC:-0}"
art "s5.p2.out" "$S5B_RC" "$S5B_OUT" "$S5B_ERR"
ne "$S5B_RC" 0 "$P zsh 语法非法样本必须非零退出"
has "$S5B_OUT" "zsh -n" "$P 发现行 detail 必含 zsh -n（契约字面量①）"
has "$S5B_OUT" "zsh-bad-sample.sh" "$P 指认样本文件"
cleanup_trees "$T_ZB"
echo "PASS $P"

# =============================================================================
# 场景 6：聚合退出码 — 多缺陷一次运行全部暴露
# =============================================================================
P="6.P1"
T_DU="$(mk_tree)"
fw_sample "$T_DU/scripts/contrib/dual-fw-sample.sh"
warn_sample "$T_DU/scripts/contrib/dual-warn-sample.sh"
S6_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S6_OUT="$(g_run "$S6_ERR" --target "$T_DU")" || S6_RC=$?
S6_RC="${S6_RC:-0}"
art "s6.p1.out" "$S6_RC" "$S6_OUT" "$S6_ERR"
ne "$S6_RC" 0 "$P 双类缺陷样本必须产出单一非零聚合退出码"
has_re "$S6_OUT" '^GATE: FAIL \(3 files, [0-9]+ findings\)$' "$P GATE FAIL 行（样本树恰 3 个 .sh）"
DM="$(gate_m "$S6_OUT")"
ge "$DM" 2 "$P findings >= 2（两类缺陷都计入）"
echo "PASS $P"

P="6.P2"
art "s6.p2.out" "$S6_RC" "$S6_OUT" "$S6_ERR"
has "$S6_OUT" "全角" "$P 同一份 stdout 列全角发现"
has "$S6_OUT" "shellcheck" "$P 同一份 stdout 列 shellcheck 发现"
has_re "$S6_OUT" '^FAIL .*dual-fw-sample\.sh fullwidth ' "$P 聚合不短路：全角 FAIL 行在列"
has_re "$S6_OUT" '^FAIL .*dual-warn-sample\.sh shellcheck ' "$P 聚合不短路：shellcheck FAIL 行在列"
cleanup_trees "$T_DU"
echo "PASS $P"

# =============================================================================
# 场景 7：非目标零波及 + 门只读
# =============================================================================
P="7.P1"
GS_BEFORE="$(mktemp "$TMPBASE/gate-acc-gs.XXXXXX")"
GS_AFTER="$(mktemp "$TMPBASE/gate-acc-gs.XXXXXX")"
git -C "$REPO_ROOT" status --porcelain > "$GS_BEFORE"
S7_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S7_OUT="$(g_run "$S7_ERR")" || S7_RC=$?
S7_RC="${S7_RC:-0}"
git -C "$REPO_ROOT" status --porcelain > "$GS_AFTER"
{ printf 'exit=%s\n--- stdout ---\n%s\n--- before ---\n' "$S7_RC" "$S7_OUT"; cat "$GS_BEFORE"; printf -- '--- after ---\n'; cat "$GS_AFTER"; } > "$ART/s7.p1.out"
eq "$S7_RC" 0 "$P 干净仓门 exit 0（前置）"
if cmp -s "$GS_BEFORE" "$GS_AFTER"; then :; else die "$P" "门运行前后 git status --porcelain 不逐字节相等（门有仓内写入副作用）"; fi
echo "PASS $P"

P="7.P2"
T_PY="$(mk_tree)"
printf '#!/bin/bash\nexit 0\n' > "$T_PY/scripts/contrib/clean-sample.sh"
pymutation_sample "$T_PY/scripts/contrib/evil.py"
printf 'const x: string = "y";\n' > "$T_PY/scripts/contrib/evil.ts"
S7B_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S7B_OUT="$(g_run "$S7B_ERR" --target "$T_PY")" || S7B_RC=$?
S7B_RC="${S7B_RC:-0}"
art "s7.p2.out" "$S7B_RC" "$S7B_OUT" "$S7B_ERR"
eq "$S7B_RC" 0 "$P 扫描范围内 .py/.ts 不得纳入结果（evil.py 含全角 mutation，误扫即 FAIL）"
hasnt "$S7B_OUT" "evil.py" "$P stdout 不得出现 evil.py"
hasnt "$S7B_OUT" "evil.ts" "$P stdout 不得出现 evil.ts"
has_re "$S7B_OUT" '^GATE: PASS \(2 files, 0 findings\)$' "$P 仅 2 个 .sh 入扫"
cleanup_trees "$T_PY"
echo "PASS $P"

# =============================================================================
# 场景 10：headless 环境健壮性 — 极简 PATH / 无 cwd 假设 / 依赖缺失不假绿
# =============================================================================
P="10.P1"
S10_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S10_OUT="$( ( cd "$REPO_ROOT" && env PATH="/usr/bin:/bin" /bin/bash scripts/contrib/tests/gate.sh ) 2>"$S10_ERR" )" || S10_RC=$?
S10_RC="${S10_RC:-0}"
art "s10.p1.out" "$S10_RC" "$S10_OUT" "$S10_ERR"
eq "$S10_RC" 2 "$P shellcheck 缺失（PATH=/usr/bin:/bin）必须 exit 2（契约：依赖缺失=2，fail closed）"
has "$S10_OUT" "shellcheck" "$P dep 类发现行 detail 必含缺失工具名 shellcheck"
has "$S10_OUT" "dep" "$P category 枚举字面量 dep"
echo "PASS $P"

P="10.P2"
S10B_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S10B_OUT="$( ( cd /tmp && bash "$GATE" ) 2>"$S10B_ERR" )" || S10B_RC=$?
S10B_RC="${S10B_RC:-0}"
art "s10.p2.out" "$S10B_RC" "$S10B_OUT" "$S10B_ERR"
eq "$S10B_RC" 0 "$P 从非仓根 cwd 绝对路径调用结果一致（exit 0，无 cwd 假设）"
echo "PASS $P"

P="10.P3"
S10C_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S10C_OUT="$(g_run "$S10C_ERR")" || S10C_RC=$?
S10C_RC="${S10C_RC:-0}"
art "s10.p3.out" "$S10C_RC" "$S10C_OUT" "$S10C_ERR"
eq "$S10C_RC" 0 "$P 完整 PATH 仓根运行 PASS"
echo "PASS $P"

# 补充（契约 fail closed 全集）：多依赖同时缺失仍必须 exit 2，不得假绿
P="10.PX"
S10D_ERR="$(mktemp "$TMPBASE/gate-acc-err.XXXXXX")"
S10D_OUT="$( ( cd "$REPO_ROOT" && env PATH="/bin" /bin/bash scripts/contrib/tests/gate.sh ) 2>"$S10D_ERR" )" || S10D_RC=$?
S10D_RC="${S10D_RC:-0}"
art "s10.px.out" "$S10D_RC" "$S10D_OUT" "$S10D_ERR"
eq "$S10D_RC" 2 "$P PATH=/bin（git/perl/find 皆缺）必须 exit 2"
echo "PASS $P"

cleanup_trees
rm -f "$S1_ERR" "$S2_ERR" "$S2D_ERR" "$S3_ERR" "$S4_ERR" "$S4B_ERR" "$S5_ERR" "$S5B_ERR" "$S6_ERR" "$S7_ERR" "$S7B_ERR" "$S10_ERR" "$S10B_ERR" "$S10C_ERR" "$S10D_ERR" "$GS_BEFORE" "$GS_AFTER"
echo "gate-cli-gates: ALL PASS（场景 1/2/3/4/5/6/7/10，19 硬断言组）"
exit 0
