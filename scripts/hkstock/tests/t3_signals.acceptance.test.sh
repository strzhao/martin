#!/bin/bash
# t3_signals.acceptance.test.sh — 信号 JSONL schema 与复盘链路契约验收（红队）
# 覆盖谓词：11.P1 / 11.P2 / 11.P3 / 11.P4 / 11.P5 / 11.P6
# 依据：设计契约 D2/D3：
#   - 11.P1 信号逐行三要素：symbol 非空 ∧ direction∈{bullish,bearish,neutral} ∧ confidence∈[0,1]
#   - 11.P2 cron list 含 hkstock-signal-review
#   - 11.P3 复盘手动执行 exit 0 含命中率字段（real-process：REVIEW_OUTPUT 注入真实运行 stdout）
#   - 11.P4 信号+复盘产物零下单关键词（negate：order/委托/下单/submit order）
#   - 11.P5 全字段校验：date/asset/horizon/rationale/source/created_by=="hkstock-worker"
#   - 11.P6 无效行 fixture（--input /tmp）→ 跳过 + 留痕含行号（黑盒驱动 signal_review.py，绝不写真实 signals.jsonl）
# 红线扫描口径：范围=scripts/hkstock（排除 tests/）∪ ~/workspace/mktdata（排除 .git/.venv）
#   ∪ hkstock-data/*.jsonl ∪ 复盘留痕日志；排除 *.md 文档声明文本与 profile SOUL
# 门控：11.P3 缺 REVIEW_OUTPUT → SKIP_REAL_PROCESS（唯一许可跳过）
# 用法：bash t3_signals.acceptance.test.sh
# 退出码：0 = 全绿（11.P3 可跳过）；1 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
SIGNALS_FILE="${SIGNALS_FILE:-$MARTIN_ROOT/hkstock-data/signals.jsonl}"
REVIEW_PY="$MARTIN_ROOT/scripts/hkstock/signal_review.py"
INVALID_LOG="$MARTIN_ROOT/hkstock-data/logs/signal-review-invalid.log"
MKTDATA_ROOT="${MKTDATA_ROOT:-$HOME/workspace/mktdata}"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t3_signals: 信号 schema 与复盘链路契约验收（场景 11）=="

TMPDIR_T3="$(mktemp -d /tmp/t3-signals-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T3"' EXIT

# ============ 11.P1 + 11.P5: 逐行 schema 校验（三要素 + 全字段）============
if [[ ! -f "$SIGNALS_FILE" ]]; then
  fail "11.P1" "signals.jsonl 不存在: ${SIGNALS_FILE}（D2 交付物）"
  fail "11.P5" "signals.jsonl 不存在: ${SIGNALS_FILE}（D2 交付物）"
elif [[ ! -s "$SIGNALS_FILE" ]]; then
  fail "11.P1" "signals.jsonl 为空文件: $SIGNALS_FILE"
  fail "11.P5" "signals.jsonl 为空文件: $SIGNALS_FILE"
else
  python3 - "$SIGNALS_FILE" <<'PYEOF' > "$TMPDIR_T3/schema.probe"
import json
import re
import sys

path = sys.argv[1]
ASSETS = {"a-stock", "hk", "fund", "futures"}
DIRECTIONS = {"bullish", "bearish", "neutral"}
HORIZONS = {"intraday", "swing", "position"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

p1_errors = []
p5_errors = []
n_lines = 0
with open(path, encoding="utf-8") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.strip()
        if not line:
            continue
        n_lines += 1
        try:
            obj = json.loads(line)
        except (ValueError, TypeError) as exc:
            p1_errors.append("line%d 非 JSON: %s" % (lineno, exc))
            p5_errors.append("line%d 非 JSON" % lineno)
            continue
        if not isinstance(obj, dict):
            p1_errors.append("line%d 非 JSON 对象" % lineno)
            p5_errors.append("line%d 非 JSON 对象" % lineno)
            continue
        # 11.P1 三要素
        if not str(obj.get("symbol") or "").strip():
            p1_errors.append("line%d symbol 为空" % lineno)
        if obj.get("direction") not in DIRECTIONS:
            p1_errors.append("line%d direction 非法: %r" % (lineno, obj.get("direction")))
        conf = obj.get("confidence")
        if isinstance(conf, bool) or not isinstance(conf, (int, float)) or not (0.0 <= float(conf) <= 1.0):
            p1_errors.append("line%d confidence 非 [0,1] 数值: %r" % (lineno, conf))
        # 11.P5 全字段
        if not DATE_RE.match(str(obj.get("date") or "")):
            p5_errors.append("line%d date 非 YYYY-MM-DD: %r" % (lineno, obj.get("date")))
        if obj.get("asset") not in ASSETS:
            p5_errors.append("line%d asset 非法: %r" % (lineno, obj.get("asset")))
        if obj.get("horizon") not in HORIZONS:
            p5_errors.append("line%d horizon 非法: %r" % (lineno, obj.get("horizon")))
        if not str(obj.get("rationale") or "").strip():
            p5_errors.append("line%d rationale 为空" % lineno)
        if not str(obj.get("source") or "").strip():
            p5_errors.append("line%d source 为空" % lineno)
        if obj.get("created_by") != "hkstock-worker":
            p5_errors.append("line%d created_by != hkstock-worker: %r" % (lineno, obj.get("created_by")))

print("11.P1:%s" % ("PASS" if not p1_errors else "FAIL"))
print("11.P1-DETAIL 共 %d 行; %s" % (n_lines, "; ".join(p1_errors[:5]) if p1_errors else "三要素全过"))
print("11.P5:%s" % ("PASS" if not p5_errors else "FAIL"))
print("11.P5-DETAIL %s" % ("; ".join(p5_errors[:5]) if p5_errors else "全字段全过"))
PYEOF
  while IFS= read -r line; do
    case "$line" in
      11.P1:PASS*) pass "11.P1" ;;
      11.P1:FAIL*) fail "11.P1" "${line#11.P1:FAIL }" ;;
      11.P1-DETAIL*) printf 'INFO 11.P1 %s\n' "${line#11.P1-DETAIL }" ;;
      11.P5:PASS*) pass "11.P5" ;;
      11.P5:FAIL*) fail "11.P5" "${line#11.P5:FAIL }" ;;
      11.P5-DETAIL*) printf 'INFO 11.P5 %s\n' "${line#11.P5-DETAIL }" ;;
    esac
  done < "$TMPDIR_T3/schema.probe"
fi

# ============ 11.P2: cron list 含 hkstock-signal-review ============
HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
[[ -z "$HERMES_BIN" && -x "$HOME/.local/bin/hermes" ]] && HERMES_BIN="$HOME/.local/bin/hermes"
if [[ -z "$HERMES_BIN" ]]; then
  fail "11.P2" "hermes CLI 不可用，无法验证复盘 cron"
else
  cron_out="$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL "$HERMES_BIN" cron list 2>&1)"
  cron_rc=$?
  if [[ $cron_rc -ne 0 ]]; then
    fail "11.P2" "hermes cron list 退出码 ${cron_rc}"
  elif ! printf '%s' "$cron_out" | grep -q 'hkstock-signal-review'; then
    fail "11.P2" "hermes cron list 输出不含 hkstock-signal-review"
  else
    pass "11.P2"
  fi
fi

# ============ 11.P3: 复盘输出含命中率字段（real-process：REVIEW_OUTPUT 注入）============
if [[ -z "${REVIEW_OUTPUT:-}" ]]; then
  printf 'SKIP_REAL_PROCESS (11.P3)\n'
  printf 'INFO 11.P3 跳过: REVIEW_OUTPUT 未注入（复盘手动执行的真实 stdout）\n'
else
  probe="$(REVIEW_OUTPUT="$REVIEW_OUTPUT" python3 - <<'PYEOF'
import json
import os

raw = os.environ.get("REVIEW_OUTPUT", "")
try:
    obj = json.loads(raw)
except (ValueError, TypeError) as exc:
    print("FAIL REVIEW_OUTPUT 非 JSON: %s" % exc)
    raise SystemExit(0)
if not isinstance(obj, dict):
    print("FAIL REVIEW_OUTPUT 非 JSON 对象")
    raise SystemExit(0)
missing = [k for k in ("total", "valid", "invalid_lines", "hit_rate", "avg_confidence") if k not in obj]
hit = obj.get("hit_rate")
if not isinstance(hit, dict):
    hit_missing = ["hit_rate 非对象"]
else:
    hit_missing = [k for k in ("bullish", "bearish") if k not in hit]
if missing or hit_missing:
    print("FAIL 命中率结构缺失: %s %s" % (missing, hit_missing))
else:
    print("PASS")
    print("DETAIL total=%s valid=%s invalid_lines=%s avg_confidence=%s" % (
        obj.get("total"), obj.get("valid"), obj.get("invalid_lines"), obj.get("avg_confidence")))
PYEOF
)"
  verdict="$(printf '%s' "$probe" | head -1)"
  if [[ "$verdict" == "PASS" ]]; then
    pass "11.P3"
    detail="$(printf '%s' "$probe" | sed -n 's/^DETAIL /DETAIL /p')"
    [[ -n "$detail" ]] && printf 'INFO 11.P3 %s\n' "$detail"
  else
    fail "11.P3" "$verdict"
  fi
fi

# ============ 11.P4: 信号+复盘产物零下单关键词（negate，红线扫描）============
python3 - "$MARTIN_ROOT" "$SIGNALS_FILE" > "$TMPDIR_T3/p4.probe" <<'PYEOF'
import os
import re
import sys

martin, signals = sys.argv[1], sys.argv[2]
pat = re.compile(r"place[sd]?\s+order|submit[_ -]?order|下单|委托|撤单", re.IGNORECASE)
targets = []
if os.path.isfile(signals):
    targets.append(signals)
logs_dir = os.path.join(martin, "hkstock-data", "logs")
if os.path.isdir(logs_dir):
    for fn in sorted(os.listdir(logs_dir)):
        if fn.startswith("signal-review"):
            targets.append(os.path.join(logs_dir, fn))
review_output = os.environ.get("REVIEW_OUTPUT")
targets.append("<REVIEW_OUTPUT>")
hits = []
for idx, t in enumerate(targets):
    text = review_output if t == "<REVIEW_OUTPUT>" else None
    if t == "<REVIEW_OUTPUT>":
        if not text:
            continue
        lines = text.splitlines()
        label = "<REVIEW_OUTPUT>"
    else:
        try:
            with open(t, encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        label = os.path.relpath(t, martin)
    for lineno, line in enumerate(lines, 1):
        if pat.search(line):
            hits.append("%s:%d" % (label, lineno))
print("11.P4:%s" % ("PASS" if not hits else "FAIL"))
print("11.P4-DETAIL %s" % ("下单关键词命中: " + "; ".join(hits[:10]) if hits else "扫描对象: " + ("; ".join(targets) if targets else "无产物文件（待落地后复检）")))
PYEOF
while IFS= read -r line; do
  case "$line" in
    11.P4:PASS*) pass "11.P4" ;;
    11.P4:FAIL*) fail "11.P4" "${line#11.P4:FAIL }" ;;
    11.P4-DETAIL*) printf 'INFO 11.P4 %s\n' "${line#11.P4-DETAIL }" ;;
  esac
done < "$TMPDIR_T3/p4.probe"

# ============ 11.P6: 无效行 fixture → 跳过 + 留痕含行号（/tmp fixture，绝不写真实 signals.jsonl）============
if [[ ! -f "$REVIEW_PY" ]]; then
  fail "11.P6" "signal_review.py 不存在: $REVIEW_PY"
else
  fx="$TMPDIR_T3/fixture.jsonl"
  {
    printf '%s\n' '{"date":"2026-09-08","asset":"a-stock","symbol":"600519","direction":"bullish","confidence":0.7,"horizon":"swing","rationale":"acceptance fixture valid line","source":"mktd quote","created_by":"hkstock-worker"}'
    printf '%s\n' '{broken json line'
    printf '%s\n' '{"date":"2026-09-08","asset":"a-stock","symbol":"600519","direction":"bullish","confidence":1.5,"horizon":"swing","rationale":"confidence out of range","source":"fixture","created_by":"hkstock-worker"}'
  } > "$fx"

  log_had=0
  if [[ -f "$INVALID_LOG" ]]; then
    log_had=1
    cp "$INVALID_LOG" "$TMPDIR_T3/invalid.log.pre"
  fi

  out="$(python3 "$REVIEW_PY" --input "$fx" --window-days 20 2>"$TMPDIR_T3/p6.err")"
  rc6=$?

  p6_ok=1
  p6_msg=""
  if [[ $rc6 -ne 0 ]]; then
    p6_ok=0
    p6_msg="exit=${rc6}（契约要求 exit 0）stderr=[$(head -c 200 "$TMPDIR_T3/p6.err")]"
  else
    p6_msg="$(printf '%s' "$out" | python3 -c 'import json,sys
raw = sys.stdin.read()
try:
    o = json.loads(raw)
except Exception as exc:
    print("stdout 非 JSON: %s" % exc)
    raise SystemExit(0)
if not isinstance(o, dict):
    print("stdout 非 JSON 对象")
    raise SystemExit(0)
errors = []
# 契约未钉 invalid_lines 类型：int=无效行数 或 list=[{line,reason}] 均可，须反映 2 条无效
inv = o.get("invalid_lines")
if isinstance(inv, bool):
    errors.append("invalid_lines=%r 布尔非法" % inv)
elif isinstance(inv, int):
    if inv != 2:
        errors.append("invalid_lines=%r 期望 2" % inv)
elif isinstance(inv, list):
    if len(inv) != 2:
        errors.append("invalid_lines 列表长度=%d 期望 2" % len(inv))
    else:
        lines_seen = sorted(e.get("line") for e in inv if isinstance(e, dict)) if all(isinstance(e, dict) for e in inv) else []
        if lines_seen and lines_seen != [2, 3]:
            errors.append("invalid_lines 行号=%r 期望 [2,3]" % lines_seen)
else:
    errors.append("invalid_lines=%r 既非 int 也非 list" % inv)
if o.get("valid") != 1:
    errors.append("valid=%r 期望 1" % o.get("valid"))
if o.get("total") != 3:
    errors.append("total=%r 期望 3" % o.get("total"))
for k in ("hit_rate", "avg_confidence"):
    if k not in o:
        errors.append("缺字段 %s" % k)
print("; ".join(errors))' 2>/dev/null || printf 'stdout 解析失败')"
    [[ -n "$p6_msg" ]] && p6_ok=0
  fi

  # 留痕校验：新追加行含 line2 / line3（格式 <日期> line<N> <原因>），校验后还原真实日志（零污染）
  log_probe="$(python3 - "$TMPDIR_T3/invalid.log.pre" "$INVALID_LOG" "$log_had" <<'PYEOF'
import re
import sys

pre_path, log_path, had = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
pre_lines = 0
if had:
    try:
        with open(pre_path, encoding="utf-8", errors="replace") as fh:
            pre_lines = sum(1 for _ in fh)
    except OSError:
        pass
appended = []
try:
    with open(log_path, encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            if lineno > pre_lines:
                appended.append(line.rstrip("\n"))
except OSError:
    pass
blob = "\n".join(appended)
problems = []
if not appended:
    problems.append("留痕日志无新增行")
if not re.search(r"line2(?!\d)\s+\S", blob):
    problems.append("无 line2 留痕行")
if not re.search(r"line3(?!\d)\s+\S", blob):
    problems.append("无 line3 留痕行")
if appended and not re.search(r"^\d{4}-\d{2}-\d{2} line\d+ \S+", blob, re.MULTILINE):
    problems.append("留痕行不符合 '<日期> line<N> <原因>' 形态")
print("; ".join(problems))
if appended:
    print("SAMPLE " + appended[0][:160])
PYEOF
)"
  log_problems="$(printf '%s' "$log_probe" | head -1)"
  [[ -n "$log_problems" ]] && p6_ok=0

  if [[ $log_had -eq 1 ]]; then
    cp "$TMPDIR_T3/invalid.log.pre" "$INVALID_LOG"
  else
    rm -f "$INVALID_LOG"
  fi

  if [[ $p6_ok -eq 1 ]]; then
    pass "11.P6"
  else
    fail "11.P6" "fixture 复盘异常: ${p6_msg:-无}；留痕: ${log_problems:-无}"
  fi
  sample="$(printf '%s' "$log_probe" | sed -n 's/^SAMPLE //p')"
  [[ -n "$sample" ]] && printf 'INFO 11.P6 留痕样例: %s\n' "$sample"

  # EXTRA-structured（D3：文件缺失/空/全无效 → exit 0 结构化，意外异常才允许 exit 1）
  printf '%s\n' 'garbage line one' 'not json at all' > "$TMPDIR_T3/allinvalid.jsonl"
  extra_fail=0
  for case_name in empty missing all-invalid; do
    case "$case_name" in
      empty)       cin="$TMPDIR_T3/empty.jsonl" ;;
      missing)     cin="$TMPDIR_T3/nonexistent-$$.jsonl" ;;
      all-invalid) cin="$TMPDIR_T3/allinvalid.jsonl" ;;
    esac
    : > "$TMPDIR_T3/empty.jsonl"
    cout="$(python3 "$REVIEW_PY" --input "$cin" 2>/dev/null)"
    crc=$?
    structured="$(printf '%s' "$cout" | python3 -c 'import json,sys
try:
    o = json.loads(sys.stdin.read())
    print("ok" if isinstance(o, dict) and "total" in o else "no-total")
except Exception:
    print("non-json")' 2>/dev/null || printf 'non-json')"
    if [[ $crc -ne 0 || "$structured" != "ok" ]]; then
      fail "EXTRA-structured-$case_name" "exit=${crc} structured=${structured}（D3 要求 exit 0 + 结构化 stdout）"
      extra_fail=1
    fi
  done
  [[ $extra_fail -eq 0 ]] && printf 'PASS EXTRA-structured (empty/missing/all-invalid 均 exit 0 结构化)\n'
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
