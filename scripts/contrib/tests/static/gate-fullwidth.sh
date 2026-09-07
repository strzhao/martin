#!/bin/bash
# gate-fullwidth.sh — Tier S：全角字符紧邻变量名静态门（run.sh static 维度 glob 自动发现，零改动接入）
#   命中形态：变量引用 `$var` 紧跟全角标点（如 `$2` 后接全角右括号）→ bash 展开吞掉全角字符，`期望 >= ${2}` 尾字符丢失。
#   regex 单源：lib/fullwidth-pattern.txt（gate.sh 同读一个源，禁双份定义漂移）。
#   perl 一律字节模式（不带 -C 系标志），契约冻结。
# 沙箱语义：CONTRIB_TEST_TARGET 指向沙箱树时只扫 target 树内 .sh；
#   approval 目录缺失按 N/A skip 显式计数；target 树零 .sh 文件必须 FAIL（保负对照）。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export DIM=static

source "$TESTS_ROOT/lib/assert.sh"
t_init "gate-fullwidth.sh"

PATTERN_FILE="$TESTS_ROOT/lib/fullwidth-pattern.txt"

t_case "依赖与 regex 单源"
if command -v perl >/dev/null 2>&1; then
  _pass "perl 可用（字节模式契约）"
else
  _fail "perl 可用" "dep: perl 缺失，全角门 fail closed"
  t_finish
fi
if [[ -s "$PATTERN_FILE" ]]; then
  _pass "regex 单源 lib/fullwidth-pattern.txt 在位"
else
  _fail "regex 单源在位" "fullwidth-pattern.txt 缺失或为空: $PATTERN_FILE"
  t_finish
fi
PATTERN="$(cat "$PATTERN_FILE")"

t_case "文件集 find 圈定（非硬编码）"
CONTRIB_DIR="$(tests_scripts_dir "$TARGET_DEFAULT")"
if [[ -n "${CONTRIB_TEST_TARGET:-}" && -d "$CONTRIB_TEST_TARGET/scripts/contrib" ]]; then
  # 沙箱根布局：approval 在沙箱根下（sb_new 不复制 approval → N/A skip 路径）
  APPROVAL_DIR="$CONTRIB_TEST_TARGET/scripts/approval"
else
  APPROVAL_DIR="$(cd "$CONTRIB_DIR/../.." && pwd)/scripts/approval"
fi

FILES=()
while IFS= read -r f; do FILES[${#FILES[@]}]="$f"; done < <(find "$CONTRIB_DIR" -name '*.sh' -type f 2>/dev/null | sort)
if [[ -d "$APPROVAL_DIR" ]]; then
  while IFS= read -r f; do FILES[${#FILES[@]}]="$f"; done < <(find "$APPROVAL_DIR" -name '*.sh' -type f 2>/dev/null | sort)
  _pass "scripts/approval 并入覆盖集"
else
  t_skip "scripts/approval 缺失（N/A：target 树不含 approval，.bash 由 approval 套件自测覆盖）"
fi

if [[ "${#FILES[@]}" -eq 0 ]]; then
  _fail "target 树含 .sh" "零 .sh 文件（CONTRIB_TEST_TARGET=${CONTRIB_TEST_TARGET:-<unset>}）——负对照失效，fail closed"
  t_finish
fi
_pass "被扫 .sh 文件数 ${#FILES[@]}"

t_case "全角 regex 门（perl 字节模式，逐文件 file:line 定位）"
scan_one() { # <file> → stdout 命中行 L<行号>:<匹配文本>；exit 0=零命中 1=有命中
  PERL_PATTERN="$PATTERN" perl -e '
    my $re = qr/$ENV{PERL_PATTERN}/;
    my $f = $ARGV[0];
    open my $in, "<", $f or do { print "L?:open-failed\n"; exit 1; };
    my $ln = 0; my $hits = 0;
    while (my $line = <$in>) {
      $ln++;
      while ($line =~ /$re/g) {
        my $m = $&;
        $m =~ s/\s+$//;
        print "L$ln:$m\n";
        $hits++;
      }
    }
    exit($hits > 0 ? 1 : 0);
  ' "$1" 2>/dev/null
}

nfail=0
for f in "${FILES[@]}"; do
  m="$(scan_one "$f")"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    nfail=$((nfail + 1))
    _fail "$f" "全角命中: $m"
  fi
done
if [[ "$nfail" -eq 0 ]]; then
  _pass "全角门零命中（${#FILES[@]} 文件）"
fi

t_finish
