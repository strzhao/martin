#!/bin/bash
# gate.sh — contrib/approval 域统一秒级入库门（薄壳自聚合，pre-commit 接线入口）
#
# 三关：① bash -n / zsh -n 语法门（按 shebang 分流）② shellcheck -x -S warning（仅 bash 系，zsh 豁免）
#       ③ 全角 regex 门（regex 单源 lib/fullwidth-pattern.txt，perl 字节模式契约冻结）
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
for t in bash zsh shellcheck perl git find; do
  command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
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

# --- 末行汇总 ---
if [[ "$FINDINGS" -eq 0 ]]; then
  printf 'GATE: PASS (%d files, 0 findings)\n' "${#FILES[@]}"
  exit 0
fi
printf 'GATE: FAIL (%d files, %d findings)\n' "${#FILES[@]}" "$FINDINGS"
exit 1
