#!/usr/bin/env bash
# =============================================================================
# t1-02-scan-gate-batch.acceptance.test.sh — T1 验收矩阵②
#   scan_gate.sh：批次文件双写（批次为主 + pending-hits 兼容写）+ state 字段 +
#   60 条命中无挤出（撤 cap40）+ 秒级批次名 + 指针文件 + backlog 两源 .number 去重
#   >80 告警幂等 + exit 语义（0/10）不变 + --init/--drain 不动
# 依据：state.md 契约「1. 批次文件 schema」「1b. fallback 数据源契约」「2. scan_gate.sh 改造」
#   契约 3「scan_gate.sh exit 语义（0/10）不变；--init/--drain 语义不变」
# CONTRACT_AMBIGUOUS：
#  - backlog 统计是否仅在 hit_count>0 路径评估未细述 → 各用例均带 ≥1 条新命中强制进命中路
#  - 「批次文件两源」取 pending-batches/ 目录全域 batch-*.json（设计原文复数语境）；
#    若蓝队只统计指针所指最新批次，2.5b 会红——按设计文本从严
#  - 去重口径反 No-op 用例 2.5a：两源求和 95>80 但去重并集 50≤80，必须零告警
# 红队纪律：黑盒；每断言硬失败；无 skip。
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

# ---- 本文件专用工具 ----

# mk_issues <out> <start> <end>：生成 gh issue JSON 数组（可过黑名单粗滤的标题）
mk_issues() {
  local out="$1" s="$2" e="$3" i
  {
    printf '['
    for ((i = s; i <= e; i++)); do
      [ "$i" -gt "$s" ] && printf ','
      printf '{"number":%d,"title":"gateway regression %d","labels":[{"name":"bug"}],"user":{"login":"alice"},"created_at":"2026-09-09T00:00:00Z","comments":0,"pull_request":null}' "$i" "$i"
    done
    printf ']\n'
  } > "$out"
}

# mk_hit_items <out> <start> <end> [state]：生成 hit 元素数组（state 可选，pending-hits 不带）
mk_hit_items() {
  local out="$1" s="$2" e="$3" st="${4:-}" i
  {
    printf '['
    for ((i = s; i <= e; i++)); do
      [ "$i" -gt "$s" ] && printf ','
      printf '{"number":%d,"title":"backlog item %d","labels":[],"author":"bob","created":"2026-09-08T00:00:00Z","comments":0' "$i" "$i"
      [ -n "$st" ] && printf ',"state":"%s"' "$st"
      printf '}'
    done
    printf ']\n'
  } > "$out"
}

seed_cursor() { # <last_issue>
  jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' > "$SB_ROOT/contrib-data/scan-cursor.json"
}

run_gate() { sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json" 'bash "$MARTIN_DIR/scripts/contrib/scan_gate.sh"'; }

backlog_event_count() { # events.jsonl 中 class=pipeline-failure 且 key 以 -backlog 结尾的条数
  jq -s '[.[] | select(.class == "pipeline-failure" and ((.key // "") | endswith("-backlog")))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

# =============================================================================
t_case "2.1 exit 语义不变：命中 exit 10"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_issues "$SB_ROOT/tmp/issues.json" 101 102
seed_cursor 100
run_gate; RC=$?
assert_exit 10 $RC "2.1 有命中 exit 10"
sb_cleanup

t_case "2.1b exit 语义不变：无命中 exit 0"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
printf '[]\n' > "$SB_ROOT/tmp/issues.json"
seed_cursor 100
run_gate; RC=$?
assert_exit 0 $RC "2.1b 无命中 exit 0"
sb_cleanup

# =============================================================================
t_case "2.2 批次文件+指针：秒级 TS（YYYYMMDD-HHMMSS）、batch-<ts>.json 落盘、schema（state + hit 字段）、count 一致"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_issues "$SB_ROOT/tmp/issues.json" 101 102
seed_cursor 100
run_gate; RC=$?
assert_exit 10 $RC "2.2 exit 10（前置）"
PTR="$SB_ROOT/contrib-data/scan-latest-batch.json"
if [ -f "$PTR" ]; then
  _pass "2.2 指针文件存在"
  TS="$(jq -r '.ts // ""' "$PTR")"
  BF="$(jq -r '.batch_file // ""' "$PTR")"
  CNT="$(jq -r '.count // -1' "$PTR")"
  case "$TS" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
      _pass "2.2 指针 ts 秒级格式（${TS}）" ;;
    *) _fail "2.2 指针 ts 秒级格式" "实得 [$TS]，期望 YYYYMMDD-HHMMSS（防同分钟重跑覆盖旧批次而 flight 仍指旧路径）" ;;
  esac
  assert_eq "$(basename "$BF")" "batch-$TS.json" "2.2 批次文件名与指针 ts 逐字一致"
  if [ -f "$BF" ]; then
    _pass "2.2 批次文件实际存在"
    assert_eq "$(jq -r 'type' "$BF")" "array" "2.2 批次文件=JSON 数组"
    assert_eq "$(jq -r 'length' "$BF")" "2" "2.2 批次条数=命中数"
    assert_eq "$(jq -r 'all(.[]; .state == "pending")' "$BF")" "true" "2.2 每元素 state=pending"
    assert_eq "$(jq -r 'all(.[]; has("number") and has("title") and has("labels") and has("author") and has("created") and has("comments") and has("state"))' "$BF")" "true" "2.2 每元素含 hit 字段+state（契约 1 schema）"
    assert_eq "$(jq -r '[.[].number] | sort | join(",")' "$BF")" "101,102" "2.2 批次含本次命中 issue 号"
  else
    _fail "2.2 批次文件实际存在" "$BF 未产出（只写指针不写批次=No-op）"
  fi
  assert_eq "$CNT" "2" "2.2 指针 count=命中数"
else
  _fail "2.2 指针文件存在" "$PTR 未产出"
fi
sb_cleanup

# =============================================================================
t_case "2.3 双写一致：批次文件（去 state）与 pending-hits.json 逐条等值"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_issues "$SB_ROOT/tmp/issues.json" 101 103
seed_cursor 100
run_gate >/dev/null
BF="$(jq -r '.batch_file // ""' "$SB_ROOT/contrib-data/scan-latest-batch.json")"
A="$(jq -S '[.[] | del(.state)] | sort_by(.number)' "$BF" 2>/dev/null)"
B="$(jq -S 'sort_by(.number)' "$SB_ROOT/contrib-data/pending-hits.json" 2>/dev/null)"
assert_eq "$A" "$B" "2.3 批次(去 state) == pending-hits（双写逐条一致）"
assert_eq "$(jq -r '[.[].number] | sort | join(",")' "$SB_ROOT/contrib-data/pending-hits.json")" "101,102,103" "2.3 pending-hits 兼容写保留（契约 1b，T6 才撤）"
sb_cleanup

# =============================================================================
t_case "2.4 无挤出：累计 60 条命中全保留（50+10 两轮；HEAD cap40 行为必须消失）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_issues "$SB_ROOT/tmp/issues.json" 101 150
seed_cursor 100
run_gate >/dev/null; RC1=$?
assert_exit 10 $RC1 "2.4 第一轮 exit 10（50 条）"
mk_issues "$SB_ROOT/tmp/issues.json" 101 160
run_gate >/dev/null; RC2=$?
assert_exit 10 $RC2 "2.4 第二轮 exit 10（+10 条）"
PEND_N="$(jq -r 'length' "$SB_ROOT/contrib-data/pending-hits.json")"
assert_eq "$PEND_N" "60" "2.4 pending-hits 累计 60 条全保留（cap40 挤出语义必须已删）"
LATEST_BF="$(jq -r '.batch_file // ""' "$SB_ROOT/contrib-data/scan-latest-batch.json")"
assert_eq "$(jq -r 'length' "$LATEST_BF" 2>/dev/null)" "10" "2.4 最新批次文件含本轮 10 条"
assert_eq "$(backlog_event_count)" "0" "2.4 60 条未过阈值，零 backlog 告警"
sb_cleanup

# =============================================================================
t_case "2.5a 去重口径（反 No-op）：两源求和 95>80 但 .number 去重并集 50≤80 → 必须零告警"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 1 30
mkdir -p "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 1 25 pending   # 与 pending 重叠 25
mk_issues "$SB_ROOT/tmp/issues.json" 101 120
seed_cursor 100
run_gate >/dev/null; RC=$?
assert_exit 10 $RC "2.5a exit 10（20 条新命中）"
assert_eq "$(backlog_event_count)" "0" "2.5a 去重并集 50 ≤ 80 → 零告警（若按两源直接求和=95 将误报，本断言必红）"
sb_cleanup

# =============================================================================
t_case "2.5b 去重并集 >80 → 恰 1 条 pipeline-failure backlog 告警（告警不丢弃）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 1 50
mkdir -p "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 51 90 pending   # 离散 40 条
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_gate >/dev/null; RC=$?
assert_exit 10 $RC "2.5b exit 10（前置）"
assert_eq "$(backlog_event_count)" "1" "2.5b 并集 91（50+40 离散+1 新）>80 → 恰 1 条 backlog 告警入账 events.jsonl"
sb_cleanup

t_case "2.5c backlog 告警幂等：重复触发同日 key 仍只 1 条"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 1 50
mkdir -p "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 51 90 pending
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_gate >/dev/null
mk_issues "$SB_ROOT/tmp/issues.json" 101 102
run_gate >/dev/null
assert_eq "$(backlog_event_count)" "1" "2.5c 两轮触发同 key（<date>-backlog）→ 事件仍恰 1 条（notify event --key 幂等）"
sb_cleanup

# =============================================================================
t_case "2.6 --init 语义不变：STUB_GH_LATEST 拨游标 + pending 清空 + exit 0"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 1 5
sb_run -e STUB_GH_LATEST=555 'bash "$MARTIN_DIR/scripts/contrib/scan_gate.sh" --init' >/dev/null; RC=$?
assert_exit 0 $RC "2.6 --init exit 0"
assert_eq "$(jq -r '.last_issue // 0' "$SB_ROOT/contrib-data/scan-cursor.json")" "555" "2.6 游标拨到 STUB_GH_LATEST"
assert_eq "$(jq -r 'length' "$SB_ROOT/contrib-data/pending-hits.json")" "0" "2.6 --init 清空 pending"
sb_cleanup

t_case "2.6b --drain：exit 0 且 pending 清空"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 1 5
sb_run 'bash "$MARTIN_DIR/scripts/contrib/scan_gate.sh" --drain' >/dev/null; RC=$?
assert_exit 0 $RC "2.6b --drain exit 0"
assert_eq "$(jq -r 'length' "$SB_ROOT/contrib-data/pending-hits.json")" "0" "2.6b --drain 清空 pending"
sb_cleanup

t_finish
