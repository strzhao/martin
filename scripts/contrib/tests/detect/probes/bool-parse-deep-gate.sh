#!/bin/bash
# 探针：auto_deep_check=false 时深检 gate 必须 exit 0（开关生效）
set -uo pipefail
jq -cn --arg id "rq-20260101-9001" '{id: $id, issue: 9001, pr: null, title: "t", disposition: "review-evidence",
  lane: "deep", score: 12, priority: 90, source: "scan", state: "queued", premises: [], ammo: [], draft: null,
  tunnel: {url: null, slug: null, deployed_at: null, removed_at: null}, budget: {week: "2026-W01", day: "2026-01-01"},
  queued_at: "2026-01-01T00:00:00+08:00", queued_epoch: 1767196800, awaiting_at: null, awaiting_epoch: null, history: []}' \
  >"$CONTRIB_DATA_DIR/seed-item.json"
jq --slurpfile s "$CONTRIB_DATA_DIR/seed-item.json" '.items += $s' "$CONTRIB_DATA_DIR/ready-queue.json" \
  >"$CONTRIB_DATA_DIR/ready-queue.json.tmp" && mv "$CONTRIB_DATA_DIR/ready-queue.json.tmp" "$CONTRIB_DATA_DIR/ready-queue.json"
jq '.auto_deep_check = false' "$CONTRIB_DATA_DIR/config.json" >"$CONTRIB_DATA_DIR/config.json.tmp" \
  && mv "$CONTRIB_DATA_DIR/config.json.tmp" "$CONTRIB_DATA_DIR/config.json"
zsh "$MARTIN_DIR/scripts/contrib/deep_check_gate.sh" >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "probe: auto_deep_check=false 但 gate exit=${rc}（布尔被 // 读成默认 true）"
  exit 1
fi
exit 0
