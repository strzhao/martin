#!/bin/bash
# gate.sh — contrib/approval 域统一秒级入库门（薄壳自聚合，pre-commit 接线入口）
#
# 四关：① bash -n / zsh -n 语法门（按 shebang 分流）② shellcheck -x -S warning（仅 bash 系，zsh 豁免）
#       ③ 全角 regex 门（regex 单源 lib/fullwidth-pattern.txt，perl 字节模式契约冻结）
#       ④ 孪生门一致性（approval/execute.sh 与 contrib/notify.sh 的 occ_all_stalled() 归一化逐字节比对）
# 覆盖集：scripts/contrib/**/*.sh ∪ scripts/approval/**/*.sh ∪ scripts/hkstock/**/*.sh
# （find 圈定，非硬编码；hkstock 于 2026-09-08 T2 纳入，constraint 6 欠账清偿）
# 退出码闭集：0=全绿 1=有发现 2=依赖缺失。聚合不短路：收集全部发现一次报告。
# 零仓内写入（不落任何临时文件进仓）；stdout 承载全部结论，stderr 仅意外错误。
# MARTIN_GATE_TARGET=<dir> 覆盖覆盖集根（mutation 自证/沙箱复现用，契约内旋钮）；
# `--target <dir>` 为同一旋钮的 CLI 别名（契约字面形态，env 优先级高于 flag）。
set -uo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$GATE_DIR/../../.." && pwd)"
PATTERN_FILE="$GATE_DIR/lib/fullwidth-pattern.txt"

# --- CLI 参数解析（仅 --target <dir>，契约内唯一 flag） ---
TARGET_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || { printf 'FAIL gate dep --target 缺参数\n' >&2; exit 2; }
      TARGET_FLAG="$2"; shift 2 ;;
    *) printf 'FAIL gate dep 未知参数: %s\n' "$1" >&2; exit 2 ;;
  esac
done

FINDINGS=0
fail_line() { # <file> <类别> <detail> —— 逐行发现，stdout 承载
  printf 'FAIL %s %s %s\n' "$1" "$2" "$3"
  FINDINGS=$((FINDINGS + 1))
}
first_line() { # <multiline> → 首行
  printf '%s' "$1" | head -n 1
}

# --- 依赖存在性探测（fail closed 全集，禁空集静默绿） ---
MISSING=""
for t in bash zsh shellcheck perl git find sed; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
# diff 必须 pin /usr/bin/diff 绝对路径（2026-09-05 知识：PATH 上第三方 diff 遮蔽系统
# diff，stdout 为空的静默假绿），故依赖探测用 -x 探可执行位而非 command -v。
[[ -x /usr/bin/diff ]] || MISSING="$MISSING /usr/bin/diff"
if [[ -n "$MISSING" ]]; then
  for t in $MISSING; do
    fail_line gate dep "缺失依赖: $t"
  done
  printf 'GATE: FAIL (0 files, %d findings)\n' "$FINDINGS"
  exit 2
fi

# --- 覆盖集根（find 圈定；env > flag > 默认两目录） ---
if [[ -n "${MARTIN_GATE_TARGET:-}" ]]; then
  ROOTS=("$MARTIN_GATE_TARGET")
elif [[ -n "$TARGET_FLAG" ]]; then
  ROOTS=("$TARGET_FLAG")
else
  ROOTS=("$REPO_ROOT/scripts/contrib" "$REPO_ROOT/scripts/approval" "$REPO_ROOT/scripts/hkstock")
fi
bad_root=0
for r in ${ROOTS[@]+${ROOTS[@]}}; do
  if [[ ! -d "$r" ]]; then
    fail_line "$r" dep "覆盖根不存在: $r"
    bad_root=1
  fi
done
if [[ "$bad_root" -ne 0 ]]; then
  printf 'GATE: FAIL (0 files, %d findings)\n' "$FINDINGS"
  exit 2
fi

FILES=()
for r in ${ROOTS[@]+${ROOTS[@]}}; do
  while IFS= read -r f; do FILES[${#FILES[@]}]="$f"; done < <(find "$r" -name '*.sh' -type f | sort)
done

# --- 覆盖面声明行（绿跑契约；MARTIN_GATE_TARGET 模式打印实际根） ---
covline="COVERAGE"
for r in ${ROOTS[@]+${ROOTS[@]}}; do
  covline="$covline ${r#"$REPO_ROOT/"}"
done
printf '%s\n' "$covline"

if [[ "${#FILES[@]}" -eq 0 ]]; then
  fail_line gate dep "覆盖集为空（零 .sh）——禁空集静默绿"
  printf 'GATE: FAIL (%d files, %d findings)\n' "${#FILES[@]}" "$FINDINGS"
  exit 1
fi

# --- 关 4：孪生门一致性（状态在 SCAN 块前算完存 shell 变量；发现发射在关 3 之后的关 4 区块） ---
# 机械比对 approval/execute.sh 与 contrib/notify.sh 的 occ_all_stalled() 函数体：
# 抽取 sed -n '/^occ_all_stalled() {/,/^}/p' → 归一化 → /usr/bin/diff。
# 全程命令替换 + 进程替换，零仓内写入。
# ⚠️ 归一化空白折叠必须用 POSIX 形态 s/[[:space:]][[:space:]]*/ /g，禁止改回
# s/[[:space:]]\+/ /g：macOS BSD sed 中 \+ 是字面 +（把 date +%s 吞成 date %s、
# 缩进不折叠，属假归一化；2026-09-12 探针实证），故此处与目标段常见写法存在刻意偏差，禁改回。
TWIN_STATUS="PASS" # PASS | FAIL | SKIP
TWIN_DETAILS=""    # 换行分隔的发现 detail（FAIL 态非空）
twin_find() { # <name> <path-glob> → ROOTS 逐根查找，sort | sed -n '1p' 取首个（禁硬编码绝对清单）
  local name="$1" pat="$2" r hit
  for r in ${ROOTS[@]+${ROOTS[@]}}; do
    hit="$(find "$r" -type f -path "$pat" -name "$name" 2>/dev/null | sort | sed -n '1p')"
    if [[ -n "$hit" ]]; then
      printf '%s' "$hit"
      return 0
    fi
  done
  return 1
}
twin_norm() { # <file> → occ_all_stalled() 函数体归一化流（纯 sed；stdout 承载）
  sed -n '/^occ_all_stalled() {/,/^}/p' "$1" \
    | sed '1d; /^[[:space:]]*#/d; /^[[:space:]]*$/d; s/[[:space:]][[:space:]]*/ /g'
}
TWIN_TARGET_STATE=0 # 默认态（env/flag 均空）=仓级不变量；TARGET 态（任一非空）对缺失可 SKIP
if [[ -n "${MARTIN_GATE_TARGET:-}" || -n "$TARGET_FLAG" ]]; then
  TWIN_TARGET_STATE=1
fi
TWIN_A="$(twin_find 'execute.sh' '*approval*')"
TWIN_B="$(twin_find 'notify.sh' '*contrib*')"
if [[ -z "$TWIN_A" || -z "$TWIN_B" ]]; then
  if [[ "$TWIN_TARGET_STATE" -eq 1 ]]; then
    TWIN_STATUS="SKIP" # target 态无孪生对：SCAN 行 SKIP，不产发现
  else
    TWIN_STATUS="FAIL" # 默认态孪生源任一缺失即 FAIL（fail-closed，禁静默绿）
    [[ -z "$TWIN_A" ]] && TWIN_DETAILS="孪生源缺失: *approval*/execute.sh"
    [[ -z "$TWIN_B" ]] && TWIN_DETAILS="${TWIN_DETAILS:+"$TWIN_DETAILS
"}孪生源缺失: *contrib*/notify.sh"
  fi
else
  TWIN_NA="$(twin_norm "$TWIN_A")"
  TWIN_NB="$(twin_norm "$TWIN_B")"
  if [[ -z "$TWIN_NA" || -z "$TWIN_NB" ]]; then
    TWIN_STATUS="FAIL" # 抽取/归一化为空即 FAIL（fail-closed，禁静默绿）
    [[ -z "$TWIN_NA" ]] && TWIN_DETAILS="occ_all_stalled 抽取/归一化为空: $TWIN_A"
    [[ -z "$TWIN_NB" ]] && TWIN_DETAILS="${TWIN_DETAILS:+"$TWIN_DETAILS
"}occ_all_stalled 抽取/归一化为空: $TWIN_B"
  else
    TWIN_DOUT="$(/usr/bin/diff <(printf '%s\n' "$TWIN_NA") <(printf '%s\n' "$TWIN_NB") 2>&1)"
    TWIN_DRC=$?
    case "$TWIN_DRC" in
      0) TWIN_STATUS="PASS" ;;
      1) # rc 1=漂移；detail 取 diff 输出首个 ^[<>] 内容行
        TWIN_STATUS="FAIL"
        TWIN_DLINE="$(printf '%s\n' "$TWIN_DOUT" | sed -n '/^[<>] /{p;q;}')"
        # ${TWIN_B} 花括号形态与 $TWIN_B 展开逐字节同义；用花括号是为避开本门关 3
        # 全角 regex（\$(\w+) 紧贴全角括号会被自检命中），运行时输出不变。
        TWIN_DETAILS="occ_all_stalled 孪生体漂移（$TWIN_A vs ${TWIN_B}）: $TWIN_DLINE"
        ;;
      *) # rc ≥2=diff 故障 fail-closed
        TWIN_STATUS="FAIL"
        TWIN_DETAILS="diff 故障 rc=$TWIN_DRC: $(first_line "$TWIN_DOUT")"
        ;;
    esac
  fi
fi

# --- shebang 分流 ---
BASH_FILES=()
ZSH_FILES=()
for f in ${FILES[@]+${FILES[@]}}; do
  first="$(head -n 1 "$f")"
  case "$first" in
    *zsh*) ZSH_FILES[${#ZSH_FILES[@]}]="$f" ;;
    *) BASH_FILES[${#BASH_FILES[@]}]="$f" ;;
  esac
done

# --- 逐维度汇总行（先于发现明细，PASS/FAIL 均打） ---
printf 'SCAN bash -n: %d files\n' "${#BASH_FILES[@]}"
printf 'SCAN zsh -n: %d files\n' "${#ZSH_FILES[@]}"
printf 'SCAN shellcheck: %d files\n' "${#BASH_FILES[@]}"
printf 'SCAN 全角: %d files\n' "${#FILES[@]}"
if [[ "$TWIN_STATUS" == "SKIP" ]]; then
  printf 'SCAN 孪生门一致性: SKIP（target 态无孪生对）\n'
else
  printf 'SCAN 孪生门一致性: %s\n' "$TWIN_STATUS"
fi

# --- 关 1：语法门 ---
for f in ${BASH_FILES[@]+${BASH_FILES[@]}}; do
  out="$(bash -n "$f" 2>&1)" && continue
  fail_line "$f" syntax "bash -n: $(first_line "$out")"
done
for f in ${ZSH_FILES[@]+${ZSH_FILES[@]}}; do
  out="$(zsh -n "$f" 2>&1)" && continue
  fail_line "$f" syntax "zsh -n: $(first_line "$out")"
done

# --- 关 2：shellcheck（仅 bash 系；zsh SC1071 属工具边界，豁免由 zsh -n 覆盖） ---
for f in ${BASH_FILES[@]+${BASH_FILES[@]}}; do
  out="$(shellcheck -x -S warning "$f" 2>&1)" && continue
  codes="$(printf '%s\n' "$out" | grep -oE 'SC[0-9]+' | sort -u | tr '\n' ' ')"
  fail_line "$f" shellcheck "codes[$codes] $(first_line "$out")"
done

# --- 关 3：全角 regex 门（perl 字节模式，逐文件 file:line 定位） ---
if [[ ! -s "$PATTERN_FILE" ]]; then
  fail_line gate dep "regex 单源缺失: $PATTERN_FILE"
else
  PATTERN="$(cat "$PATTERN_FILE")"
  for f in ${FILES[@]+${FILES[@]}}; do
    m="$(PERL_PATTERN="$PATTERN" perl -e '
      my $re = qr/$ENV{PERL_PATTERN}/;
      my $f = $ARGV[0];
      open my $in, "<", $f or do { print "L?:open-failed\n"; exit 1; };
      my $ln = 0; my $hits = 0;
      while (my $line = <$in>) {
        $ln++;
        while ($line =~ /$re/g) {
          my $mm = $&;
          $mm =~ s/\s+$//;
          print "L$ln:$mm\n";
          $hits++;
        }
      }
      exit($hits > 0 ? 1 : 0);
    ' "$f" 2>/dev/null)" && continue
    fail_line "$f" fullwidth "全角命中: $m"
  done
fi

# --- 关 4：孪生门一致性发现发射（状态已在 SCAN 块前算完；复用 fail_line，聚合不短路） ---
if [[ "$TWIN_STATUS" == "FAIL" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] && fail_line gate twin "$d"
  done <<< "$TWIN_DETAILS"
fi

# --- 末行汇总 ---
if [[ "$FINDINGS" -eq 0 ]]; then
  printf 'GATE: PASS (%d files, 0 findings)\n' "${#FILES[@]}"
  exit 0
fi
printf 'GATE: FAIL (%d files, %d findings)\n' "${#FILES[@]}" "$FINDINGS"
exit 1
