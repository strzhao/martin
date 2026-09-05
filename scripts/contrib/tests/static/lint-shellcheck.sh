#!/bin/bash
# lint-shellcheck.sh — Tier S 静态检查门：bash 系脚本零发现（场景10.P1，-x -S warning）
# 范围：bash 系生产脚本 4 个 + 套件全部 .sh + 6 个 stub（zsh 3 个豁免，以 zsh -n 覆盖）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export DIM=static

source "$TESTS_ROOT/lib/assert.sh"
TARGET="$(tests_scripts_dir "$TARGET_DEFAULT")"
t_init "shellcheck.sh"

if ! command -v shellcheck >/dev/null 2>&1; then
  t_init "shellcheck.sh"
  t_case "shellcheck 可用性"
  t_skip "shellcheck 不在 PATH（极简环境；run.sh 会注入 shim 绝对路径）"
  t_finish
fi

t_case "文件集计数 >= 10"
files="$TARGET/notify.sh $TARGET/rq.sh $TARGET/scan_gate.sh $TARGET/deep_check_gate.sh"
for f in $(cd "$TESTS_ROOT" && find . -name '*.sh' -type f | sort); do
  files="$files $TESTS_ROOT/$f"
done
for s in hermes claude gh tunnel osascript pgrep; do
  files="$files $TESTS_ROOT/stubs/$s"
done
n=0
for f in $files; do
  [[ -f "$f" ]] && n=$((n + 1))
done
if [[ "$n" -ge 10 ]]; then
  _pass "被检文件数 $n >= 10"
else
  _fail "被检文件数 $n >= 10" "文件缺失（CONTRIB_TEST_TARGET=$TARGET 是否为空目录？）"
fi

t_case "shellcheck -x -S warning 零发现"
out="$(shellcheck -x -S warning $files 2>&1)"
rc=$?
assert_exit 0 $rc "shellcheck exit 0"
assert_eq "$out" "" "stdout 零输出"

t_finish
