#!/bin/bash
# t2_guard.acceptance.test.sh — 盘前简报守卫 brief_guard.sh 契约验收（红队，黑盒，全 seam 注入）
# 覆盖谓词：7.P1 / 7.P2 / 8.P1 / 8.P2 / 8.P3（场景 7/8，det-machine）
# 依据：设计契约（守卫 CLI 契约，红队任务书 2026-09-08 下发口径）：
#   - CLI: bash scripts/hkstock/brief_guard.sh [--date YYYY-MM-DD] [--holdings <path>]
#   - 非交易日 → exit 0 + stdout 含 SKIP_HOLIDAY（7.P1 注入 2026-09-12 周六）
#   - 非交易日分支零副作用：briefs/ 无新文件 ∧ guard-fail.log 无新行（7.P2 negate）
#   - 数据源失败（HKSTOCK_GUARD_FAIL_SOURCE=1 测试钩子注入）→ exit != 0 ∧ briefs/ 无当日新简报（8.P1）
#   - 失败记录 hkstock-data/logs/guard-fail.log 末行含 <日期> ∧ 非空原因（8.P2）
#   - holdings 缺失 → exit != 0（8.P3，显式 pin 交易日避免非交易日短路干扰）
# ⚠ 口径声明：本文件按任务书下发契约编写，覆盖了此前 staging 中基于 G1 旧口径
#   （exit 2 / skip:非交易日 / --probe-url / briefs/guard-failures.log）的版本——
#   两套口径互斥（7.P1 exit 值直接矛盾），以任务书契约为验收 SSOT，冲突已上报仲裁。
# 留痕说明（8.P2）：guard-fail.log 为真实路径，测试注入产生的失败行属预期留痕；
#   断言采用「行数基线 + 末行内容」对比，不删除、不改写既有记录。除该日志外
#   测试不写任何真实产物目录（快照对比为只读）。
# 用法：bash t2_guard.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
GUARD="$MARTIN_ROOT/scripts/hkstock/brief_guard.sh"
BRIEFS_DIR="$MARTIN_ROOT/hkstock-data/briefs"
FAIL_LOG="$MARTIN_ROOT/hkstock-data/logs/guard-fail.log"
HOLIDAY_DATE="2026-09-12"      # 周六（date -j 实证），非交易日注入
TRADING_DATE="2026-09-08"      # 周二（date -j 实证），确定性交易日注入

TMPDIR_T2="$(mktemp -d /tmp/t2-guard-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T2"' EXIT

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

# briefs 目录文件清单快照（目录不存在 = 空清单；只读，不建目录）
snap_briefs() {
  if [[ -d "$BRIEFS_DIR" ]]; then
    find "$BRIEFS_DIR" -type f | sort
  fi
}

# guard-fail.log 行数（文件不存在 = 0）
log_line_count() {
  if [[ -f "$FAIL_LOG" ]]; then
    wc -l < "$FAIL_LOG" | tr -d '[:space:]'
  else
    printf '0'
  fi
}

echo "== t2_guard: brief_guard.sh 守卫契约验收（场景 7/8）=="

# --- 前置：守卫脚本存在 ---
if [[ ! -f "$GUARD" ]]; then
  fail "PRE" "守卫脚本不存在: ${GUARD}（T2 交付物缺失）"
  printf 'RESULT: FAIL=1\n'
  exit 1
fi

# ============ 7.P1 + 7.P2：非交易日注入（一次运行，双谓词） ============
snap_before="$(snap_briefs)"
[[ -z "$snap_before" ]] && snap_before="(empty)"
log_before="$(log_line_count)"

h_out="$(bash "$GUARD" --date "$HOLIDAY_DATE" 2>&1)"
h_rc=$?

# --- 7.P1: exit == 0 ∧ stdout 含 SKIP_HOLIDAY ---
if [[ $h_rc -eq 0 ]] && printf '%s' "$h_out" | grep -q 'SKIP_HOLIDAY'; then
  pass "7.P1"
else
  fail "7.P1" "非交易日注入（--date $HOLIDAY_DATE 周六）: exit=${h_rc}（要求 0），stdout=[$(printf '%s' "$h_out" | head -3 | tr '\n' ' ')]（要求含 SKIP_HOLIDAY）"
fi

# --- 7.P2: 零副作用（negate）：briefs/ 无新文件 ∧ guard-fail.log 无新行 ---
snap_after="$(snap_briefs)"
[[ -z "$snap_after" ]] && snap_after="(empty)"
log_after="$(log_line_count)"
p2_fail=""
if [[ "$snap_before" != "$snap_after" ]]; then
  p2_fail="briefs 目录快照有新增: $(diff <(printf '%s\n' "$snap_before") <(printf '%s\n' "$snap_after") | grep '^>' | head -3 | tr '\n' ' ')"
fi
if [[ "$log_after" -ne "$log_before" ]]; then
  p2_fail="${p2_fail:+$p2_fail | }guard-fail.log 行数变化: before=${log_before} after=${log_after}（非交易日 skip 分支不应留失败记录）"
fi
if [[ -z "$p2_fail" ]]; then
  pass "7.P2"
else
  fail "7.P2" "$p2_fail"
fi

# ============ 8.P1 + 8.P2：数据源失败注入（测试钩子，一次运行，双谓词） ============
snap_before_ds="$(snap_briefs)"
[[ -z "$snap_before_ds" ]] && snap_before_ds="(empty)"
log_before_ds="$(log_line_count)"

ds_out="$(HKSTOCK_GUARD_FAIL_SOURCE=1 bash "$GUARD" --date "$TRADING_DATE" 2>&1)"
ds_rc=$?
log_after_ds="$(log_line_count)"
snap_after_ds="$(snap_briefs)"
[[ -z "$snap_after_ds" ]] && snap_after_ds="(empty)"

# --- 8.P1: exit != 0 ∧ briefs/ 无当日新简报（防空简报静默放行）---
p1_fail=""
if [[ $ds_rc -eq 0 ]]; then
  p1_fail="数据源失败注入（HKSTOCK_GUARD_FAIL_SOURCE=1 --date ${TRADING_DATE}）后守卫 exit=0（要求非 0），stdout=[$(printf '%s' "$ds_out" | head -3 | tr '\n' ' ')]"
elif [[ "$snap_before_ds" != "$snap_after_ds" ]]; then
  new_files="$(diff <(printf '%s\n' "$snap_before_ds") <(printf '%s\n' "$snap_after_ds") | grep '^>' | head -3 | tr '\n' ' ')"
  p1_fail="守卫失败的同时 briefs 目录有新增产物（疑当日空简报）: $new_files"
fi
if [[ -z "$p1_fail" ]]; then
  pass "8.P1"
else
  fail "8.P1" "$p1_fail"
fi

# --- 8.P2: guard-fail.log 末行含当日日期 ∧ 非空原因 ---
p2ds_fail=""
if [[ ! -f "$FAIL_LOG" ]]; then
  p2ds_fail="失败记录未落盘: $FAIL_LOG 不存在"
elif [[ "$log_after_ds" -le "$log_before_ds" ]]; then
  p2ds_fail="guard-fail.log 行数未增长（before=${log_before_ds} after=${log_after_ds}），失败记录未追加"
else
  last_line="$(tail -n 1 "$FAIL_LOG")"
  if ! printf '%s' "$last_line" | grep -q "$TRADING_DATE"; then
    p2ds_fail="末行不含当日日期 $TRADING_DATE: [$last_line]"
  elif ! printf '%s' "$last_line" | sed -E "s/^.*${TRADING_DATE}//" | grep -q '[^[:space:]]'; then
    p2ds_fail="末行原因字段为空（要求 '<日期> <原因>' 且原因非空）: [$last_line]"
  fi
fi
if [[ -z "$p2ds_fail" ]]; then
  pass "8.P2"
else
  fail "8.P2" "$p2ds_fail"
fi

# ============ 8.P3：holdings 缺失注入 ============
h3_out="$(bash "$GUARD" --holdings /nonexistent/h.yaml --date "$TRADING_DATE" 2>&1)"
h3_rc=$?
if [[ $h3_rc -ne 0 ]]; then
  pass "8.P3"
else
  fail "8.P3" "holdings 缺失注入（--holdings /nonexistent/h.yaml --date ${TRADING_DATE}）: exit=0（要求非 0），stdout=[$(printf '%s' "$h3_out" | head -3 | tr '\n' ' ')]"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
