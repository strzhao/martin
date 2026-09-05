#!/bin/bash
# 探针：同 key 二次 event 不得新增行（dedup/幂等簿记守卫）
set -uo pipefail
bash "$MARTIN_DIR/scripts/contrib/notify.sh" event own-pr-activity --key bk-dedup --summary "第一次" >/dev/null 2>&1
bash "$MARTIN_DIR/scripts/contrib/notify.sh" event own-pr-activity --key bk-dedup --summary "第二次" >/dev/null 2>&1
n="$(grep -c '"key":"bk-dedup"' "$CONTRIB_DATA_DIR/events.jsonl" 2>/dev/null || true)"
if [[ "${n:-0}" -ge 2 ]]; then
  echo "probe: 同 key 重复入账（幂等守卫被拆）"
  exit 1
fi
exit 0
