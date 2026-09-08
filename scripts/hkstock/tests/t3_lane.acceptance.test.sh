#!/bin/bash
# t3_lane.acceptance.test.sh — lane 模式红线与 gate 契约验收（红队）
# 覆盖谓词：13.P1 / 13.P2 / 13.P3 / 13.P4
# 依据：红线簇 13.P1-13.P4：
#   - 13.P1 hkstock 域脚本/数据零 cc-lane 特征（negate：*-cc assignee / kanban claim / autopilot --fast / git worktree）
#   - 13.P2 hkstock 域脚本 + hkstock cron 体零 claude -p 特征（negate）
#   - 13.P3 外发通道有 AI 整理层（正向：morning-brief cron prompt 含 AI 整理/三段式 ∧ deliver=weixin:）
#   - 13.P4 gate.sh exit ∈ {0,2}（0=全绿，2=依赖缺失；其余皆违规）
# 红线扫描口径：范围=scripts/hkstock/**/*.sh|py（排除 tests/）∪ ~/workspace/mktdata/**/*.sh|py
#   （排除 .git/.venv）∪ hkstock-data/*.jsonl；排除 *.md 文档声明文本与 profile SOUL
# 用法：bash t3_lane.acceptance.test.sh
# 退出码：0 = 全绿；1 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
MKTDATA_ROOT="${MKTDATA_ROOT:-$HOME/workspace/mktdata}"
HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
JOBS_JSON="$HERMES_ROOT/cron/jobs.json"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t3_lane: lane 红线与 gate 契约验收（场景 13）=="

TMPDIR_T3="$(mktemp -d /tmp/t3-lane-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T3"' EXIT

# ============ 13.P1 + 13.P2: cc-lane / claude -p 特征 negate 扫描 ============
python3 - "$MARTIN_ROOT" "$MKTDATA_ROOT" > "$TMPDIR_T3/lane.probe" <<'PYEOF'
import os
import re
import sys

martin, mktdata = sys.argv[1], sys.argv[2]

scan_files = []
for root, skip in ((os.path.join(martin, "scripts", "hkstock"), {"tests"}),
                   (mktdata, {".git", ".venv", "venv", "__pycache__", "node_modules"})):
    if not os.path.isdir(root):
        continue
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if fn.endswith((".sh", ".py")):
                scan_files.append(os.path.join(dirpath, fn))
data_dir = os.path.join(martin, "hkstock-data")
if os.path.isdir(data_dir):
    for dirpath, dirnames, filenames in os.walk(data_dir):
        for fn in filenames:
            if fn.endswith(".jsonl"):
                scan_files.append(os.path.join(dirpath, fn))

cc_pat = re.compile(
    r"(contrib|ops|life|hkstock|coder)-cc\b|kanban\s+claim|autopilot\s+--fast|"
    r"git\s+worktree\s+add|EnterWorktree",
    re.IGNORECASE)
clauderp_pat = re.compile(r"claude\s+(-p\b|--print\b)", re.IGNORECASE)

p1_hits = []
p2_hits = []
for path in scan_files:
    label = os.path.relpath(path, martin)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            content = fh.readlines()
    except OSError:
        continue
    for lineno, line in enumerate(content, 1):
        if cc_pat.search(line):
            p1_hits.append("%s:%d" % (label, lineno))
        if clauderp_pat.search(line):
            p2_hits.append("%s:%d" % (label, lineno))

print("13.P1:%s" % ("PASS" if not p1_hits else "FAIL"))
print("13.P1-DETAIL %s" % ("cc-lane 特征命中: " + "; ".join(p1_hits[:10]) if p1_hits
                          else "域脚本/数据零 cc-lane 特征（扫描 %d 文件）" % len(scan_files)))
print("13.P2-FILES:%s" % ";".join(scan_files))
print("13.P2-SCRIPTS %s" % ("claude -p 特征命中: " + "; ".join(p2_hits[:10]) if p2_hits
                           else "域脚本零 claude -p 特征（扫描 %d 文件）" % len(scan_files)))
PYEOF

CRON_PROMPTS_FILE="$TMPDIR_T3/cron_prompts.txt"
if [[ -f "$JOBS_JSON" ]]; then
  python3 - "$JOBS_JSON" "$CRON_PROMPTS_FILE" <<'PYEOF'
import json
import re
import sys

path, out_path = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as fh:
        jobs = (json.load(fh) or {}).get("jobs") or []
except (OSError, ValueError):
    jobs = []
pat = re.compile(r"claude\s+(-p\b|--print\b)", re.IGNORECASE)
with open(out_path, "w", encoding="utf-8") as out:
    for job in jobs:
        name = job.get("name") or ""
        if not name.startswith("hkstock"):
            continue
        prompt = job.get("prompt") or ""
        hits = ["<cron:%s>" % name] if pat.search(prompt) else []
        out.write("13.P2-CRON %s %s\n" % (name, "HIT" if hits else "CLEAN"))
PYEOF
fi

p2_all_clean=1
while IFS= read -r line; do
  case "$line" in
    13.P1:PASS*) pass "13.P1" ;;
    13.P1:FAIL*) fail "13.P1" "${line#13.P1:FAIL }" ;;
    13.P1-DETAIL*) printf 'INFO 13.P1 %s\n' "${line#13.P1-DETAIL }" ;;
    13.P2-SCRIPTS*)
      msg="${line#13.P2-SCRIPTS }"
      if [[ "$msg" == claude* ]]; then
        fail "13.P2" "$msg"
        p2_all_clean=0
      else
        printf 'INFO 13.P2 %s\n' "$msg"
      fi
      ;;
  esac
done < "$TMPDIR_T3/lane.probe"
if [[ -f "$CRON_PROMPTS_FILE" ]]; then
  while IFS= read -r line; do
    name="$(printf '%s' "$line" | awk '{print $2}')"
    verdict="$(printf '%s' "$line" | awk '{print $3}')"
    if [[ "$verdict" == "HIT" ]]; then
      fail "13.P2" "cron $name 任务体含 claude -p 特征"
      p2_all_clean=0
    fi
  done < "$CRON_PROMPTS_FILE"
fi
if [[ $p2_all_clean -eq 1 ]]; then
  pass "13.P2"
fi

# ============ 13.P3: 外发通道有 AI 整理层（正向）============
if [[ ! -f "$JOBS_JSON" ]]; then
  fail "13.P3" "jobs.json 不存在: $JOBS_JSON"
else
  python3 - "$JOBS_JSON" > "$TMPDIR_T3/p3.probe" <<'PYEOF'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    jobs = (json.load(fh) or {}).get("jobs") or []
ai_pat = re.compile(r"AI\s*整理|三段式")
briefs = [j for j in jobs if j.get("name") == "hkstock-morning-brief"]
if not briefs:
    print("13.P3:FAIL jobs.json 无 hkstock-morning-brief（外发通道主体缺失）")
    raise SystemExit(0)
job = briefs[0]
prompt = job.get("prompt") or ""
deliver = str(job.get("deliver") or "")
problems = []
if not deliver.startswith("weixin:"):
    problems.append("deliver 非 weixin: 渠道: %r" % deliver[:40])
if not ai_pat.search(prompt):
    problems.append("cron 任务体无 AI 整理/三段式标记（外发载荷必须先经 AI 整理）")
reviews = [j for j in jobs if j.get("name") == "hkstock-signal-review"]
if reviews:
    rprompt = reviews[0].get("prompt") or ""
    rdeliver = str(reviews[0].get("deliver") or "")
    if not rdeliver.startswith("weixin:"):
        problems.append("复盘 cron deliver 非 weixin: 渠道")
    if not (ai_pat.search(rprompt) or "[SILENT]" in rprompt):
        problems.append("复盘 cron 任务体无 AI 整理/三段式/[SILENT] 标记")
print("13.P3:%s" % ("FAIL" if problems else "PASS"))
if problems:
    print("13.P3-DETAIL %s" % "; ".join(problems))
PYEOF
  while IFS= read -r line; do
    case "$line" in
      13.P3:PASS*) pass "13.P3" ;;
      13.P3:FAIL*) fail "13.P3" "${line#13.P3:FAIL }" ;;
      13.P3-DETAIL*) printf 'INFO 13.P3 %s\n' "${line#13.P3-DETAIL }" ;;
    esac
  done < "$TMPDIR_T3/p3.probe"
fi

# ============ 13.P4: gate.sh exit ∈ {0,2} ============
gate_out="$TMPDIR_T3/gate.out"
(cd "$MARTIN_ROOT" && bash scripts/contrib/tests/gate.sh) > "$gate_out" 2>&1
gate_rc=$?
if [[ $gate_rc -eq 0 || $gate_rc -eq 2 ]]; then
  pass "13.P4"
  printf 'INFO 13.P4 gate exit=%d（0=全绿 2=依赖缺失）\n' "$gate_rc"
else
  fail "13.P4" "gate.sh exit=${gate_rc}（契约只允许 0/2）；输出尾部: $(tail -c 300 "$gate_out")"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
