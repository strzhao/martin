#!/usr/bin/env bash
# =============================================================================
# s10-static-gates.acceptance.sh — 场景 10：静态检查门（并入一条命令）
# 覆盖谓词：10.P1 10.P2（det-machine，10.P1 为调和后收窄版）
# 依据：state.md `## 验收场景`：
#   10.P1（调和后）shellcheck -x -S warning 对 bash 系生产脚本（notify/rq/scan_gate/
#        deep_check_gate）+ 套件全部 .sh + stub 零发现；3 个 zsh 脚本 SC1071 为
#        工具边界豁免，由 10.P2 的 zsh -n 语法门覆盖。
#   10.P2 全部 .sh（含 zsh 3 个以 zsh -n）零语法错误。
# 解释器归属（设计文档测绘结论冻结）：bash=notify.sh/rq.sh/scan_gate.sh/deep_check_gate.sh；
#   zsh=deep-check.sh/run-deepcheck.sh/run-watch.sh。本文件不读任何实现内容，
#   仅按文件名与上述归属构造检查集。
# 纪律：shellcheck 缺失即 FAIL（测绘确认 ✓ 存在；禁止静默 skip）。
# 产物：/tmp/autopilot-artifacts/s10-p{1,2}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
TARGET="$REPO_ROOT/scripts/contrib"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }

# -----------------------------------------------------------------------------
# 10.P1 [det-machine] shellcheck -x -S warning
# assert: exit==0 且 stdout 行数==0 且 被检文件数>=10
# -----------------------------------------------------------------------------
P="10.P1"
SC="$(command -v shellcheck 2>/dev/null || true)"
[ -z "$SC" ] && for p in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
  [ -x "$p/shellcheck" ] && SC="$p/shellcheck" && break
done
[ -n "$SC" ] || die "$P" "shellcheck 不可得（测绘确认存在；禁止静默跳过）"

FILES=""
for f in notify.sh rq.sh scan_gate.sh deep_check_gate.sh; do
  [ -f "$TARGET/$f" ] || die "$P" "bash 系生产脚本缺失: $TARGET/$f"
  FILES="$FILES $TARGET/$f"
done
while IFS= read -r f; do
  [ -n "$f" ] && FILES="$FILES $f"
done < <(find "$SUITE" -name '*.sh' -type f | sort)
[ -d "$SUITE/stubs" ] && while IFS= read -r f; do
  [ -n "$f" ] && FILES="$FILES $f"
done < <(find "$SUITE/stubs" -type f | sort)

NFILES=0
for f in $FILES; do NFILES=$((NFILES+1)); done
ge "$NFILES" 10 "$P 被检文件数（生产 4 + 套件 .sh + stub）"

# 运行命令：shellcheck -x -S warning "$FILES" —— stdout 应为零行、exit 0
SC_OUT="$(mktemp "${TMPDIR:-/tmp}/acc-s10-p1.XXXXXX")"
# shellcheck disable=SC2086
"$SC" -x -S warning $FILES >"$SC_OUT" 2>"$ART/.s10-p1.stderr"
RC=$?
STDOUT_LINES="$(wc -l < "$SC_OUT" | tr -d ' ')"
{
  echo "--- shellcheck: $SC -x -S warning（$NFILES 个文件）"
  echo "--- exit=$RC / stdout_lines=$STDOUT_LINES"
  cat "$SC_OUT"
  echo "--- stderr ---"
  cat "$ART/.s10-p1.stderr"
} > "$ART/s10-p1.out"
eq "$RC" 0 "$P shellcheck exit（$NFILES 文件）"
eq "$STDOUT_LINES" 0 "$P shellcheck stdout 行数（零发现）"
rm -f "$SC_OUT" "$ART/.s10-p1.stderr"
echo "PASS ${P}（$NFILES 文件零发现）"

# -----------------------------------------------------------------------------
# 10.P2 [det-machine] bash -n / zsh -n 全文件集
# assert: exit==0（零失败）且 stderr 行数==0
# -----------------------------------------------------------------------------
P="10.P2"
ZSH_BIN="$(command -v zsh 2>/dev/null || echo /bin/zsh)"
[ -x "$ZSH_BIN" ] || die "$P" "zsh 不可得（macOS 自带 /bin/zsh）"

ERRFILE="$(mktemp "${TMPDIR:-/tmp}/acc-s10-p2.XXXXXX")"
CHECKED=0; BAD=0
chk_bash(){ bash -n "$1" 2>>"$ERRFILE" || BAD=$((BAD+1)); CHECKED=$((CHECKED+1)); }
chk_zsh(){ "$ZSH_BIN" -n "$1" 2>>"$ERRFILE" || BAD=$((BAD+1)); CHECKED=$((CHECKED+1)); }

for f in notify.sh rq.sh scan_gate.sh deep_check_gate.sh; do
  [ -f "$TARGET/$f" ] || die "$P" "bash 系生产脚本缺失: $TARGET/$f"
  chk_bash "$TARGET/$f"
done
for f in deep-check.sh run-deepcheck.sh run-watch.sh; do
  [ -f "$TARGET/$f" ] || die "$P" "zsh 系生产脚本缺失: $TARGET/$f"
  chk_zsh "$TARGET/$f"
done
while IFS= read -r f; do chk_bash "$f"; done < <(find "$SUITE" -name '*.sh' -type f | sort)
[ -d "$SUITE/stubs" ] && while IFS= read -r f; do chk_bash "$f"; done < <(find "$SUITE/stubs" -type f | sort)

ERRLINES="$(wc -l < "$ERRFILE" | tr -d ' ')"
{
  echo "--- bash -n + zsh -n（$CHECKED 个文件，zsh: deep-check/run-deepcheck/run-watch）"
  echo "--- bad=$BAD stderr_lines=$ERRLINES"
  cat "$ERRFILE"
} > "$ART/s10-p2.out"
rm -f "$ERRFILE"
eq "$BAD" 0 "$P 语法检查失败文件数"
eq "$ERRLINES" 0 "$P 语法检查 stderr 行数"
ge "$CHECKED" 10 "$P 被检文件数（下限与 10.P1 对齐）"
echo "PASS ${P}（$CHECKED 个文件零语法错误）"

echo "s10: ALL PASS（10.P1 10.P2）"
exit 0
