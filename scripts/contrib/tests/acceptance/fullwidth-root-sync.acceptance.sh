#!/usr/bin/env bash
# =============================================================================
# fullwidth-root-sync.acceptance.sh — 红队黑盒验收：全角独立门圈定真源派生（项A）
#                                     + 孪生 T8（项B）+ gate.sh 回归守卫
#                                     （卡 t_f5da07f7 测试面卫生收尾）
# 覆盖谓词：R1（=验收场景 P2：bash scripts/contrib/tests/static/gate-fullwidth.sh 黑盒）/
#           R2（=验收场景 P1：bash scripts/contrib/tests/acceptance/gate-twin-consistency.acceptance.sh 黑盒）/
#           R3（=验收场景 P3：bash scripts/contrib/tests/gate.sh 回归守卫，gate.sh 本卡零改动）
# SSOT：.autopilot/runtime/sessions/t_f5da07f7/requirements/20260912-【目标：卡-t_f5da07f7-测/context.md
#       及同目录 state.md `## 验收场景`（预注册谓词权威清单）；根集派生先例：commit 3caa12a（卡 t_1d48fa2f）
# 纪律：黑盒视角——对 gate-fullwidth.sh / gate-twin-consistency.acceptance.sh 只经 `bash <文件>`
#       观察 exit/stdout，绝不读其实现源码；缺陷样本只进 mktemp 临时树（本验收为只读跑、不注入
#       样本，绝不写仓内 scripts/ 真实树）；无 warn/skip 宽容，任一硬断言失败立即 die 非零退出。
# 真源纪律（两路计数一致语义，绝对值退场）：覆盖集根集由本文件从 gate.sh 默认态 ROOTS 行独立派生
#       （grep 提取 + grep -c==1 唯一性守卫 + \$REPO_ROOT 替换 + 改名 eval），绝不手抄清单；
#       R1 断言全角门自报 `被扫 .sh 文件数 N` == find @派生 FW_ROOTS 独立圈定数——两路独立计数
#       一致，覆盖集增长不再恒红；R3 末行逐字断言的 files 数同源取派生计数（不硬编码 144）；
#       逐根并入行断言用派生 FW_ROOTS 的相对根名（非手抄），`scripts/hkstock 并入覆盖集`
#       即 hkstock 真在扫描集内的直接证据（它是 gate.sh ROOTS 行真身内容之一）。
# 产物：/tmp/autopilot-artifacts/fw-r{1,2,3}.out
# =============================================================================
set -u

FW_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$FW_HERE" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
FW_GATE="$REPO_ROOT/scripts/contrib/tests/gate.sh"
FW_STATIC="$REPO_ROOT/scripts/contrib/tests/static/gate-fullwidth.sh"
FW_TWIN="$REPO_ROOT/scripts/contrib/tests/acceptance/gate-twin-consistency.acceptance.sh"
ART="/tmp/autopilot-artifacts"
TMPBASE="${TMPDIR:-/tmp}"
mkdir -p "$ART"

# 助手（acceptance 家族签名；ne() 不设——零调用死代码，本卡项C 同纪律不复发）
die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
has(){ printf '%s' "$1" | grep -qF -- "$2" || die "$3" "stdout 未包含 [$2]"; }
hasnt(){ if printf '%s' "$1" | grep -qF -- "$2"; then die "$3" "不应包含却包含 [$2]"; fi; }
has_re(){ printf '%s' "$1" | grep -qE -- "$2" || die "$3" "未匹配正则 [$2]"; }

# mktemp 暂存各跑 stderr，用完（含 die 路径）统一 rm
FW_TMP_LIST=""
fw_mktmp(){ local t; t="$(mktemp "$TMPBASE/fwacc-err.XXXXXX")" || die "env" "mktemp 失败"; FW_TMP_LIST="$FW_TMP_LIST $t"; printf '%s' "$t"; }
fw_cleanup_tmp(){ for _t in $FW_TMP_LIST; do rm -f "$_t"; done; }
trap fw_cleanup_tmp EXIT

art(){ # art <artifact 名> <rc> <stdout> <errfile>
  { printf 'exit=%s\n--- stdout ---\n' "$2"; printf '%s\n' "$3"; printf -- '--- stderr ---\n'; cat "$4" 2>/dev/null; } > "$ART/$1"
}
fw_run(){ # fw_run <errfile> <repo 相对脚本路径...> -> stdout；rc 由调用方经 || rc=$? 捕获
  local ef="$1"; shift
  ( cd "$REPO_ROOT" && bash "$@" ) 2>"$ef"
}

# ---- 环境前提（fail closed，禁静默 skip） ----
[ -f "$FW_GATE" ] || die "env" "gate.sh 缺失: $FW_GATE"
[ -f "$FW_STATIC" ] || die "env" "gate-fullwidth.sh 缺失: $FW_STATIC"
[ -f "$FW_TWIN" ] || die "env" "twin acceptance 缺失: $FW_TWIN"
command -v find >/dev/null 2>&1 || die "env" "本机缺 find（两路计数的独立一路依赖）"

# ---- 仓内事实：根集真源唯一化（从 gate.sh 默认态 ROOTS 行独立派生，绝不手抄清单） ----
[ "$(grep -cE '^[[:space:]]*ROOTS=\("\$REPO_ROOT/scripts/' "$FW_GATE")" -eq 1 ] \
  || die "env" "覆盖集真源契约漂移：gate.sh 默认态 ROOTS 行应恰 1 行"
FW_ROOTS_SRC="$(grep -E '^[[:space:]]*ROOTS=\("\$REPO_ROOT/scripts/' "$FW_GATE")"
FW_ROOTS_SRC="${FW_ROOTS_SRC/\\\$REPO_ROOT/$REPO_ROOT}"
eval "${FW_ROOTS_SRC/ROOTS=/FW_ROOTS=}" || die "env" "gate.sh ROOTS 行 eval 失败"
[ "${#FW_ROOTS[@]}" -ge 1 ] || die "env" "FW_ROOTS 派生空根集"
for _r in "${FW_ROOTS[@]}"; do
  [ -d "$_r" ] || die "env" "派生根目录缺失（真仓缺根应 fail-closed）: $_r"
done
FW_FIND_N="$(find "${FW_ROOTS[@]}" -name '*.sh' -type f | wc -l | tr -d ' ')"
case "$FW_FIND_N" in ''|*[!0-9]*) die "env" "find 独立计数非数值 [$FW_FIND_N]";; esac
[ "$FW_FIND_N" -ge 1 ] || die "env" "find 独立计数为 0（覆盖集空，禁空集静默绿）"

# =============================================================================
# R1（=验收 P2）：gate-fullwidth.sh 黑盒 —— rc==0；自报被扫数 == find 独立计数（两路一致）；
# 逐根 `<rel> 并入覆盖集`（scripts/hkstock 并入覆盖集 为其中一根）；末行 ##SUMMARY JSON .failed==0
# =============================================================================
P="R1"
R1_ERR="$(fw_mktmp)"
R1_OUT="$(fw_run "$R1_ERR" scripts/contrib/tests/static/gate-fullwidth.sh)" || R1_RC=$?
R1_RC="${R1_RC:-0}"
art "fw-r1.out" "$R1_RC" "$R1_OUT" "$R1_ERR"
eq "$R1_RC" 0 "$P 全角独立门 exit（契约：static 维度全绿=0）"
has "$R1_OUT" "被扫 .sh 文件数 $FW_FIND_N" "$P 自报被扫 .sh 文件数 == 独立计数 $FW_FIND_N"
# CONTRACT_AMBIGUOUS: `被扫 .sh 文件数 N` 所在行完整行形未冻结（是否为 assert.sh PASS 行 [msg] 包裹）——
# 解析按子串定位捕获数字，多次出现取末次；捕获失败即 die（fail closed）。
FW_N="$(printf '%s\n' "$R1_OUT" | sed -n 's/.*被扫 \.sh 文件数 \([0-9][0-9]*\).*/\1/p' | tail -n 1)"
case "$FW_N" in ''|*[!0-9]*) die "$P" "未解析到 被扫 .sh 文件数 <N>（stdout 须含该字面）";; esac
eq "$FW_N" "$FW_FIND_N" "$P 两路计数一致（全角门自报 == find 圈定@gate.sh ROOTS 派生）"
for _r in "${FW_ROOTS[@]}"; do
  has "$R1_OUT" "${_r#"$REPO_ROOT"/} 并入覆盖集" "$P 逐根并入声明（${_r#"$REPO_ROOT"/}，根名来自真源派生非手抄）"
done
R1_LAST="$(printf '%s\n' "$R1_OUT" | tail -n 1)"
has_re "$R1_LAST" '^##SUMMARY \{' "$P 末行须为 ##SUMMARY JSON 协议行"
R1_SUM="${R1_LAST#"##SUMMARY "}"
if command -v jq >/dev/null 2>&1; then
  R1_FAILED="$(printf '%s' "$R1_SUM" | jq -r '.failed' 2>/dev/null)" || R1_FAILED="jq-error"
  eq "$R1_FAILED" 0 "$P ##SUMMARY .failed==0"
else
  has "$R1_SUM" '"failed":0' "$P ##SUMMARY failed==0（jq 缺失 grep 形态回退；键序由 lib/assert.sh t_finish 冻结）"
fi
echo "PASS ${P}（self=$FW_N find=$FW_FIND_N roots=${#FW_ROOTS[@]}）"

# =============================================================================
# R2（=验收 P1）：twin acceptance 黑盒直跑 —— rc==0；含 `PASS T8`（项B 新谓词在列，
# D5②：默认态孪生源缺失 fail-closed）；末个非空行含 ALL PASS
# =============================================================================
P="R2"
R2_ERR="$(fw_mktmp)"
R2_OUT="$(fw_run "$R2_ERR" scripts/contrib/tests/acceptance/gate-twin-consistency.acceptance.sh)" || R2_RC=$?
R2_RC="${R2_RC:-0}"
art "fw-r2.out" "$R2_RC" "$R2_OUT" "$R2_ERR"
eq "$R2_RC" 0 "$P 孪生一致性验收 exit（契约：全 PASS=0）"
has "$R2_OUT" "PASS T8" "$P 新增 T8 谓词在列（D5②：默认态孪生源缺失 fail-closed）"
R2_LAST="$(printf '%s\n' "$R2_OUT" | sed '/^[[:space:]]*$/d' | tail -n 1)"
has "$R2_LAST" "ALL PASS" "$P 末个非空行含 ALL PASS"
echo "PASS ${P}（twin 直跑全绿且含 T8）"

# =============================================================================
# R3（=验收 P3）：gate.sh 回归守卫（本卡零改动）—— rc==0；末行逐字
# `GATE: PASS (<独立计数> files, 0 findings)`（files 取派生 find 计数，绝对值不硬编码）
# =============================================================================
P="R3"
R3_ERR="$(fw_mktmp)"
R3_OUT="$(fw_run "$R3_ERR" scripts/contrib/tests/gate.sh)" || R3_RC=$?
R3_RC="${R3_RC:-0}"
art "fw-r3.out" "$R3_RC" "$R3_OUT" "$R3_ERR"
eq "$R3_RC" 0 "$P 入库门 exit（gate.sh 本卡零改动，回归守卫）"
R3_LAST="$(printf '%s\n' "$R3_OUT" | tail -n 1)"
eq "$R3_LAST" "GATE: PASS ($FW_FIND_N files, 0 findings)" "$P 末行逐字 GATE: PASS（files=派生 find 独立计数）"
hasnt "$R3_OUT" "FAIL " "$P 干净跑零发现（无 FAIL 发现行）"
echo "PASS ${P}（files=${FW_FIND_N}）"

echo "fullwidth-root-sync: ALL PASS（R1/R2/R3 硬断言组；两路计数一致 self=find=${FW_FIND_N} roots=${#FW_ROOTS[@]}）"
exit 0
