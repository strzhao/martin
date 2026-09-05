#!/bin/bash
# 探针：config notify_dry_run=false 必须真发（hermes stub 被调 >=1）
# pristine（null/缺失才缺省的 cfg）→ 真发；mutated（jq // 布尔塌缩）→ 静默 dry-run → 本探针非零
set -uo pipefail
EV="$CONTRIB_DATA_DIR/events.jsonl"
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"bp-1","channel":"contrib","summary":"bool-parse 探针事件","pushed":false,"attempts":0,"pushed_at":null}' >>"$EV"
jq '.notify_dry_run = false' "$CONTRIB_DATA_DIR/config.json" >"$CONTRIB_DATA_DIR/config.json.tmp" \
  && mv "$CONTRIB_DATA_DIR/config.json.tmp" "$CONTRIB_DATA_DIR/config.json"
bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
awk -F'|' '$1 == "hermes" { c++ } END { exit (c + 0 >= 1) ? 0 : 1 }' "$STUB_LOG_DIR/calls.log" 2>/dev/null || {
  echo "probe: hermes 未被调用（config false 被读成默认 true，静默 dry-run）"
  exit 1
}
exit 0
