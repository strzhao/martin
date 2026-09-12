#!/usr/bin/env bash
# =============================================================================
# gate-twin-consistency.acceptance.sh — gate.sh 第 4 关「孪生门一致性」黑盒验收
# （T1-T7 预注册谓词硬断言；T8 见下方声明位）
# SSOT：.autopilot/runtime/sessions/t_9202949f/requirements/20260912-给-contrib-审批链的「孪/context.md
#       + 同卡设计文档 D1-D7（验收权威源；SCAN/FAIL/GATE 字面量按 D7 冻结）
# 覆盖谓词（驱动 → 硬断言）：
#   T1 默认态绿         真仓默认跑 → exit=0 ∧ 含 SCAN 孪生门一致性: PASS ∧ 末行 GATE: PASS (N files, 0 findings)
#   T2 沙箱一致对       MARTIN_GATE_TARGET=真孪生对沙箱 → exit=0 ∧ 含 SCAN 孪生门一致性: PASS
#   T3 沙箱单侧漂移     --target 沙箱 execute.sh 副本 21 * 86400→22 * 86400 →
#                       exit=1 ∧ 含 SCAN 孪生门一致性: FAIL ∧ FAIL 行含 twin 且含 22 * 86400 ∧ 末行 GATE: FAIL
#   T4 口径敏感性       --target 沙箱 execute.sh 副本 date +%s→date %s → exit=1
#                       （若归一化退化成 BSD sed 字面 \+ 口径，两侧同样被吃 → 本谓词必红；D3 禁令）
#   T5 target 无对 SKIP MARTIN_GATE_TARGET=仅杂散 .sh 沙箱 → exit=0 ∧ 含 SKIP（target 态无孪生对）∧ 零 FAIL 行
#   T6 注释差异容忍     --target 沙箱 notify.sh 副本仅函数头前注释/函数内列 0 纯注释行不同 → exit=0 ∧ PASS
#   T7 单侧抽取为空     --target 沙箱 notify.sh 副本 occ_all_stalled→occ_all_stalled_old →
#                       exit=1 ∧ FAIL 行含 twin 且含「抽取」或「为空」
# T8 声明：真身 mutation 自证（真身原地 21 * 86400→22 * 86400 → gate FAIL(exit 1) → git checkout 还原 →
#   全绿）由编排器 QA 轮在真身执行，不在本文件（本文件以沙箱副本等价覆盖见 T3）。
# 纪律：黑盒视角——只经 `bash scripts/contrib/tests/gate.sh`（含 --target flag / MARTIN_GATE_TARGET env）
#   观察 exit/stdout；绝不读 gate.sh 源码（被实现对象）；缺陷样本一律注入 mktemp 临时树，绝不写仓内
#   scripts/ 真实树（含被守卫的 execute.sh/notify.sh）；沙箱副本从真仓 scripts/approval/execute.sh 与
#   scripts/contrib/notify.sh 拷贝后做最小变异，且每处变异先断言「确实生效」（防沙箱装配自身 vacuous
#   PASS）；无 warn/skip 宽容，任一硬断言失败立即非零退出；禁 try/catch 吞错、禁条件断言。
# Mutation-Survival：T3/T4 各钉三类 no-op mutation——「SCAN 行缺失」（SCAN FAIL 子串断言）、「FAIL 不改
#   exit code」（exit 恰=1 断言）、「detail 不含漂移内容」（FAIL gate twin 行内容断言）。
# CONTRACT_AMBIGUOUS: D7「FAIL gate twin <detail>」中 gate token 按「file 位字面 token」解释——孪生发现属
#   对级、不归属单文件（当前实装吻合；若实现把 file 位放实际路径，则 T3/T4/T7 红，需设计澄清）。
# CONTRACT_AMBIGUOUS: D3「去纯注释行」未写明缩进口径（列 0「# 行」与缩进「# 行」是否同判）；T6 仅用列 0
#   注释钉契约，缩进注释不设硬断言（不钉未注册口径）。
# 测试命令：bash scripts/contrib/tests/acceptance/gate-twin-consistency.acceptance.sh
# 产物：/tmp/autopilot-artifacts/twin.t{1,2,3,4,5,6,7}.out
# =============================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 安装位深度：scripts/contrib/tests/acceptance/ → 被测 gate.sh 即 "$HERE/../gate.sh"；
# 调用锚沿用 gate-cli-gates.acceptance.sh 先例（git 仓根推导），staging 试跑与安装位两态皆可运行。
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
GATE="$REPO_ROOT/scripts/contrib/tests/gate.sh"   # 安装位深度等价于 "$HERE/../gate.sh"
ART="/tmp/autopilot-artifacts"
TMPBASE="${TMPDIR:-/tmp}"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" || die "$3" "stdout 未包含 [$2]"; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then die "$3" "不应包含却包含 [$2]"; fi; }
has_re(){ printf '%s' "$1" | grep -qE -- "$2" || die "$3" "未匹配正则 [$2]"; }

# ---- 环境前提（fail closed，禁静默 skip） ----
[ -f "$GATE" ] || die "env" "gate.sh 缺失: $GATE"
[ -f "$REPO_ROOT/scripts/approval/execute.sh" ] || die "env" "真身 execute.sh 缺失: $REPO_ROOT/scripts/approval/execute.sh"
[ -f "$REPO_ROOT/scripts/contrib/notify.sh" ] || die "env" "真身 notify.sh 缺失: $REPO_ROOT/scripts/contrib/notify.sh"
for t in sed awk grep git mktemp cmp; do
  command -v "$t" >/dev/null 2>&1 || die "env" "本机缺 ${t}（本验收自身依赖集，验收环境不得缺）"
done
[ -x /usr/bin/diff ] || die "env" "缺 /usr/bin/diff（D4 pin 绝对路径的依赖前提，fail closed）"

# ---- 全角括号经字节转义构造（沿 gate-cli-gates.acceptance.sh 先例纪律） ----
FW_L="$(printf '\357\274\210')"   # 全角左括号 U+FF08
FW_R="$(printf '\357\274\211')"   # 全角右括号 U+FF09

# ---- 被守卫孪生真身（只读拷贝源；绝不原地改） ----
EX_A="$REPO_ROOT/scripts/approval/execute.sh"
EX_N="$REPO_ROOT/scripts/contrib/notify.sh"

# ---- 样本与临时树工具（缺陷样本只进 mktemp 沙箱） ----
extract_fn(){ # 镜像 D2 抽取口径，仅用于沙箱装配自检（验证变异落点），非对实现的断言
  sed -n '/^occ_all_stalled() {/,/^}/p' "$1"
}
mk_twin_sbx(){ # -> 输出沙箱根：scripts/approval/execute.sh + scripts/contrib/notify.sh（真身原样拷贝）
  local r; r="$(mktemp -d "$TMPBASE/gate-twin.XXXXXX")"
  mkdir -p "$r/scripts/approval" "$r/scripts/contrib"
  cp "$EX_A" "$r/scripts/approval/execute.sh"
  cp "$EX_N" "$r/scripts/contrib/notify.sh"
  printf '%s' "$r"
}
mk_stray_sbx(){ # -> 输出仅含杂散 .sh 的沙箱（无孪生对）
  local r; r="$(mktemp -d "$TMPBASE/gate-twin.XXXXXX")"
  mkdir -p "$r/scripts/approval" "$r/scripts/contrib"
  printf '#!/bin/bash\nexit 0\n' > "$r/scripts/approval/stray-a.sh"
  printf '#!/bin/bash\nexit 0\n' > "$r/scripts/contrib/stray-c.sh"
  printf '%s' "$r"
}
run_flag(){ # run_flag <errfile> <target-root> -> stdout（--target flag 态；rc 经 $? / || rc=$? 取）
  local ef="$1" t="$2"
  ( cd "$REPO_ROOT" && bash "$GATE" --target "$t" ) 2>"$ef"
}
run_env(){ # run_env <errfile> <target-root> -> stdout（MARTIN_GATE_TARGET env 态）
  local ef="$1" t="$2"
  ( cd "$REPO_ROOT" && MARTIN_GATE_TARGET="$t" bash "$GATE" ) 2>"$ef"
}
art(){ # art <artifact 名> <rc> <stdout> <errfile>
  { printf 'exit=%s\n--- stdout ---\n' "$2"; printf '%s\n' "$3"; printf -- '--- stderr ---\n'; cat "$4" 2>/dev/null; } > "$ART/$1"
}
last_line(){ # 末个非空行（D7 末行闭集断言用）
  printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -n 1
}
twin_line(){ # 首个 FAIL gate twin 发现行（无则输出空）
  printf '%s\n' "$1" | grep -E '^FAIL gate twin ' | head -n 1
}

# =============================================================================
# T1 默认态绿 — 真仓默认跑：第 4 关并入三关聚合，全绿闭集
# =============================================================================
P="T1"
T1_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T1_OUT="$( ( cd "$REPO_ROOT" && bash "$GATE" ) 2>"$T1_ERR" )" || T1_RC=$?
T1_RC="${T1_RC:-0}"
art "twin.t1.out" "$T1_RC" "$T1_OUT" "$T1_ERR"
eq "$T1_RC" 0 "$P 默认态 exit（D1/D7：全绿=0）"
if [ -s "$T1_ERR" ]; then die "$P" "干净跑 stderr 应为空（契约：stderr 仅承载意外错误）"; fi
has "$T1_OUT" "SCAN 孪生门一致性: PASS" "$P 第 4 关 SCAN PASS 字面量（D7 冻结，逐字）"
has_re "$(last_line "$T1_OUT")" '^GATE: PASS \([0-9]+ files, 0 findings\)$' "$P 末行闭集 GATE: PASS (N files, 0 findings)（D7 冻结）"
rm -f "$T1_ERR"
echo "PASS $P"

# =============================================================================
# T2 沙箱一致对 — MARTIN_GATE_TARGET env 态：真孪生对原样拷贝 → PASS
# =============================================================================
P="T2"
T2_SBX="$(mk_twin_sbx)"
T2_EA="$(extract_fn "$T2_SBX/scripts/approval/execute.sh")"
T2_EN="$(extract_fn "$T2_SBX/scripts/contrib/notify.sh")"
[ -n "$T2_EA" ] || die "$P 装配" "execute.sh 副本抽取段为空（装配失败）"
[ -n "$T2_EN" ] || die "$P 装配" "notify.sh 副本抽取段为空（装配失败）"
eq "$T2_EA" "$T2_EN" "$P 装配：两副本抽取段原文一致（vacuous-PASS 防线：对子必须真的一致）"
T2_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T2_OUT="$(run_env "$T2_ERR" "$T2_SBX")" || T2_RC=$?
T2_RC="${T2_RC:-0}"
art "twin.t2.out" "$T2_RC" "$T2_OUT" "$T2_ERR"
eq "$T2_RC" 0 "$P 一致对 exit=0"
if [ -s "$T2_ERR" ]; then die "$P" "干净跑 stderr 应为空"; fi
has "$T2_OUT" "SCAN 孪生门一致性: PASS" "$P SCAN PASS 字面量（D7 冻结）"
has_re "$(last_line "$T2_OUT")" '^GATE: PASS \(2 files, 0 findings\)$' "$P 末行闭集（沙箱恰 2 个 .sh）"
rm -rf "$T2_SBX"; rm -f "$T2_ERR"
echo "PASS $P"

# =============================================================================
# T3 沙箱单侧漂移 — execute.sh 副本 21 * 86400→22 * 86400 → FAIL(1)，detail 载漂移字节
# =============================================================================
P="T3"
T3_SBX="$(mk_twin_sbx)"
T3_A="$T3_SBX/scripts/approval/execute.sh"
T3_N="$T3_SBX/scripts/contrib/notify.sh"
sed -i '' 's/cutoff=\$(( 21 \* 86400 ))/cutoff=\$(( 22 * 86400 ))/' "$T3_A"
T3_EA="$(extract_fn "$T3_A")"
has "$T3_EA" "22 * 86400" "$P 装配：漂移字节 22 * 86400 已注入 execute.sh 副本（变异生效断言）"
hasnt "$T3_EA" "21 * 86400" "$P 装配：原字节 21 * 86400 已从 execute.sh 副本消失"
has "$(extract_fn "$T3_N")" "21 * 86400" "$P 装配：notify.sh 副本保持原字节（单侧漂移前提）"
hasnt "$(extract_fn "$T3_N")" "22 * 86400" "$P 装配：notify.sh 副本无漂移字节"
T3_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T3_OUT="$(run_flag "$T3_ERR" "$T3_SBX")" || T3_RC=$?
T3_RC="${T3_RC:-0}"
art "twin.t3.out" "$T3_RC" "$T3_OUT" "$T3_ERR"
eq "$T3_RC" 1 "$P 漂移必须 exit 恰=1（D4/D7：发现=1；kill「FAIL 不改 exit code」no-op）"
has "$T3_OUT" "SCAN 孪生门一致性: FAIL" "$P SCAN FAIL 字面量（D7 冻结；kill「SCAN 行缺失」no-op）"
T3_TL="$(twin_line "$T3_OUT")"
[ -n "$T3_TL" ] || die "$P" "缺 FAIL gate twin 发现行（D7 冻结前缀；CONTRACT_AMBIGUOUS 见文件头 gate token 注）"
has "$T3_TL" "occ_all_stalled 孪生体漂移${FW_L}${T3_A} vs ${T3_N}${FW_R}: " "$P 漂移 detail 冻结形态（pathA=approval 副本 vs pathB=contrib 副本，D7）"
has "$T3_TL" "22 * 86400" "$P detail 含首个差异行内容（kill「detail 不含漂移内容」no-op）"
has_re "$(last_line "$T3_OUT")" '^GATE: FAIL \(2 files, [0-9]+ findings\)$' "$P 末行闭集 GATE: FAIL（D7 冻结）"
rm -rf "$T3_SBX"; rm -f "$T3_ERR"
echo "PASS $P"

# =============================================================================
# T4 口径敏感性 — execute.sh 副本 date +%s→date %s：POSIX 归一化必须判漂移；
# 若实现退化成 BSD sed 字面 \+ 口径（把「 +」吃成「 」），两侧同样被吃 → 假绿，本谓词必红
# =============================================================================
P="T4"
T4_SBX="$(mk_twin_sbx)"
T4_A="$T4_SBX/scripts/approval/execute.sh"
T4_N="$T4_SBX/scripts/contrib/notify.sh"
sed -i '' 's/now="\$(date +%s)"/now="\$(date %s)"/' "$T4_A"
T4_EA="$(extract_fn "$T4_A")"
has "$T4_EA" 'date %s' "$P 装配：date %s 已注入 execute.sh 副本（变异生效断言）"
hasnt "$T4_EA" 'date +%s' "$P 装配：原字节 date +%s 已从 execute.sh 副本消失"
has "$(extract_fn "$T4_N")" 'date +%s' "$P 装配：notify.sh 副本保持原字节"
T4_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T4_OUT="$(run_flag "$T4_ERR" "$T4_SBX")" || T4_RC=$?
T4_RC="${T4_RC:-0}"
art "twin.t4.out" "$T4_RC" "$T4_OUT" "$T4_ERR"
eq "$T4_RC" 1 "$P 必须判漂移 exit 恰=1（D3 POSIX 形态口径；BSD 字面 \\+ 退化此处必假绿）"
has "$T4_OUT" "SCAN 孪生门一致性: FAIL" "$P SCAN FAIL 字面量（kill「SCAN 行缺失」no-op）"
T4_TL="$(twin_line "$T4_OUT")"
[ -n "$T4_TL" ] || die "$P" "缺 FAIL gate twin 发现行"
has_re "$T4_TL" 'date \+?%s' "$P detail 含漂移行内容（+ 号存否即口径敏感性本体；kill「detail 不含漂移内容」no-op）"
has_re "$(last_line "$T4_OUT")" '^GATE: FAIL \(2 files, [0-9]+ findings\)$' "$P 末行闭集 GATE: FAIL"
rm -rf "$T4_SBX"; rm -f "$T4_ERR"
echo "PASS $P"

# =============================================================================
# T5 target 无对 SKIP — MARTIN_GATE_TARGET=仅杂散 .sh 沙箱：SKIP 不产发现
# =============================================================================
P="T5"
T5_SBX="$(mk_stray_sbx)"
T5_SKIP_NEEDLE="$(printf 'SCAN 孪生门一致性: SKIP%starget 态无孪生对%s' "$FW_L" "$FW_R")"
T5_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T5_OUT="$(run_env "$T5_ERR" "$T5_SBX")" || T5_RC=$?
T5_RC="${T5_RC:-0}"
art "twin.t5.out" "$T5_RC" "$T5_OUT" "$T5_ERR"
eq "$T5_RC" 0 "$P 无对 SKIP 态 exit=0（D6：target 态缺失=SKIP，不产发现）"
if [ -s "$T5_ERR" ]; then die "$P" "SKIP 态 stderr 应为空"; fi
has "$T5_OUT" "$T5_SKIP_NEEDLE" "$P SKIP 冻结字面量（D7 逐字，全角括号经字节转义构造）"
if printf '%s\n' "$T5_OUT" | grep -qE '^FAIL '; then die "$P" "SKIP 态不得产任何 FAIL 发现行（D6）"; fi
has_re "$(last_line "$T5_OUT")" '^GATE: PASS \(2 files, 0 findings\)$' "$P 末行闭集（杂散沙箱恰 2 个 .sh）"
rm -rf "$T5_SBX"; rm -f "$T5_ERR"
echo "PASS $P"

# =============================================================================
# T6 注释差异容忍 — notify.sh 副本仅函数头前注释 + 函数内列 0 纯注释行不同（正文同）→ PASS
# =============================================================================
P="T6"
T6_SBX="$(mk_twin_sbx)"
T6_N="$T6_SBX/scripts/contrib/notify.sh"
awk '
  /^occ_all_stalled\(\) \{/ && !done { print "# twin-t6 pre-header probe comment (ascii)"; done = 1 }
  { print }
  /^occ_all_stalled\(\) \{/ { print "# twin-t6 in-function pure comment (ascii)" }
' "$EX_N" > "$T6_N"
T6_EN="$(extract_fn "$T6_N")"
has "$T6_EN" "# twin-t6 in-function pure comment (ascii)" "$P 装配：函数内列 0 纯注释行已注入抽取段（变异生效断言）"
hasnt "$T6_EN" "pre-header probe" "$P 装配：函数头前注释在抽取段之外（D2 抽取口径前提）"
if grep -qF '# twin-t6 pre-header probe comment' "$T6_N"; then :; else die "$P 装配" "函数头前注释未注入副本"; fi
T6_EA="$(extract_fn "$T6_SBX/scripts/approval/execute.sh")"
hasnt "$T6_EA" "twin-t6" "$P 装配：对照侧无探针注释（单侧注释差异前提）"
T6_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T6_OUT="$(run_flag "$T6_ERR" "$T6_SBX")" || T6_RC=$?
T6_RC="${T6_RC:-0}"
art "twin.t6.out" "$T6_RC" "$T6_OUT" "$T6_ERR"
eq "$T6_RC" 0 "$P 仅注释差异必须容忍 exit=0（D3：去纯注释行/去空行在折叠空白前完成）"
if [ -s "$T6_ERR" ]; then die "$P" "干净跑 stderr 应为空"; fi
has "$T6_OUT" "SCAN 孪生门一致性: PASS" "$P SCAN PASS 字面量（kill「不剥注释即比对」退化实现）"
has_re "$(last_line "$T6_OUT")" '^GATE: PASS \(2 files, 0 findings\)$' "$P 末行闭集"
rm -rf "$T6_SBX"; rm -f "$T6_ERR"
echo "PASS $P"

# =============================================================================
# T7 单侧抽取为空 — notify.sh 副本 occ_all_stalled→occ_all_stalled_old：抽取空 → fail-closed FAIL(1)
# =============================================================================
P="T7"
T7_SBX="$(mk_twin_sbx)"
T7_N="$T7_SBX/scripts/contrib/notify.sh"
sed -i '' 's/^occ_all_stalled()/occ_all_stalled_old()/' "$T7_N"
eq "$(grep -c '^occ_all_stalled_old() {' "$T7_N")" "1" "$P 装配：定义行已改名（变异生效断言）"
if grep -q '^occ_all_stalled() {' "$T7_N"; then die "$P 装配" "原名定义行仍在（变异未生效）"; fi
[ -z "$(extract_fn "$T7_N")" ] || die "$P 装配" "改名后抽取段应为空（D2 口径自检）"
[ -n "$(extract_fn "$T7_SBX/scripts/approval/execute.sh")" ] || die "$P 装配" "对照侧抽取段不应为空"
T7_ERR="$(mktemp "$TMPBASE/gate-twin-err.XXXXXX")"
T7_OUT="$(run_flag "$T7_ERR" "$T7_SBX")" || T7_RC=$?
T7_RC="${T7_RC:-0}"
art "twin.t7.out" "$T7_RC" "$T7_OUT" "$T7_ERR"
eq "$T7_RC" 1 "$P 单侧抽取为空必须 fail-closed exit 恰=1（D5；不得 0/2）"
has "$T7_OUT" "SCAN 孪生门一致性: FAIL" "$P SCAN FAIL 字面量（D7 冻结）"
T7_TL="$(twin_line "$T7_OUT")"
[ -n "$T7_TL" ] || die "$P" "缺 FAIL gate twin 发现行"
has_re "$T7_TL" '抽取|为空' "$P 发现行 detail 含「抽取」或「为空」（D5 经 D7 发现行承载；kill「detail 空洞化」no-op）"
has_re "$(last_line "$T7_OUT")" '^GATE: FAIL \(2 files, [0-9]+ findings\)$' "$P 末行闭集 GATE: FAIL"
rm -rf "$T7_SBX"; rm -f "$T7_ERR"
echo "PASS $P"

echo "gate-twin-consistency: ALL PASS（T1-T7 硬断言全绿；T8 真身 mutation 自证由编排器 QA 轮执行）"
exit 0
