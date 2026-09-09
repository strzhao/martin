#!/bin/bash
# deepcheck-cardify.sh — Tier U：深检依赖卡链（T4）
# 覆盖：
#   ① run-watch 快车道建卡主路：gate rc10 → preflight 卡（flight-deepcheck 六键 / attempt 级幂等键 /
#     body 契约锚点 / budget reserve / TARGET_FILE 消费 / 零 claude / 状态推进交 worker）
#   ② run-deepcheck 09:37 入口两入口等价（同一 stub 断言集）
#   ③ 全局单深检：任一登记在飞 → 两入口一律跳过（零第二张卡 / 零 fallback claude / 零双 reserve）
#   ④ 建卡失败 → fallback deep-check.sh（claude 被调 + -deepcheck-card-fallback + refund 先行）
#   ⑤ 终态收割四态矩阵（done 链判定 / blocked 闭集 / stale / orphan）+ 子卡补查 + auto-gate 桥接
#   ⑥ probe 分叉（免红队不建子卡，body 无 --parent 模板）
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN/DEEPCHECK_TARGET_FILE stub 沙箱隔离，零真实调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "deepcheck-cardify.sh"

TODAY="$(date +%F)"

# ---- 通用工具 ----
count_create() {
  awk -F'|' '$1 == "hermes" && index($0, "kanban create") { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
count_claude_prompt() { # <prompt 子串>
  awk -F'|' -v s="$1" '$1 == "claude" && index($0, s) { c++ } END { printf "%d", c + 0 }' \
    "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null
}
ev_key_count() { # <key 后缀>（endswith 口径，日期段不钉死）
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}
deep_used() { # 今日 deep 预算 used
  jq -r --arg d "$TODAY" '.days[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo 0
}
rq_state_of() { # <id> → state
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null || echo ""
}
rq_history_events() { # <id> → history event 串
  jq -r --arg id "$1" '[.items[] | select(.id == $id) | .history[].event] | join(",")' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null || echo ""
}
seed_card_store() { # <card_id> <status>
  printf '{"id":"%s","status":"%s","assignee":"contrib","priority":0}\n' "$1" "$2" \
    >"$SB_ROOT/stublog/kanban-cards.jsonl"
}
seed_flight_dc() { # <card_id> <rq_id> <lane> <epoch>
  jq -n --arg id "$1" --arg rq "$2" --arg lane "$3" --argjson e "$4" \
    '{kind:"deepcheck",card_id:$id,rq_id:$rq,lane:$lane,batch_file:"",created_epoch:$e}' \
    >"$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"
}

# ---- 沙箱预备 ----
quiet_sb() { # 新沙箱 + scan/mail/radar 全静默
  sb_new >/dev/null 2>&1
  mkdir -p "$SB_ROOT/mailstub"
  printf '[]\n' >"$SB_ROOT/mailstub/envelopes.json"
  printf '[]\n' >"$SB_ROOT/gh-issues.json"
  printf '{"last_issue":9000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
}
run_watch() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"; extra[${#extra[@]}]="$kv"
  done
  sb_run -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" \
    -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    ${extra[@]+"${extra[@]}"} \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}
run_dc() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"; extra[${#extra[@]}]="$kv"
  done
  sb_run -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" \
    -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    ${extra[@]+"${extra[@]}"} \
    'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
}
run_helper() { # <harvest|create> [kv ...]
  local sub="$1"; shift
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"; extra[${#extra[@]}]="$kv"
  done
  sb_run ${extra[@]+"${extra[@]}"} \
    "bash \"\$MARTIN_DIR/scripts/contrib/deepcheck_card.sh\" $sub" >/dev/null 2>&1
}
wait_for() { # <secs> <jq 条件（作用于 ready-queue）> — nohup fallback 异步收口轮询
  local secs="$1" cond="$2" i=0
  while (( i < secs * 4 )); do
    if jq -e "$cond" "$SB_ROOT/contrib-data/ready-queue.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
dc_flight() { printf '%s/contrib-data/kanban-flight-deepcheck.json' "$SB_ROOT"; }

# ================= ① run-watch 快车道建卡主路 =================

t_case "watch 建卡: gate rc10 → preflight 卡 + flight 六键 + attempt 级幂等键 + reserve + TARGET_FILE 消费 + 零 claude"
quiet_sb
sb_seed_queue_item "rq-20260909-5001" 5001 deep queued 40
run_watch
assert_exit 0 $?
F="$(dc_flight)"
assert_eq "$(jq -r '.kind // empty' "$F" 2>/dev/null)" "deepcheck" "flight kind=deepcheck"
case "$(jq -r '.card_id // empty' "$F" 2>/dev/null)" in t_stub_*) _pass "flight card_id 登记" ;; *) _fail "flight card_id 登记" "缺" ;; esac
assert_eq "$(jq -r '.rq_id // empty' "$F" 2>/dev/null)" "rq-20260909-5001" "flight rq_id"
assert_eq "$(jq -r '.lane // empty' "$F" 2>/dev/null)" "deep" "flight lane"
assert_eq "$(jq -r '.batch_file // empty' "$F" 2>/dev/null)" "" "flight batch_file 空串占位"
assert_eq "$(jq -r '.created_epoch > 0' "$F" 2>/dev/null)" "true" "flight created_epoch"
assert_contains "$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)" \
  "--idempotency-key deepcheck-rq-20260909-5001-" "attempt 级幂等键 deepcheck-<rq-id>-<epoch>"
assert_contains "$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)" \
  "深检 preflight rq-20260909-5001" "卡 title 含 rq-id"
assert_eq "$(deep_used)" "1" "budget reserve（编排层）"
assert_eq "$(rq_state_of "rq-20260909-5001")" "queued" "状态推进交 worker 卡内（编排层不 set deep-check）"
[[ -f "$SB_ROOT/locks/deepcheck-target" ]] && _fail "TARGET_FILE 已消费（I5 幽灵防残留）" "文件残留" \
  || _pass "TARGET_FILE 已消费（I5 幽灵防残留）"
assert_eq "$(count_claude_prompt 'contrib-watch deep-check')" "0" "主路零 claude"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] || _fail "卡 body 可捕获" "stub bodies 缺副本"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "SKILL.md" "body 含 SKILL.md 模式四权威"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "runs/deep-check/rq-20260909-5001/preflight.md" "body 含 preflight 产出契约"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "pending/rq-20260909-5001.md" "body 含草稿 v2 契约"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "verdict.json" "body 含 verdict 契约"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "--parent" "body 含 redteam 自建子卡 --parent 模板"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "--assignee contrib" "redteam 模板必含 --assignee contrib（审查 I2）"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "fresh-context" "body 含 fresh-context 铁律"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "budget reserve/refund 为编排层专属" "worker 禁碰 budget（审查 I4）"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "rq.sh 授权仅限 set/list/show" "worker 授权边界（审查 I4）"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "rq.sh set rq-20260909-5001 deep-check" "body 含状态推进指示"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban_complete" "body 含收尾双传"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "python -c" "body 含 -q 禁脚本形态红线"

t_case "watch 建卡: 幂等键为 attempt 级（<rq-id>-<10 位 epoch> 形态，非日期分秒形态）"
create_line="$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)"
assert_contains "$create_line" "deepcheck-rq-20260909-5001-17" "key 含 rq-id + epoch 前缀（17 开头 epoch）"

# ================= ② run-deepcheck 入口等价 =================

t_case "run-deepcheck 等价: gate rc10 → 同一 stub 断言集（六键/幂等键/reserve/零 claude）"
quiet_sb
sb_seed_queue_item "rq-20260909-5002" 5002 deep queued 40
run_dc
assert_exit 0 $?
F="$(dc_flight)"
assert_eq "$(jq -r '.kind // empty' "$F" 2>/dev/null)" "deepcheck" "flight kind=deepcheck"
assert_eq "$(jq -r '.rq_id // empty' "$F" 2>/dev/null)" "rq-20260909-5002" "flight rq_id"
assert_eq "$(jq -r '.lane // empty' "$F" 2>/dev/null)" "deep" "flight lane"
assert_eq "$(jq -r '.batch_file // empty' "$F" 2>/dev/null)" "" "batch_file 空串"
assert_contains "$(awk -F'|' '$1 == "hermes" && index($0, "kanban create") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)" \
  "--idempotency-key deepcheck-rq-20260909-5002-" "attempt 级幂等键"
assert_eq "$(deep_used)" "1" "budget reserve"
assert_eq "$(count_claude_prompt 'contrib-watch deep-check')" "0" "主路零 claude"
[[ -f "$SB_ROOT/locks/deepcheck-target" ]] && _fail "TARGET_FILE 已消费" "残留" || _pass "TARGET_FILE 已消费"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "--parent" "body 含 --parent 模板（等价）"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "SKILL.md" "body 含 SKILL 权威（等价）"

# ================= ③ 全局单深检（两入口在飞跳过）=================

t_case "在飞跳过: 登记在飞（不同 rq-id 亦然）→ 两入口零第二张卡/零 fallback claude/零双 reserve"
quiet_sb
sb_seed_queue_item "rq-20260909-5003" 5003 deep queued 40
seed_flight_dc "t_old" "rq-20260909-4999" "deep" "$(date +%s)"
seed_card_store "t_old" "running"
run_watch
assert_exit 0 $?
assert_eq "$(count_create)" "0" "watch: 在飞不建第二张卡"
assert_eq "$(count_claude_prompt 'contrib-watch deep-check')" "0" "watch: 在飞零 fallback claude"
assert_eq "$(deep_used)" "0" "watch: 在飞零 reserve（防双 reserve）"
assert_eq "$(jq -r '.card_id // empty' "$(dc_flight)" 2>/dev/null)" "t_old" "登记保留"
run_dc
assert_exit 0 $?
assert_eq "$(count_create)" "0" "run-deepcheck: 在飞零第二张卡"
assert_eq "$(count_claude_prompt 'contrib-watch deep-check')" "0" "run-deepcheck: 10=绝不 fallback（设计钉死①）"
assert_eq "$(deep_used)" "0" "run-deepcheck: 在飞零 reserve"
assert_eq "$(jq -r '.card_id // empty' "$(dc_flight)" 2>/dev/null)" "t_old" "登记保留"

# ================= ④ 建卡失败 → fallback =================

t_case "watch 建卡失败: fallback deep-check.sh 被调（claude）+ -deepcheck-card-fallback + refund 先行"
quiet_sb
sb_config_set '.refund_failed_deep_check = true'
sb_seed_queue_item "rq-20260909-5004" 5004 deep queued 40
run_watch "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(ev_key_count '-deepcheck-card-fallback')" "1" "-deepcheck-card-fallback 入账（建卡失败分支）"
if wait_for 20 '.items[] | select(.id == "rq-20260909-5004") | .state == "awaiting-approval"'; then
  _pass "fallback deep-check.sh 编排收口（awaiting-approval）"
else
  _fail "fallback deep-check.sh 编排收口" "20s 内未到 awaiting-approval（state=$(rq_state_of rq-20260909-5004)）"
fi
[[ "$(count_claude_prompt 'contrib-watch deep-check')" -ge 1 ]] \
  && _pass "fallback claude 被调（仅此一次路）" \
  || _fail "fallback claude 被调" "零调用"
assert_eq "$(deep_used)" "1" "refund 先行（create 失败 refund 后 fallback 再 reserve——单轮不双计）"
[[ -f "$SB_ROOT/locks/deepcheck-target" ]] && _fail "TARGET_FILE 被 fallback 消费" "残留" \
  || _pass "TARGET_FILE 被 fallback 消费（deep-check.sh:66 对称）"

t_case "run-deepcheck 建卡失败: 同样 fallback claude 编排壳（两入口等价）"
quiet_sb
sb_config_set '.refund_failed_deep_check = true'
sb_seed_queue_item "rq-20260909-5005" 5005 probe queued 40
run_dc "STUB_HERMES_FAIL=1"
assert_exit 0 $?
assert_eq "$(ev_key_count '-deepcheck-card-fallback')" "1" "-deepcheck-card-fallback 入账"
if wait_for 20 '.items[] | select(.id == "rq-20260909-5005") | .state != "queued"'; then
  _pass "fallback 编排推进状态（claude 壳执行）"
else
  _fail "fallback 编排推进状态" "state=$(rq_state_of rq-20260909-5005)"
fi
[[ "$(count_claude_prompt 'contrib-watch deep-check')" -ge 1 ]] \
  && _pass "fallback claude 被调" || _fail "fallback claude 被调" "零调用"

# ================= ⑤ 终态收割矩阵（direct helper）=================

t_case "harvest: done+awaiting-approval+verdict auto → 编排层 auto-gate rc0 → approved（L2-auto 桥接保留，复刻 deep-check.sh:177-182）"
quiet_sb
sb_seed_queue_item "rq-20260909-5101" 5101 deep awaiting-approval 40
mkdir -p "$SB_ROOT/contrib-data/runs/deep-check/rq-20260909-5101"
printf '{"decision":"auto","confidence":"high","risk_level":"low","reasons":[]}\n' \
  >"$SB_ROOT/contrib-data/runs/deep-check/rq-20260909-5101/verdict.json"
seed_flight_dc "t_old" "rq-20260909-5101" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest
assert_exit 0 $?
assert_contains "$(rq_history_events "rq-20260909-5101")" "approved" "rq set approved（auto-gate rc0）"
[[ ! -f "$(dc_flight)" ]] && _pass "链收尾完成登记已清" || _fail "登记已清" "残留"
# state 断言：execute.sh 确定性执行链在沙箱内经 gh stub TTL 复验失败转 failed 属合法下游行为；
# 桥接本身由 history 的 approved 事件钉住（awaiting-approval 停滞 = 桥接缺失）
case "$(rq_state_of "rq-20260909-5101")" in
  approved|failed) _pass "state 已离开 awaiting-approval（桥接推进）" ;;
  *) _fail "state 已离开 awaiting-approval" "actual=$(rq_state_of rq-20260909-5101)" ;;
esac

t_case "harvest: done+awaiting-approval+verdict escalate → 维持人工路（不 approved）+ 登记清"
quiet_sb
sb_seed_queue_item "rq-20260909-5102" 5102 deep awaiting-approval 40
mkdir -p "$SB_ROOT/contrib-data/runs/deep-check/rq-20260909-5102"
printf '{"decision":"escalate","confidence":"medium","risk_level":"medium","reasons":["拿不准"]}\n' \
  >"$SB_ROOT/contrib-data/runs/deep-check/rq-20260909-5102/verdict.json"
seed_flight_dc "t_old" "rq-20260909-5102" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest
assert_exit 0 $?
assert_not_contains "$(rq_history_events "rq-20260909-5102")" "approved" "非 0 → 维持 awaiting-approval"
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清（人工路照常走审批推送链）" || _fail "登记已清" "残留"

t_case "harvest: done+deep-check+子卡 blocked → rq failed + refund + -deepcheck-stale（链悬挂收口）"
quiet_sb
sb_config_set '.refund_failed_deep_check = true'
sb_seed_queue_item "rq-20260909-5103" 5103 deep deep-check 40
sb_rq budget reserve "rq-20260909-5103" --lane deep >/dev/null 2>&1
assert_eq "$(deep_used)" "1" "前置：reserve 已占额"
seed_flight_dc "t_old" "rq-20260909-5103" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest "STUB_KANBAN_STATUS_MAP={\"t_old\":\"done\",\"t_child\":\"blocked\"}" \
  "STUB_KANBAN_CHILDREN=[\"t_child\"]"
assert_exit 0 $?
assert_eq "$(rq_state_of "rq-20260909-5103")" "failed" "子卡 blocked → rq set failed"
assert_eq "$(deep_used)" "0" "refund（编排层，幂等口径）"
assert_eq "$(ev_key_count '-deepcheck-stale')" "1" "-deepcheck-stale 入账"
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清" || _fail "登记已清" "残留"

t_case "harvest: done+deep-check+子卡在跑 → 保留登记（不误杀链）"
quiet_sb
sb_seed_queue_item "rq-20260909-5104" 5104 deep deep-check 40
seed_flight_dc "t_old" "rq-20260909-5104" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest "STUB_KANBAN_STATUS_MAP={\"t_old\":\"done\",\"t_child\":\"running\"}" \
  "STUB_KANBAN_CHILDREN=[\"t_child\"]"
assert_exit 0 $?
assert_eq "$(jq -r '.card_id // empty' "$(dc_flight)" 2>/dev/null)" "t_old" "登记保留"
assert_eq "$(rq_state_of "rq-20260909-5104")" "deep-check" "状态不动"

t_case "harvest: done+deep-check+子卡未建 → 保留登记（stale 24h 兜底，实现注③）"
quiet_sb
sb_seed_queue_item "rq-20260909-5105" 5105 deep deep-check 40
seed_flight_dc "t_old" "rq-20260909-5105" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest "STUB_KANBAN_STATUS_MAP={\"t_old\":\"done\"}"
assert_exit 0 $?
assert_eq "$(jq -r '.card_id // empty' "$(dc_flight)" 2>/dev/null)" "t_old" "登记保留（worker 漏 set 由 stale 兜底）"

t_case "harvest: done+failed → 清登记 + refund 幂等"
quiet_sb
sb_config_set '.refund_failed_deep_check = true'
sb_seed_queue_item "rq-20260909-5106" 5106 deep failed 40
sb_rq budget reserve "rq-20260909-5106" --lane deep >/dev/null 2>&1
seed_flight_dc "t_old" "rq-20260909-5106" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest
assert_exit 0 $?
assert_eq "$(deep_used)" "0" "refund"
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清" || _fail "登记已清" "残留"

t_case "harvest: done+队列项查无 → 清登记 + -deepcheck-orphan"
quiet_sb
seed_flight_dc "t_old" "rq-20260909-5107" "deep" "$(date +%s)"
seed_card_store "t_old" "done"
run_helper harvest
assert_exit 0 $?
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清" || _fail "登记已清" "残留"
assert_eq "$(ev_key_count '-deepcheck-orphan')" "1" "-deepcheck-orphan 入账（人工复核）"

t_case "harvest: blocked+outcome 闭集 → rq failed + refund + -deepcheck-card-fallback；非闭集保留"
quiet_sb
sb_config_set '.refund_failed_deep_check = true'
sb_seed_queue_item "rq-20260909-5108" 5108 deep deep-check 40
sb_rq budget reserve "rq-20260909-5108" --lane deep >/dev/null 2>&1
seed_flight_dc "t_old" "rq-20260909-5108" "deep" "$(date +%s)"
seed_card_store "t_old" "blocked"
run_helper harvest "STUB_KANBAN_STATUS_MAP={\"t_old\":\"blocked\"}" "STUB_KANBAN_RUN_OUTCOME=gave_up"
assert_exit 0 $?
assert_eq "$(rq_state_of "rq-20260909-5108")" "failed" "重试耗尽 → failed"
assert_eq "$(deep_used)" "0" "refund"
assert_eq "$(ev_key_count '-deepcheck-card-fallback')" "1" "卡路失败事件入账"
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清" || _fail "登记已清" "残留"
# 非闭集 outcome → 保留
seed_card_store "t_old2" "blocked"
seed_flight_dc "t_old2" "rq-20260909-5108" "deep" "$(date +%s)"
run_helper harvest "STUB_KANBAN_STATUS_MAP={\"t_old2\":\"blocked\"}" "STUB_KANBAN_RUN_OUTCOME=completed"
assert_eq "$(jq -r '.card_id // empty' "$(dc_flight)" 2>/dev/null)" "t_old2" "非重试耗尽 → 保留登记"

t_case "harvest: 非终态超 DEEPCHECK_STALE_SECS（独立 24h 阈值，缺省不复用 6h）→ 清 + failed + -deepcheck-stale"
quiet_sb
sb_config_set '.refund_failed_deep_check = true'
sb_seed_queue_item "rq-20260909-5109" 5109 deep deep-check 40
sb_rq budget reserve "rq-20260909-5109" --lane deep >/dev/null 2>&1
seed_flight_dc "t_old" "rq-20260909-5109" "deep" "$(( $(date +%s) - 90000 ))"
seed_card_store "t_old" "running"
run_helper harvest
assert_exit 0 $?
assert_eq "$(rq_state_of "rq-20260909-5109")" "failed" "陈旧 → failed"
assert_eq "$(deep_used)" "0" "refund"
assert_eq "$(ev_key_count '-deepcheck-stale')" "1" "-deepcheck-stale 入账"
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清" || _fail "登记已清" "残留"

t_case "harvest: 非终态未超阈值（seam=86400 缺省）→ 保留登记"
quiet_sb
sb_seed_queue_item "rq-20260909-5110" 5110 deep deep-check 40
seed_flight_dc "t_old" "rq-20260909-5110" "deep" "$(( $(date +%s) - 3600 ))"
seed_card_store "t_old" "running"
run_helper harvest
assert_exit 0 $?
assert_eq "$(jq -r '.card_id // empty' "$(dc_flight)" 2>/dev/null)" "t_old" "登记保留"

t_case "harvest: 卡查无终态（archived/清理）→ 清 + failed + -deepcheck-orphan"
quiet_sb
sb_seed_queue_item "rq-20260909-5111" 5111 deep deep-check 40
seed_flight_dc "t_old" "rq-20260909-5111" "deep" "$(date +%s)"
run_helper harvest "STUB_KANBAN_LIST_EMPTY=1"
assert_exit 0 $?
assert_eq "$(rq_state_of "rq-20260909-5111")" "failed" "查无视同失败终态收口"
assert_eq "$(ev_key_count '-deepcheck-orphan')" "1" "-deepcheck-orphan 入账"
[[ ! -f "$(dc_flight)" ]] && _pass "登记已清" || _fail "登记已清" "残留"

# ================= ⑥ probe 分叉 =================

t_case "probe 分叉: probe 车道 body 免红队不建子卡（无 --parent 模板）+ probe 预算车道"
quiet_sb
sb_seed_queue_item "rq-20260909-5201" 5201 probe queued 40
run_watch
assert_exit 0 $?
assert_eq "$(jq -r '.lane // empty' "$(dc_flight)" 2>/dev/null)" "probe" "flight lane=probe"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "免红队" "body 含免红队分叉"
[[ -n "$body_copy" ]] && assert_not_contains "$(cat "$body_copy")" "--parent" "probe 不建子卡（无模板）"
probe_used="$(jq -r --arg d "$TODAY" '.probes[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo 0)"
assert_eq "$probe_used" "1" "probe 车道 reserve"

t_finish
