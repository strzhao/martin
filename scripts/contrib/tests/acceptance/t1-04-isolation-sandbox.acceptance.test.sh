#!/usr/bin/env bash
# =============================================================================
# t1-04-isolation-sandbox.acceptance.test.sh — T1 验收矩阵④
#   隔离验证：CONTRIB_DATA_DIR 沙箱（真实 contrib-data 零污染）/ 真实 hermes/gh 零调用
#   （沙箱 shim 结构性无逃逸面）/ notify-state 零新增（零订阅语义独立复核）
# 依据：state.md 契约 6「L1 红线不变：测试环境必须隔离 CONTRIB_DATA_DIR + stub 注入，
#   禁真实外发」+ 任务级契约「零订阅语义：scan 卡 CLI 建卡默认零微信订阅 → 终态零推送
#   （红队断言 notify-state 零新增）」
# 说明：本文件会依次运行同目录下 t1-01/02/03 三份验收测试（黑盒子进程），
#   前后对生产 contrib-data 做逐字节快照对比——三份测试各自内部已全部沙箱化，
#   本文件从「整组运行」视角补一道生产零污染总闸。
# 红队纪律：黑盒；每断言硬失败；无 skip。
# =============================================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析——git rev-parse --show-toplevel 在 ${SELF_DIR} 无输出（非 git 仓库 / git 不可用）；本套件禁静默兜底到生产主 checkout" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

[ -d "$REPO_ROOT/contrib-data" ] || { _fail "env 前置" "生产 contrib-data/ 不存在: $REPO_ROOT/contrib-data"; t_finish; }

snap_contrib() {
  ( cd "$REPO_ROOT" && find contrib-data -type f -print0 2>/dev/null | sort -z | xargs -0 shasum -a 256 2>/dev/null )
}

# =============================================================================
t_case "4.1 组级零污染：整组运行 t1-01/02/03 前后，生产 contrib-data 快照逐字节一致"
snap_contrib > "$ART/t1-snap.before" 2>&1
[ -s "$ART/t1-snap.before" ] || _fail "4.1 快照非空" "生产 contrib-data 快照为空（shasum/find 失败？）"

SIB_FAILED=0
for sib in "$HERE"/t1-01-kanban-card-create.acceptance.test.sh \
           "$HERE"/t1-02-scan-gate-batch.acceptance.test.sh \
           "$HERE"/t1-03-run-watch-flight.acceptance.test.sh; do
  if [ ! -f "$sib" ]; then
    _fail "4.1 兄弟测试存在" "缺失: ${sib}（验收组不完整，拒绝空真通过）"
    SIB_FAILED=1
    continue
  fi
  bash "$sib" > "$ART/t1-sib-$(basename "$sib" .sh).out" 2>&1 || SIB_FAILED=1
done
assert_eq "$SIB_FAILED" "0" "4.1 前置：t1-01/02/03 三份验收测试自身全绿"

snap_contrib > "$ART/t1-snap.after" 2>&1
DIFFN="$(diff "$ART/t1-snap.before" "$ART/t1-snap.after" | wc -l | tr -d ' ')"
assert_eq "$DIFFN" "0" "4.1 生产 contrib-data 前后快照 diff 行数=0（CONTRIB_DATA_DIR 沙箱隔离零污染）"

# =============================================================================
t_case "4.2 沙箱结构性无逃逸：shim 白名单不含外部服务命令、bin/ 只含影子 stub"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
ESCAPE=0
for c in hermes gh claude tunnel osascript pgrep; do
  [ -e "$SB_ROOT/shim/$c" ] && { _fail "4.2 shim 无逃逸面" "shim 中出现 ${c}（外部命令可经 PATH 逃逸）"; ESCAPE=1; }
done
[ "$ESCAPE" -eq 0 ] && _pass "4.2 shim 无 hermes/gh/claude/tunnel/osascript"
for c in hermes gh claude; do
  if [ -f "$SB_ROOT/bin/$c" ] && grep -q 'STUB_LOG_DIR' "$SB_ROOT/bin/$c"; then
    _pass "4.2 bin/$c 是影子 stub（带 STUB_LOG_DIR 守卫）"
  else
    _fail "4.2 bin/$c 是影子 stub" "缺失或非 stub 实现（真实命令可能被调用）"
  fi
done
# 守卫面本身必须有效：无 STUB_LOG_DIR 时 stub 拒绝运行（防沙箱外误用）
env -i "$SB_ROOT/bin/hermes" kanban create t >/dev/null 2>&1
rc=$?
assert_ne "$rc" "0" "4.2 stub 沙箱外自毁守卫（无 STUB_LOG_DIR 必须 exit≠0）"
sb_cleanup

# =============================================================================
t_case "4.3 notify-state 零新增：完整 scan 卡化轮次后 approvals/receipts 均为零"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
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
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
jq -n '{last_issue:100,initialized:"2026-09-09T00:00:00Z"}' > "$SB_ROOT/contrib-data/scan-cursor.json"
sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
APPROVALS="$(jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?")"
RECEIPTS="$(jq -r '.receipts // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?")"
assert_eq "$APPROVALS" "0" "4.3 notify-state approvals 零新增（scan 卡零微信订阅 → 终态零推送）"
assert_eq "$RECEIPTS" "0" "4.3 notify-state receipts 零新增"
# 双保险：整轮 events.jsonl 里不允许出现任何已推送（pushed=true）记录
PUSHED="$(jq -s '[.[] | select(.pushed == true)] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?")"
assert_eq "$PUSHED" "0" "4.3 events.jsonl 零 pushed=true（本轮零外发消费）"
sb_cleanup

t_finish
