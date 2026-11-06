#!/usr/bin/env zsh
# contrib 岗哨 monitor v2（2026-11-06 批量化改造）——只报事实 + 批量阈值 + 最长延迟保证。
# 背景：farm 生态新 issue 接近恒在（实测 ~29 条/天），v1 每有新 issue 即唤醒一次 agent（每次 ~152K input）。
# v2 语义：新 issue 数 < BATCH 且最老一条等待 < MAX_AGE_MIN 分钟 → 输出恒定 "none"
#         （框架 cron/monitor.py 对 monitor 输出做 hash，不变 → 静默抑制 agent，零 LLM 成本）；
#         攒够 BATCH 条 或 最老条等待 ≥ MAX_AGE_MIN → 输出 nums 唤醒（一次带全批，agent 逐条分诊）。
# stall 兜底：同一批 nums 唤醒后 STALL_MIN 分钟仍未推进（agent 没跑 sentry-advance）→
#         输出 stall_escalation 强制再唤一次（输出串不同 → hash 变化 → 必唤醒），并重置计时。
# 游标推进契约不变：只有 agent 跑 sentry-advance.sh 才推进；首启只定位不回灌；cursor_behind 语义不变。
# 阈值可用环境变量覆盖（测试用）：SENTRY_BATCH / SENTRY_MAX_AGE_MIN / SENTRY_STALL_MIN
CONTRIB="$HOME/workspace/martin/contrib-data"
CURSOR="$CONTRIB/sentry/cursor.json"
WAKE_STATE="$CONTRIB/sentry/last_wake.json"
BATCH=${SENTRY_BATCH:-5}
MAX_AGE_MIN=${SENTRY_MAX_AGE_MIN:-120}
STALL_MIN=${SENTRY_STALL_MIN:-240}
mkdir -p "$CONTRIB/sentry"

# 首启只定位不回灌
if [[ ! -f "$CURSOR" ]]; then
  LAST=$(gh api -X GET search/issues -f "q=repo:NousResearch/hermes-agent is:issue is:open" -f sort=created -f order=desc -f per_page=1 --jq '.items[0].number' 2>/dev/null)
  [[ -z "$LAST" ]] && exit 1
  echo "{\"last_issue\":$LAST}" > "$CURSOR"
  echo "none (cursor init #$LAST)"
  exit 0
fi

LAST=$(python3 -c "import json;print(json.load(open('$CURSOR'))['last_issue'])")
PAIRS_FILE=$(mktemp /tmp/sentry-pairs.XXXXXX)
REACHED=0
for p in 1 2 3 4 5; do
  sleep 2  # search API 限速温和间隔
  PAGE=$(gh api -X GET search/issues -f "q=repo:NousResearch/hermes-agent is:issue is:open" \
    -f sort=created -f order=desc -f per_page=100 -f page=$p \
    --jq '[.items[] | {n:.number, c:.created_at}]' 2>/dev/null) || { rm -f "$PAIRS_FILE"; exit 1 }
  COUNT=$(python3 -c "import json;print(len(json.loads('''$PAGE''')))")
  if [[ "$COUNT" -eq 0 ]]; then REACHED=1; break; fi
  python3 -c "import json;[print(json.dumps(x)) for x in json.loads('''$PAGE''')]" >> "$PAIRS_FILE"
  MIN_IN_PAGE=$(python3 -c "import json;print(min(x['n'] for x in json.loads('''$PAGE''')))")
  if (( MIN_IN_PAGE <= LAST )); then REACHED=1; break; fi
done

if (( ! REACHED )); then
  rm -f "$PAIRS_FILE"
  echo "cursor_behind: 游标 #${LAST} 落后超 5 页(500 open issues)仍未追平——人工排查为何落后，勿盲目推进"
  exit 0
fi

# 批量判定 + stall 兜底（单进程 python 内完成，输出恒一行）
NOW_EPOCH=$(date +%s)
FINAL=$(python3 - "$PAIRS_FILE" "$LAST" "$NOW_EPOCH" "$WAKE_STATE" "$BATCH" "$MAX_AGE_MIN" "$STALL_MIN" <<'PYEOF'
import json, sys, os, calendar, time
pairs_path, last, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
wake_path, batch, max_age, stall_min = sys.argv[4], int(sys.argv[5]), int(sys.argv[6]), int(sys.argv[7])
pairs = []
with open(pairs_path) as f:
    for line in f:
        line = line.strip()
        if line:
            pairs.append(json.loads(line))
new = sorted((x['n'], x['c']) for x in pairs if x['n'] > last)
if not new:
    print('none'); sys.exit(0)
oldest = min(calendar.timegm(time.strptime(c, '%Y-%m-%dT%H:%M:%SZ')) for _, c in new)
age_min = int((now - oldest) / 60)
nums = sorted(n for n, _ in new)
if len(nums) < batch and age_min < max_age:
    print('none'); sys.exit(0)  # 攒批窗口内：输出恒 none，框架 hash 抑制
state = None
try:
    state = json.load(open(wake_path))
except Exception:
    state = None
if state and state.get('nums') == nums and now - state.get('ts', 0) >= stall_min * 60:
    json.dump({'nums': nums, 'ts': now}, open(wake_path, 'w'))
    print(f"stall_escalation: 同一批 nums 已于 {time.strftime('%Y-%m-%d %H:%M', time.localtime(state.get('ts', now)))} 唤醒过且仍未推进——检查上一 fire 是否跑了 sentry-advance.sh；pending={len(nums)} nums={nums}")
    sys.exit(0)
json.dump({'nums': nums, 'ts': now}, open(wake_path, 'w'))
print(f"new_issues={len(nums)} nums={nums} oldest_wait={age_min}min (batch>= {batch} 条或最老 >= {max_age} 分钟即唤醒)")
PYEOF
)
PYEXIT=$?
rm -f "$PAIRS_FILE"
[[ $PYEXIT -ne 0 ]] && exit 1
print "$FINAL"
