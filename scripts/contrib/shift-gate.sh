#!/usr/bin/env bash
# contrib-operator 班次空班守卫（monitor_script，2026-11-06 上线）
# 语义：输出恒定 "none" → 框架 hash 抑制不唤 agent（cron/monitor.py）；输出变化 → 唤醒并注入 diff 上下文。
# 检查（全零 LLM，按优先级短路）：
#   ① ops-journal 末行 <60min = 上一班未收口 → 续命班（尾行 python3 utf-8 容错读取 + "| panel-truth */5"
#      岗哨行排除；s0525 班实证：非法 UTF-8 行致 BSD grep 假阴/cut 炸管道，真根因=bash3.2 heredoc
#      变量展开紧邻全角标点吞多字节字节，append 脚本一律花括号展开）
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
  # 长中文行上 BSD grep/cut 双缺陷（s0525 班实证：grep 部分行假阴 + cut Illegal byte sequence
  # → LAST_TS 恒空 → 守卫①聋）。尾行时刻读取走 python3（utf-8 replace，行首模式在安全区）。
  # panel-truth */5 岗哨班每 5 分钟自记一行——续命语义只认 operator 班活动，岗哨行排除（s0525 班实证）。
  LAST_TS=$(python3 -c 'import re,sys
rows=[l for l in open(sys.argv[1],encoding="utf-8",errors="replace") if re.match(r"^\| 20\d{2}-\d{2}-\d{2} ",l) and "| panel-truth */5" not in l]
m=re.match(r"^\| (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) \|",rows[-1]) if rows else None
print(m.group(1) if m else "")' "$JOURNAL" 2>/dev/null)
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
  # rq 活跃计数排除 release-gate 项（s0630 班实证：flashcards 发版项 approved 态挂 7 天恒触发
  # 假唤醒——该项归 flashcards 域、批准后业务已链式提审，rq 行态推进也不归 contrib 域管）。
  RQ_N=$(bash "$MARTIN/scripts/contrib/rq.sh" list 2>/dev/null | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
print(sum(1 for r in d if r.get('state') in ('awaiting-approval','approved','pending') and r.get('disposition') != 'release-gate'))" 2>/dev/null || echo 0)
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
    # LC_ALL=C：看板列表行含中文标题时 BSD cut 会 Illegal byte sequence 弃行（s0525 班实证）
    DUE=$(printf '%s\n' "$KB" | LC_ALL=C grep -oE 'due 20[0-9]{2}-[0-9]{2}-[0-9]{2}' | LC_ALL=C cut -d' ' -f2 | sort | while read -r d; do d_n=${d//-/}; t_n=${TODAY//-/}; (( d_n <= t_n )) && { echo "$d"; break; }; done)
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
