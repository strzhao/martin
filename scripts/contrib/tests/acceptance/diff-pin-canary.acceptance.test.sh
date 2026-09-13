#!/usr/bin/env bash
# =============================================================================
# diff-pin-canary.acceptance.test.sh — 验收：diff 判据 pin /usr/bin/diff 的否证力
# 覆盖谓词：S1.P1 S1.P2 S1.P3 S2.P1 S2.P2 S2.P3 S2.P4 S2.P5（全 det-machine）
# 依据：设计文档「验收场景（预注册谓词，SSOT）」+ context.md 历史知识——
#   PATH 上 OpenHarmony toolchain 的 diff 对**任意**输入 rc=0 零输出 ⇒ 未 pin 的
#   「diff 行数 == 0」判据恒真（假绿），与真实差异无关。
#
# 被测对象（**运行时**黑盒扫描 / 求值；本文件不复制其内容，也不引用其行号）：
#   1) scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh
#   2) scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh
#   3) scripts/hkstock/tests/t2_guard.acceptance.test.sh
#
# 纪律：
#   - 每条断言硬失败（无 SKIP / 无 warn 降级 / 无 `|| true` 宽容 / 无条件放行）
#   - 零仓内写入：临时产物只进 mktemp 目录（EXIT trap 清理）
#   - 环境依赖（本机是否存在真实影子）**显式检测后分支断言**，两分支均为硬断言
#   - Mutation-Survival：把任一 /usr/bin/diff 改回裸 diff ⇒ C5（裸调用数=0 / pin 调用点=5 /
#     命令 token 唯一）与 C6（判据 canary 在遮蔽态下必须仍能检出 1 行差异）双双变红
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析——git rev-parse --show-toplevel 在 ${SELF_DIR} 无输出（非 git 仓库 / git 不可用）；本套件禁静默兜底到生产主 checkout" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=/dev/null
source "$TESTS_ROOT/lib/assert.sh"
t_init "$T_FILE"

T_S4="$REPO_ROOT/scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh"
T_T104="$REPO_ROOT/scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh"
T_HK2="$REPO_ROOT/scripts/hkstock/tests/t2_guard.acceptance.test.sh"

# 本机真实影子（OpenHarmony toolchain）。存在性在 C1/C3 中显式检测后分支断言；
# 不存在时退化为「裸 diff 与 pin diff 行为一致」等价事实（同为硬断言）。
SHADOW_REAL="/Users/stringzhao/.local/harmony/command-line-tools/sdk/default/openharmony/toolchains/diff"

# 命令位识别正则（ERE）：
#   - 前缀 = 行首 / shell 分隔符（; & | (）/ 命令替换起点（$( 写成 [$][(] 以避开全角门）
#   - 真裸调用必落在命令位；`/usr/bin/diff` 前有 `/`、`git diff` 的 diff 前有 `git `，
#     二者都不满足「分隔符紧跟命令名」⇒ 天然不匹配（已对语料正/负样本自证，见 C4）
NAKED_RE='(^|[;&|(]|[$][(])[[:space:]]*diff([[:space:]]|[;&|)<]|$)'
PIN_RE='(^|[;&|(]|[$][(])[[:space:]]*/usr/bin/diff([[:space:]]|[;&|)<]|$)'
TOKEN_RE='(^|[;&|(]|[$][(])[[:space:]]*(/usr/bin/diff|diff)([[:space:]]|[;&|)<]|$)'

SB="$(mktemp -d "${TMPDIR:-/tmp}/acc-diffpin.XXXXXX")" || {
  echo "ACCEPTANCE-FAIL[env]: mktemp 失败（无法建立临时工作区，禁静默放行）" >&2
  exit 1
}
trap 'rm -rf "$SB"' EXIT
SB_SHADOW="$SB/shadow"
mkdir -p "$SB_SHADOW"
# 自建影子 diff：对任意输入 rc=0 零输出——复刻本机 OpenHarmony toolchain 影子的实测行为
# （context.md「第三方 diff 遮蔽系统 diff = stdout 空静默假绿」）。机器无关、确定性。
printf '#!/bin/sh\nexit 0\n' > "$SB_SHADOW/diff"
chmod +x "$SB_SHADOW/diff"

FX_A="$SB/fx-a.txt"
FX_B="$SB/fx-b.txt"
FX_C="$SB/fx-c.txt"
printf 'alpha\nbeta\n' > "$FX_A"
printf 'alpha\ngamma\n' > "$FX_B"
cp "$FX_A" "$FX_C"   # 与 FX_A 逐字节相同（cp 保证，非重写）

_lines() { # <file> → 行数
  wc -l < "$1" | tr -d ' '
}

_diffprobe() { # <token> <a> <b> <out> → rc（影子目录前置到 PATH；token 为裸名时经 PATH 解析）
  ( export PATH="$SB_SHADOW:$PATH"; "$1" "$2" "$3" > "$4" 2>&1 )
}

_scan_naked() { # <file> → 命令位裸 diff 命中行数
  grep -cE "$NAKED_RE" "$1"
}

_scan_pinned() { # <file> → 命令位 /usr/bin/diff 命中行数
  grep -cE "$PIN_RE" "$1"
}

_file_tokens() { # <file> → 去重后的命令位 diff token（每行一个）
  grep -oE "$TOKEN_RE" "$1" \
    | sed -E 's/^[;&|(]+//; s/^[$][(]//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/[;&|)<]$//' \
    | sort -u
}

# =============================================================================
t_case "C1 S1.P1 遮蔽态裸 diff 恒真假绿：自建影子下 rc=0 且 0 行"
_diffprobe diff "$FX_A" "$FX_B" "$SB/c1.out"
C1_RC=$?
C1_LINES="$(_lines "$SB/c1.out")"
assert_eq "$C1_RC" "0" "S1.P1 自建影子下裸 diff rc=0（有差异输入也判等）"
assert_eq "$C1_LINES" "0" "S1.P1 自建影子下裸 diff 输出 0 行（判据无法区分输入）"
if [ -x "$SHADOW_REAL" ]; then
  "$SHADOW_REAL" "$FX_A" "$FX_B" > "$SB/c1-real.out" 2>&1
  C1R_RC=$?
  assert_eq "$C1R_RC" "0" "S1.P1 本机真实影子 rc=0（OpenHarmony toolchain diff）"
  assert_eq "$(_lines "$SB/c1-real.out")" "0" "S1.P1 本机真实影子输出 0 行（假绿实锤）"
else
  # 无真实影子（非 mac/OH 环境）：断言「裸 diff 与 pin diff 行为一致」等价事实
  _diffprobe /usr/bin/diff "$FX_A" "$FX_B" "$SB/c1-eq.out"
  C1E_RC=$?
  assert_eq "$C1E_RC" "$C1_RC" "S1.P1 无影子态：裸 diff 与 /usr/bin/diff rc 一致（等价事实）"
  assert_eq "$(_lines "$SB/c1-eq.out")" "$C1_LINES" "S1.P1 无影子态：裸 diff 与 /usr/bin/diff 行数一致"
fi

# =============================================================================
t_case "C2 S1.P2 pin 态对同一对文件判红（rc=1 且输出 >= 1 行）"
_diffprobe /usr/bin/diff "$FX_A" "$FX_B" "$SB/c2.out"
C2_RC=$?
C2_LINES="$(_lines "$SB/c2.out")"
assert_eq "$C2_RC" "1" "S1.P2 /usr/bin/diff 对差异输入 rc=1（真求值）"
if [ "$C2_LINES" -ge 1 ]; then
  _pass "S1.P2 /usr/bin/diff 对差异输入输出 >= 1 行（实得 ${C2_LINES}）"
else
  _fail "S1.P2 /usr/bin/diff 对差异输入输出 >= 1 行" "实得 ${C2_LINES} 行（pin 未生效？）"
fi
# 否证力对照：同一对文件在**无影子** PATH 下用裸 diff 必须同样判红
# （证明 C1 的 0 行是影子造成的，而不是两文件其实相同——反恒真控制）
(
  export PATH="/usr/bin:/bin"
  diff "$FX_A" "$FX_B" > "$SB/c2-unshaded.out" 2>&1
)
C2U_RC=$?
assert_eq "$C2U_RC" "1" "S1.P2 对照：无影子 PATH 下裸 diff 对同一对文件 rc=1（输入确实有差异）"
if [ "$(_lines "$SB/c2-unshaded.out")" -ge 1 ]; then
  _pass "S1.P2 对照：无影子 PATH 下裸 diff 输出 >= 1 行"
else
  _fail "S1.P2 对照：无影子 PATH 下裸 diff 输出 >= 1 行" "实得 $(_lines "$SB/c2-unshaded.out") 行"
fi

# =============================================================================
t_case "C3 S1.P3 ambient PATH 下 diff 解析（遮蔽态命中影子 / 非遮蔽态行为等价）"
C3_RESOLVED="$(command -v diff 2>/dev/null || true)"
assert_ne "$C3_RESOLVED" "" "S1.P3 ambient 可解析 diff（PATH 至少含 /usr/bin）"
case "$C3_RESOLVED" in
  *openharmony/toolchains/diff)
    assert_contains "$C3_RESOLVED" "openharmony/toolchains/diff" \
      "S1.P3 遮蔽态：ambient 首解命中影子（本机默认态，判据未 pin 即恒假绿）"
    ;;
  *)
    # 非遮蔽态：裸 diff 与 pin diff 对同一对文件必须行为一致且都能检出差异。
    # ⚠️ 此处裸 diff 必须在**真 ambient PATH 语义**下求值——不得经 _diffprobe：它把自建
    # 影子 SB_SHADOW 前置到 PATH，会把「ambient 裸 diff」偷换成影子 ⇒ rc 恒 0 假红本分支。
    diff "$FX_A" "$FX_B" > "$SB/c3-naked.out" 2>&1
    C3N_RC=$?
    _diffprobe /usr/bin/diff "$FX_A" "$FX_B" "$SB/c3-pin.out"
    C3P_RC=$?
    assert_eq "$C3N_RC" "$C3P_RC" "S1.P3 非遮蔽态：裸 diff 与 pin diff rc 一致（等价事实）"
    assert_eq "$(_lines "$SB/c3-naked.out")" "$(_lines "$SB/c3-pin.out")" \
      "S1.P3 非遮蔽态：裸 diff 与 pin diff 行数一致"
    assert_eq "$C3N_RC" "1" "S1.P3 非遮蔽态：ambient diff 仍能检出差异（rc=1）"
    ;;
esac

# =============================================================================
t_case "C4 扫描器自证：合成语料正/负样本计数精确（防 no-op 扫描器恒绿）"
CORPUS="$SB/corpus.sh"
cat > "$CORPUS" <<'EOF'
x="$(diff a b)"
git diff --name-only HEAD
# diff 注释提及：不得计入
echo ok | diff a b
/usr/bin/diff a b > out 2>&1
[ -x /usr/bin/diff ] || die "env" "缺 /usr/bin/diff"
diff -q a b && echo same
mydiff a b
suffix_diff a b
EOF
assert_eq "$(_scan_naked "$CORPUS")" "3" "C4 语料裸调用数=3（命令替换形态 / 管道 / 行首命令位）"
assert_eq "$(_scan_pinned "$CORPUS")" "1" "C4 语料 pin 调用点=1（-x 守卫不计为调用点）"
C4_TOKS="$(_file_tokens "$CORPUS")"
C4_WANT="$(printf '%s\n%s' '/usr/bin/diff' 'diff')"
assert_eq "$C4_TOKS" "$C4_WANT" "C4 语料 token 集合为 /usr/bin/diff 与 diff 两者（mydiff/suffix_diff 不得命中）"

# =============================================================================
t_case "C5 S2.P1+S2.P2 三文件：裸 diff 调用数=0，/usr/bin/diff 调用点=5"
C5_NAKED=0
C5_PINNED=0
_check_file() { # <path> <期望 pin 调用点数> <tag>
  local f="$1" exp="$2" tag="$3" n p t
  if [ ! -f "$f" ]; then
    _fail "$tag 被测文件存在" "缺失: $f"
    return 0
  fi
  n="$(_scan_naked "$f")"
  p="$(_scan_pinned "$f")"
  assert_eq "$n" "0" "$tag 命令位裸 diff 调用数=0"
  assert_eq "$p" "$exp" "$tag 命令位 /usr/bin/diff 调用点数=${exp}"
  t="$(_file_tokens "$f")"
  assert_eq "$t" "/usr/bin/diff" "$tag 调用命令 token 唯一且为 /usr/bin/diff"
  C5_NAKED=$((C5_NAKED + n))
  C5_PINNED=$((C5_PINNED + p))
}
_check_file "$T_S4" 2 "S2.P1 ② s4"
_check_file "$T_T104" 1 "S2.P1 ② t1-04"
_check_file "$T_HK2" 2 "S2.P1 ② hkstock t2_guard"
assert_eq "$C5_NAKED" "0" "S2.P1 三文件合计裸 diff 调用数=0"
assert_eq "$C5_PINNED" "5" "S2.P2 三文件合计 /usr/bin/diff 调用点数=5（s4 两处 + t1-04 一处 + hkstock 两处）"

# =============================================================================
t_case "C6 S2.P3+S2.P4 判据 canary：token 取自被测文件，注入 1 行差异判红 / 无差异判绿"
_check_canary() { # <path> <tag>
  local f="$1" tag="$2" tok rc_d rc_s
  if [ ! -f "$f" ]; then
    _fail "$tag 被测文件存在" "缺失: $f"
    return 0
  fi
  tok="$(_file_tokens "$f")"
  assert_eq "$tok" "/usr/bin/diff" "$tag canary 取到唯一 pin token"
  _diffprobe "$tok" "$FX_A" "$FX_B" "$SB/c6-diff.out"
  rc_d=$?
  _diffprobe "$tok" "$FX_A" "$FX_C" "$SB/c6-same.out"
  rc_s=$?
  assert_eq "$rc_d" "1" "$tag 遮蔽态下注入 1 行差异须判红（判据真求值）rc=1"
  if [ "$(_lines "$SB/c6-diff.out")" -ge 1 ]; then
    _pass "$tag 遮蔽态下差异输出 >= 1 行（判据不等）"
  else
    _fail "$tag 遮蔽态下差异输出 >= 1 行" "实得 $(_lines "$SB/c6-diff.out") 行（pin 失效则恒 0 行假绿）"
  fi
  assert_eq "$rc_s" "0" "$tag 未注入差异的同构输入须判绿 rc=0"
  assert_eq "$(_lines "$SB/c6-same.out")" "0" "$tag 同构输入输出 0 行（判据判等）"
}
_check_canary "$T_S4" "S2.P3 ② s4"
_check_canary "$T_T104" "S2.P3 ② t1-04"
_check_canary "$T_HK2" "S2.P3 ② hkstock t2_guard"

# =============================================================================
t_case "C7 S2.P5 fail-closed：/usr/bin/diff 缺失态须非零退出且不得翻过前置"
_check_guard() { # <path> <tag>
  local f="$1" tag="$2" n missing orig missing_rc orig_rc out reached
  if [ ! -f "$f" ]; then
    _fail "$tag 被测文件存在" "缺失: $f"
    return 0
  fi
  n="$(grep -cE -- '-x[[:space:]]+/usr/bin/diff' "$f")"
  assert_eq "$n" "1" "$tag 存在 1 行 \`-x /usr/bin/diff\` fail-closed 依赖前置"
  grep -E -- '-x[[:space:]]+/usr/bin/diff' "$f" > "$SB/guard.orig"
  missing="$SB/no-such-diff-dir/diff"
  sed "s|/usr/bin/diff|$missing|g" "$SB/guard.orig" > "$SB/guard.missing"
  # 提取文件**本体**的守卫行，配最小 fail-closed 桩执行（die/_fail/_die/fail → exit 1）：
  #   在位态（/usr/bin/diff 存在）→ 断言必须翻过守卫（对照组，防「恒非零」的假红套件）
  #   缺失态（改写为不存在路径）→ 断言必须卡死（rc != 0 且未翻过守卫）
  for pair in "orig:$SB/guard.orig" "missing:$SB/guard.missing"; do
    orig="${pair%%:*}"
    {
      printf 'die(){ exit 1; }\n_fail(){ exit 1; }\n_die(){ exit 1; }\nfail(){ exit 1; }\n'
      cat "${pair#*:}"
      printf 'echo REACHED_END\n'
    } > "$SB/harness.$orig.sh"
  done
  out="$(bash "$SB/harness.orig.sh" 2>&1)"
  orig_rc=$?
  reached="no"
  case "$out" in *REACHED_END*) reached="yes" ;; esac
  assert_eq "$orig_rc" "0" "$tag 对照：/usr/bin/diff 在位时守卫放行（rc=0）"
  assert_eq "$reached" "yes" "$tag 对照：在位时执行流翻过守卫（提取与执行链有效）"
  out="$(bash "$SB/harness.missing.sh" 2>&1)"
  missing_rc=$?
  reached="no"
  case "$out" in *REACHED_END*) reached="yes" ;; esac
  assert_ne "$missing_rc" "0" "$tag 缺失态：fail-closed 非零退出（禁静默放行）"
  assert_eq "$reached" "no" "$tag 缺失态：执行流不得翻过守卫（禁空重定向假绿路径）"
}
_check_guard "$T_S4" "S2.P5 ② s4"
_check_guard "$T_T104" "S2.P5 ② t1-04"

# =============================================================================
t_case "C8 D3 回归：hkstock t2_guard 套件在 pin 后仍全绿（断言语义零改动）"
if [ ! -f "$T_HK2" ]; then
  _fail "C8 t2_guard 存在" "缺失: $T_HK2"
else
  HK2_OUT="$(bash "$T_HK2" 2>&1)"
  HK2_RC=$?
  assert_eq "$HK2_RC" "0" "C8 t2_guard 整体 rc=0"
  assert_ne "$HK2_OUT" "" "C8 t2_guard 有实际输出（非同构空跑）"
fi

t_finish
