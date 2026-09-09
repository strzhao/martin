#!/usr/bin/env bash
# =============================================================================
# t2-01-qc-card-matrix.acceptance.test.sh — T2 验收矩阵①：QC×建卡 3 态（run-watch 经 zsh，镜像生产）
#   ①QC 开+命中 → 建卡照常发起 + 零 claude（建卡永不受 QC 限，收窄 rc==10 顺延分支）
#   ②QC 开+建卡失败 → fallback 入口被调（-scan-fallback-skipped 恰 1 条）但 claude 不被调
#     + 日志语义行「断路器仅挡兜底路」
#   ③幂等重跑 → -scan-fallback-skipped 仍恰 1 条（notify --key 幂等）
#   ④QC 闭+建卡失败 → claude 被调（T1 原语义回归，fallback 未被 QC 挡）
# 依据：state.md「## 设计文档」§2（run-watch.sh QC 语义收窄）+ 任务级契约：
#   「QC 新语义：quota_circuit = claude 路的断路器；建卡路（deepseek 卡）永不受 QC 限制」
#   「事件面：<日期>-scan-fallback-skipped（QC 挡兜底）新幂等 key」
#   「fallback 内 QC gate：QC 开 → 跳过 claude + 日志语义行『断路器仅挡兜底路（GLM 配额），
#   本轮 fallback 跳过』+ notify event --key <日期>-scan-fallback-skipped」
# 前置态构造（黑盒 fixture，契约钉死的文件路径/格式）：
#   .quota-circuit = 未来 epoch 单整数（quota_circuit.sh check exit 1 → QC_OPEN=1）
#   scan-cursor.json / STUB_GH_ISSUES_FILE 驱动 scan_gate exit 10（同 t1-03 模式）
# 红队纪律：黑盒（未读 kanban_card.sh / run-watch.sh 本次改动）；每断言硬失败；无 skip。
# Mental Mutation 自检：删 fallback QC gate → ②③红；恢复顺延分支 → ①红；删事件 → ②红；
#   改 key 后缀 → ②③红（endswith 不命中）；事件重复入账 → ③红。
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

# ---- 本文件专用工具（镜像 t1-03 模式）----

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

seed_cursor() {
  jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' > "$SB_ROOT/contrib-data/scan-cursor.json"
}

qc_open() { # 未来 epoch 旗标 → quota_circuit check exit 1
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$SB_ROOT/contrib-data/.quota-circuit"
}

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls() { hermes_lines | grep -c 'kanban create' || true; }
claude_scan_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'contrib-watch scan' || true; }

flight_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-scan.json" ]; }

ev_key_count() { # <key 后缀> → events.jsonl 中该后缀 key 的条数（<日期>-<后缀> 的日期段不钉死）
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

pipeline_failure_count() {
  jq -s '[.[] | select(.class == "pipeline-failure")] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

GHF=""
common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mk_issues "$SB_ROOT/tmp/issues.json" 101 101
  seed_cursor 100
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}

run_watch() { sb_run -e "$GHF" "$@"; }

# =============================================================================
t_case "5.1 QC 开+命中 → 建卡照常发起：kanban create 被调 + 零 claude + 零 fallback-skipped 事件（建卡永不受 QC 限）"
common_setup
qc_open
run_watch 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "5.1 run-watch exit"
case "$(create_calls)" in
  0) _fail "5.1 建卡发起" "QC 开闸下 kanban create 零调用（顺延分支未收窄 = No-op）" ;;
  *) _pass "5.1 建卡发起（create 调用 $(create_calls) 次）" ;;
esac
assert_eq "$(claude_scan_calls)" "0" "5.1 QC 开 → 零 claude -p scan（建卡主路不含 claude）"
assert_eq "$(ev_key_count -scan-fallback-skipped)" "0" "5.1 零 fallback-skipped 事件（建卡成功无需兜底）"
flight_exists && _pass "5.1 flight 登记存在" || _fail "5.1 flight 登记存在" "建卡成功应写 kanban-flight-scan.json"
assert_eq "$(notify_approvals)" "0" "5.1 notify-state approvals 零新增（隔离：零订阅零外发）"
sb_cleanup

# =============================================================================
t_case "5.2 QC 开+建卡失败 → fallback 入口被调但 claude 不被调：-scan-fallback-skipped 恰 1 条 + 日志语义行"
common_setup
qc_open
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "5.2 run-watch exit"
case "$(create_calls)" in
  0) _fail "5.2 前置自证" "create 零调用——注毒未生效，本用例断言为空转" ;;
  *) _pass "5.2 前置自证：建卡确实被尝试后失败" ;;
esac
assert_eq "$(claude_scan_calls)" "0" "5.2 QC 开 → fallback 跳过 claude（QC gate 收窄钉死点）"
assert_eq "$(ev_key_count -scan-fallback-skipped)" "1" "5.2 -scan-fallback-skipped 恰 1 条（fallback 入口被调的凭证）"
assert_eq "$(ev_key_count -scan-card-fallback)" "1" "5.2 既有 -scan-card-fallback 事件保留（T1 契约不回归）"
assert_file_contains "$SB_ROOT/contrib-data/logs/launchd.log" "断路器仅挡兜底路" "5.2 日志含语义行『断路器仅挡兜底路』"
sb_cleanup

# =============================================================================
t_case "5.3 幂等重跑 → -scan-fallback-skipped 仍恰 1 条（notify --key 幂等，重跑不重复告警）"
common_setup
qc_open
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(ev_key_count -scan-fallback-skipped)" "1" "5.3 首跑恰 1 条（前置）"
# 重跑前置：scan_gate 每轮推进游标 → 重拨游标复现命中
seed_cursor 100
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "5.3 重跑 exit"
assert_eq "$(claude_scan_calls)" "0" "5.3 重跑仍零 claude"
assert_eq "$(ev_key_count -scan-fallback-skipped)" "1" "5.3 重跑后仍恰 1 条（同 key 幂等去重）"
assert_eq "$(ev_key_count -scan-card-fallback)" "1" "5.3 既有 key 同样幂等仍 1 条"
sb_cleanup

# =============================================================================
t_case "5.4 QC 闭+建卡失败 → claude 被调（T1 原语义回归：fallback 不受 QC 挡）+ 零 fallback-skipped 事件"
common_setup
run_watch -e STUB_HERMES_FAIL=1 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
case "$(create_calls)" in
  0) _fail "5.4 前置自证" "create 零调用——注毒未生效" ;;
  *) _pass "5.4 前置自证：建卡被尝试后失败" ;;
esac
case "$(claude_scan_calls)" in
  0) _fail "5.4 QC 闭 fallback 放行" "断路器闭合时建卡失败应回落 claude 旧路，实得零调用" ;;
  *) _pass "5.4 QC 闭 → claude 旧路被调（$(claude_scan_calls) 次）" ;;
esac
assert_eq "$(ev_key_count -scan-fallback-skipped)" "0" "5.4 QC 闭 → 零 fallback-skipped 事件"
sb_cleanup

t_finish
