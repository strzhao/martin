#!/bin/bash
# =============================================================================
# diff-pin-canary-c3-ambient.acceptance.test.sh — 卡 t_23b17603 红队验收
#   目标：守卫套件 C3「S1.P3 非遮蔽态」分支假红修复（修复前：该分支经内部探针把自建
#   exit-0 假影子前置到 PATH 再求值裸 diff ⇒ 三条断言必然假红）
#
# SUT（被测系统）= 同目录 diff-pin-canary.acceptance.test.sh（**进程级黑盒**）：
#   本套件只以不同 PATH 取值驱动它，观测其末行 ##SUMMARY / 退出码 / PASS|FAIL 行；
#   其 C3 分支实现不被通读——源码面只做一处形态判定（R2.P3：该分支不得出现
#   `_diffprobe` 前置裸 diff 求值），且只比对遮蔽分支块文本（R2.P4）。
#
# 谓词映射（SSOT：预注册验收谓词 R2.P1–R2.P7，期望值字面量取自各条 assert:）：
#   T1 ← R2.P1 非遮蔽态 PATH=/usr/bin:/bin:/usr/sbin:/sbin：failed=0 ∧ skipped=0 ∧ total=53 ∧ rc=0
#   T2 ← R2.P2 遮蔽态（真实 toolchains 目录前置；无则机器无关自建 exit-0 假影子）：51/0/0 rc=0
#   T3 ← R2.P3 非遮蔽态三条 S1.P3 断言全 PASS ∧ C3 非遮蔽分支无 `_diffprobe` 前置形态
#   T4 ← R2.P4 C3 遮蔽分支（*openharmony/toolchains/diff) 命中块）与 HEAD 版逐字节一致
#   T5 ← R2.P5 三个生产文件相对 HEAD 零改动（git diff HEAD 输出为空）
#   T6 ← R2.P6 变异回缺陷形态（自建影子目录前置）后在非遮蔽态重新判红 failed>=3 ∧ rc!=0
#   T7 ← R2.P7 回归门：gate.sh rc=0 且末行 GATE: PASS；run.sh failed=0 且 rc=0
#
# 纪律：零 skip / 每断言硬失败 / 零仓内受管文件写入（唯一例外 = 仓内 gitignored 的
#   .autopilot/runtime/ 变异副本，跑完即删并断言无残留）；本套件**所有判据**的 diff
#   一律 pin /usr/bin/diff 绝对路径（禁裸 diff 判据：PATH 遮蔽下裸 diff rc=0 零输出 ⇒
#   判据恒真假绿，正是本轮被测缺陷的同族形态）。
# CONTRACT_AMBIGUOUS: R2.P5 谓词正文写「四个生产文件」，但列举与 assert 均只给 3 个路径
#   ⇒ 本套件按列举的 3 个路径硬断言（差额覆盖风险已在红队报告标注）。
# CONTRACT_AMBIGUOUS: R2.P4 基线口径 = `git show HEAD:<套件>`，而基线性质取决于 blue 的落盘形态：
#   本次红队复核时 HEAD = 修复前提交、修复以**未提交改动**落在工作区 ⇒ 该比对确为「修复前 vs
#   修复后」的遮蔽分支逐字节比对（有效谓词）。本套件照 SSOT 实现，并补非平凡性守卫（块非空 ∧
#   含 case 模式）以防空块比空的假绿；反之若 blue 把修复改为**新提交**（工作区转干净），同一谓词
#   即退化为「文件与自身比对」——该盲区已在红队报告标注，不在此处擅改基线为 HEAD~1。
# CONTRACT_AMBIGUOUS: 遮蔽态构造顺序 = 优先本机真实 toolchains 目录（契约称「toolchains 目录
#   前置」），不存在时回退自建 exit-0 假影子，且假影子路径刻意保持 *openharmony/toolchains/diff
#   形态——使「按路径模式选分支」与「按影子行为选分支」两种实现假设都能被命中（零 skip、零软判）。
# =============================================================================
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析——git rev-parse --show-toplevel 在 ${SELF_DIR} 无输出（非 git 仓库 / git 不可用）；本套件禁静默兜底到生产主 checkout" >&2
  exit 1
fi

TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
SUT_NAME="diff-pin-canary.acceptance.test.sh"
SUT_REL="scripts/contrib/tests/acceptance/${SUT_NAME}"
if [[ -f "$SELF_DIR/$SUT_NAME" ]]; then
  SUT="$SELF_DIR/$SUT_NAME"
else
  SUT="$REPO_ROOT/$SUT_REL"
fi

export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"

# ---------------- 常量（契约字面量，逐字一致） ----------------
NONSHADOW_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
SHADOW_PAT="openharmony/toolchains/diff"
LBL_NONSHADOW_RC="S1.P3 非遮蔽态：裸 diff 与 pin diff rc 一致（等价事实）"
LBL_NONSHADOW_LINES="S1.P3 非遮蔽态：裸 diff 与 pin diff 行数一致"
LBL_NONSHADOW_DETECT="S1.P3 非遮蔽态：ambient diff 仍能检出差异（rc=1）"
LBL_SHADOW_HIT="S1.P3 遮蔽态：ambient 首解命中影子（本机默认态，判据未 pin 即恒假绿）"
P5_FILES=(
  "scripts/contrib/tests/acceptance/s4-production-zero-touch.acceptance.sh"
  "scripts/contrib/tests/acceptance/t1-04-isolation-sandbox.acceptance.test.sh"
  "scripts/hkstock/tests/t2_guard.acceptance.test.sh"
)
MUT_DIR="$REPO_ROOT/.autopilot/runtime/r2-c3-mut-$$"

t_init "$T_FILE"

# ---------------- fail-closed 前置（禁静默兜底） ----------------
[ -x /usr/bin/diff ] || { _fail "env 前置" "缺 /usr/bin/diff 绝对路径——本套件全部判据 pin 该路径（裸 diff 在 PATH 遮蔽下 rc=0 零输出 ⇒ 判据恒真假绿，正是本轮被测缺陷的同族形态）"; t_finish; }
[ -f "$SUT" ] || { _fail "env 前置" "SUT 缺失: ${SUT}"; t_finish; }
[ -d "$REPO_ROOT/scripts/contrib/tests/acceptance" ] || { _fail "env 前置" "验收目录缺失: $REPO_ROOT/scripts/contrib/tests/acceptance"; t_finish; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dpc-c3-ambient.XXXXXX")"
cleanup() { rm -rf "$TMP" "${MUT_DIR:-}"; }
trap cleanup EXIT

# ---------------- 辅助 ----------------
RUN_RC=0
run_with_path() { # <out> <path-value> <script> → RUN_RC；cwd=REPO_ROOT，MARTIN_DIR 未设（契约）
  local out="$1" pv="$2" script="$3"
  RUN_RC=0
  (
    cd "$REPO_ROOT" || exit 1
    unset MARTIN_DIR
    PATH="$pv" bash "$script"
  ) >"$out" 2>&1 || RUN_RC=$?
}

sum_field() { # <##SUMMARY 行> <键> → 值（缺行/缺键 → 空串）
  local line="$1" key="$2"
  if [[ "$line" =~ \"$key\":([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf ''
  fi
}

last_summary() { # <out> → 末条 ##SUMMARY 行（无 → 空串）
  grep '^##SUMMARY ' "$1" 2>/dev/null | tail -n 1
}

ctx() { # <out> [n] → 末 n 行（默认 2）压成一行（FAIL 明细定位用）
  local f="$1" n="${2:-2}"
  tail -n "$n" "$f" 2>/dev/null | tr '\n' '|' | cut -c1-220
}

pass_count_of_label() { # <out> <label 字面量> → 以 PASS 开头且含该标签的行数
  grep -F -- "$2" "$1" 2>/dev/null | grep -c '^PASS ' || true
}

line_count() { wc -l < "$1" | tr -d ' '; }

fails_digest() { # <out> → 前 3 条 FAIL/发现行（压成一行，供回归门 FAIL 明细定位）
  grep -E '^(FAIL |run\.sh: \[crash\])' "$1" 2>/dev/null | head -n 3 | tr '\n' '|' | cut -c1-320
}

awk_shadow_block() { # <src> → C3 遮蔽分支块（case 模式行 .. 其 `;;`/esac）
  awk -v pat="$SHADOW_PAT" '
    state == 0 {
      if ($0 ~ /^[[:space:]]*\*/ && index($0, pat) > 0 && $0 ~ /\)[[:space:]]*$/) { state = 1; print }
      next
    }
    state == 1 {
      print
      if ($0 ~ /;;/ || $0 ~ /^[[:space:]]*esac[[:space:]]*$/) exit
    }
  ' "$1"
}

awk_case_body_minus_arm() { # <src> → 该 case 体内**去掉遮蔽分支**的其余部分（= C3 非遮蔽态分支）
  awk -v pat="$SHADOW_PAT" '
    { L[NR] = $0 }
    END {
      cstart = 0; arm = 0; arm_end = 0; esac_line = 0
      for (i = 1; i <= NR; i++) {
        if (arm == 0 && L[i] ~ /^[[:space:]]*case[[:space:]]/) cstart = i
        if (arm == 0 && L[i] ~ /^[[:space:]]*\*/ && index(L[i], pat) > 0 && L[i] ~ /\)[[:space:]]*$/) arm = i
        if (arm > 0 && arm_end == 0 && i > arm && L[i] ~ /;;/) arm_end = i
        if (arm > 0 && arm_end > 0 && L[i] ~ /^[[:space:]]*esac[[:space:]]*$/) { esac_line = i; break }
      }
      if (cstart == 0 || arm == 0 || arm_end == 0 || esac_line == 0) exit 1
      for (i = cstart + 1; i < esac_line; i++) if (i < arm || i > arm_end) print L[i]
    }
  ' "$1"
}

mutate_default_arm() { # <src> <dst> <插入行文件> → 在默认分支（*）臂）首行后插入影子前置行
  awk -v pat="$SHADOW_PAT" -v insf="$3" '
    { L[NR] = $0 }
    END {
      ins = ""
      while ((getline l < insf) > 0) ins = ins l
      close(insf)
      cstart = 0; arm = 0; arm_end = 0; esac_line = 0; target = 0
      for (i = 1; i <= NR; i++) {
        if (arm == 0 && L[i] ~ /^[[:space:]]*case[[:space:]]/) cstart = i
        if (arm == 0 && L[i] ~ /^[[:space:]]*\*/ && index(L[i], pat) > 0 && L[i] ~ /\)[[:space:]]*$/) arm = i
        if (arm > 0 && arm_end == 0 && i > arm && L[i] ~ /;;/) arm_end = i
        if (arm > 0 && arm_end > 0 && L[i] ~ /^[[:space:]]*esac[[:space:]]*$/) { esac_line = i; break }
      }
      if (cstart == 0 || arm == 0 || arm_end == 0 || esac_line == 0) exit 1
      for (i = arm_end + 1; i < esac_line; i++) if (L[i] ~ /^[[:space:]]*\*\)/) { target = i; break }
      if (target == 0 || ins == "") exit 1
      for (i = 1; i <= NR; i++) { print L[i]; if (i == target) print ins }
    }
  ' "$1" > "$2"
}

# =============================================================================
t_case "T1/R2.P1 非遮蔽态（PATH=/usr/bin:/bin:/usr/sbin:/sbin）跑 SUT：failed=0 ∧ skipped=0 ∧ total=53 ∧ rc=0"
run_with_path "$TMP/p1.out" "$NONSHADOW_PATH" "$SUT"
assert_exit 0 "$RUN_RC" "R2.P1 rc=0（末行：$(ctx "$TMP/p1.out" 1)）"
P1_SUM="$(last_summary "$TMP/p1.out")"
assert_ne "$P1_SUM" "" "R2.P1 末行 ##SUMMARY 存在（缺行=整文件崩，禁当绿；末 2 行：$(ctx "$TMP/p1.out" 2)）"
assert_eq "$(sum_field "$P1_SUM" total)" "53" "R2.P1 total=53（非遮蔽态断言总数）"
assert_eq "$(sum_field "$P1_SUM" failed)" "0" "R2.P1 failed=0"
assert_eq "$(sum_field "$P1_SUM" skipped)" "0" "R2.P1 skipped=0"
assert_eq "$(sum_field "$P1_SUM" passed)" "53" "R2.P1 passed=53"

# =============================================================================
t_case "T2/R2.P2 遮蔽态（toolchains 目录前置）跑同一 SUT：failed=0 ∧ skipped=0 ∧ total=51 ∧ rc=0"
SHADOW_DIR=""
SHADOW_SRC=""
AMBIENT_DIFF="$(command -v diff 2>/dev/null || true)"
case "$AMBIENT_DIFF" in
  *"$SHADOW_PAT") SHADOW_DIR="$(dirname "$AMBIENT_DIFF")" ;;
esac
if [[ -z "$SHADOW_DIR" || ! -x "$SHADOW_DIR/diff" ]]; then
  SHADOW_DIR="$TMP/openharmony/toolchains"
  mkdir -p "$SHADOW_DIR"
  printf '#!/bin/sh\nexit 0\n' > "$SHADOW_DIR/diff"
  chmod +x "$SHADOW_DIR/diff"
  SHADOW_SRC="自建 exit-0 假影子"
else
  SHADOW_SRC="本机真实 OpenHarmony toolchain 影子"
fi
SHADOW_RESOLVED="$(PATH="$SHADOW_DIR:$NONSHADOW_PATH" bash -c 'command -v diff' 2>/dev/null)"
assert_eq "$SHADOW_RESOLVED" "$SHADOW_DIR/diff" "R2.P2 前置：遮蔽态 ambient 首解命中影子（${SHADOW_SRC}：${SHADOW_DIR}）"
# 影子无操作自证：对**确有差异**的一对输入判等且零输出（这正是假绿形态本身；此处故意
# 走 PATH 解析以观测影子行为，不属本套件判据——判据一律 /usr/bin/diff 绝对路径）
printf 'alpha\n' > "$TMP/fx-a"
printf 'beta\n'  > "$TMP/fx-b"
SHADOW_RC=0
SHADOW_OUT="$(PATH="$SHADOW_DIR:$NONSHADOW_PATH" command diff "$TMP/fx-a" "$TMP/fx-b" 2>/dev/null)" || SHADOW_RC=$?
assert_exit 0 "$SHADOW_RC" "R2.P2 前置：影子对差异输入 rc=0（零信息量判据形态）"
assert_eq "$(printf '%s' "$SHADOW_OUT" | wc -l | tr -d ' ')" "0" "R2.P2 前置：影子输出 0 行"
run_with_path "$TMP/p2.out" "$SHADOW_DIR:$NONSHADOW_PATH" "$SUT"
assert_exit 0 "$RUN_RC" "R2.P2 rc=0（末行：$(ctx "$TMP/p2.out" 1)）"
P2_SUM="$(last_summary "$TMP/p2.out")"
assert_ne "$P2_SUM" "" "R2.P2 末行 ##SUMMARY 存在（末 2 行：$(ctx "$TMP/p2.out" 2)）"
assert_eq "$(sum_field "$P2_SUM" total)" "51" "R2.P2 total=51（遮蔽态断言总数）"
assert_eq "$(sum_field "$P2_SUM" failed)" "0" "R2.P2 failed=0"
assert_eq "$(sum_field "$P2_SUM" skipped)" "0" "R2.P2 skipped=0"
assert_eq "$(sum_field "$P2_SUM" passed)" "51" "R2.P2 passed=51"
assert_ne "$(pass_count_of_label "$TMP/p2.out" "$LBL_SHADOW_HIT")" "0" "R2.P2 遮蔽分支确被命中（PASS 行含遮蔽态标签，非静默走默认分支）"

# =============================================================================
t_case "T3/R2.P3 非遮蔽态三条 S1.P3 断言全 PASS ∧ C3 非遮蔽分支无 _diffprobe 前置裸 diff 形态"
assert_ne "$(pass_count_of_label "$TMP/p1.out" "$LBL_NONSHADOW_RC")" "0" "R2.P3 S1.P3 非遮蔽态：裸 diff 与 pin diff rc 一致（等价事实）判 PASS"
assert_ne "$(pass_count_of_label "$TMP/p1.out" "$LBL_NONSHADOW_LINES")" "0" "R2.P3 S1.P3 非遮蔽态：裸 diff 与 pin diff 行数一致判 PASS"
assert_ne "$(pass_count_of_label "$TMP/p1.out" "$LBL_NONSHADOW_DETECT")" "0" "R2.P3 S1.P3 非遮蔽态：ambient diff 仍能检出差异（rc=1）判 PASS"
awk_case_body_minus_arm "$SUT" > "$TMP/c3-nonshadow.txt" 2>/dev/null
C3N_SRC_RC=$?
assert_exit 0 "$C3N_SRC_RC" "R2.P3 源码扫描：C3 非遮蔽分支块可定位（结构变更时 fail-closed，禁空块静默绿）"
C3N_LINES="$(line_count "$TMP/c3-nonshadow.txt")"
assert_ne "$C3N_LINES" "0" "R2.P3 源码扫描：C3 非遮蔽分支块非空（实得 ${C3N_LINES} 行）"
assert_ne "$(grep -c 'S1\.P3' "$TMP/c3-nonshadow.txt" || true)" "0" "R2.P3 源码扫描：该块含 S1.P3 判据（防提取错位导致的空真）"
# 形态判定：该块内不得存在「_diffprobe 前置 + 裸 diff」求值（注释行先剥离，避免注释误报）
sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' "$TMP/c3-nonshadow.txt" > "$TMP/c3-nonshadow.nocomment.txt"
PROBE_BARE="$(grep -c -E '_diffprobe[[:space:]]+diff([[:space:]]|$)' "$TMP/c3-nonshadow.nocomment.txt" || true)"
assert_eq "$PROBE_BARE" "0" "R2.P3 源码扫描：C3 非遮蔽分支无 _diffprobe 前置裸 diff 求值（禁假影子污染 ambient 判定）"

# =============================================================================
t_case "T4/R2.P4 C3 遮蔽分支与修复前 HEAD 版逐字节一致"
git -C "$REPO_ROOT" show "HEAD:${SUT_REL}" > "$TMP/head-ver.sh" 2>"$TMP/head-ver.err"
HEAD_VER_RC=$?
assert_exit 0 "$HEAD_VER_RC" "R2.P4 前置：git show HEAD:${SUT_REL} 可取（err：$(ctx "$TMP/head-ver.err" 1)）"
awk_shadow_block "$TMP/head-ver.sh" > "$TMP/blk-head.txt" 2>/dev/null
awk_shadow_block "$SUT" > "$TMP/blk-work.txt" 2>/dev/null
BLK_HEAD_LINES="$(line_count "$TMP/blk-head.txt")"
BLK_WORK_LINES="$(line_count "$TMP/blk-work.txt")"
assert_ne "$BLK_HEAD_LINES" "0" "R2.P4 遮蔽分支块非空（HEAD 版实得 ${BLK_HEAD_LINES} 行）"
assert_ne "$BLK_WORK_LINES" "0" "R2.P4 遮蔽分支块非空（工作区版实得 ${BLK_WORK_LINES} 行）"
assert_ne "$(grep -c "$SHADOW_PAT" "$TMP/blk-work.txt" || true)" "0" "R2.P4 工作区块即 *openharmony/toolchains/diff) 命中块（块内含该 case 模式）"
/usr/bin/diff "$TMP/blk-head.txt" "$TMP/blk-work.txt" > "$TMP/blk.diff" 2>&1
BLK_RC=$?
assert_exit 0 "$BLK_RC" "R2.P4 遮蔽分支块与 HEAD 版逐字节一致（diff rc=0；差异行数=$(line_count "$TMP/blk.diff")）"

# =============================================================================
t_case "T5/R2.P5 三个生产文件相对 HEAD 零改动（git diff HEAD 输出为空）"
P5_IDX=0
for p5f in "${P5_FILES[@]}"; do
  P5_IDX=$((P5_IDX + 1))
  assert_eq "$([[ -f "$REPO_ROOT/$p5f" ]] && printf 'yes' || printf 'no')" "yes" "R2.P5 文件存在（#${P5_IDX}）：${p5f}"
  P5_DIFF="$(git -C "$REPO_ROOT" diff HEAD -- "$p5f" 2>&1)"
  assert_eq "$P5_DIFF" "" "R2.P5 零改动（#${P5_IDX}）：${p5f}（git diff HEAD 输出为空）"
done

# =============================================================================
t_case "T6/R2.P6 变异回缺陷形态（自建影子目录前置）后在非遮蔽态重新判红：failed>=3 ∧ rc!=0"
mkdir -p "$MUT_DIR"
cat > "$TMP/mut-line.txt" <<'EOS'
    SB_SHADOW="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "${SB_SHADOW}/diff"; chmod +x "${SB_SHADOW}/diff"; PATH="${SB_SHADOW}:${PATH}"
EOS
MUT_FILE="$MUT_DIR/$SUT_NAME"
mutate_default_arm "$SUT" "$MUT_FILE" "$TMP/mut-line.txt" 2>/dev/null
MUT_BUILD_RC=$?
assert_exit 0 "$MUT_BUILD_RC" "R2.P6 变异副本构建成功（默认分支臂可定位并插入影子前置行）"
MUT_SRC_LINES="$(line_count "$SUT")"
MUT_OUT_LINES="$(line_count "$MUT_FILE")"
assert_eq "$MUT_OUT_LINES" "$((MUT_SRC_LINES + 1))" "R2.P6 变异=原文件 +1 行（非空操作：${MUT_SRC_LINES} → ${MUT_OUT_LINES}）"
bash -n "$MUT_FILE" 2>"$TMP/mut-syntax.err"
MUT_SYN_RC=$?
assert_exit 0 "$MUT_SYN_RC" "R2.P6 变异副本语法有效（bash -n；err：$(ctx "$TMP/mut-syntax.err" 1)）"
git -C "$REPO_ROOT" check-ignore -q "$MUT_FILE"
MUT_IGN_RC=$?
assert_exit 0 "$MUT_IGN_RC" "R2.P6 变异副本落在仓内 gitignored 路径（.autopilot/runtime/，仓内受管文件零改动）"
run_with_path "$TMP/p6.out" "$NONSHADOW_PATH" "$MUT_FILE"
assert_ne "$RUN_RC" "0" "R2.P6 变异副本在非遮蔽态判红 rc!=0（rc=${RUN_RC}；末行：$(ctx "$TMP/p6.out" 1)）"
P6_SUM="$(last_summary "$TMP/p6.out")"
assert_ne "$P6_SUM" "" "R2.P6 变异副本仍产出 ##SUMMARY（崩死=不可诊断，禁当绿）"
assert_eq "$([[ "$(sum_field "$P6_SUM" failed)" =~ ^[0-9]+$ ]] && [ "$(sum_field "$P6_SUM" failed)" -ge 3 ] && printf 'yes' || printf 'no')" "yes" "R2.P6 变异副本 failed>=3（实得 $(sum_field "$P6_SUM" failed)）——本套件/P1 判据对缺陷形态敏感"
rm -rf "$MUT_DIR"
assert_eq "$([[ -e "$MUT_DIR" ]] && printf 'yes' || printf 'no')" "no" "R2.P6 变异副本已清理（零残留）"
case "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" in
  *r2-c3-mut*) _fail "R2.P6 零仓内受管文件写入" "git status 残留变异副本路径" ;;
  *) _pass "R2.P6 零仓内受管文件写入（git status 无变异副本残留）" ;;
esac

# =============================================================================
t_case "T7/R2.P7 回归门：gate.sh rc=0 且末行 GATE: PASS；run.sh failed=0 且 rc=0"
RUN_RC=0
(
  cd "$REPO_ROOT" || exit 1
  unset MARTIN_DIR
  bash "$REPO_ROOT/scripts/contrib/tests/gate.sh"
) >"$TMP/gate.out" 2>&1 || RUN_RC=$?
assert_exit 0 "$RUN_RC" "R2.P7 gate.sh rc=0（发现：$(fails_digest "$TMP/gate.out")）"
GATE_LAST="$(grep '^GATE: ' "$TMP/gate.out" 2>/dev/null | tail -n 1)"
assert_contains "$GATE_LAST" "GATE: PASS" "R2.P7 gate.sh 末行含 GATE: PASS（实得：${GATE_LAST}）"
RUN_RC=0
(
  cd "$REPO_ROOT" || exit 1
  MARTIN_DIR="$REPO_ROOT" bash "$REPO_ROOT/scripts/contrib/tests/run.sh"
) >"$TMP/runsh.out" 2>&1 || RUN_RC=$?
assert_exit 0 "$RUN_RC" "R2.P7 run.sh rc=0（末行：$(ctx "$TMP/runsh.out" 1)；发现：$(fails_digest "$TMP/runsh.out")）"
RUN_LAST="$(tail -n 1 "$TMP/runsh.out" 2>/dev/null)"
assert_eq "$(sum_field "$RUN_LAST" failed)" "0" "R2.P7 run.sh failed=0（末行 JSON：${RUN_LAST}；发现：$(fails_digest "$TMP/runsh.out")）"

t_finish
