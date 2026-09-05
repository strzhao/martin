#!/bin/bash
# 探针：当日告警限额已满时必须拒推（quota/limit 簿记守卫）
set -uo pipefail
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"own-pr-activity","key":"bk-quota","channel":"contrib","summary":"限额探针","pushed":false,"attempts":0,"pushed_at":null}' >>"$CONTRIB_DATA_DIR/events.jsonl"
TODAY="$(date +%F)"
jq -c --arg d "$TODAY" '.alerts[$d] = 3' "$CONTRIB_DATA_DIR/notify-state.json" >"$CONTRIB_DATA_DIR/notify-state.json.tmp" \
  && mv "$CONTRIB_DATA_DIR/notify-state.json.tmp" "$CONTRIB_DATA_DIR/notify-state.json"
bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
c="$(awk -F'|' '$1 == "hermes" { c++ } END { printf "%d", c + 0 }' "$STUB_LOG_DIR/calls.log" 2>/dev/null)"
if [[ "${c:-0}" -ge 1 ]]; then
  echo "probe: 当日限额 3/3 已满仍调用 hermes 推送（限额守卫被拆）"
  exit 1
fi
exit 0
