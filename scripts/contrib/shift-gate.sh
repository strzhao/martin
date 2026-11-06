#!/usr/bin/env bash
# contrib-operator 班次空班守卫（monitor_script，2026-11-06 上线）
# 语义：输出恒定 "none" → 框架 hash 抑制不唤 agent（cron/monitor.py）；输出变化 → 唤醒并注入 diff 上下文。
# 检查（全零 LLM，按优先级短路）：
#   ① ops-journal 末行 <60min = 上一班未收口 → 续命班
#   ② rq.sh list 活跃项（awaiting-approval/approved/pending）
#   ③ contrib 板 triage/ready 列非空（operator 收件箱；patrol unblock 后的到期 watch 也落 ready，同被此条覆盖）
#   ④ [watch] 卡到期（list 行内 due YYYY-MM-DD ≤ 今天；patrol 之外的冗余第三道）
# stall 兜底：同一 run 理由连续 GATE_STALL_TICKS 次评估不变 → 追加 -stall 后缀强制唤醒一次
#   （输出串变化 → hash 变化 → 必唤醒；防 operator 跑过但没清掉状态时永久静默）。
# 回退：`hermes cron edit 3e5c6e23e260 --monitor-script ""` 即回纯计划班次（上线时已演练一次）。
# 真源 = ~/workspace/martin/scripts/contrib/shift-gate.sh；部署副本 = ~/.hermes/scripts/shift-gate.sh（/usr/bin/diff 自证，
# 勿用 PATH diff——OpenHarmony toolchain 遮蔽，恒 rc=0 假绿）。
set -uo pipefail
MARTIN="$HOME/workspace/martin"
CONTRIB="$MARTIN/contrib-data"
GATE_STATE="$CONTRIB/sentry/gate_state.json"
STALL_TICKS=${GATE_STALL_TICKS:-3}
mkdir -p "$CONTRIB/sentry"

run_reason=""

# ① journal 末行时刻（四栏契约：| 时刻 | 决策 | 对象 | 理由 |）
JOURNAL="$CONTRIB/ops-journal.md"
if [[ -f "$JOURNAL" ]]; then
  LAST_TS=$(grep -E '^\| 20[0-9]{2}-[0-9]{2}-[0-9]{2} ' "$JOURNAL" | tail -1 | cut -d'|' -f2 | xargs)
  if [[ -n "$LAST_TS" ]]; then
    TS_EPOCH=$(date -j -f "%Y-%m-%d %H:%M" "$LAST_TS" +%s 2>/dev/null || echo 0)
    AGE=$(( $(date +%s) - TS_EPOCH ))
    if (( TS_EPOCH > 0 && AGE >= 0 && AGE < 3600 )); then
      run_reason="run: journal_tail_recent 上一班 60min 内有活动→开班自读 journal 尾行判续命"
    fi
  fi
fi

# ② rq 队列活跃项
if [[ -z "$run_reason" ]]; then
  RQ_N=$(bash "$MARTIN/scripts/contrib/rq.sh" list 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
print(sum(1 for r in d if r.get('state') in ('awaiting-approval','approved','pending')))" 2>/dev/null || echo 0)
  if (( RQ_N > 0 )); then run_reason="run: rq_active=${RQ_N}"; fi
fi

# ③④ 看板（triage/ready 列 + 到期 due）
if [[ -z "$run_reason" ]]; then
  KB=$(env -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL hermes kanban --board contrib list 2>/dev/null || true)
  TRI=$(printf '%s\n' "$KB" | grep -cE ' t_[0-9a-f]{8,}  (triage|ready) ' || true)
  if (( TRI > 0 )); then
    run_reason="run: board_triage_ready=${TRI}"
  else
    TODAY=$(date +%Y-%m-%d)
    DUE=$(printf '%s\n' "$KB" | grep -oE 'due 20[0-9]{2}-[0-9]{2}-[0-9]{2}' | cut -d' ' -f2 | sort | while read -r d; do d_n=${d//-/}; t_n=${TODAY//-/}; (( d_n <= t_n )) && { echo "$d"; break; }; done)
    if [[ -n "$DUE" ]]; then run_reason="run: watch_due=${DUE}"; fi
  fi
fi

# stall 兜底（状态文件记录上次输出与连续计数）
OUT="none"
[[ -n "$run_reason" ]] && OUT="$run_reason"
STATE_N=0; STATE_OUT=""
if [[ -f "$GATE_STATE" ]]; then
  STATE_JSON=$(python3 -c "import json;s=json.load(open('$GATE_STATE'));print(s.get('n',0));print(s.get('out',''))" 2>/dev/null || true)
  STATE_N=$(printf '%s\n' "$STATE_JSON" | sed -n 1p)
  STATE_OUT=$(printf '%s\n' "$STATE_JSON" | sed -n 2p)
  STATE_N=${STATE_N:-0}
fi
if [[ "$OUT" == "none" ]]; then
  python3 -c "import json;json.dump({'n':0,'out':'none'},open('$GATE_STATE','w'))" 2>/dev/null
elif [[ -n "$STATE_OUT" && "$OUT" == "$STATE_OUT" ]]; then
  N=$(( STATE_N + 1 ))
  if (( N >= STALL_TICKS )); then
    OUT="${OUT} -stall${N}"
    N=0
  fi
  python3 -c "import json;json.dump({'n':$N,'out':'''$OUT'''},open('$GATE_STATE','w'))" 2>/dev/null
else
  python3 -c "import json;json.dump({'n':1,'out':'''$OUT'''},open('$GATE_STATE','w'))" 2>/dev/null
fi
echo "$OUT"
exit 0
