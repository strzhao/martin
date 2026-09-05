#!/bin/bash
# cfg-semantics.sh — Tier U：cfg(path, default) 三处实现同一语义（契约规约第 1 条）
#   配置值 false → 输出 false；null/键缺失/文件缺失 → 输出 default；数值/字符串原样透传
# 历史事故锚点：09-05 ① jq `//` 运算符把 notify_dry_run:false 读成默认 true（推送全静默 dry-run）。
# deep_check_gate 的 auto_deep_check 读取同构（设计登记 live bug），黑盒行为断言在本文件尾部。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "cfg-semantics.sh"

# cfg_case <notify|rq> <jq-path> <default> <config-json|__MISSING__> → cfg 输出
#   独立子进程：写沙箱 config → source 被测脚本（SOURCE_ONLY guard，不执行 dispatch）→ 调 cfg
cfg_case() {
  local which="$1" path="$2" def="$3" cfgjson="$4"
  local script="notify.sh" guard="NOTIFY_SOURCE_ONLY" setup out
  if [[ "$which" == "rq" ]]; then
    script="rq.sh"
    guard="RQ_SOURCE_ONLY"
  fi
  if [[ "$cfgjson" == "__MISSING__" ]]; then
    setup='rm -f "$CONTRIB_DATA_DIR/config.json"'
  else
    setup="printf '%s\\n' '$cfgjson' > \"\$CONTRIB_DATA_DIR/config.json\""
  fi
  sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; return 99; }
  out="$(sb_run -e "$guard=1" "$setup
source \"\$MARTIN_DIR/scripts/contrib/$script\" >/dev/null 2>&1
cfg '$path' '$def'")"
  sb_cleanup
  printf '%s' "$out"
}

# ---- notify.sh cfg 五态 ----
t_case "notify cfg: false 态（09-05 事故第一用例）"
assert_eq "$(cfg_case notify '.notify_dry_run' 'true' '{"notify_dry_run": false}')" "false" "false 是合法配置值"

t_case "notify cfg: null 态"
assert_eq "$(cfg_case notify '.notify_dry_run' 'true' '{"notify_dry_run": null}')" "true" "null → default"

t_case "notify cfg: 键缺失"
assert_eq "$(cfg_case notify '.notify_dry_run' 'true' '{}')" "true" "键缺失 → default"

t_case "notify cfg: 文件缺失"
assert_eq "$(cfg_case notify '.notify_dry_run' 'true' '__MISSING__')" "true" "文件缺失 → default"

t_case "notify cfg: 数字/字符串透传"
assert_eq "$(cfg_case notify '.notify_min_interval_min' '20' '{"notify_min_interval_min": 7}')" "7"
assert_eq "$(cfg_case notify '.notify_target' '""' '{"notify_target": "weixin:x"}')" "weixin:x"

# ---- rq.sh cfg 同构语义 ----
t_case "rq cfg: false 态"
assert_eq "$(cfg_case rq '.refund_failed_deep_check' 'false' '{"refund_failed_deep_check": false}')" "false" "false 是合法配置值"

t_case "rq cfg: null/键缺失/文件缺失"
assert_eq "$(cfg_case rq '.refund_failed_deep_check' 'false' '{"refund_failed_deep_check": null}')" "false"
assert_eq "$(cfg_case rq '.deep_check_per_day' '1' '{}')" "1"
assert_eq "$(cfg_case rq '.deep_check_per_day' '1' '__MISSING__')" "1"

t_case "rq cfg: 数字/字符串透传"
assert_eq "$(cfg_case rq '.approval_ttl_hours' '48' '{"approval_ttl_hours": 24}')" "24"

# ---- deep_check_gate.sh auto_deep_check 布尔（黑盒行为断言）----
# 前置：队列有一条 queued 的 deep 候选 + 预算可行；probe 车道无候选
gate_run() { # <false|true|__MISSING__> → 打印 "rc:<gate exit>"
  local val="$1"
  sb_new >/dev/null 2>&1 || { echo "rc:99"; return 1; }
  sb_seed_queue_item "rq-20260905-101" 101 deep queued 40
  case "$val" in
    false) sb_config_set '.auto_deep_check = false' ;;
    true) sb_config_set '.auto_deep_check = true' ;;
    __MISSING__) sb_config_set 'del(.auto_deep_check)' ;;
  esac
  sb_run 'zsh "$MARTIN_DIR/scripts/contrib/deep_check_gate.sh"' >/dev/null 2>&1
  local rc=$?
  sb_cleanup
  echo "rc:$rc"
}

t_case "deep gate: auto_deep_check=false → exit 0（开关必须生效）"
assert_eq "$(gate_run false)" "rc:0" "false 不得被读成 true"

t_case "deep gate: auto_deep_check 缺失 → 缺省 true → exit 10"
assert_eq "$(gate_run __MISSING__)" "rc:10" "键缺失 → default true"

t_case "deep gate: auto_deep_check=true → exit 10"
assert_eq "$(gate_run true)" "rc:10" "true → 开深检"

t_finish
