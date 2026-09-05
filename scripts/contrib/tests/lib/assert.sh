#!/bin/bash
# assert.sh — 零外部依赖断言库（tests/ 套件共用；bash 3.2 兼容；launchd 极简 PATH 下自足）
#
# 协议：测试文件 source 本库 → t_init → （t_case + 断言...）→ t_finish。
#   - 每条断言打印一行 PASS/FAIL/SKIP（run.sh 透传给调用方，便于定位）
#   - t_finish 在**末行**打 ##SUMMARY JSON（run.sh 按此行聚合）；failed>0 时 exit 1
#   - 测试文件意外死亡（缺 ##SUMMARY）由 run.sh 识别为整文件失败
#
# stub 调用断言依赖 sandbox.sh 注入的 CONTRIB_TEST_STUB_LOG（沙箱调用日志目录）。

DIM="${DIM:-unknown}"
T_FILE="${T_FILE:-unknown.sh}"
T_TOTAL=0
T_PASSED=0
T_FAILED=0
T_SKIPPED=0
T_CURRENT=""

# tests_scripts_dir <default-target-dir> → 被测脚本目录
# 兼容两种 CONTRIB_TEST_TARGET 布局：脚本目录本身，或含 scripts/contrib/ 的沙箱根
# （后者支持 DETECT_KEEP/E2E_KEEP 保留沙箱后直接指向它独立复现）
tests_scripts_dir() {
  local t="${CONTRIB_TEST_TARGET:-$1}"
  if [[ -f "$t/rq.sh" ]]; then
    printf '%s' "$t"
    return 0
  fi
  if [[ -f "$t/scripts/contrib/rq.sh" ]]; then
    printf '%s/scripts/contrib' "$t"
    return 0
  fi
  printf '%s' "$t"
}

t_init() {
  T_FILE="${1:-$T_FILE}"
  T_TOTAL=0
  T_PASSED=0
  T_FAILED=0
  T_SKIPPED=0
  T_CURRENT=""
}

t_case() { T_CURRENT="${1:-}"; }

t_skip() {
  T_TOTAL=$((T_TOTAL + 1))
  T_SKIPPED=$((T_SKIPPED + 1))
  printf 'SKIP %s %s%s\n' "$T_FILE" "$T_CURRENT" "${1:+ :: $1}"
}

_pass() {
  T_TOTAL=$((T_TOTAL + 1))
  T_PASSED=$((T_PASSED + 1))
  printf 'PASS %s %s%s\n' "$T_FILE" "$T_CURRENT" "${1:+ [$1]}"
}

_fail() {
  T_TOTAL=$((T_TOTAL + 1))
  T_FAILED=$((T_FAILED + 1))
  printf 'FAIL %s %s%s :: %s\n' "$T_FILE" "$T_CURRENT" "${1:+ [$1]}" "$2"
}

assert_eq() { # <actual> <expected> [label]
  if [[ "$1" == "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual=[$1] expected=[$2]"
  fi
}

assert_ne() { # <actual> <not-expected> [label]
  if [[ "$1" != "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "actual 与预期不同值相悖：[$1]"
  fi
}

assert_contains() { # <haystack> <needle> [label]
  if [[ "$1" == *"$2"* ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "未找到 [$2]，实际前 240 字节=[${1:0:240}]"
  fi
}

assert_not_contains() { # <haystack> <needle> [label]
  if [[ "$1" != *"$2"* ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "不应出现却出现 [$2]"
  fi
}

assert_exit() { # <expected_rc> <actual_rc> [label]
  if [[ "$1" == "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "exit actual=$2 expected=$1"
  fi
}

assert_file_contains() { # <file> <needle> [label]
  if [[ ! -f "$1" ]]; then
    _fail "${3:-}" "文件缺失: $1"
    return 0
  fi
  if grep -qF -- "$2" "$1"; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "文件 $1 未包含 [$2]"
  fi
}

# ---------------- 沙箱 stub 调用断言 ----------------
# calls.log 行格式：<stub 名>|<cwd>|<argv 以空格连接>
# 消息体副本在 bodies/<stub 名>-<序号>.txt

_stub_calls_log() { printf '%s/calls.log' "${CONTRIB_TEST_STUB_LOG:-/nonexistent}"; }

stub_count() { # <stub 名> → 调用次数（无日志=0）
  local f
  f="$(_stub_calls_log)"
  if [[ ! -f "$f" ]]; then
    printf '0'
    return 0
  fi
  awk -F'|' -v n="$1" '$1 == n { c++ } END { printf "%d", c + 0 }' "$f"
}

stub_body() { # <stub 名> <序号(1-based)> → 消息体副本路径（不存在=空）
  local p
  p="${CONTRIB_TEST_STUB_LOG:-}/bodies/$1-$2.txt"
  [[ -f "$p" ]] && printf '%s' "$p"
  return 0
}

stub_last_body() { # <stub 名> → 最后一个消息体副本路径（无=空）
  local d="${CONTRIB_TEST_STUB_LOG:-}/bodies" p="" max="" n f
  [[ -d "$d" ]] || return 0
  for f in "$d/$1-"*.txt; do
    [[ -f "$f" ]] || continue
    n="${f##*/}"
    n="${n#"$1-"}"
    n="${n%.txt}"
    if [[ -z "$max" || "$n" -gt "$max" ]]; then
      max="$n"
      p="$f"
    fi
  done
  [[ -n "${p:-}" ]] && printf '%s' "$p"
  return 0
}

assert_stub_called() { # <stub 名> [最小次数] [label]
  local n
  n="$(stub_count "$1")"
  if [[ "$n" -ge "${2:-1}" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "stub $1 调用次数 $n < 期望 ${2:-1}"
  fi
}

assert_stub_called_times() { # <stub 名> <恰好次数> [label]
  local n
  n="$(stub_count "$1")"
  if [[ "$n" == "$2" ]]; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "stub $1 调用次数 $n != 期望 $2"
  fi
}

assert_stub_not_called() { # <stub 名> [label]
  local n
  n="$(stub_count "$1")"
  if [[ "$n" == "0" ]]; then
    _pass "${2:-}"
  else
    _fail "${2:-}" "stub $1 被调用了 $n 次（期望 0）"
  fi
}

t_finish() {
  printf '##SUMMARY {"dim":"%s","file":"%s","total":%d,"passed":%d,"failed":%d,"skipped":%d}\n' \
    "$DIM" "$T_FILE" "$T_TOTAL" "$T_PASSED" "$T_FAILED" "$T_SKIPPED"
  if [[ "$T_FAILED" -ne 0 ]]; then
    exit 1
  fi
  exit 0
}
