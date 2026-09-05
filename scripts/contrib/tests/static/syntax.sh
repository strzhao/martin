#!/bin/bash
# syntax.sh — Tier S：语法门（bash -n / zsh -n 全文件集，场景10.P2）
# 3 个 zsh 脚本以 zsh -n 覆盖（shellcheck 对 zsh 的 SC1071 属工具边界，见 README 豁免清单）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export DIM=static

source "$TESTS_ROOT/lib/assert.sh"
TARGET="$(tests_scripts_dir "$TARGET_DEFAULT")"
t_init "syntax.sh"

BASH_PROD="notify.sh rq.sh scan_gate.sh deep_check_gate.sh"
ZSH_PROD="deep-check.sh run-deepcheck.sh run-watch.sh"

t_case "生产脚本在位（7 个）"
for f in $BASH_PROD $ZSH_PROD; do
  if [[ -f "$TARGET/$f" ]]; then
    _pass "$f 在位"
  else
    _fail "$f 在位" "被测目录缺 ${f}（CONTRIB_TEST_TARGET=${TARGET}）"
  fi
done

t_case "bash -n：bash 系生产脚本 + 套件 + stub"
bash_files=""
for f in $BASH_PROD; do
  [[ -f "$TARGET/$f" ]] && bash_files="$bash_files $TARGET/$f"
done
for f in $(cd "$TESTS_ROOT" && find . -name '*.sh' -type f | sort); do
  bash_files="$bash_files $TESTS_ROOT/$f"
done
for f in "$TESTS_ROOT"/stubs/hermes "$TESTS_ROOT"/stubs/claude "$TESTS_ROOT"/stubs/gh "$TESTS_ROOT"/stubs/tunnel "$TESTS_ROOT"/stubs/osascript "$TESTS_ROOT"/stubs/pgrep; do
  [[ -f "$f" ]] && bash_files="$bash_files $f"
done
err_out="$(bash -n $bash_files 2>&1)"
rc=$?
assert_exit 0 $rc "bash -n 全集"
assert_eq "$err_out" "" "bash -n 零输出"

t_case "zsh -n：3 个 zsh 编排脚本"
if command -v zsh >/dev/null 2>&1; then
  for f in $ZSH_PROD; do
    err="$(zsh -n "$TARGET/$f" 2>&1)"
    rc=$?
    assert_exit 0 $rc "zsh -n $f"
    assert_eq "$err" "" "zsh -n $f 零 stderr"
  done
else
  t_skip "zsh 不可用（极简环境）"
fi

t_finish
