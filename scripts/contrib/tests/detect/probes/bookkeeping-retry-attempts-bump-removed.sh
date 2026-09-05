#!/bin/bash
# 探针：发送失败后事件 attempts 必须递增（retry 簿记守卫）
set -uo pipefail
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"bk-retry","channel":"contrib","summary":"探针","pushed":false,"attempts":0,"pushed_at":null}' >>"$CONTRIB_DATA_DIR/events.jsonl"
STUB_HERMES_FAIL=1 bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
att="$(jq -r 'select(.key == "bk-retry") | .attempts' "$CONTRIB_DATA_DIR/events.jsonl")"
if [[ "${att:-0}" -lt 1 ]]; then
  echo "probe: 发送失败但 attempts 未递增（重试簿记被拆，事件将永不重试）"
  exit 1
fi
exit 0
