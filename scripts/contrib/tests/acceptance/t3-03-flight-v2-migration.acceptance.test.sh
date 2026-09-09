#!/usr/bin/env bash
# =============================================================================
# t3-03-flight-v2-migration.acceptance.test.sh — T3 验收矩阵③：flight per-kind 文件化迁移 + 接口零改动
#   F1  旧单文件 kanban-flight.json（kind=scan）存在且新文件不存在 → 兼容读取（在飞语义生效：
#       不建新卡不 fallback）+ 一次性迁移 mv 为 kanban-flight-scan.json（旧文件消失、内容保真）
#   F2  scan 建卡成功 → 写 kanban-flight-scan.json（per-kind 新路径）；旧单文件路径零产出
#   F3  scan 登记四键精确键集（无 pending_max_id；mail 五键由 t3-01 M1 独立钉死）
#   F4  mail_gate.sh / quota_circuit.sh 零改动：工作树 vs HEAD diff 空，且 blob 与 T2 锚定
#       commit（55604ca，T3 改动前基线）一致——防「先 commit 再跑测试」使 HEAD-diff 检查空转
#   F5  scan 段语义零变化（flight 路径迁移除外）：done→清+本轮建新卡 的 t1-03 语义在新路径下复演
# 依据：state.md「## 设计文档」§1（flight per-kind 文件化）+ 任务级契约：
#   「kanban-flight-<kind>.json（kind∈scan|mail|radar|deepcheck|digest）；读端兼容旧
#     kanban-flight.json（只读迁移一次）；写入一律新路径；旧文件迁移清除（检测到旧文件且新建
#     对应文件不存在 → mv 为 -scan 命名）」
#   「接口不变量：mail_gate.sh 零改动（--commit-cursor/--init/exit 语义原样）；quota_circuit.sh 不动」
# 红队纪律：黑盒（未读 run-watch.sh 本次改动 / SKILL.md 新段）；每断言硬失败；无 skip；
#   Mental Mutation：兼容读删→F1 红（查无→fallback）；mv 改 copy→F1 红（旧文件残留）；
#   写入回落旧单路径→F2 红；schema 加/丢键→F3 红；零改动检查删→F4 失去防回归面。
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

T2_ANCHOR="${T3_T2_ANCHOR:-55604ca}" # T2 commit：mail_gate.sh / quota_circuit.sh 的改动前基线

install_fake_date() { # 沙箱 $HOME/.local/bin/date：仅劫持裸 '+%H'，固定非 08 时段（消除真实时钟依赖）
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

mk_issues() { # <out> <首号> <末号>
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

seed_scan_cursor() { # <last_id>
  jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' \
    > "$SB_ROOT/contrib-data/scan-cursor.json"
}

seed_old_flight() { # <card_id> <created_epoch> — T1/T2 旧单文件登记（kind=scan）
  jq -n --arg id "$1" --argjson ep "$2" \
    --arg bf "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" \
    '{kind:"scan",card_id:$id,batch_file:$bf,created_epoch:$ep}' \
    > "$SB_ROOT/contrib-data/kanban-flight.json"
}

seed_card_store() { # <status>
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" \
    > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

old_flight_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight.json" ]; }
scan_flight_card() { jq -r '.card_id // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null || echo ""; }
scan_flight_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-scan.json" ]; }
scan_flight_keys() { jq -r 'keys | join(",")' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null || echo "?"; }

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls_kind() { hermes_lines | grep 'kanban create' | grep -c -- "--idempotency-key $1-" || true; }
claude_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c -- "$1" || true; }

notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

GHF=""
common_setup() { # <首号> <末号>：scan 命中面可调
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  install_fake_date
  mk_issues "$SB_ROOT/tmp/issues.json" "${1:-101}" "${2:-101}"
  seed_scan_cursor "$(( ${1:-101} - 1 ))"
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}

run_watch() { sb_run -e "$GHF" 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"'; }

ge1() {
  case "${1:-}" in
    ''|*[!0-9]*) _fail "$2" "非数值 [$1]" ;;
    *) [ "$1" -ge 1 ] && _pass "$2" || _fail "$2" "实得 $1 < 1" ;;
  esac
}

# =============================================================================
t_case "F1 旧单文件登记（kind=scan）→ 兼容读取（在飞语义生效）+ 一次性 mv 迁移为 -scan 命名"
common_setup 101 101
seed_old_flight "t_old" "$(date +%s)"
seed_card_store "running"
run_watch >/dev/null; RC=$?
assert_exit 0 $RC "F1 run-watch exit"
assert_eq "$(create_calls_kind scan)" "0" "F1 兼容读取：旧登记视作在飞 → 不建新卡（契约 5 不因迁移破）"
assert_eq "$(claude_calls 'contrib-watch scan')" "0" "F1 兼容读取：不误判查无 → 不 fallback"
if old_flight_exists; then
  _fail "F1 旧文件已迁移清除" "kanban-flight.json 未 mv（兼容读残留写隐患）"
else
  _pass "F1 旧文件已迁移清除（mv 非 copy）"
fi
scan_flight_exists && _pass "F1 新路径 -scan 文件存在" \
  || _fail "F1 新路径 -scan 文件存在" "迁移未产出 kanban-flight-scan.json"
assert_eq "$(scan_flight_card)" "t_old" "F1 迁移内容保真（card_id 保留）"
assert_eq "$(jq -r '.kind' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null)" "scan" "F1 迁移 kind 保真"
sb_cleanup

# =============================================================================
t_case "F2 scan 建卡成功 → 写 kanban-flight-scan.json（新路径）；旧单文件路径零产出"
common_setup 101 101
run_watch >/dev/null; RC=$?
assert_exit 0 $RC "F2 run-watch exit"
assert_eq "$(create_calls_kind scan)" "1" "F2 恰 1 次 scan 建卡（命中→建卡主路回归）"
scan_flight_exists && _pass "F2 登记 per-kind 新路径" || _fail "F2 登记 per-kind 新路径" "建卡成功未写 kanban-flight-scan.json"
case "$(scan_flight_card)" in "") _fail "F2 card_id 非空" "为空" ;; *) _pass "F2 card_id 非空" ;; esac
if old_flight_exists; then
  _fail "F2 旧单文件零产出" "T3 后仍写旧 kanban-flight.json（读端回落永不触发，兼容层死代码化）"
else
  _pass "F2 旧单文件零产出（写入一律新路径）"
fi
assert_eq "$(claude_calls 'contrib-watch scan')" "0" "F2 主路零 claude"
assert_eq "$(notify_approvals)" "0" "F2 notify-state approvals 零新增"
sb_cleanup

# =============================================================================
t_case "F3 scan 登记四键精确键集（schema 不变四键；无 mail 专属 pending_max_id）"
common_setup 101 101
run_watch >/dev/null
scan_flight_exists || { _fail "F3 前置" "无 scan 登记可供 schema 断言"; t_finish; }
assert_eq "$(scan_flight_keys)" "batch_file,card_id,created_epoch,kind" "F3 四键精确键集（多键/少键均挂）"
assert_eq "$(jq -r '.created_epoch | type' "$SB_ROOT/contrib-data/kanban-flight-scan.json")" "number" "F3 created_epoch 数值"
sb_cleanup

# =============================================================================
t_case "F4 mail_gate.sh / quota_circuit.sh 零改动（工作树=HEAD=T2 基线 55604ca；无沙箱用例）"
for f in mail_gate.sh quota_circuit.sh; do
  p="scripts/contrib/$f"
  git -C "$REPO_ROOT" diff --exit-code HEAD -- "$p" >/dev/null 2>&1
  assert_exit 0 $? "F4 $p 工作树 vs HEAD 零 diff"
  if git -C "$REPO_ROOT" cat-file -e "$T2_ANCHOR" 2>/dev/null; then
    git -C "$REPO_ROOT" diff --exit-code "$T2_ANCHOR" -- "$p" >/dev/null 2>&1
    assert_exit 0 $? "F4 $p vs T2 基线 $T2_ANCHOR 零 diff（防 HEAD 前移使空转）"
  else
    _fail "F4 T2 基线锚不可解析" "commit $T2_ANCHOR 不在仓内（历史重写？）——T2 基线校验失效"
  fi
done

# =============================================================================
t_case "F5 scan 段语义零变化（flight 路径迁移除外）：新路径登记 done → 清+本轮建新卡"
common_setup 201 201 # 游标 200，issue 201 命中 → 建 scan 卡 t_stub_1（ready）
run_watch >/dev/null
FIRST_CARD="$(scan_flight_card)"
case "$FIRST_CARD" in "") _fail "F5 前置：首卡登记" "为空——建卡/登记链路异常"; t_finish ;; *) _pass "F5 前置：首卡登记 $FIRST_CARD" ;; esac
# 第二轮：游标重拨复现命中 + 卡库该卡置 done → 新路径下复演 t1-03「done→清+建新卡」
seed_scan_cursor 200
printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$FIRST_CARD" \
  > "$SB_ROOT/stublog/kanban-cards.jsonl"
run_watch >/dev/null; RC=$?
assert_exit 0 $RC "F5 第二轮 exit"
assert_eq "$(create_calls_kind scan)" "2" "F5 done → 本轮继续建新卡（t1-03 3.3 语义在新路径复演）"
assert_ne "$(scan_flight_card)" "$FIRST_CARD" "F5 登记已换新卡"
assert_eq "$(claude_calls 'contrib-watch scan')" "0" "F5 done 路零 fallback"
sb_cleanup

t_finish
