#!/bin/bash
# 探针：hermes exit 0 但 success:false 时事件不得标 pushed（回执证据未绑定）
set -uo pipefail
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"lv-2","channel":"contrib","summary":"探针","pushed":false,"attempts":0,"pushed_at":null}' >>"$CONTRIB_DATA_DIR/events.jsonl"
STUB_HERMES_SUCCESS_FALSE=1 bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
pushed="$(jq -r 'select(.key == "lv-2") | .pushed' "$CONTRIB_DATA_DIR/events.jsonl")"
if [[ "$pushed" == "true" ]]; then
  echo "probe: exit0 但 success:false 仍标 pushed（回执未绑定发送证据）"
  exit 1
fi
exit 0
