#!/bin/bash
# 探针：launchd 仿真（cwd=/）下，claude 子进程的 PWD 必须等于 MARTIN 根（Bug② 回归锚点）
set -uo pipefail
jq -cn --arg id "rq-20260101-9002" '{id: $id, issue: 9002, pr: null, title: "t", disposition: "review-evidence",
  lane: "probe", score: 12, priority: 90, source: "scan", state: "queued", premises: [], ammo: [], draft: null,
  tunnel: {url: null, slug: null, deployed_at: null, removed_at: null}, budget: {week: "2026-W01", day: "2026-01-01"},
  queued_at: "2026-01-01T00:00:00+08:00", queued_epoch: 1767196800, awaiting_at: null, awaiting_epoch: null, history: []}' \
  >"$CONTRIB_DATA_DIR/seed-item.json"
jq --slurpfile s "$CONTRIB_DATA_DIR/seed-item.json" '.items += $s' "$CONTRIB_DATA_DIR/ready-queue.json" \
  >"$CONTRIB_DATA_DIR/ready-queue.json.tmp" && mv "$CONTRIB_DATA_DIR/ready-queue.json.tmp" "$CONTRIB_DATA_DIR/ready-queue.json"
cd / || exit 99
zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh" >/dev/null 2>&1
cwd_seen="$(awk -F'|' '$1 == "claude" { print $2; exit }' "$STUB_LOG_DIR/calls.log" 2>/dev/null)"
if [[ "$cwd_seen" != "$MARTIN_DIR" ]]; then
  echo "probe: claude 子进程 cwd=[$cwd_seen] 期望 [$MARTIN_DIR]（缺 cd，launchd cwd=/ 下找不到项目 skill）"
  exit 1
fi
exit 0
