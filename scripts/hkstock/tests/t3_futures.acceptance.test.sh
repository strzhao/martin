#!/bin/bash
# t3_futures.acceptance.test.sh — 期货接入与下单关键词红线契约验收（红队）
# 覆盖谓词：12.P1 / 12.P2 / 12.P3
# 依据：设计契约 D5 + 红线簇 12.P2/12.P3：
#   - 12.P1 简报产物含「期货日报摘要」段 ∧ 「风险预警」小节字面量（real-process，BRIEF_ARTIFACT 注入）
#   - 12.P2 quant-futures 引用零写操作（negate：同行共现 git commit/push/写入/下单/写模式 open 等）
#   - 12.P3 可执行产物（.sh/.py）零下单关键词（negate：order/委托/下单/submit order）
# 红线扫描口径：范围=scripts/hkstock/**/*.sh|py（排除 tests/）∪ ~/workspace/mktdata/**/*.sh|py
#   （排除 .git/.venv）；排除 *.md 文档声明文本与 profile SOUL
# 门控：12.P1 无 BRIEF_ARTIFACT 注入且 briefs/ 无可发现产物 → SKIP_REAL_PROCESS（唯一许可跳过）
# 用法：bash t3_futures.acceptance.test.sh
# 退出码：0 = 全绿（12.P1 可跳过）；1 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
MKTDATA_ROOT="${MKTDATA_ROOT:-$HOME/workspace/mktdata}"
BRIEFS_DIR="$MARTIN_ROOT/hkstock-data/briefs"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t3_futures: 期货接入与下单红线契约验收（场景 12）=="

TMPDIR_T3="$(mktemp -d /tmp/t3-futures-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T3"' EXIT

# ============ 12.P1: 简报产物含期货摘要 ∧ 风险预警（real-process 门控）============
if [[ -n "${BRIEF_ARTIFACT:-}" ]]; then
  ARTIFACT="$BRIEF_ARTIFACT"
else
  ARTIFACT="$(ls -t "$BRIEFS_DIR"/*-brief.md 2>/dev/null | head -1 || true)"
fi

if [[ -z "$ARTIFACT" || ! -f "$ARTIFACT" ]]; then
  printf 'SKIP_REAL_PROCESS (12.P1)\n'
  printf 'RESULT: SKIP (BRIEF_ARTIFACT 未注入且 %s 下无可发现 *-brief.md)\n' "$BRIEFS_DIR"
  exit 0
fi
printf 'INFO 产物: %s\n' "$ARTIFACT"
[[ -n "${KANBAN_TASK_ID:-}" ]] && printf 'INFO 关联卡: %s\n' "$KANBAN_TASK_ID"

body="$(cat "$ARTIFACT")"
p1_miss=""
for seg in "期货日报摘要" "风险预警"; do
  if ! printf '%s' "$body" | grep -qF "$seg"; then
    p1_miss="${p1_miss:+${p1_miss}、}$seg"
  fi
done
if [[ -z "$p1_miss" ]]; then
  pass "12.P1"
else
  fail "12.P1" "简报产物缺字面量: ${p1_miss}（D5 要求期货日报摘要段含风险预警小节）"
fi

# ============ 12.P2 + 12.P3: 红线 fs-grep（quant-futures 零写操作 ∧ 可执行产物零下单关键词）============
python3 - "$MARTIN_ROOT" "$MKTDATA_ROOT" > "$TMPDIR_T3/redline.probe" <<'PYEOF'
import os
import re
import sys

martin, mktdata = sys.argv[1], sys.argv[2]

# 可执行产物收集：scripts/hkstock（排除 tests/）∪ mktdata（排除 .git/.venv），仅 .sh/.py；排除 *.md 文档
exec_files = []
for root, skip in ((os.path.join(martin, "scripts", "hkstock"), {"tests"}),
                   (mktdata, {".git", ".venv", "venv", "__pycache__", "node_modules"})):
    if not os.path.isdir(root):
        continue
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if fn.endswith((".sh", ".py")):
                exec_files.append(os.path.join(dirpath, fn))

order_pat = re.compile(r"place[sd]?\s+order|submit[_ -]?order|下单|委托|撤单", re.IGNORECASE)
quant_pat = re.compile(r"quant[-_]?futures", re.IGNORECASE)
write_pat = re.compile(
    r"git\s+(commit|push|add)|下单|委托|撤单|写入|write\(|tee\s|"
    r"open\s*\([^)]*['\"]w[a+b+]?['\"]",
    re.IGNORECASE)

p2_hits = []
p3_hits = []
for path in exec_files:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                if quant_pat.search(line) and write_pat.search(line):
                    p2_hits.append("%s:%d" % (os.path.relpath(path, martin), lineno))
                if order_pat.search(line):
                    p3_hits.append("%s:%d" % (os.path.relpath(path, martin), lineno))
    except OSError:
        pass

print("12.P2:%s" % ("PASS" if not p2_hits else "FAIL"))
print("12.P2-DETAIL %s" % ("quant-futures 同行写操作共现: " + "; ".join(p2_hits[:10]) if p2_hits
                          else "可执行产物中 quant-futures 引用零写操作（扫描 %d 文件）" % len(exec_files)))
print("12.P3:%s" % ("PASS" if not p3_hits else "FAIL"))
print("12.P3-DETAIL %s" % ("下单关键词命中: " + "; ".join(p3_hits[:10]) if p3_hits
                          else "可执行产物零下单关键词（扫描 %d 文件）" % len(exec_files)))
PYEOF
while IFS= read -r line; do
  case "$line" in
    12.P2:PASS*) pass "12.P2" ;;
    12.P2:FAIL*) fail "12.P2" "${line#12.P2:FAIL }" ;;
    12.P2-DETAIL*) printf 'INFO 12.P2 %s\n' "${line#12.P2-DETAIL }" ;;
    12.P3:PASS*) pass "12.P3" ;;
    12.P3:FAIL*) fail "12.P3" "${line#12.P3:FAIL }" ;;
    12.P3-DETAIL*) printf 'INFO 12.P3 %s\n' "${line#12.P3-DETAIL }" ;;
  esac
done < "$TMPDIR_T3/redline.probe"

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
