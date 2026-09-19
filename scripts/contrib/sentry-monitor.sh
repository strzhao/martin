#!/usr/bin/env zsh
# contrib 岗哨 monitor：只报事实（游标后的新 issue 号），零判断零词表。
# 输出确定性好（同状态同输出）；被 cronjob monitor 消费——输出不变则不唤醒 agent。
# search API（is:issue is:open，无 PR 污染）按 created 降序分页推进到游标为止；
# 游标落后超 5 页报 cursor_behind 事实（提示人工排查，不自动推进）。
CONTRIB="$HOME/workspace/martin/contrib-data"
CURSOR="$CONTRIB/sentry/cursor.json"
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
ALLNUMS=""
REACHED=0
for p in 1 2 3 4 5; do
  sleep 2  # search API 限速温和间隔
  PAGE=$(gh api -X GET search/issues -f "q=repo:NousResearch/hermes-agent is:issue is:open" \
    -f sort=created -f order=desc -f per_page=100 -f page=$p \
    --jq '[.items[].number]' 2>/dev/null) || exit 1
  COUNT=$(python3 -c "import json;print(len(json.loads('''$PAGE''')))")
  if [[ "$COUNT" -eq 0 ]]; then REACHED=1; break; fi
  ALLNUMS="$ALLNUMS|$PAGE"
  MIN_IN_PAGE=$(python3 -c "import json;print(min(json.loads('''$PAGE''')))")
  if (( MIN_IN_PAGE <= LAST )); then REACHED=1; break; fi
done

if (( ! REACHED )); then
  echo "cursor_behind: 游标 #${LAST} 落后超 5 页(500 open issues)仍未追平——人工排查为何落后，勿盲目推进"
  exit 0
fi

NEW=$(python3 -c "
import json
nums = []
for chunk in '''$ALLNUMS'''.split('|'):
    if chunk.strip():
        nums += json.loads(chunk.strip())
new = sorted(n for n in nums if n > $LAST)
print(json.dumps(new) if new else '[]')")

COUNT=$(python3 -c "import json;print(len(json.loads('''$NEW''')))")
if [[ "$COUNT" -eq 0 ]]; then
  echo "none"
else
  echo "new_issues=$COUNT nums=$NEW"
fi
