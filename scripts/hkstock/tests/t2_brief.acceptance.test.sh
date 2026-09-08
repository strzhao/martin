#!/bin/bash
# t2_brief.acceptance.test.sh — 盘前简报产物契约验收（红队，real-process 门控）
# 覆盖谓词：6.P1 / 6.P2 / 6.P3 / 6.P4
# 依据：设计契约 C4：
#   - 简报产物四段闭集：隔夜与盘前/持仓关联/期货日报摘要/今日关注与建议
#   - T2 时点期货段=「数据缺失：期货接入 T3 上线」（6.P1 断 contains 数据缺失）
#   - 免责尾行逐字「以上为 AI 整理的客观信息，不构成投资建议」（6.P4 断 contains 不构成投资建议）
#   - 产物落 hkstock-data/briefs/<date>-brief.md
# real-process 门控（唯一允许跳过的场景）：
#   - 产物路径：优先 BRIEF_ARTIFACT 环境变量注入；未注入则运行时从 briefs/ 目录发现最新 <date>-brief.md
#   - 两者均不可得 → 输出 SKIP_REAL_PROCESS，exit 0
#   - KANBAN_TASK_ID 可注入卡 id 作留痕（本文件机械断言不依赖）
# 6.P3 推送证据：hermes forensics timeline 中简报时段（产物 mtime -30min ~ +6h）存在
#   send_result 且 ok=true 的正证据行（机械证据；微信侧 AI 整理形态由编排器/用户确认）
# 用法：bash t2_brief.acceptance.test.sh
# 退出码：0 = 全绿（含 SKIP_REAL_PROCESS）；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
BRIEFS_DIR="$MARTIN_ROOT/hkstock-data/briefs"
HOLDINGS_PATH="${HKSTOCK_HOLDINGS:-$MARTIN_ROOT/hkstock-data/holdings.yaml}"

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

# --- 6.P1: 四段结构（三段字面 + 期货段数据缺失标注）---
p1_miss=""
for seg in "隔夜与盘前" "持仓关联" "今日关注与建议" "数据缺失"; do
  if ! printf '%s' "$body" | grep -q "$seg"; then
    p1_miss="${p1_miss:+${p1_miss}、}$seg"
  fi
done
if [[ -z "$p1_miss" ]]; then
  pass "6.P1"
else
  fail "6.P1" "产物缺段: ${p1_miss}（C4 四段闭集 + 期货段「数据缺失：期货接入 T3 上线」标注）"
fi

# --- 6.P2: 持仓关联（contains 任一 holdings 持仓代码 ∨ contains 无持仓关联）---
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

# --- 6.P3: 推送证据（forensics timeline 简报时段 send_result ok=true）---
art_mtime="$(stat -f %m "$ARTIFACT" 2>/dev/null || echo 0)"
if [[ "$art_mtime" -le 0 ]]; then
  fail "6.P3" "无法读取产物 mtime（stat -f %m ${ARTIFACT}）"
else
  HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
  [[ -z "$HERMES_BIN" && -x "$HOME/.local/bin/hermes" ]] && HERMES_BIN="$HOME/.local/bin/hermes"
  if [[ -z "$HERMES_BIN" ]]; then
    fail "6.P3" "hermes CLI 不可用，无法取 forensics timeline 推送证据"
  else
    tl_file="$MARTIN_ROOT/.autopilot/runtime/requirements/20260908-T2-morning-brief-loop/acceptance-staging/.t2_brief_timeline.$$"
    "$HERMES_BIN" forensics timeline --since 48h > "$tl_file" 2>/dev/null
    ok_hit="$(python3 - "$tl_file" "$art_mtime" <<'PYEOF'
import sys, time

path, mtime = sys.argv[1], int(sys.argv[2])
start, end = mtime - 1800, mtime + 6 * 3600  # 简报时段：产物落盘前 30min ~ 后 6h
fmt = "%Y-%m-%d %H:%M:%S"
hit = 0
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if "send_result" not in line or "ok=true" not in line:
                continue
            try:
                ts = time.mktime(time.strptime(line[:19], fmt))
            except ValueError:
                continue
            if start <= ts <= end:
                hit = 1
                break
except FileNotFoundError:
    pass
print(hit)
PYEOF
)"
    rm -f "$tl_file"
    if [[ "$ok_hit" == "1" ]]; then
      pass "6.P3"
    else
      fail "6.P3" "forensics timeline（since 48h）在简报时段（产物 mtime -30min~+6h）未找到 send_result ok=true 正证据行"
    fi
  fi
fi

# --- 6.P4: 免责尾行（contains 不构成投资建议）---
if printf '%s' "$body" | grep -q '不构成投资建议'; then
  pass "6.P4"
else
  fail "6.P4" "产物不含免责尾行「以上为 AI 整理的客观信息，不构成投资建议」"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
