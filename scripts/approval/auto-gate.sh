#!/bin/bash
# auto-gate.sh — L2 自动批准确定性闸门（09-06 用户拍板：默认自动，例外升级）
#
# 输入：深检阶段（redteam/preflight）写出的 verdict.json（LLM 意见）+ 队列项 + config。
# 原则：模型意见只是输入，机制层硬条件全过才放行——任一不过 → 升级人工（exit 1）。
#
# 用法: auto-gate.sh <rq-id>
# 退出码: 0=自动批准放行；1=升级人工；2=用法/数据错误（调用方按升级处理）
# 放行时 stdout 打印一行理由（进日志/台账 note）；升级时打印升级原因列表（给通知层渲染）。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
CONTRIB="${CONTRIB_DATA_DIR:-$MARTIN/contrib-data}"
QUEUE="$CONTRIB/ready-queue.json"
CONFIG="$CONTRIB/config.json"

[[ $# -ge 1 ]] || { echo "用法: auto-gate.sh <rq-id>" >&2; exit 2; }
ID="$1"

# ── goods 度量（单写方：深检全局单飞；原子写；fail-soft 不影响闸门主路）──
_goods_metrics() {
  local f="$CONTRIB/goods-metrics.json" today
  today="$(date -u +%F)"
  if jq -c --arg s "$1" --arg d "$today" '
      .history = ((.history // []) + [{status: $s, date: $d}])
      | .history = (.history | if length > 100 then .[-100:] else . end)
      | .counters = ((.counters // {}) + {($s): 1})
    ' "$f" 2>/dev/null > "$f.tmp" && mv "$f.tmp" "$f"; then
    return 0
  fi
  printf '{"counters":{"%s":1},"history":[{"status":"%s","date":"%s"}]}\n' "$1" "$1" "$today" > "$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f" || true
}

# ── 硬条件 0：总开关（缺省 true=09-06 拍板语义；显式 false 回到全人工） ──
auto_cfg="$(jq -r 'if has("auto_approve") then .auto_approve else true end' "$CONFIG" 2>/dev/null)"
if [[ "$auto_cfg" != "true" ]]; then
  echo "ESCALATE|config.auto_approve=false（总开关关闭）"
  exit 1
fi

# ── 读取队列项 ──
item="$(jq -c --arg id "$ID" '.items[] | select(.id == $id)' "$QUEUE" 2>/dev/null)"
[[ -n "$item" ]] || { echo "ESCALATE|队列中找不到 $ID"; exit 2; }
disp="$(jq -r '.disposition // ""' <<<"$item")"
score="$(jq -r '.score // 0' <<<"$item")"

# ── 硬条件 1：own-PR 永不自动（push/gh pr create 闸门不可被 LLM 意见覆盖） ──
if [[ "$disp" == "own-PR" ]]; then
  echo "ESCALATE|own-PR 推送永不自动（allow_own_pr_push 闸门语义优先）"
  exit 1
fi

# ── 硬条件 2：disposition 白名单（评论类动作可逆——评论可删可改，今天实证过） ──
case "$disp" in
  review-evidence|probe-salvage) ;;
  *) echo "ESCALATE|disposition=${disp:-未知} 不在自动白名单（review-evidence/probe-salvage）"; exit 1 ;;
esac

# ── 硬条件 3：分数达标（默认 ≥12，config.auto_approve_min_score 可调） ──
min_score="$(jq -r '.auto_approve_min_score // 12' "$CONFIG" 2>/dev/null)"
[[ "$min_score" =~ ^[0-9]+$ ]] || min_score=12
if (( score < min_score )); then
  echo "ESCALATE|score=${score} 低于自动线 ${min_score}"
  exit 1
fi

# ── 硬条件 4：verdict.json 存在且 LLM 明确判 auto + 高置信 + 低风险 ──
V="$CONTRIB/runs/deep-check/$ID/verdict.json"
if [[ ! -s "$V" ]]; then
  echo "ESCALATE|verdict.json 缺失（深检未给出自动/升级判定——无意见不自动）"
  exit 1
fi
vj="$(jq -c '.' "$V" 2>/dev/null)" || { echo "ESCALATE|verdict.json 不是合法 JSON"; exit 1; }
dec="$(jq -r '.decision // ""' <<<"$vj")"
conf="$(jq -r '.confidence // ""' <<<"$vj")"
risk="$(jq -r '.risk_level // ""' <<<"$vj")"
goods="$(jq -r '.goods.status // "missing"' <<<"$vj")"
_goods_metrics "$goods"

if [[ "$dec" != "auto" ]]; then
  reasons="$(jq -r '(.reasons // []) | join("；")' <<<"$vj")"
  echo "ESCALATE|深检判定需人工：${reasons:-未给理由（一律升级）}"
  exit 1
fi
if [[ "$conf" != "high" || "$risk" != "low" ]]; then
  echo "ESCALATE|置信度=${conf:-?}/风险=${risk:-?} 未达到 high/low 双门槛"
  exit 1
fi

# ── 硬条件 5：goods 三态判定（commit 进仓优先闸，09-09 升级：fail-closed）──
# offered=评审稿带库存 offer / forge-lane=缺口可修已立项造货（评审先发、存活期内 follow-up
# offer）/ none=不可修纯 review。缺失 = 深检没走 Goods 判定 = 流程不完整，不自动。
case "$goods" in
  offered|forge-lane|none) ;;
  *) echo "ESCALATE|verdict.json 缺合法 goods.status（commit 进仓优先闸：三态判定缺失不自动）"; exit 1 ;;
esac

echo "AUTO|深检高置信低风险（score=${score}，${disp}，评论类可逆动作，goods=${goods}）"
exit 0
