#!/bin/bash
# run.sh — 套件一条命令入口：聚合 unit/contract/e2e/static 四维度 + 全部 detect 捕获自证
#
# 用法：bash scripts/contrib/tests/run.sh
#   末行输出 JSON 摘要：{"total":N,"passed":N,"failed":N,"skipped":N,"dims":{"unit":N,"contract":N,"e2e":N,"static":N}}
#   exit 0 当且仅当 failed==0 且全部 detect 类 exit 0
#
# 环境适配（launchd 仿真，场景2.P1）：
#   - cwd 无关：资源一律依本脚本位置解析
#   - 极简 PATH 自足：启动期按已知前缀探测 jq/python3/shellcheck/git/zsh 绝对路径，
#     建白名单 shim 目录注入子进程 PATH（绝不包含 hermes/gh/claude/tunnel/osascript——
#     外部命令逃逸在任何 PATH 下都会被抓，见 sandbox.sh）
#   - 被测脚本目录经 CONTRIB_TEST_TARGET 注入（默认本仓 scripts/contrib；可指向沙箱/缺陷注入副本）
set -uo pipefail

TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

# ---------------- 工具发现（极简 PATH 自足） ----------------
find_tool() {
  local p prefix
  p="$(command -v "$1" 2>/dev/null || true)"
  if [[ -n "$p" && -x "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  for prefix in /opt/homebrew/bin /usr/local/bin "${HOME:-/root}/.local/bin" /usr/bin /bin; do
    if [[ -x "$prefix/$1" ]]; then
      printf '%s/%s' "$prefix" "$1"
      return 0
    fi
  done
  return 1
}

SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/contrib-shim.XXXXXX")"
MISSING_TOOLS=""
for t in jq python3 shellcheck git zsh bash awk sed grep; do
  if p="$(find_tool "$t")"; then
    ln -sf "$p" "$SHIM_DIR/$t" 2>/dev/null || true
  else
    MISSING_TOOLS="$MISSING_TOOLS $t"
  fi
done
export PATH="$SHIM_DIR:/usr/bin:/bin"
if [[ -n "$MISSING_TOOLS" ]]; then
  echo "run.sh: 以下工具未探测到（相关维度将按设计降级/skip）：$MISSING_TOOLS" >&2
fi

# ---------------- 维度运行 ----------------
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
DIM_UNIT=0
DIM_CONTRACT=0
DIM_E2E=0
DIM_STATIC=0
DETECT_FAILED=0

run_test_file() { # <dim> <file>
  local dim="$1" file="$2" out rc summary
  out="$(DIM="$dim" T_FILE="$(basename "$file")" bash "$file" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  summary="$(printf '%s\n' "$out" | grep '^##SUMMARY ' | tail -1 || true)"
  if [[ -z "$summary" ]]; then
    # 文件意外死亡（无末行汇总）：计 1 个失败用例
    echo "run.sh: [crash] $file 无 ##SUMMARY（exit=${rc}）"
    TOTAL=$((TOTAL + 1))
    FAILED=$((FAILED + 1))
    return 0
  fi
  summary="${summary#\#\#SUMMARY }"
  local t p f s
  t="$(printf '%s' "$summary" | jq -r '.total')"
  p="$(printf '%s' "$summary" | jq -r '.passed')"
  f="$(printf '%s' "$summary" | jq -r '.failed')"
  s="$(printf '%s' "$summary" | jq -r '.skipped')"
  TOTAL=$((TOTAL + t))
  PASSED=$((PASSED + p))
  FAILED=$((FAILED + f))
  SKIPPED=$((SKIPPED + s))
  case "$dim" in
    unit) DIM_UNIT=$((DIM_UNIT + t)) ;;
    contract) DIM_CONTRACT=$((DIM_CONTRACT + t)) ;;
    e2e) DIM_E2E=$((DIM_E2E + t)) ;;
    static) DIM_STATIC=$((DIM_STATIC + t)) ;;
  esac
}

echo "==== 维度 1/4：unit ===="
for f in "$TESTS_ROOT"/unit/*.sh; do
  [[ -e "$f" ]] && run_test_file unit "$f"
done

echo "==== 维度 2/4：contract ===="
for f in "$TESTS_ROOT"/contract/*.sh; do
  [[ -e "$f" ]] && run_test_file contract "$f"
done

echo "==== 维度 3/4：e2e ===="
for f in "$TESTS_ROOT"/e2e/*.sh; do
  [[ -e "$f" ]] && run_test_file e2e "$f"
done
echo "---- e2e 冒烟独立入口 ----"
if bash "$TESTS_ROOT/e2e-smoke.sh" >/tmp/contrib-e2e-smoke-$$.json 2>/tmp/contrib-e2e-smoke-$$.err; then
  echo "PASS e2e-smoke"
  echo "run.sh: smoke $(tail -1 /tmp/contrib-e2e-smoke-$$.json)"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
  DIM_E2E=$((DIM_E2E + 1))
else
  echo "FAIL e2e-smoke"
  cat /tmp/contrib-e2e-smoke-$$.json /tmp/contrib-e2e-smoke-$$.err
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  DIM_E2E=$((DIM_E2E + 1))
fi
rm -f /tmp/contrib-e2e-smoke-$$.json /tmp/contrib-e2e-smoke-$$.err

echo "==== 维度 4/4：static ===="
for f in "$TESTS_ROOT"/static/*.sh; do
  [[ -e "$f" ]] && run_test_file static "$f"
done

echo "==== 捕获自证：detect（5 类） ===="
for cls in bool-parse cwd-dep ledger-vs-delivery state-machine bookkeeping; do
  if bash "$TESTS_ROOT/detect/run.sh" "$cls" >"/tmp/contrib-detect-$cls-$$.json" 2>&1; then
    echo "PASS detect/$cls"
    echo "run.sh: $(tail -1 "/tmp/contrib-detect-$cls-$$.json")"
  else
    echo "FAIL detect/$cls"
    cat "/tmp/contrib-detect-$cls-$$.json"
    DETECT_FAILED=$((DETECT_FAILED + 1))
  fi
  rm -f "/tmp/contrib-detect-$cls-$$.json"
done

rmdir "$SHIM_DIR" 2>/dev/null || true

# ---------------- 末行 JSON 摘要 ----------------
printf '{"total":%d,"passed":%d,"failed":%d,"skipped":%d,"dims":{"unit":%d,"contract":%d,"e2e":%d,"static":%d}}\n' \
  "$TOTAL" "$PASSED" "$FAILED" "$SKIPPED" "$DIM_UNIT" "$DIM_CONTRACT" "$DIM_E2E" "$DIM_STATIC"

if [[ "$FAILED" -eq 0 && "$DETECT_FAILED" -eq 0 ]]; then
  exit 0
fi
exit 1
