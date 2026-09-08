#!/bin/bash
# t2_cron.acceptance.test.sh — hkstock-morning-brief cron 定时链路契约验收（红队，黑盒，det-machine）
# 覆盖谓词：5.P1 / 5.P2 / 5.P3
# 依据：设计契约 C5：
#   - cron 名 `hkstock-morning-brief`、schedule `23 8 * * 1-5`（8:23 早于 09:30 开盘）
#   - pin model/provider 非空
#   - cron 任务体引用 hkstock 派单（contains `hkstock` ∧ contains 派单标识 kanban/建卡）
# 驱动方式：`hermes cron list`（5.P1）+ ~/.hermes/cron/jobs.json 字段直查（5.P2/5.P3，只 grep 字段不评实现）
# 用法：bash t2_cron.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

HERMES_ROOT="${HERMES_HOME:-$HOME/.hermes}"
JOBS_JSON="$HERMES_ROOT/cron/jobs.json"
CRON_NAME="hkstock-morning-brief"

# 解析 hermes 可执行文件（PATH 优先，回落标准安装路径）
HERMES_BIN="$(command -v hermes 2>/dev/null || true)"
[[ -z "$HERMES_BIN" && -x "$HOME/.local/bin/hermes" ]] && HERMES_BIN="$HOME/.local/bin/hermes"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

TMPDIR_T2="$(mktemp -d /tmp/t2-cron-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T2"' EXIT

echo "== t2_cron: hkstock-morning-brief cron 契约验收（场景 5）=="

# ============ 5.P1: hermes cron list 含 hkstock-morning-brief ∧ 调度时间早于 09:30 ============
if [[ -z "$HERMES_BIN" ]]; then
  fail "5.P1" "hermes CLI 不可用（PATH 与 ~/.local/bin/hermes 均未找到）"
else
  cron_out="$("$HERMES_BIN" cron list 2>&1)"
  cron_rc=$?
  if [[ $cron_rc -ne 0 ]]; then
    fail "5.P1" "hermes cron list 退出码 ${cron_rc}，输出: ${cron_out:0:300}"
  elif ! printf '%s' "$cron_out" | grep -q "$CRON_NAME"; then
    fail "5.P1" "hermes cron list 输出不含 $CRON_NAME"
  else
    # 从该 job 的块内提取 Schedule 行（Name 命中后向下找最近的 Schedule:）
    sched="$(printf '%s\n' "$cron_out" | awk -v name="$CRON_NAME" '
      $0 ~ "Name:.*" name { seen=1 }
      seen && /Schedule:/ { print; exit }')"
    if [[ -z "$sched" ]]; then
      fail "5.P1" "cron list 中 $CRON_NAME 块内未找到 Schedule 行"
    else
      # 取调度表达式的分钟与小时字段（前两列），换算为当日分钟数与 09:30（570）比较
      expr5="$(printf '%s' "$sched" | sed -E 's/.*Schedule:[[:space:]]*//')"
      minute="$(printf '%s' "$expr5" | awk '{print $1}')"
      hour="$(printf '%s' "$expr5" | awk '{print $2}')"
      if [[ "$minute" =~ ^[0-9]+$ && "$hour" =~ ^[0-9]+$ ]] && (( hour * 60 + minute < 570 )); then
        pass "5.P1"
      else
        fail "5.P1" "调度时间不早于 09:30 或无法解析: schedule=[$expr5]（C5 要求 23 8 * * 1-5）"
      fi
    fi
  fi
fi

# ============ 5.P2 / 5.P3: jobs.json 任务体与 pin 字段 ============
if [[ ! -f "$JOBS_JSON" ]]; then
  fail "5.P2" "jobs.json 不存在: $JOBS_JSON"
  fail "5.P3" "jobs.json 不存在: $JOBS_JSON"
else
  python3 - "$JOBS_JSON" "$CRON_NAME" > "$TMPDIR_T2/probe.txt" <<'PYEOF'
import json, sys

path, name = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    jobs = (json.load(fh) or {}).get("jobs") or []
matches = [j for j in jobs if j.get("name") == name]
if not matches:
    print("5.P2:FAIL", "jobs.json 无 name=%s 的 job" % name)
    print("5.P3:FAIL", "jobs.json 无 name=%s 的 job" % name)
    sys.exit(0)
job = matches[0]

# 5.P2: 任务体引用 hkstock 派单（contains 'hkstock' ∧ contains 派单标识 kanban/建卡）
prompt = job.get("prompt") or ""
has_hk = "hkstock" in prompt
has_dispatch = ("kanban" in prompt) or ("建卡" in prompt)
if has_hk and has_dispatch:
    print("5.P2:PASS")
else:
    print("5.P2:FAIL", "cron 任务体派单标识缺失: contains hkstock=%s, contains kanban/建卡=%s, prompt 长度=%d" % (has_hk, has_dispatch, len(prompt)))

# 5.P3: pin 字段（model/provider）非空
model = (job.get("model") or "").strip()
provider = (job.get("provider") or "").strip()
if model and provider:
    print("5.P3:PASS")
else:
    print("5.P3:FAIL", "pin 字段为空: model=%r provider=%r" % (model, provider))
PYEOF
  probe_rc=$?
  if [[ $probe_rc -ne 0 ]]; then
    fail "5.P2" "jobs.json 解析失败（python3 退出码 ${probe_rc}）"
    fail "5.P3" "jobs.json 解析失败（python3 退出码 ${probe_rc}）"
  else
    while IFS= read -r line; do
      pid="${line%%:*}"
      verdict="${line#*:}"
      if [[ "$verdict" == "PASS" ]]; then
        pass "$pid"
      else
        fail "$pid" "${verdict#FAIL }"
      fi
    done < "$TMPDIR_T2/probe.txt"
  fi
fi

# --- EXTRA（2026-09-08 auto-fix，qa-reviewer Important 缺口补齐）：prompt↔guard 一致性 + 框架缺口守卫 ---
# EXTRA-silent-sentinel: 三分支休市与成功路径都必须锚定 [SILENT]（防非交易日/建卡后空推微信）
grep -q '\[SILENT\]' "$JOBS_JSON" || { fail "EXTRA-silent-sentinel" "cron prompt 缺 [SILENT] 哨兵锚定"; }
# EXTRA-subscribe-step: bot-chat/CLI 起源建卡不触发 auto-subscribe（kanban_tools.py:1514 CLI/cron no-op），
# prompt 必须固化 notify-subscribe 补订步（漏掉 = worker 终态静默不推微信）
grep -q 'notify-subscribe' "$JOBS_JSON" || { fail "EXTRA-subscribe-step" "cron prompt 缺补订步（上游缺口 requires 显式 notify-subscribe）"; }
# EXTRA-idempotency: 定时建卡必须带 --idempotency-key（lane 协议红线，防重复派单）
grep -q 'idempotency-key' "$JOBS_JSON" || { fail "EXTRA-idempotency" "cron prompt 缺 --idempotency-key"; }
# EXTRA-no-g1: 被仲裁作废的 G1 口径字面量不得回流（guard:ok / exit 2 / brief-<date>.md / brief_dir）
if grep -qE 'guard:ok|exit 2|brief-<date>\.md|brief_dir' "$JOBS_JSON"; then
  fail "EXTRA-no-g1" "cron prompt 含 G1 作废口径字面量（回退污染）"
fi
# 重新计算退出码（前面的谓词可能已置 FAIL_COUNT）
if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS (with EXTRA)\n'
exit 0
