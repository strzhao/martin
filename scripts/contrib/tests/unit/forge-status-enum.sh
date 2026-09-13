#!/bin/bash
# forge-status-enum.sh — Tier U：forge.sh set-status 值域闭集验收（黑盒 CLI 调用，不 source、不读实现）
#
# 契约（设计文档「契约规约」节逐字）：
#   forge.sh set-status <id> <status>
#   值域闭集 7 值：ready | stale | in-flight | spent | needs-decision | dead | idea
#   exit 0=成功（沙箱台账该件 .status 原子更新 + stdout 日志行 `[forge] <id> → <status>`）
#   exit 2=用法/数据错误（值域外 / 缺件 / 台账缺失或非法）；值域外拒绝先于写盘（台账字节不变）
#
# 验收谓词锚：AC3 dead 真变更 / AC4 idea 收编 / AC5 既有 5 值全通 / AC6 值域外拒绝零写盘
#   补样：大写 DEAD（闭集字面值）/ 缺件 / 用法缺参 / 台账缺失 / 台账非法
#
# 断言铁律（双证，防空心 PASS）：每条判定 = 退出码 + 沙箱台账 jq 读回；禁止 stdout/stderr
#   裸 token 定判（die 拒绝文案同含 "dead"，正负样本不可分）。契约日志行/拒绝文案只作第三证。
# git 哨兵：sb_run env 白名单不含 FORGE_GIT——一律 -e 注入 /nonexistent/git；set-status 契约上
#   零 git 触达，实现若误加 git 调用即当场失败。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "forge-status-enum.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }

LEDGER="${CONTRIB_DATA_DIR}/inventory.json"

seed_inventory() { # sb_seed_data 不播 inventory.json——自播最小台账（合法 JSON，含 .items 数组）；8 件 id 全真实存在（缺件归因隔离）
  cat >"$LEDGER" <<'EOF'
{
  "version": 1,
  "updated": "2026-09-13T00:00:00+08:00",
  "items": [
    {"id": "forge-test-001", "status": "ready", "title": "AC3 用件"},
    {"id": "forge-test-002", "status": "stale", "title": "AC4 用件"},
    {"id": "forge-acc5-ready", "status": "idea", "title": "AC5 用件"},
    {"id": "forge-acc5-stale", "status": "ready", "title": "AC5 用件"},
    {"id": "forge-acc5-inflight", "status": "stale", "title": "AC5 用件"},
    {"id": "forge-acc5-spent", "status": "in-flight", "title": "AC5 用件"},
    {"id": "forge-acc5-decision", "status": "spent", "title": "AC5 用件"},
    {"id": "forge-test-008", "status": "ready", "title": "AC6 用件"}
  ]
}
EOF
}

run_set_status() { # <id> <status> → 沙箱内黑盒执行 forge.sh set-status；stdout=脚本 stdout，rc=脚本 rc
  local id="$1" st="$2"
  sb_run -e 'FORGE_GIT=/nonexistent/git' "\"\${MARTIN_DIR}/scripts/contrib/forge.sh\" set-status ${id} ${st}"
}

run_set_status_no_status() { # <id> → 缺 status 实参的用法错误形态（契约 exit-2 之「用法」半边）
  local id="$1"
  sb_run -e 'FORGE_GIT=/nonexistent/git' "\"\${MARTIN_DIR}/scripts/contrib/forge.sh\" set-status ${id}"
}

inv_status() { # <id> → 沙箱台账该件 .status（缺件/缺账输出空）——读回证据的唯一通道
  jq -r --arg id "$1" '(.items[] | select(.id == $id) | .status) // ""' "$LEDGER" 2>/dev/null
}

assert_ledger_bytes_unchanged() { # <快照路径> — 拒绝路径零写盘证据（cp 快照 + cmp -s 字节比对）
  if cmp -s "$1" "$LEDGER"; then
    _pass "台账字节不变（cmp -s 快照一致）"
  else
    _fail "台账字节不变（cmp -s 快照一致）" "拒绝路径发生了写盘"
  fi
}

# ================= 第一沙箱：值域行为（AC3-AC6 + 值域/缺件补样） =================
seed_inventory

t_case "前置自检：沙箱副本在位 + 自播台账 8 件逐件可读回（fail-fast 归因锚）"
if [[ -f "${MARTIN_DIR}/scripts/contrib/forge.sh" ]]; then
  _pass "被测副本在位（黑盒，不读内容）"
else
  _fail "被测副本在位（黑盒，不读内容）" "缺失: ${MARTIN_DIR}/scripts/contrib/forge.sh"
fi
if [[ -s "$LEDGER" ]]; then
  _pass "自播台账在位"
else
  _fail "自播台账在位" "缺失或空: ${LEDGER}"
fi
assert_eq "$(inv_status forge-test-001)" "ready" "seed 读回 forge-test-001"
assert_eq "$(inv_status forge-test-002)" "stale" "seed 读回 forge-test-002"
assert_eq "$(inv_status forge-acc5-ready)" "idea" "seed 读回 forge-acc5-ready"
assert_eq "$(inv_status forge-acc5-stale)" "ready" "seed 读回 forge-acc5-stale"
assert_eq "$(inv_status forge-acc5-inflight)" "stale" "seed 读回 forge-acc5-inflight"
assert_eq "$(inv_status forge-acc5-spent)" "in-flight" "seed 读回 forge-acc5-spent"
assert_eq "$(inv_status forge-acc5-decision)" "spent" "seed 读回 forge-acc5-decision"
assert_eq "$(inv_status forge-test-008)" "ready" "seed 读回 forge-test-008"

t_case "AC3: set-status dead——exit 0 且沙箱台账 .status 读回 dead（终态补样，真变更全链）"
ac3_out="$(run_set_status forge-test-001 dead)"
assert_exit 0 $? "set-status forge-test-001 dead"
assert_eq "$(inv_status forge-test-001)" "dead" "台账读回 .status==dead"
assert_contains "$ac3_out" "[forge] forge-test-001 → dead" "stdout 成功行（契约逐字，第三证）"
assert_stub_not_called hermes "set-status 不触 hermes stub"
assert_stub_not_called gh "set-status 不触 gh stub"

t_case "AC4: set-status idea 收编——exit 0 且沙箱台账 .status 读回 idea"
ac4_out="$(run_set_status forge-test-002 idea)"
assert_exit 0 $? "set-status forge-test-002 idea"
assert_eq "$(inv_status forge-test-002)" "idea" "台账读回 .status==idea"
assert_contains "$ac4_out" "[forge] forge-test-002 → idea" "stdout 成功行（契约逐字，第三证）"

t_case "AC5: 既有 5 值全通——每值 exit 0 且台账读回目标值（初始态均异于目标，写必真变更）"
run_set_status forge-acc5-ready ready >/dev/null
assert_exit 0 $? "set-status → ready"
assert_eq "$(inv_status forge-acc5-ready)" "ready" "读回 ready"

run_set_status forge-acc5-stale stale >/dev/null
assert_exit 0 $? "set-status → stale"
assert_eq "$(inv_status forge-acc5-stale)" "stale" "读回 stale"

run_set_status forge-acc5-inflight in-flight >/dev/null
assert_exit 0 $? "set-status → in-flight"
assert_eq "$(inv_status forge-acc5-inflight)" "in-flight" "读回 in-flight"

run_set_status forge-acc5-spent spent >/dev/null
assert_exit 0 $? "set-status → spent"
assert_eq "$(inv_status forge-acc5-spent)" "spent" "读回 spent"

run_set_status forge-acc5-decision needs-decision >/dev/null
assert_exit 0 $? "set-status → needs-decision"
assert_eq "$(inv_status forge-acc5-decision)" "needs-decision" "读回 needs-decision"

t_case "AC6: bogus-status 值域外拒绝——exit 2 且台账字节不变（拒绝先于写盘；件真实存在，失败归因值域）"
cp "$LEDGER" "${SB_TMP}/ac6-before.json"
run_set_status forge-test-008 bogus-status >/dev/null
assert_exit 2 $? "bogus-status → exit 2"
assert_ledger_bytes_unchanged "${SB_TMP}/ac6-before.json"
ac6_err="$(sb_out 20)"
assert_contains "$ac6_err" "[forge] status 只许 ready|stale|in-flight|spent|needs-decision|dead|idea" "stderr 拒绝文案（契约逐字，第三证）"

t_case "值域外补样：大写 DEAD 亦拒——闭集字面值不做归一化，exit 2 且字节不变"
cp "$LEDGER" "${SB_TMP}/dead-upper-before.json"
run_set_status forge-test-008 DEAD >/dev/null
assert_exit 2 $? "DEAD → exit 2"
assert_ledger_bytes_unchanged "${SB_TMP}/dead-upper-before.json"

t_case "缺件拒绝：值域内 dead + 未知 id——exit 2 且台账字节不变"
cp "$LEDGER" "${SB_TMP}/miss-id-before.json"
run_set_status forge-test-nonexistent dead >/dev/null
assert_exit 2 $? "未知 id → exit 2"
assert_ledger_bytes_unchanged "${SB_TMP}/miss-id-before.json"

sb_cleanup

# ================= 第二沙箱：台账级数据错误 + 用法错误（契约 exit-2 闭集补样） =================
if sb_new >/dev/null 2>&1; then
  LEDGER="${CONTRIB_DATA_DIR}/inventory.json"

  t_case "台账缺失 → exit 2"
  if [[ ! -f "$LEDGER" ]]; then
    _pass "前置：沙箱无 inventory.json"
  else
    _fail "前置：沙箱无 inventory.json" "意外存在: ${LEDGER}"
  fi
  run_set_status forge-test-001 dead >/dev/null
  assert_exit 2 $? "台账缺失 set-status → exit 2"

  t_case "用法错误：缺 status 实参 → exit 2"
  seed_inventory # 归因隔离：先恢复合法台账，本 case 的 exit 2 只许来自用法而非数据
  run_set_status_no_status forge-test-001 >/dev/null
  assert_exit 2 $? "缺 status 实参 → exit 2（合法台账前置）"

  t_case "台账非法（非 JSON）→ exit 2"
  printf 'this-is-not-json' >"$LEDGER"
  if jq empty "$LEDGER" >/dev/null 2>&1; then
    _fail "前置：台账确为非法 JSON" "意外可解析"
  else
    _pass "前置：台账确为非法 JSON"
  fi
  run_set_status forge-test-001 dead >/dev/null
  assert_exit 2 $? "台账非法 set-status → exit 2"

  sb_cleanup
else
  _fail "第二沙箱创建" "sb_new 失败——台账缺失/用法/台账非法三 case 未执行"
  if [[ -n "$SB_ROOT" ]]; then sb_cleanup; fi
fi

t_finish
