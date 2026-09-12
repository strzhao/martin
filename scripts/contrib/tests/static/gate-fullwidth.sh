#!/bin/bash
# gate-fullwidth.sh — Tier S：全角字符紧邻变量名静态门（run.sh static 维度 glob 自动发现，零改动接入）
#   命中形态：变量引用 `$var` 紧跟全角标点（如 `$2` 后接全角右括号）→ bash 展开吞掉全角字符，`期望 >= ${2}` 尾字符丢失。
#   regex 单源：lib/fullwidth-pattern.txt（gate.sh 同读一个源，禁双份定义漂移）。
#   perl 一律字节模式（不带 -C 系标志），契约冻结。
# 覆盖集根集真源 = gate.sh 默认态 ROOTS 行派生（禁手抄清单，t_1d48fa2f/3caa12a 纪律）；
#   真仓缺根 fail-closed、沙箱缺根 N/A skip。
# 沙箱语义：活动树根 TREE_ROOT=CONTRIB_DIR/../..（tests_scripts_dir 解析，统一 run.sh 默认态/
#   DETECT_KEEP 沙箱根/缺陷注入副本三种布局），逐根按 ROOTS 相对路径并入；
#   target 树零 .sh 文件必须 FAIL（保负对照）。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_ROOT/../../.." && pwd)"
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

t_case "文件集 find 圈定（根集从 gate.sh ROOTS 真源派生）"
CONTRIB_DIR="$(tests_scripts_dir "$TARGET_DEFAULT")"
TREE_ROOT="$(cd "$CONTRIB_DIR/../.." && pwd)"

# 根集真源唯一化（3caa12a 既定形态）：从 gate.sh 默认态 ROOTS 行 grep 派生，绝不手抄清单
ROOTS_N="$(grep -cE '^[[:space:]]*ROOTS=\("\$REPO_ROOT/scripts/' "$TESTS_ROOT/gate.sh")"
if [[ "$ROOTS_N" -ne 1 ]]; then
  _fail "覆盖集真源唯一" "gate.sh 默认态 ROOTS 行应恰 1 行（实得 ${ROOTS_N} 行）——覆盖集真源漂移，fail closed"
  t_finish
fi
SRC="$(grep -E '^[[:space:]]*ROOTS=\("\$REPO_ROOT/scripts/' "$TESTS_ROOT/gate.sh")"
SRC="${SRC/\\\$REPO_ROOT/$REPO_ROOT}"
FW_ROOTS=()
eval "${SRC/ROOTS=/FW_ROOTS=}"
if [[ "${#FW_ROOTS[@]}" -eq 0 ]]; then
  _fail "覆盖集派生非空" "gate.sh 默认态 ROOTS 行派生出空根集，fail closed"
  t_finish
fi

FILES=()
for r in ${FW_ROOTS[@]+${FW_ROOTS[@]}}; do
  rel="${r#"$REPO_ROOT/"}"
  if [[ "$rel" == "$r" ]]; then
    _fail "覆盖根派生异常" "根剥不出 REPO_ROOT 前缀: $r ，fail closed"
    t_finish
  fi
  dir="$TREE_ROOT/$rel"
  if [[ -d "$dir" ]]; then
    n=0
    while IFS= read -r f; do FILES[${#FILES[@]}]="$f"; n=$((n + 1)); done < <(find "$dir" -name '*.sh' -type f 2>/dev/null | sort)
    _pass "$rel 并入覆盖集 ($n)"
  elif [[ "$TREE_ROOT" == "$REPO_ROOT" ]]; then
    _fail "真仓根在位: $rel" "真仓结构性缺根 $dir ，对齐 gate.sh bad_root 语义，fail closed"
    t_finish
  else
    t_skip "N/A：target 树不含 $rel"
  fi
done

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
