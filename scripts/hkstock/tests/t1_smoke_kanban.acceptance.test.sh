#!/bin/bash
# t1_smoke_kanban.acceptance.test.sh — hkstock smoke 卡全链 real-process 验收（红队，黑盒）
# 覆盖谓词：2.P1 / 2.P2 / 2.P3（real-process）
# 依据：设计文档「smoke 卡契约」：
#   - 存在一张 assignee=hkstock 的卡到达 status=done
#   - 终态推回微信且 AI 整理形态（微信侧用户确认留编排器；此处验 forensics 含 smoke 时段记录）
# task-id 注入：KANBAN_TASK_ID 环境变量（由编排器/QA 阶段注入）。
#   缺该变量时三个用例输出 SKIP_REAL_PROCESS 并 exit 0（唯一允许的条件跳过——real-process 由 QA 编排器带证执行）。
# 用法：KANBAN_TASK_ID=t_xxx bash t1_smoke_kanban.acceptance.test.sh
# 退出码：0 = 全绿（或 SKIP_REAL_PROCESS）；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"

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

echo "== t1_smoke_kanban: smoke 卡 real-process 验收 =="

# --- real-process 门：KANBAN_TASK_ID 未注入 → SKIP_REAL_PROCESS exit 0 ---
if [[ -z "${KANBAN_TASK_ID:-}" ]]; then
  echo "SKIP_REAL_PROCESS 2.P1"
  echo "SKIP_REAL_PROCESS 2.P2"
  echo "SKIP_REAL_PROCESS 2.P3"
  printf 'RESULT: SKIP_REAL_PROCESS\n'
  exit 0
fi

TASK_ID="$KANBAN_TASK_ID"

if [[ -z "$HERMES_BIN" ]]; then
  fail "2.P1" "hermes CLI 不可用（PATH 与 ~/.local/bin/hermes 均未找到）"
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi

# --- 2.P1: smoke 卡 assignee == hkstock ---
# --- 2.P2: smoke 卡 status == done ---
show_out="$("$HERMES_BIN" kanban show "$TASK_ID" 2>&1)"
show_rc=$?
if [[ $show_rc -ne 0 ]]; then
  fail "2.P1" "hermes kanban show $TASK_ID 退出码 $show_rc，输出: ${show_out:0:300}"
  fail "2.P2" "同上（kanban show 失败，无法核 status）"
else
  # assignee 断言：整词匹配（防止 hkstock-cc 等 lane 名误配）
  if printf '%s' "$show_out" | grep -Eq 'assignee["=: ]+hkstock(["[:space:]]|$)'; then
    pass "2.P1"
  else
    fail "2.P1" "卡 $TASK_ID 的 assignee 非 hkstock，输出: $(printf '%s' "$show_out" | grep -i 'assignee' | head -3 | tr '\n' ' ')"
  fi
  # status 断言：status == done（终态）
  if printf '%s' "$show_out" | grep -Eq 'status["=: ]+done(["[:space:]]|$)'; then
    pass "2.P2"
  else
    fail "2.P2" "卡 $TASK_ID 的 status 非 done，输出: $(printf '%s' "$show_out" | grep -i 'status' | head -3 | tr '\n' ' ')"
  fi
fi

# --- 2.P3: 终态推回微信 → 正证据双闸（2026-09-08 auto-fix 强化，替换 vacuous forensics 非空断言）---
# ① 卡存在订阅记录（notify-subscribe / 微信侧建卡 auto-subscribe 二者之一落地）
# ② forensics timeline 在卡终态窗口内存在 send_result ok=true（真实推送遥测）
# 微信侧内容人工确认（AI 整理形态）留编排器，此处只断机械可判的正证据。
sub_out="$("$HERMES_BIN" kanban notify-list "$TASK_ID" 2>&1)"
sub_rc=$?
p3_fail=""
if [[ $sub_rc -ne 0 || "$sub_out" == *"(no subscriptions)"* || -z "$sub_out" ]]; then
  p3_fail="卡 $TASK_ID 无订阅记录（notify-list: ${sub_out:0:120}）"
fi

completed_at="$("$HERMES_BIN" kanban show "$TASK_ID" --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin).get('task',{})
print(d.get('completed_at') or d.get('updated_at') or '')" 2>/dev/null)"
timeline_out="$("$HERMES_BIN" forensics timeline --since 6h 2>&1)"
send_hit="$(COMPLETED_AT="$completed_at" python3 - "$timeline_out" <<'PYIN'
import sys, os, re, datetime
cut = os.environ.get('COMPLETED_AT', '').strip()
# cut 可能是 epoch 秒（kanban completed_at）或 ISO 字符串——统一转 epoch 秒
if cut.isdigit():
    cut_epoch = int(cut)
elif cut:
    try:
        cut_epoch = int(datetime.datetime.fromisoformat(cut.replace(' ', 'T')[:19]).timestamp())
    except ValueError:
        cut_epoch = 0
else:
    cut_epoch = 0
hit = False
for line in sys.argv[1].splitlines():
    line = line.strip()
    if 'send_result' not in line:
        continue
    if '"ok":true' not in line.replace(' ', '') and 'ok=true' not in line:
        continue
    if not cut_epoch:
        hit = True
        break
    m = re.search(r'20\d\d-\d\d-\d\d[T ]\d\d:\d\d:\d\d', line)
    if m:
        try:
            ts = int(datetime.datetime.fromisoformat(m.group(0).replace(' ', 'T')).timestamp())
        except ValueError:
            continue
        if ts >= cut_epoch - 60:  # 宽容 60s 时钟偏移
            hit = True
            break
print('HIT' if hit else 'MISS')
PYIN
)"
if [[ "$send_hit" == "HIT" ]]; then
  :
else
  p3_fail="${p3_fail:+$p3_fail | }forensics timeline no send_result ok=true in terminal window (completed_at=$completed_at, got=$send_hit)"
fi

if [[ -z "$p3_fail" ]]; then
  pass "2.P3"
else
  fail "2.P3" "$p3_fail"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
