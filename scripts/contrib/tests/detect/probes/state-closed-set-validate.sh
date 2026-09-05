#!/bin/bash
# 探针：validate 状态闭集 schema——10 个合法生产态（含 approved/revise/shelved 三条生产路径产物）
# 不得被误报非法；真非法状态必须被抓
set -uo pipefail
Q="$CONTRIB_DATA_DIR/ready-queue.json"
i=0
for st in queued deep-check awaiting-approval approved executed revise shelved rejected expired failed; do
  i=$((i + 1))
  jq -cn --arg id "rq-20260101-91$i" --argjson issue "$((9100 + i))" --arg st "$st" \
    '{id: $id, issue: $issue, pr: null, title: "t", disposition: "review-evidence",
      lane: "deep", score: 12, priority: 90, source: "scan", state: $st, premises: [], ammo: [], draft: null,
      tunnel: {url: null, slug: null, deployed_at: null, removed_at: null}, budget: {week: "2026-W01", day: "2026-01-01"},
      queued_at: "2026-01-01T00:00:00+08:00", queued_epoch: 1767196800, awaiting_at: null, awaiting_epoch: null, history: []}' \
    >"$CONTRIB_DATA_DIR/seed-item.json"
  jq --slurpfile s "$CONTRIB_DATA_DIR/seed-item.json" '.items += $s' "$Q" >"$Q.tmp" && mv "$Q.tmp" "$Q"
done
bash "$MARTIN_DIR/scripts/contrib/rq.sh" validate >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "probe: 合法生产态被 validate 误报非法（状态闭集 schema 被收缩）"
  exit 1
fi
# 反向：真非法状态必须被抓
jq -cn --arg id "rq-20260101-9999" '{id: $id, issue: 9999, pr: null, title: "t", disposition: "review-evidence",
  lane: "deep", score: 12, priority: 90, source: "scan", state: "bogus-state", premises: [], ammo: [], draft: null,
  tunnel: {url: null, slug: null, deployed_at: null, removed_at: null}, budget: {week: "2026-W01", day: "2026-01-01"},
  queued_at: "2026-01-01T00:00:00+08:00", queued_epoch: 1767196800, awaiting_at: null, awaiting_epoch: null, history: []}' \
  >"$CONTRIB_DATA_DIR/seed-item.json"
jq --slurpfile s "$CONTRIB_DATA_DIR/seed-item.json" '.items += $s' "$Q" >"$Q.tmp" && mv "$Q.tmp" "$Q"
bash "$MARTIN_DIR/scripts/contrib/rq.sh" validate >/dev/null 2>&1
rc=$?
if [[ "$rc" -eq 0 ]]; then
  echo "probe: bogus-state 未被 validate 抓住（闭集校验失效）"
  exit 1
fi
exit 0
