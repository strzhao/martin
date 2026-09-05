#!/bin/bash
# 探针：非法迁移必须 exit 2 且 ready-queue.json 字节级零改动（迁移守卫）
set -uo pipefail
Q="$CONTRIB_DATA_DIR/ready-queue.json"
jq -cn --arg id "rq-20260101-9003" '{id: $id, issue: 9003, pr: null, title: "t", disposition: "review-evidence",
  lane: "deep", score: 12, priority: 90, source: "scan", state: "queued", premises: [], ammo: [], draft: null,
  tunnel: {url: null, slug: null, deployed_at: null, removed_at: null}, budget: {week: "2026-W01", day: "2026-01-01"},
  queued_at: "2026-01-01T00:00:00+08:00", queued_epoch: 1767196800, awaiting_at: null, awaiting_epoch: null, history: []}' \
  >"$CONTRIB_DATA_DIR/seed-item.json"
jq --slurpfile s "$CONTRIB_DATA_DIR/seed-item.json" '.items += $s' "$Q" >"$Q.tmp" && mv "$Q.tmp" "$Q"
before="$(shasum -q "$Q")"
bash "$MARTIN_DIR/scripts/contrib/rq.sh" set rq-20260101-9003 executed >/dev/null 2>&1
rc=$?
after="$(shasum -q "$Q")"
if [[ "$rc" -eq 0 ]]; then
  echo "probe: 非法迁移 queued→executed 被放行（守卫被拆）"
  exit 1
fi
if [[ "$before" != "$after" ]]; then
  echo "probe: 非法迁移被拒但文件有写入"
  exit 1
fi
exit 0
