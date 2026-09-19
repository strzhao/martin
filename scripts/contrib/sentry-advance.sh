#!/usr/bin/env zsh
# 岗哨游标推进：由被唤醒的 agent 在完成增量分诊后调用，参数 = 已分诊的最大 issue 号
# 用法: sentry-advance.sh <max_issue_number>
CURSOR="$HOME/workspace/martin/contrib-data/sentry/cursor.json"
N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "usage: sentry-advance.sh <max_issue_number>"; exit 1; }
OLD=$(python3 -c "import json;print(json.load(open('$CURSOR'))['last_issue'])" 2>/dev/null || echo 0)
if (( N > OLD )); then
  echo "{\"last_issue\":$N}" > "$CURSOR"
  echo "cursor: #$OLD → #$N"
else
  echo "cursor unchanged (#$OLD)"
fi
