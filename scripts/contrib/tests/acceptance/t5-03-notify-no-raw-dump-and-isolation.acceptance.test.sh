#!/usr/bin/env bash
# =============================================================================
# t5-03-notify-no-raw-dump-and-isolation.acceptance.test.sh — T5 验收③：三路永不 raw dump + 零改动自证 + 隔离
#   R1  卡路（worker 只发摘要文件）：digest 卡 body 不含原始事件哨兵
#   R2  fallback 路（旧 _ai_digest → _send）：外发载荷不含原始事件哨兵/JSON 结构字段
#       （载荷=AI 摘要文本，实证摘要路径而非 raw 兜底）
#   R3  osascript 兜底路（3 败）：本地通知文案不含原始事件哨兵（机械提示文案）
#   R4  零改动自证：kanban_card.sh 对 HEAD diff 空 + porcelain 干净（接口不变量：建卡地基零改动）
#   R5  隔离：沙箱 notify-state approvals 零新增 + 真实仓 contrib-data/events.jsonl 零测试哨兵污染
# 依据：state.md「## 设计文档」§3 闸不变量：
#   「永不 raw dump：卡路（worker 只发摘要文件）/fallback 路（_ai_digest）/兜底路（osascript 文案）
#     三路均不产 raw dump」「kanban_card.sh 零改动」「L1 红线：测试全 stub + CONTRIB_DATA_DIR 隔离」
# CONTRACT_AMBIGUOUS：
#   - R2 用「卡 done+sent:false → fallback」构造 fallback 外发载荷（黑盒下最稳定的 fallback
#     入口）；建卡失败构造（STUB_HERMES_FAIL=1）下 _send 同败、载荷副本仍落但语义等价——不重复用例
# 红队纪律：黑盒；每断言硬失败；无 skip。Mental Mutation：卡 body 携带 raw 事件→R1 红；
#   fallback 摘要失败降级 raw dump→R2 红；osascript 文案带明细→R3 红；有人顺手改
#   kanban_card.sh→R4 红；隔离失效写真实仓→R5 红。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

# 各路独立哨兵（防跨用例串扰导致的假绿）
RAW_CARD='RAWTOKEN-CARD-1a'
RAW_FALL='RAWTOKEN-FALL-2b'
RAW_OSA='RAWTOKEN-OSA-3c'

mk_batch_file() { # <path> <sent> <key...> — 快照 fixture：JSONL 事件行+尾部 sent 控制行（同 t5-01 口径）
  local path="$1" sent="$2" k
  shift 2
  : > "$path"
  for k in "$@"; do
    printf '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"%s","channel":"contrib","summary":"s-%s","pushed":false,"attempts":0,"pushed_at":null}\n' "$k" "$k" >> "$path"
  done
  case "$sent" in
    true|false) printf '{"sent":%s,"reason":null,"sent_at":"2026-09-09T12:00:00+08:00","send_result":null}\n' "$sent" >> "$path" ;;
  esac
}

any_body_has() { # <needle> → bodies/ 全集是否有命中（0=无 1=有）
  local n
  n="$(grep -l -- "$1" "$SB_ROOT"/stublog/bodies/hermes-*.txt "$SB_ROOT"/stublog/bodies/osascript-*.txt 2>/dev/null | wc -l | tr -d ' ')"
  [ "$n" -ge 1 ] && return 0 || return 1
}

send_body() { stub_last_body hermes; }

# =============================================================================
t_case "R1 卡路无 raw dump：digest 卡 body 不含原始事件哨兵"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-card" "$RAW_CARD 原始叙事事件全文（含 rq-1/PR#2/日志行等细节）"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
BODYF="$(stub_last_body hermes)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  _pass "R1 卡 body 副本已捕获"
  if grep -qF "$RAW_CARD" "$BODYF"; then
    _fail "R1 卡路无 raw dump" "卡 body 含原始事件哨兵: $RAW_CARD -- body 只准带快照路径与规范"
  else
    _pass "R1 卡路无 raw dump"
  fi
else
  _fail "R1 卡 body 副本已捕获" "bodies/hermes-*.txt 无建卡载荷"
fi
sb_cleanup

# =============================================================================
t_case "R2 fallback 路无 raw dump：外发载荷=AI 摘要文本，无哨兵无 JSON 结构字段"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-fall" "$RAW_FALL 原始叙事事件全文（含 jq/日志行形态细节）"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-r2.json"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" false "k-fall"
jq -n --arg id t_old --arg bf "$BATCHF" --argjson ep "$(date +%s)" \
  '{kind:"digest",card_id:$id,batch_file:$bf,created_epoch:$ep}' \
  > "$SB_ROOT/contrib-data/kanban-flight-digest.json"
printf '{"id":"t_old","status":"done","assignee":"contrib","priority":0}\n' \
  > "$SB_ROOT/stublog/kanban-cards.jsonl"
sb_run -e STUB_KANBAN_CARD_STATUS=done 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
BODYF="$(send_body)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  _pass "R2 外发载荷副本已捕获"
  assert_contains "$(cat "$BODYF")" "claude stub ok" "R2 载荷=fallback 摘要产物（非 raw 兜底）"
  if grep -qF "$RAW_FALL" "$BODYF"; then
    _fail "R2 fallback 路无 raw dump" "外发载荷含原始事件哨兵 $RAW_FALL"
  else
    _pass "R2 fallback 路无 raw dump"
  fi
  assert_not_contains "$(cat "$BODYF")" '"summary"' "R2 载荷零 JSON 结构字段（summary）"
  assert_not_contains "$(cat "$BODYF")" '"class"' "R2 载荷零 JSON 结构字段（class）"
else
  _fail "R2 外发载荷副本已捕获" "bodies/hermes-*.txt 无 send 载荷（fallback 未发送？）"
fi
sb_cleanup

# =============================================================================
t_case "R3 osascript 兜底路无 raw dump：3 败通知文案为机械提示，无哨兵无明细"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-osa" "$RAW_OSA 原始叙事事件全文（三败兜底用例）" contrib 2
sb_run -e STUB_HERMES_FAIL=1 -e STUB_CLAUDE_FAIL=1 \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
OSAF="$(stub_last_body osascript)"
if [ -n "$OSAF" ] && [ -f "$OSAF" ]; then
  _pass "R3 osascript 文案副本已捕获"
  if grep -qF "$RAW_OSA" "$OSAF"; then
    _fail "R3 兜底路无 raw dump" "osascript 文案含原始事件哨兵 $RAW_OSA"
  else
    _pass "R3 兜底路无 raw dump"
  fi
  assert_contains "$(cat "$OSAF")" "contrib" "R3 文案为 contrib 机械提示（含域标识）"
  assert_not_contains "$(cat "$OSAF")" "rq-" "R3 文案零技术明细（rq-id 不当正文）"
else
  _fail "R3 osascript 文案副本已捕获" "3 败未触发 osascript 兜底"
fi
if any_body_has "$RAW_OSA"; then
  _fail "R3 全载荷哨兵终检" "任何外发载荷副本含 $RAW_OSA"
else
  _pass "R3 全载荷哨兵终检"
fi
sb_cleanup

# =============================================================================
t_case "R4 零改动自证：kanban_card.sh 对 HEAD diff 空 + porcelain 干净"
DIFF_OUT="$(git -C "$REPO_ROOT" diff --name-only HEAD -- scripts/contrib/kanban_card.sh)"
assert_eq "$DIFF_OUT" "" "R4 kanban_card.sh 对 HEAD 零 diff（接口不变量：建卡地基零改动）"
PORC_OUT="$(git -C "$REPO_ROOT" status --porcelain -- scripts/contrib/kanban_card.sh)"
assert_eq "$PORC_OUT" "" "R4 kanban_card.sh porcelain 干净（含 staged 态）"

# =============================================================================
t_case "R5 隔离：沙箱 approvals 零新增 + 真实仓账本零测试哨兵污染"
# 复用本文件此前多轮 flush 沙箱均 Approvals=0 的事实面，另起最小沙箱直证隔离底线
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-iso" "隔离直证事件 rq-iso"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_eq "$(jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?")" "0" \
  "R5 flush 全程 notify-state approvals 零新增"
if [ -f "$REPO_ROOT/contrib-data/events.jsonl" ]; then
  HIT="$(grep -c 'rq-iso' "$REPO_ROOT/contrib-data/events.jsonl" || true)"
  assert_eq "$HIT" "0" "R5 真实仓 contrib-data/events.jsonl 零测试污染"
else
  _pass "R5 真实仓 contrib-data/events.jsonl 不存在（零污染平凡真）"
fi
sb_cleanup

t_finish
