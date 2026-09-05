#!/bin/bash
# 探针：fallback_notice 当日已置 1 时不得重复 osascript（alert/notify 日幂等守卫）
set -uo pipefail
TODAY="$(date +%F)"
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"bk-alert","channel":"contrib","summary":"探针","pushed":false,"attempts":3,"pushed_at":null}' >>"$CONTRIB_DATA_DIR/events.jsonl"
jq -c --arg d "$TODAY" '.alerts[$d] = 0 | .fallback_notice[$d] = 1' "$CONTRIB_DATA_DIR/notify-state.json" \
  >"$CONTRIB_DATA_DIR/notify-state.json.tmp" && mv "$CONTRIB_DATA_DIR/notify-state.json.tmp" "$CONTRIB_DATA_DIR/notify-state.json"
STUB_HERMES_FAIL=1 bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
c="$(awk -F'|' '$1 == "osascript" { c++ } END { printf "%d", c + 0 }' "$STUB_LOG_DIR/calls.log" 2>/dev/null)"
if [[ "${c:-0}" -ge 1 ]]; then
  echo "probe: fallback_notice 已置当日幂等位仍重复 osascript（日幂等守卫被拆）"
  exit 1
fi
exit 0
