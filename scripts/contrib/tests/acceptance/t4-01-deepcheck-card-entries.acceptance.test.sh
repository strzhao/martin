#!/usr/bin/env bash
# =============================================================================
# t4-01-deepcheck-card-entries.acceptance.test.sh — T4 验收①：deep-check 双入口建卡契约等价
#   E1  run-deepcheck 入口（09:37 兜底）：gate rc10 → 建卡主路全契约
#       （hermes create 参数 / 卡 body 契约 / flight 登记 schema / budget reserve /
#        TARGET_FILE 消费 / rq 状态不被编排层动 / 零 claude / 零 fallback 事件）
#   E2  run-watch 快车道入口：同一 stub 断言集复跑 → 全契约等价
#   E3  两入口建卡 argv+body 归一化（卡 id/epoch/时间戳占位后）逐字节等价
#   E4  probe 车道分叉：body 含免红队指示、零 --parent 子卡模板、worker 自写 verdict 指示
#   E5  attempt 级 idempotency-key：同 rq-id 两次建卡 → key 必含 rq-id 且 epoch 每次更新
# 依据：state.md「## 设计文档」§1 create_deepcheck_card / §3 两入口 / §契约规约（本任务级）：
#   「两入口等价（同 stub 断言集）；flight 登记 kanban-flight-deepcheck.json schema = scan 四键
#    + rq_id/lane（batch_file 空串）；idempotency-key = deepcheck-<rq-id>-<attempt-epoch>；
#    TARGET_FILE 建卡主路成功后 rm；queued→deep-check 由 worker 卡内做（编排层不碰）」
# CONTRACT_AMBIGUOUS：
#  - --kind deepcheck 是 kanban_card.sh 内部参数（不出现在 hermes argv）——以幂等键 deepcheck-
#    前缀 + flight.kind=deepcheck 双代理断言
#  - 卡 title 全角括号内 lane 子格式未钉死——只断言「深检 preflight」+ rq-id 出现
#  - body 内 lane 字样无独立格式——以「独立词 deep（非 deep-check 组成部分）」正则代理
# 红队纪律：黑盒（未读 run-watch.sh / run-deepcheck.sh / kanban_card.sh 本次改动 / SKILL.md 新段）；
#   每断言硬失败；无 skip。Mental Mutation：主路改 fallback → E1/E2 零 claude 挂；body 删
#   parent 指示/fresh-context/verdict 契约 → E1 body 断言挂；probe 分叉丢失 → E4 挂；attempt
#   key 退化固定 key → E5 两 key 相等挂；TARGET_FILE 不消费 → E1 残留断言挂；编排层代 set
#   deep-check → E1 rq set==0 挂。
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

# ---- 本文件专用装具 ----

install_rq_recorder() { # rq.sh 调用记录器（透传真身）：观察 reserve/refund/set 的调用与顺序
  mv "$SB_ROOT/scripts/contrib/rq.sh" "$SB_ROOT/scripts/contrib/rq-real.sh"
  cat > "$SB_ROOT/scripts/contrib/rq.sh" <<'EOF'
#!/bin/bash
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -n "$LOG_DIR" ]]; then
  line="rq|$PWD|"
  first=1
  for a in "$@"; do
    if [[ $first -eq 0 ]]; then line="$line "; fi
    line="$line${a//$'\n'/ }"
    first=0
  done
  printf '%s\n' "$line" >>"$LOG_DIR/calls.log"
fi
if [[ "${STUB_RQ_RESERVE_FAIL:-}" == "1" && "${1:-}" == "budget" && "${2:-}" == "reserve" ]]; then
  echo "DENY day-limit"
  exit 1
fi
exec bash "${MARTIN_DIR:?}/scripts/contrib/rq-real.sh" "$@"
EOF
  chmod +x "$SB_ROOT/scripts/contrib/rq.sh"
}

install_fake_date() { # 沙箱 date stub：仅劫持裸 '+%H'（radar 窗口消除），其余透传
  mkdir -p "$SB_HOME/.local/bin"
  cat > "$SB_HOME/.local/bin/date" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "+%H" && "$#" -eq 1 ]]; then
  printf '%s\n' "${STUB_DATE_HOUR:-14}"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$SB_HOME/.local/bin/date"
}

seed_item() { # <id> <issue> <lane> <state>
  sb_seed_queue_item "$1" "$2" "$3" "$4"
}

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
rq_lines()     { grep '^rq|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_span()  { awk '/^hermes\|/{f=($0 ~ /kanban create/)} f' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }

create_calls_for() { hermes_lines | grep -c -- "--idempotency-key deepcheck-$1-" || true; }
claude_calls()     { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c -- "$1" || true; }
rq_set_calls()     { rq_lines | grep -c ' set ' || true; }

create_body_file() { # deepcheck 建卡调用的 --body 副本路径（hermes stub 契约：bodies/hermes-<seq>.txt）
  local n
  n="$(awk '/^hermes\|/{c++; if ($0 ~ /--idempotency-key deepcheck-/) {print c; exit}}' "$SB_ROOT/stublog/calls.log")"
  if [[ -n "$n" && -f "$SB_ROOT/stublog/bodies/hermes-$n.txt" ]]; then
    printf '%s/stublog/bodies/hermes-%s.txt' "$SB_ROOT" "$n"
  fi
  return 0
}

events_with()      { grep -c -- "$1" "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true; }
notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }
budget_deep_used() { jq -r --arg d "$(date +%F)" '.days[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo "?"; }
budget_probe_used() { jq -r --arg d "$(date +%F)" '.probes[$d].used // 0' "$SB_ROOT/contrib-data/budget.json" 2>/dev/null || echo "?"; }
rq_state_of() {
  jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null || echo "?"
}

assert_grep() { # <haystack> <ERE> [label]
  if printf '%s' "$1" | grep -qE -- "$2"; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "未匹配 /$2/"
  fi
}
assert_not_grep() { # <haystack> <ERE> [label]
  if printf '%s' "$1" | grep -qE -- "$2"; then
    _fail "${3:-}" "不应匹配却匹配 /$2/"
  else
    _pass "${3:-}"
  fi
}
assert_file_grep() { # <file> <ERE> [label]
  if [[ ! -f "$1" ]]; then
    _fail "${3:-}" "文件缺失: $1"
    return 0
  fi
  if grep -qE -- "$2" "$1"; then
    _pass "${3:-}"
  else
    _fail "${3:-}" "文件未匹配 /$2/"
  fi
}

norm_stream() { # <$1=SB_ROOT> 卡 id / attempt epoch / 时间戳 / 沙箱绝对路径占位化（等价比较归一化层）
  sed -E -e "s#$1#SB#g" \
    -e 's/t_stub_[0-9]+/CARD/g; s/[0-9]{10,}/1757400000/g; s/[0-9]{8}-[0-9]{6}/TS/g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(:[0-9]{2})?/DT/g'
}

# assert_full_card_contract <label> <rq_id> <lane> — 双入口共用的主路成功态断言集
assert_full_card_contract() {
  local L="$1" ID="$2" LANE="$3" SPAN BODYF DCF EP
  SPAN="$(create_span)"
  assert_eq "$(create_calls_for "$ID")" "1" "$L 恰 1 次 deepcheck 建卡"
  assert_eq "$(claude_calls claude)" "0" "$L 主路零 claude（fallback 保留但不在主路触发）"
  assert_grep "$SPAN" "kanban create" "$L 调用形态=hermes kanban create"
  assert_grep "$SPAN" "--assignee contrib" "$L 建卡带 --assignee contrib（I2 防错轨）"
  assert_grep "$SPAN" "--json" "$L 建卡带 --json（解析卡 id 契约）"
  assert_grep "$SPAN" "--max-retries 2" "$L 建卡带 --max-retries 2"
  assert_grep "$SPAN" "--idempotency-key deepcheck-$ID-[0-9]+" "$L 幂等键=deepcheck-<rq-id>-<attempt-epoch>"
  assert_grep "$SPAN" "深检 preflight" "$L 卡 title 前缀（设计 §1）"
  assert_grep "$SPAN" "$ID" "$L title/argv 携带 rq-id"

  BODYF="$(create_body_file)"
  if [[ -n "$BODYF" && -f "$BODYF" ]]; then
    _pass "$L 卡 body 副本可得"
    assert_file_grep "$BODYF" "$ID" "$L body 含 rq-id"
    assert_file_grep "$BODYF" "(^|[^-a-zA-Z])$LANE([^a-zA-Z-]|$)" "$L body 含 lane 独立词"
    assert_file_grep "$BODYF" "SKILL.md" "$L body 引用 SKILL.md 权威路径"
    assert_file_grep "$BODYF" "模式四" "$L body 引用 SKILL 模式四"
    assert_file_grep "$BODYF" "preflight.md" "$L body 含 preflight 产出契约文件名"
    assert_file_grep "$BODYF" "runs/deep-check/$ID" "$L body 含产出目录路径"
    assert_file_grep "$BODYF" "--parent" "$L body 含 redteam 子卡 --parent 关联指示"
    assert_file_grep "$BODYF" "--assignee contrib" "$L redteam 命令模板含 --assignee contrib（I2）"
    assert_file_grep "$BODYF" "fresh-context" "$L body 含 fresh-context 铁律"
    assert_file_grep "$BODYF" "verdict.json" "$L body 含 verdict.json 契约"
    assert_file_grep "$BODYF" "decision" "$L verdict 契约含 decision 键"
    assert_file_grep "$BODYF" "escalate" "$L verdict 契约含 escalate 值（原文）"
    assert_file_grep "$BODYF" "awaiting-approval" "$L body 含 rq set awaiting-approval 指示"
    assert_file_grep "$BODYF" "set .*deep-check" "$L body 含 rq set deep-check 指示"
    assert_file_grep "$BODYF" "只读" "$L 红线段：gh 只读"
    assert_file_grep "$BODYF" "gh" "$L 红线段提及 gh"
    assert_file_grep "$BODYF" "python -c|jq -e|-e/-c" "$L 红线段：-q 禁脚本执行形态"
    assert_file_grep "$BODYF" "refund|返还" "$L 授权边界：budget refund 编排层专属（卡内禁碰）"
    assert_file_grep "$BODYF" "rq\\.sh|rq set" "$L 授权边界：rq.sh 仅限 set 本项"
    assert_file_grep "$BODYF" "kanban_complete" "$L 收尾要求：kanban_complete"
    assert_file_grep "$BODYF" "summary" "$L 收尾双传：summary"
    assert_file_grep "$BODYF" "result" "$L 收尾双传：result"
  else
    _fail "$L 卡 body 副本可得" "hermes stub 未捕获 --body 副本（建卡未带 body？）"
  fi

  DCF="$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"
  if [[ -s "$DCF" ]]; then
    _pass "$L flight 登记存在（kanban-flight-deepcheck.json）"
    assert_eq "$(jq -r 'keys | join(",")' "$DCF" 2>/dev/null)" \
      "batch_file,card_id,created_epoch,kind,lane,rq_id" \
      "$L flight schema = scan 四键 + rq_id/lane（精确键集，jq keys 字母序）"
    assert_eq "$(jq -r '.kind' "$DCF" 2>/dev/null)" "deepcheck" "$L flight.kind=deepcheck"
    assert_eq "$(jq -r '.rq_id' "$DCF" 2>/dev/null)" "$ID" "$L flight.rq_id"
    assert_eq "$(jq -r '.lane' "$DCF" 2>/dev/null)" "$LANE" "$L flight.lane"
    assert_eq "$(jq -r '.batch_file' "$DCF" 2>/dev/null)" "" "$L flight.batch_file 空串占位（T3 口径）"
    assert_eq "$(jq -r '.card_id' "$DCF" 2>/dev/null | grep -c '^t_stub_')" "1" "$L flight.card_id=新建卡 id"
    EP="$(jq -r '.created_epoch' "$DCF" 2>/dev/null)"
    case "$EP" in ''|*[!0-9]*) _fail "$L created_epoch 数值" "实得 [$EP]" ;; *) [ "$EP" -gt 0 ] && _pass "$L created_epoch>0" || _fail "$L created_epoch>0" "实得 $EP" ;; esac
  else
    _fail "$L flight 登记存在" "建卡成功未写 kanban-flight-deepcheck.json"
  fi

  if [[ -e "$SB_ROOT/locks/deepcheck-target" ]]; then
    _fail "$L TARGET_FILE 建卡成功后消费（rm）" "残留（跨轮幽灵建卡隐患，审查 I5）"
  else
    _pass "$L TARGET_FILE 建卡成功后消费（rm）"
  fi

  assert_eq "$(rq_state_of "$ID")" "queued" "$L rq 状态保持 queued（queued→deep-check 由 worker 卡内做）"
  assert_eq "$(rq_set_calls)" "0" "$L 编排层零 rq set（状态迁移授权边界）"
  assert_eq "$(events_with "-deepcheck-card-fallback")" "0" "$L 零 card-fallback 事件"
  assert_eq "$(events_with "-deepcheck-stale")" "0" "$L 零 stale 事件"
  assert_eq "$(events_with "-deepcheck-orphan")" "0" "$L 零 orphan 事件"
  assert_eq "$(notify_approvals)" "0" "$L notify-state approvals 零新增"
}

run_deepcheck_entry() { sb_run 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"'; }
run_watch_entry()     { sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json" \
                          'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"'; }

common_setup() { # 沙箱 + rq 记录器 + gh 空命中 + date 影子（radar 窗口消除）
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  install_rq_recorder
  install_fake_date
  printf '[]\n' > "$SB_ROOT/tmp/issues.json"
}

# =============================================================================
t_case "E1 run-deepcheck 入口（09:37 兜底）gate rc10 → 建卡主路全契约（deep 车道）"
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "E1 run-deepcheck exit"
assert_full_card_contract "E1" "rq-20260909-101" "deep"
assert_eq "$(budget_deep_used)" "1" "E1 budget reserve 已占额（deep 当日 1 次）"
assert_eq "$(budget_probe_used)" "0" "E1 probe 预算零消耗"
SPAN1="$(create_span | norm_stream "$SB_ROOT")"
BODYF1="$(create_body_file)"
BODY1=""
[ -n "$BODYF1" ] && BODY1="$(norm_stream "$SB_ROOT" < "$BODYF1")"
FLIGHT1="$(norm_stream "$SB_ROOT" < "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json")"
sb_cleanup

# =============================================================================
t_case "E2 run-watch 快车道入口：同一 stub 断言集 → 全契约等价"
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_watch_entry >/dev/null; RC=$?
assert_exit 0 $RC "E2 run-watch exit"
assert_full_card_contract "E2" "rq-20260909-101" "deep"
sb_cleanup

# =============================================================================
t_case "E3 两入口建卡 argv+body 归一化后逐字节等价（同一建卡函数的黑盒证据）"
assert_contains "$SPAN1" "kanban create" "E3 前置：E1 快照含建卡调用"
assert_contains "$SPAN1" "--idempotency-key deepcheck-rq-20260909-101-1757400000" "E3 前置：epoch 已占位化"
case "$BODY1" in
  "") _fail "E3 前置：body 快照非空" "E1 body 快照为空" ;;
  *)  _pass "E3 前置：body 快照非空" ;;
esac
common_setup
seed_item "rq-20260909-101" 101 deep queued
run_watch_entry >/dev/null
SPAN2="$(create_span | norm_stream "$SB_ROOT")"
BODYF2="$(create_body_file)"
BODY2=""
[ -n "$BODYF2" ] && BODY2="$(norm_stream "$SB_ROOT" < "$BODYF2")"
sb_cleanup
assert_eq "$SPAN1" "$SPAN2" "E3 两入口建卡 argv 逐字节等价（归一化后）"
assert_eq "$BODY1" "$BODY2" "E3 两入口卡 body 逐字节等价（归一化后）"
FLIGHT_KIND="$(printf '%s' "$FLIGHT1" | jq -r '.kind // "?"' 2>/dev/null)"
assert_eq "$FLIGHT_KIND" "deepcheck" "E3 E1 flight 快照可复核（kind 保留）"

# =============================================================================
t_case "E4 probe 车道分叉：body 免红队指示、零 --parent 子卡模板、worker 自写 verdict 指示"
common_setup
seed_item "rq-20260909-202" 202 probe queued
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "E4 run-deepcheck exit"
assert_eq "$(create_calls_for "rq-20260909-202")" "1" "E4 probe 候选同样建卡（单轮 preflight 卡）"
BODYF="$(create_body_file)"
if [[ -n "$BODYF" && -f "$BODYF" ]]; then
  _pass "E4 probe body 副本可得"
  assert_file_grep "$BODYF" "rq-20260909-202" "E4 body 含 rq-id"
  assert_file_grep "$BODYF" "免红队|不建子卡|跳过红队|无需红队" "E4 body 含免红队指示（probe 单轮策略）"
  assert_not_grep "$(cat "$BODYF")" "--parent" "E4 probe 卡零 --parent 子卡模板"
  assert_file_grep "$BODYF" "verdict.json" "E4 body 含 worker 自写 verdict.json 指示"
  assert_file_grep "$BODYF" "awaiting-approval" "E4 body 含 rq set awaiting-approval 指示"
else
  _fail "E4 probe body 副本可得" "未捕获 probe 建卡 body"
fi
assert_eq "$(claude_calls claude)" "0" "E4 主路零 claude"
sb_cleanup

# =============================================================================
t_case "E5 attempt 级 idempotency-key：同 rq-id 两次建卡 → epoch 每次更新（防上游同 key 返旧卡死锁）"
common_setup
seed_item "rq-20260909-301" 301 deep queued
run_deepcheck_entry >/dev/null
rm -f "$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"   # 模拟下一轮（链已收割）
sleep 1.1                                                    # 保证 attempt epoch 必然推进
run_deepcheck_entry >/dev/null; RC=$?
assert_exit 0 $RC "E5 第二轮 exit"
KEYS="$(hermes_lines | grep -oE -- '--idempotency-key deepcheck-[A-Za-z0-9-]+' | sed 's/--idempotency-key //' | sort -u)"
N_KEYS="$(printf '%s\n' "$KEYS" | grep -c . || true)"
assert_eq "$N_KEYS" "2" "E5 两次建卡产出 2 个互异幂等键"
assert_eq "$(printf '%s\n' "$KEYS" | grep -c -- '^deepcheck-rq-20260909-301-[0-9]\{10,\}$')" "2" \
  "E5 每个键均匹配 deepcheck-<rq-id>-<epoch> 形态"
sb_cleanup

t_finish
