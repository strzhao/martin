#!/bin/bash
# 探针：hermes 非零退出时事件不得标 pushed（账实分离守卫）
set -uo pipefail
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"lv-1","channel":"contrib","summary":"探针","pushed":false,"attempts":0,"pushed_at":null}' >>"$CONTRIB_DATA_DIR/events.jsonl"
STUB_HERMES_FAIL=1 bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
pushed="$(jq -r 'select(.key == "lv-1") | .pushed' "$CONTRIB_DATA_DIR/events.jsonl")"
if [[ "$pushed" == "true" ]]; then
  echo "probe: 发送失败仍标 pushed（账面成功≠实际送达）"
  exit 1
fi
exit 0
