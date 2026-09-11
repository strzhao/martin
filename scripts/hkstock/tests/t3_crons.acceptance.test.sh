#!/bin/bash
# t3_crons.acceptance.test.sh — cron 并存/路由表/持仓不入 git 契约验收（红队）
# 覆盖谓词：14.P1 / 14.P2 / 14.P3
# 依据：红线簇 14.P1-14.P3 + D4 复盘 cron 细节（EXTRA）：
#   - 14.P1 简报 cron（hkstock-morning-brief）∧ 复盘 cron（hkstock-signal-review）并存
#   - 14.P2 default SOUL 路由表 hkstock 行 ∧ life 行并存
#   - 14.P3 持仓文件（hkstock-data/holdings.yaml）不入 git（negate）
#   - EXTRA-review-detail（D4 字面量）：schedule 43 9 * * 6 / pin 非空 / prompt 含绝对路径
#     signal_review.py + --input signals.jsonl + [SILENT] / deliver weixin:
# 用法：bash t3_crons.acceptance.test.sh
# 退出码：0 = 全绿；1 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
JOBS_JSON="$HERMES_ROOT/cron/jobs.json"
SOUL_FILE="$HERMES_ROOT/SOUL.md"
HOLDINGS_FILE="$MARTIN_ROOT/hkstock-data/holdings.yaml"
REVIEW_CRON="hkstock-signal-review"
BRIEF_CRON="hkstock-morning-brief"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t3_crons: cron 并存/路由表/持仓红线契约验收（场景 14）=="

TMPDIR_T3="$(mktemp -d /tmp/t3-crons-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T3"' EXIT

# ============ 14.P1: 简报 + 复盘 cron 并存（且 enabled）============
if [[ ! -f "$JOBS_JSON" ]]; then
  fail "14.P1" "jobs.json 不存在: $JOBS_JSON"
else
  python3 - "$JOBS_JSON" "$BRIEF_CRON" "$REVIEW_CRON" > "$TMPDIR_T3/p1.probe" <<'PYEOF'
import json
import sys

path, brief_name, review_name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as fh:
        jobs = (json.load(fh) or {}).get("jobs") or []
except (OSError, ValueError) as exc:
    print("14.P1:FAIL jobs.json 解析失败: %s" % exc)
    raise SystemExit(0)
names = {j.get("name") or "" for j in jobs}
problems = []
for name in (brief_name, review_name):
    if name not in names:
        problems.append("缺 cron: %s" % name)
    else:
        job = next(j for j in jobs if j.get("name") == name)
        if not job.get("enabled"):
            problems.append("%s 存在但 enabled=false" % name)
print("14.P1:%s" % ("FAIL" if problems else "PASS"))
if problems:
    print("14.P1-DETAIL %s" % "; ".join(problems))

# EXTRA-review-detail（D4 字面量）
review = next((j for j in jobs if j.get("name") == review_name), None)
if review is None:
    print("EXTRA-review-detail:FAIL 复盘 cron 不存在，D4 细节无从校验")
    raise SystemExit(0)
prompt = review.get("prompt") or ""
sched = review.get("schedule")
expr = sched.get("expr") if isinstance(sched, dict) else sched
errors = []
if str(expr or "").strip() != "43 9 * * 6":
    errors.append("schedule=%r 期望 '43 9 * * 6'" % expr)
model = str(review.get("model") or "").strip()
provider = str(review.get("provider") or "").strip()
if not model or not provider:
    errors.append("pin 不完整: model=%r provider=%r" % (model, provider))
if "scripts/hkstock/signal_review.py" not in prompt:
    errors.append("prompt 缺绝对路径 signal_review.py")
if "--input" not in prompt:
    errors.append("prompt 缺 --input（契约字面量，非 --file）")
if "signals.jsonl" not in prompt:
    errors.append("prompt 缺 signals.jsonl")
if "[SILENT]" not in prompt:
    errors.append("prompt 缺 [SILENT] 哨兵")
deliver = str(review.get("deliver") or "")
if not deliver.startswith("weixin:"):
    errors.append("deliver 非 weixin: 渠道: %r" % deliver[:40])
print("EXTRA-review-detail:%s" % ("FAIL" if errors else "PASS"))
if errors:
    print("EXTRA-review-detail-DETAIL %s" % "; ".join(errors))
PYEOF
  while IFS= read -r line; do
    case "$line" in
      14.P1:PASS*) pass "14.P1" ;;
      14.P1:FAIL*) fail "14.P1" "${line#14.P1:FAIL }" ;;
      14.P1-DETAIL*) printf 'INFO 14.P1 %s\n' "${line#14.P1-DETAIL }" ;;
      EXTRA-review-detail:PASS*) printf 'PASS EXTRA-review-detail (schedule/pin/prompt 字面量全过)\n' ;;
      EXTRA-review-detail:FAIL*) fail "EXTRA-review-detail" "${line#EXTRA-review-detail:FAIL }" ;;
      EXTRA-review-detail-DETAIL*) printf 'INFO EXTRA-review-detail %s\n' "${line#EXTRA-review-detail-DETAIL }" ;;
    esac
  done < "$TMPDIR_T3/p1.probe"
fi

# ============ 14.P2: default SOUL 路由表 hkstock 行 ∧ life 行并存 ============
if [[ ! -f "$SOUL_FILE" ]]; then
  fail "14.P2" "default SOUL.md 不存在: $SOUL_FILE"
else
  hk_row="$(grep -E '^\|.*`hkstock`' "$SOUL_FILE" 2>/dev/null | head -1 || true)"
  life_row="$(grep -E '^\|.*`life`' "$SOUL_FILE" 2>/dev/null | head -1 || true)"
  if [[ -n "$hk_row" && -n "$life_row" ]]; then
    pass "14.P2"
    printf 'INFO 14.P2 hkstock 行: %s\n' "$(printf '%s' "$hk_row" | cut -c1-80)"
    printf 'INFO 14.P2 life 行: %s\n' "$(printf '%s' "$life_row" | cut -c1-80)"
  else
    fail "14.P2" "路由表缺行: hkstock=${hk_row:+有}${hk_row:-无} life=${life_row:+有}${life_row:-无}（要求两行并存）"
  fi
fi

# ============ 14.P3: 持仓文件不入 git（negate）============
if [[ ! -f "$HOLDINGS_FILE" ]]; then
  fail "14.P3" "持仓文件不存在，无从校验: $HOLDINGS_FILE"
else
  rel_path="hkstock-data/holdings.yaml"
  if git -C "$MARTIN_ROOT" ls-files --error-unmatch "$rel_path" > /dev/null 2>&1; then
    fail "14.P3" "持仓文件已被 git 跟踪: ${rel_path}（红线：持仓不入 git）"
  else
    if git -C "$MARTIN_ROOT" check-ignore -q "$rel_path" 2>/dev/null; then
      pass "14.P3"
      printf 'INFO 14.P3 %s 未被跟踪且已被 gitignore 覆盖\n' "$rel_path"
    else
      pass "14.P3"
      printf 'INFO 14.P3 %s 未被跟踪（未被 gitignore 显式覆盖，建议 hkstock-data/ 入 .gitignore）\n' "$rel_path"
    fi
  fi
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
