#!/bin/bash
# e3-cwd-root.sh — E3：launchd cwd=/ 回归（Bug② 再现防护）
# 09-05 事故：run-deepcheck.sh 缺 `cd "$MARTIN"`，launchd cwd=/ 下 claude 找不到项目 skill。
# 契约锚点：run-deepcheck.sh 调用 claude 子进程时 $PWD == MARTIN 根。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e3-cwd-root.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }

t_case "E3: cwd=/ 下 run-deepcheck 全链 → claude 子进程 PWD == MARTIN"
sb_seed_queue_item "rq-20260905-501" 501 probe queued 40
sb_run -C / 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
rc=$?
assert_exit 0 $rc "run-deepcheck 黑洞契约（恒 0）"
assert_stub_called claude 1 "claude 被调"
# 影子 stub 记录的 cwd 必须是 MARTIN 根（沙箱根），而非 /
cwd_seen="$(head -1 "$SB_ROOT/stublog/calls.log" | cut -d'|' -f2)"
assert_eq "$cwd_seen" "$SB_ROOT" "claude 子进程 cwd == MARTIN"

t_case "E3b: cwd=/ 下 gate 与编排产物全部落沙箱（launchd 相对路径防护）"
assert_file_contains "$SB_ROOT/contrib-data/logs/deepcheck.log" "run-deepcheck start" "入口日志落沙箱"
state="$(jq -r '.items[] | select(.id == "rq-20260905-501") | .state' "$SB_ROOT/contrib-data/ready-queue.json")"
assert_eq "$state" "awaiting-approval" "队列状态推进"
if [[ ! -e "/.rq-fingerprint" ]]; then
  _pass "沙箱外零残留（cwd=/ 无写点）"
else
  _fail "沙箱外零残留" "检测到 cwd=/ 写点"
fi

sb_cleanup
t_finish
