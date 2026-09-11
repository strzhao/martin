#!/bin/bash
# 探针：config notify_dry_run=false 必须真发（hermes send stub 被调 >=1）
# pristine（null/缺失才缺省的 cfg）→ 真发；mutated（jq // 布尔塌缩）→ 静默 dry-run → 本探针非零
# T5 卡化口径：代理信号从「hermes 有调用」改为「hermes send 有调用」——digest 卡化后
# flush 叙事批在 dry-run 下仍会建卡（kanban 调用），send 才是发送行为的唯一真值；
# 事件用机械类（own-pr-activity）走模板卡直发路径，绕开卡化异步窗口。
set -uo pipefail
EV="$CONTRIB_DATA_DIR/events.jsonl"
printf '%s\n' '{"ts":"2026-01-01T00:00:00+08:00","class":"own-pr-activity","key":"bp-1","channel":"contrib","summary":"bool-parse 探针事件","pushed":false,"attempts":0,"pushed_at":null}' >>"$EV"
jq '.notify_dry_run = false' "$CONTRIB_DATA_DIR/config.json" >"$CONTRIB_DATA_DIR/config.json.tmp" \
  && mv "$CONTRIB_DATA_DIR/config.json.tmp" "$CONTRIB_DATA_DIR/config.json"
bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush >/dev/null 2>&1
awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { exit (c + 0 >= 1) ? 0 : 1 }' "$STUB_LOG_DIR/calls.log" 2>/dev/null || {
  echo "probe: hermes send 未被调用（config false 被读成默认 true，静默 dry-run）"
  exit 1
}
exit 0
