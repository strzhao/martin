#!/bin/bash
# notify-state.sh — Tier U：notify.sh 簿记纯函数 + DRY_RUN 解析优先级 + 事件分级
# 覆盖：state_bump/state_get/state_set、DRY_RUN 优先级（契约规约第 2 条）、is_mechanical 分级（第 7 条）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "notify-state.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }

nf_fn() { # nf_fn <表达式> — 子进程 source notify.sh 后求值
  sb_run -e "NOTIFY_SOURCE_ONLY=1" "source \"\$MARTIN_DIR/scripts/contrib/notify.sh\" >/dev/null 2>&1
$1"
}

# ---------------- state_bump / state_get / state_set ----------------
t_case "state_bump：同键累加"
assert_eq "$(nf_fn 'state_bump alerts "$(today)" >/dev/null; state_bump alerts "$(today)" >/dev/null; state_get alerts "$(today)"')" "2" "两次 bump → 2"

t_case "state_get：缺失键 → 0"
assert_eq "$(nf_fn 'state_get fallback_notice "$(today)"')" "0" "未初始化键读 0"

t_case "state_set：一次性标记幂等写"
assert_eq "$(nf_fn 'state_set fallback_notice "$(today)" 1 >/dev/null; state_set fallback_notice "$(today)" 1 >/dev/null; state_get fallback_notice "$(today)"')" "1" "重复 set 仍为 1（日幂等锚点）"

t_case "state 文件保留既有键"
nf_fn 'state_bump receipts "$(today)" >/dev/null' >/dev/null
state_file="$(nf_fn 'printf %s "$STATE"')"
if [[ -f "$state_file" ]]; then
  assert_contains "$(jq -S 'keys | join(",")' "$state_file")" "alerts" "state 文件含 alerts"
  assert_contains "$(jq -S 'keys | join(",")' "$state_file")" "receipts" "state 文件含 receipts"
else
  _fail "state 文件存在性" "nf_fn 未返回 STATE 路径"
fi

# ---------------- DRY_RUN 解析优先级（env > config > "true"）----------------
t_case "DRY_RUN：env 最高优先"
sb_config_set '.notify_dry_run = true'
assert_eq "$(sb_run -e "NOTIFY_SOURCE_ONLY=1" -e "NOTIFY_DRY_RUN=false" 'source "$MARTIN_DIR/scripts/contrib/notify.sh" >/dev/null 2>&1; printf %s "$DRY_RUN"')" "false" "env false 压过 config true"

t_case "DRY_RUN：次选 config"
assert_eq "$(sb_run -e "NOTIFY_SOURCE_ONLY=1" 'source "$MARTIN_DIR/scripts/contrib/notify.sh" >/dev/null 2>&1; printf %s "$DRY_RUN"')" "true" "config true 生效"
sb_config_set '.notify_dry_run = false'
assert_eq "$(sb_run -e "NOTIFY_SOURCE_ONLY=1" 'source "$MARTIN_DIR/scripts/contrib/notify.sh" >/dev/null 2>&1; printf %s "$DRY_RUN"')" "false" "config false 生效（09-05 事故回归锚点）"

t_case "DRY_RUN：兜底 true"
assert_eq "$(sb_run -e "NOTIFY_SOURCE_ONLY=1" 'rm -f "$CONTRIB_DATA_DIR/config.json"; source "$MARTIN_DIR/scripts/contrib/notify.sh" >/dev/null 2>&1; printf %s "$DRY_RUN"')" "true" "无配置 → true（fail-safe）"

# ---------------- 事件分级（双级渲染契约的分类函数）----------------
t_case "is_mechanical：三类机械事件"
for cls in probe-premise-dead own-pr-activity deep-budget-exhausted; do
  nf_fn "is_mechanical $cls"
  assert_exit 0 $? "$cls 是机械事件"
done

t_case "is_mechanical：叙事事件"
for cls in pipeline-failure scan-hit unknown-class; do
  nf_fn "is_mechanical $cls"
  assert_exit 1 $? "$cls 是叙事事件"
done

t_case "class_title/class_action：未知类兜底"
assert_eq "$(nf_fn 'class_title totally-new-class')" "totally-new-class" "未知类标题原样透传"
assert_eq "$(nf_fn 'class_action totally-new-class')" "" "未知类无动作行"

sb_cleanup
t_finish
