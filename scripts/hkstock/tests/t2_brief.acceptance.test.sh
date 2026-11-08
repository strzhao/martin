#!/bin/bash
# t2_brief.acceptance.test.sh — 盘前简报产物契约验收（红队，real-process 门控）
# 覆盖谓词：6.P1 / 6.P2 / 6.P3 / 6.P4
# 依据：设计契约 C4（2026-09-11 2.2 版）：
#   - AI Native 3.0：组合观点 + 证据与数据缺口两段，六列表含行动/仓位/教学原因/触发条件/证据
#   - 免责套话废除（6.P4 断「不构成投资建议」缺席 + 「组合观点」段在场）
#   - 产物落 hkstock-data/briefs/<date>-brief.md
#   - 契约漂移豁免：holdings.yaml 或 SKILL.md 的 mtime 晚于产物 = 产物按旧契约产出，6.P1/6.P2/6.P4
#     谓词不可判定 → INFO 放行，下一份简报自动愈合（6.P3 推送证据不受影响，仍强制）
# real-process 门控（唯一允许跳过的场景）：
#   - 产物路径：优先 BRIEF_ARTIFACT 环境变量注入；未注入则运行时从 briefs/ 目录发现最新 <date>-brief.md
#   - 两者均不可得 → 输出 SKIP_REAL_PROCESS，exit 0
#   - KANBAN_TASK_ID 可注入卡 id 作留痕（本文件机械断言不依赖）
# 6.P3 推送证据：仅消费 HKSTOCK_TEST_DELIVERY_RECEIPT 的真实回执；未注入时明确 SKIP，
#   真实 cron→微信由 AI Native 3.0 S12 独立门控。旧 hermes forensics 已退役，不再调用。
# 用法：bash t2_brief.acceptance.test.sh
# 退出码：0 = 全绿（含 SKIP_REAL_PROCESS）；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
BRIEFS_DIR="$MARTIN_ROOT/hkstock-data/briefs"
HOLDINGS_PATH="${HKSTOCK_HOLDINGS:-$MARTIN_ROOT/hkstock-data/holdings.yaml}"
SKILL_PATH="${HKSTOCK_SKILL:-$HOME/.hermes/profiles/hkstock/skills/morning-brief/SKILL.md}"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t2_brief: 盘前简报产物契约验收（场景 6，real-process）=="

# --- 产物定位：BRIEF_ARTIFACT 注入优先，否则运行时发现最新 <date>-brief.md ---
if [[ -n "${BRIEF_ARTIFACT:-}" ]]; then
  ARTIFACT="$BRIEF_ARTIFACT"
else
  ARTIFACT="$(ls -t "$BRIEFS_DIR"/*-brief.md 2>/dev/null | head -1 || true)"
fi

if [[ -z "$ARTIFACT" || ! -f "$ARTIFACT" ]]; then
  printf 'SKIP_REAL_PROCESS\n'
  printf 'RESULT: SKIP (BRIEF_ARTIFACT 未注入且 %s 下无可发现的 *-brief.md 产物)\n' "$BRIEFS_DIR"
  exit 0
fi
printf 'INFO 产物: %s\n' "$ARTIFACT"
[[ -n "${KANBAN_TASK_ID:-}" ]] && printf 'INFO 关联卡: %s\n' "$KANBAN_TASK_ID"

body="$(cat "$ARTIFACT")"

# --- 契约漂移检测：holdings.yaml 或 SKILL.md 晚于产物 = 产物按旧契约产出 ---
art_mt="$(stat -f %m "$ARTIFACT" 2>/dev/null || echo 0)"
DRIFT=""
hold_mt="$(stat -f %m "$HOLDINGS_PATH" 2>/dev/null || echo 0)"
skill_mt="$(stat -f %m "$SKILL_PATH" 2>/dev/null || echo 0)"
if [[ "$art_mt" -gt 0 ]]; then
  [[ "$hold_mt" -gt "$art_mt" ]] && DRIFT="holdings.yaml"
  [[ "$skill_mt" -gt "$art_mt" ]] && DRIFT="${DRIFT:+${DRIFT}+}SKILL.md"
fi
[[ -n "$DRIFT" ]] && printf 'INFO 契约漂移窗口：%s 晚于产物 mtime——6.P1/6.P2/6.P4 待下一份简报判定\n' "$DRIFT"

# --- 6.P1: AI Native 3.0 必需章节与六列组合观点表 ---
if [[ -n "$DRIFT" ]]; then
  printf 'INCONCLUSIVE 6.P1: %s 晚于产物，未按当前契约判定\n' "$DRIFT"
else
  p1_miss=""
  for seg in "组合观点" "证据与数据缺口"; do
    if ! printf '%s' "$body" | grep -q "$seg"; then
      p1_miss="${p1_miss:+${p1_miss}、}$seg"
    fi
  done
  if ! printf '%s' "$body" | grep -qF '| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |'; then
    p1_miss="${p1_miss:+${p1_miss}、}六列组合观点表"
  fi
  if [[ -z "$p1_miss" ]]; then
    pass "6.P1"
  else
    fail "6.P1" "AI Native 3.0 契约缺失: ${p1_miss}"
  fi
fi

# --- 6.P2: 持仓关联（contains 任一 holdings 持仓代码 ∨ contains 无持仓关联）---
if [[ -n "$DRIFT" ]]; then
  printf 'INCONCLUSIVE 6.P2: %s 晚于产物，未按当前契约判定\n' "$DRIFT"
else
  symbols=""
  if [[ -f "$HOLDINGS_PATH" ]]; then
    symbols="$(grep -E '^[[:space:]]*-?[[:space:]]*symbol:' "$HOLDINGS_PATH" 2>/dev/null \
      | sed -E 's/.*symbol:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' | grep -v '^$' || true)"
  fi
  hit_symbol=""
  if [[ -n "$symbols" ]]; then
    while IFS= read -r sym; do
      [[ -z "$sym" ]] && continue
      if printf '%s' "$body" | grep -qF "$sym"; then
        hit_symbol="$sym"
        break
      fi
    done <<< "$symbols"
  fi
  if [[ -n "$hit_symbol" ]]; then
    pass "6.P2"
  elif printf '%s' "$body" | grep -q '无持仓关联'; then
    if [[ -n "$symbols" ]]; then
      printf 'INFO 6.P2: 产物走「无持仓关联」分支，而 holdings.yaml 含 symbol=%s（语义上可疑，机械谓词按 OR 口径放行）\n' "$(printf '%s' "$symbols" | tr '\n' ',')"
    fi
    pass "6.P2"
  else
    fail "6.P2" "产物不含任何持仓代码（候选: $(printf '%s' "$symbols" | tr '\n' ',' | cut -c1-60)）也不含「无持仓关联」"
  fi
fi

# --- 6.P3: 真实投递回执（S12 专用；旧 hermes forensics 已退役，不再以空调用判失败）---
RECEIPT="${HKSTOCK_TEST_DELIVERY_RECEIPT:-}"
if [[ -z "$RECEIPT" ]]; then
  printf 'SKIP_REAL_PROCESS 6.P3: 未注入投递回执；真实 cron→微信由 S12 独立门控，不执行外发\n'
elif [[ ! -f "$RECEIPT" ]]; then
  fail "6.P3" "HKSTOCK_TEST_DELIVERY_RECEIPT 已注入但文件不存在: $RECEIPT"
else
  ok_hit="$(python3 - "$RECEIPT" "$ARTIFACT" <<'PYEOF'
import json, sys
from pathlib import Path
receipt_path, artifact_path = sys.argv[1:]
local = Path(artifact_path).read_text(encoding='utf-8')
report_id = ''
for line in local.splitlines():
    if line.startswith('report_id:'):
        report_id = line.split(':', 1)[1].strip()
        break
lines = [line for line in Path(receipt_path).read_text(encoding='utf-8').splitlines() if line.strip()]
try:
    receipt = json.loads(lines[-1]) if lines else {}
except json.JSONDecodeError:
    receipt = {}
ok = bool(
    report_id
    and receipt.get('report_id') == report_id
    and receipt.get('generated_report_id') == report_id
    and (receipt.get('delivery_status') or receipt.get('status')) == 'delivered'
    and receipt.get('report_generated') is True
    and receipt.get('delivered_content') == local
)
print(1 if ok else 0)
PYEOF
)"
  if [[ "$ok_hit" == "1" ]]; then
    pass "6.P3"
  else
    fail "6.P3" "投递回执未证明 delivered/generated report_id 与本地晨报完全一致"
  fi
fi

# --- 6.P4: 组合观点段存在 + 免责套话缺席（2.2 契约，2026-09-11 用户拍板：核心产出=组合观点列表；纯自用工具，「不构成投资建议」式尾行废除）---
if [[ -n "$DRIFT" ]]; then
  printf 'INCONCLUSIVE 6.P4: %s 晚于产物，未按当前契约判定\n' "$DRIFT"
else
  if printf '%s' "$body" | grep -q '组合观点'; then
    pass "6.P4-opinion"
  else
    fail "6.P4" "产物缺「组合观点」段（2.2 起开篇必含：每仓一行 动不动+一句原因+新买入候选行）"
  fi
  if printf '%s' "$body" | grep -q '不构成投资建议'; then
    fail "6.P4" "产物仍含免责套话（2.2 起废除）"
  else
    pass "6.P4-no-disclaimer"
  fi
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
if [[ -n "$DRIFT" ]]; then
  printf 'RESULT: INCONCLUSIVE（契约漂移；未将旧产物记为当前契约 PASS）\n'
  exit 0
fi
printf 'RESULT: ALL PASS\n'
exit 0
