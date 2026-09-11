#!/bin/bash
# t3_review.acceptance.test.sh — signal_review.py（D3 复盘统计入口）契约自测（蓝队，黑盒 CLI）
# 覆盖：D3 exit 闭集 / 11.P6（无效行跳过 + 失败记录含行号）/ fixture 四态
# 用法：bash scripts/hkstock/tests/t3_review.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
REVIEW="$MARTIN_ROOT/scripts/hkstock/signal_review.py"

TMP="$(mktemp -d /tmp/t3-review-accept.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAIL_COUNT=0
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { printf 'PASS %s\n' "$1"; }

# ---------- fixture 生成 ----------
mk_valid_line() {
  printf '{"date":"2026-09-07","asset":"a-stock","symbol":"600519","direction":"bullish","confidence":0.7,"horizon":"swing","rationale":"基本面三分析师收敛多空对照偏多","source":"mktd daily 600519 @2026-09-08T08:00","created_by":"hkstock-worker"}\n'
}

# 合法行 ×2（一 bull 一 neutral）+ 无效行 ×3（缺 rationale / direction 枚举越界 / 非法 JSON）
{
  mk_valid_line
  printf '{"date":"2026-09-07","asset":"hk","symbol":"00700","direction":"neutral","confidence":0.4,"horizon":"intraday","rationale":"事件面无方向","source":"mktd hk 00700 @2026-09-08T08:00","created_by":"hkstock-worker"}\n'
  printf '{"date":"2026-09-07","asset":"a-stock","symbol":"600519","direction":"bearish","confidence":0.6,"horizon":"swing","created_by":"hkstock-worker"}\n'
  printf '{"date":"2026-09-07","asset":"a-stock","symbol":"600519","direction":"very-bullish","confidence":0.6,"horizon":"swing","rationale":"x","source":"y","created_by":"hkstock-worker"}\n'
  printf '{broken json\n'
} > "$TMP/mixed.jsonl"

: > "$TMP/empty.jsonl"
mk_valid_line > "$TMP/legal.jsonl"

# ---------- 用例 1：合法行 → exit 0，valid 计数正确 ----------
OUT="$(python3 "$REVIEW" --input "$TMP/legal.jsonl" --log "$TMP/log1.log" 2>"$TMP/err1")"
RC=$?
[ "$RC" -eq 0 ] || fail "1-legal-exit0" "exit=$RC stderr=$(cat "$TMP/err1")"
printf '%s' "$OUT" | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["total"]==1 and r["valid"]==1 and r["invalid_lines"]==[], r
assert "hit_rate" in r and "bullish" in r["hit_rate"] and "bearish" in r["hit_rate"], r
assert "avg_confidence" in r and "bullish" in r["avg_confidence"], r
assert r["avg_confidence"]["bullish"]==0.7, r
' && pass "1-legal-schema" || fail "1-legal-schema" "$OUT"

# ---------- 用例 2：无效行 → 跳过 + 失败记录含行号（11.P6）----------
MIXED_OUT="$(python3 "$REVIEW" --input "$TMP/mixed.jsonl" --log "$TMP/log2.log" 2>"$TMP/err2")"
RC=$?
[ "$RC" -eq 0 ] || fail "2-mixed-exit0" "exit=$RC"
printf '%s' "$MIXED_OUT" | python3 -c '
import json,sys
r=json.load(sys.stdin)
assert r["total"]==5 and r["valid"]==2, r
lines={i["line"] for i in r["invalid_lines"]}
assert lines=={3,4,5}, r
assert all("reason" in i and i["reason"] for i in r["invalid_lines"]), r
' && pass "2-mixed-invalid-lines" || fail "2-mixed-invalid-lines" "$OUT"
grep -q "line3" "$TMP/log2.log" && grep -q "line5" "$TMP/log2.log" \
  && pass "2-mixed-log-lineno" || fail "2-mixed-log-lineno" "$(cat "$TMP/log2.log")"

# ---------- 用例 3：空文件 → exit 0 且 total 0（D3：无信号不是错误）----------
OUT="$(python3 "$REVIEW" --input "$TMP/empty.jsonl" --log "$TMP/log3.log" 2>"$TMP/err3")"
RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"total": *0' \
  && pass "3-empty-exit0" || fail "3-empty-exit0" "exit=$RC out=$OUT"

# ---------- 用例 3b：文件不存在 → exit 0 且 total 0 ----------
OUT="$(python3 "$REVIEW" --input "$TMP/does-not-exist.jsonl" --log "$TMP/log3b.log" 2>/dev/null)"
RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '"total": *0' \
  && pass "3b-missing-exit0" || fail "3b-missing-exit0" "exit=$RC out=$OUT"

# ---------- 用例 4：异常注入（意外 IO 错误）→ exit 1（D3 exit 闭集另一侧）----------
python3 "$REVIEW" --input "$TMP" --log "$TMP/log4.log" >/dev/null 2>"$TMP/err4"
RC=$?
[ "$RC" -eq 1 ] && pass "4-ioerror-exit1" || fail "4-ioerror-exit1" "exit=$RC 意外异常须 exit 1"

# ---------- 用例 5：无效行不进 valid、valid 行不进 invalid（双向断言，用例 2 的混合结果）----------
printf '%s' "$MIXED_OUT" | python3 -c '
import json,sys
r=json.load(sys.stdin)
# neutral 不进命中率：hit_rate 字段可空但 avg_confidence.bearish 应为 None（唯一 bearish 行无效）
assert r["avg_confidence"]["bearish"] is None, r
assert r["avg_confidence"]["bullish"]==0.7, r
' && pass "5-neutral-excluded" || fail "5-neutral-excluded" "$OUT"

printf '\n%s\n' "FAIL_COUNT=$FAIL_COUNT"
exit "$([ "$FAIL_COUNT" -eq 0 ] && echo 0 || echo 1)"
