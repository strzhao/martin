#!/usr/bin/env bash
# =============================================================================
# t2-03-hermes-call-seams.acceptance.test.sh — T2 验收矩阵③：hermes_call 统一封装 seam
#   ③stderr 分离：stub 往 stderr 写告警 → create 仍 exit 0 且 stdout 恒一行可解析 JSON
#     （顺手修 T1 挂账 B3：stderr 不再并入 stdout 污染 JSON 解析）
#   超时：HERMES_TIMEOUT env 注入（秒）生效，超时退出码视为调用失败（B4 闭合）
#     - healthcheck 超时 → exit 1 + down 计数 +1（超时=探测失败）
#     - create 自身超时（探测成功）→ exit≠0，且 down 计数不被 create 失败驱动（只有 healthcheck 探测驱动计数）
#   B4 run-watch 侧：flight 检查的 hermes kanban list 经 FLIGHT_TIMEOUT seam 包裹——
#     hermes 挂死不再拖死整轮，超时视同「查无」走 fallback
#   env -u：hermes_call 统一封装剥离 ANTHROPIC_* 三变量（healthcheck 路同样生效）
# 依据：state.md「## 设计文档」§1（hermes_call 封装：stdout/stderr 分离 + 统一超时包裹
#   三级退化 + B4 flight 超时）+ 任务级契约「hermes_call 契约：stdout/stderr 分离；
#   HERMES_TIMEOUT env 可注入（秒，缺省 60，healthcheck 10）；超时退出码视为调用失败」
# CONTRACT_AMBIGUOUS：
#   - 设计 §3「STUB 加 sleep 旋钮」未钉旋钮名——本测试不依赖蓝队新增旋钮，用测试本地
#     decoy 包装（sleep 后委托真身 stub）实现挂死，语义等价。
#   - healthcheck 超时秒数：设计 §1 写「healthcheck 用 10s」、§3 写「用 1s 短超时 env 注入
#     测」——按 §3 消费 HERMES_TIMEOUT 注入；若实现给 healthcheck 硬编码 10s 而不认注入，
#     本测试会红（属设计 §3 明示的验证路径，按红处理并在报告标注）。
# 红队纪律：黑盒；每断言硬失败；无 skip。Mutation 自检：恢复 2>&1 并流 → 3.1 红；
#   删超时包裹 → 3.2/3.3/3.4 红；create 失败也写计数 → 3.3 的 down 文件存在红；
#   FLIGHT_TIMEOUT seam 未消费 → 3.4 走在飞跳过支路 → claude 零调用红。
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

run_card() {
  local a snippet=""
  for a in "$@"; do snippet+="$(printf '%q ' "$a")"; done
  sb_run "bash \"\$MARTIN_DIR/scripts/contrib/kanban_card.sh\" $snippet"
}

decoy_hermes() { # <mode: stderr|sleep> — 测试本地 decoy 包装，委托真身 stub
  local mode="$1"
  cp "$SB_ROOT/bin/hermes" "$SB_ROOT/tmp/hermes.real" || { _fail "decoy_hermes" "备份真身失败"; t_finish; }
  {
    printf '#!/bin/bash\n'
    case "$mode" in
      stderr)
        printf 'echo "decoy stderr warning ACC-T2-3.1 (W2026-09-09 warning line)" >&2\n'
        ;;
      sleep)
        printf 'sleep "${DECOY_SLEEP:-5}"\n'
        ;;
      sleepcreate)
        printf 'for a in "$@"; do\n'
        printf '  if [ "$a" = "create" ]; then\n'
        printf '    echo "hermes|decoy|kanban create (sleepcreate decoy, to be killed)" >> "$STUB_LOG_DIR/calls.log"\n'
        printf '    sleep "${DECOY_SLEEP:-5}"\n'
        printf '  fi\n'
        printf 'done\n'
        ;;
    esac
    printf 'exec "%s" "$@"\n' "$SB_ROOT/tmp/hermes.real"
  } > "$SB_ROOT/bin/hermes"
  chmod +x "$SB_ROOT/bin/hermes"
}

down_value() { tr -d '[:space:]' < "$SB_ROOT/contrib-data/.hermes-down" 2>/dev/null || true; }
hermes_create_calls() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'kanban create' || true; }
hermes_list_calls() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'kanban list' || true; }
claude_scan_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'contrib-watch scan' || true; }
flight_exists() { [ -s "$SB_ROOT/contrib-data/kanban-flight-scan.json" ]; }
ev_key_count() {
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}
notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

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
seed_flight() {
  jq -n --arg id "$1" --arg bf "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" --argjson ep "$2" \
    '{kind:"scan",card_id:$id,batch_file:$bf,created_epoch:$ep}' > "$SB_ROOT/contrib-data/kanban-flight-scan.json"
}
seed_card_store() {
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

sb_new_or_die() { sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }; }

# =============================================================================
t_case "3.1 stderr 分离：stub 往 stderr 写告警 → create 仍成功且 stdout 恒一行 {id,status}（B3 闭合）"
sb_new_or_die
decoy_hermes stderr
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t2-stderr --body-file "$SB_ROOT/tmp/body.md")"; RC=$?
assert_exit 0 $RC "3.1 create exit 0（stderr 告警不构成失败）"
NLINES="$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "$NLINES" "1" "3.1 stdout 恒一行（stderr 混入必多行/解析失败=红）"
KEYS="$(printf '%s' "$OUT" | jq -cr 'keys | sort | join(",")' 2>/dev/null)"
assert_eq "$KEYS" "id,status" "3.1 stdout 可解析且键闭集 {id,status}（2>&1 并流=No-op 必红）"
CID="$(printf '%s' "$OUT" | jq -r '.id // ""' 2>/dev/null)"
case "$CID" in "") _fail "3.1 卡 id 非空" "id 缺失" ;; *) _pass "3.1 卡 id 非空" ;; esac
sb_cleanup

# =============================================================================
t_case "3.2 healthcheck 超时注入：HERMES_TIMEOUT=1 + stub 挂死 5s → exit 1 + down=1（超时视为探测失败）"
sb_new_or_die
decoy_hermes sleep
OUT="$(sb_run -e DECOY_SLEEP=5 -e HERMES_TIMEOUT=1 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck')"; RC=$?
assert_exit 1 $RC "3.2 超时=单次探测失败 → exit 1（输出闭集；若超时未被包裹会等满 5s 后 exit 0=红）"
case "$OUT" in FAIL*) _pass "3.2 stdout 以 FAIL 开头" ;; *) _fail "3.2 stdout 以 FAIL 开头" "实得 [${OUT:0:80}]" ;; esac
assert_eq "$(down_value)" "1" "3.2 超时计入 down 计数（超时退出码视为调用失败）"
assert_eq "$(ev_key_count -hermes-down)" "1" "3.2 首次探测失败 emit -hermes-down 恰 1 条"
sb_cleanup

# =============================================================================
t_case "3.3 create 自身超时 → exit≠0 且 down 计数不被 create 失败驱动（探测成功后 create 挂死：down 保持不存在）"
sb_new_or_die
decoy_hermes sleepcreate   # 只挂死 kanban create，探测 list 秒回成功
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
sb_run -e DECOY_SLEEP=5 -e HERMES_TIMEOUT=1 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t2-ct --body-file "$MARTIN_DIR/tmp/body.md"' >/dev/null
create_rc=$?
case "$create_rc" in
  0) _fail "3.3 create 超时失败" "hermes create 超时下 create 仍 exit 0（超时未被包裹/未被视作失败=假成功）" ;;
  *) _pass "3.3 create exit≠0（rc=${create_rc}）" ;;
esac
case "$(hermes_create_calls)" in
  0) _fail "3.3 前置自证" "kanban create 零调用——decoy 未拦截到 create，本用例空转" ;;
  *) _pass "3.3 前置自证：create 确实被发起后超时" ;;
esac
if [ -f "$SB_ROOT/contrib-data/.hermes-down" ]; then
  _fail "3.3 create 失败不写 down 计数" "create 自身超时后 .hermes-down 存在（值=$(down_value)）——只有 healthcheck 探测才驱动计数"
else
  _pass "3.3 create 自身失败不写 down 计数（探测成功即清，create 超时不 +1）"
fi
assert_eq "$(ev_key_count -hermes-down)" "0" "3.3 零 -hermes-down 事件（探测从未失败）"
sb_cleanup

# =============================================================================
t_case "3.4 run-watch flight 检查超时（B4）：hermes 挂死 + FLIGHT_TIMEOUT=1 → 视同失败走 fallback，不挂死整轮"
sb_new_or_die
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
seed_flight "t_old" "$(date +%s)"   # 在飞卡 running（若 list 不被超时打断 → 走「在飞跳过」支路）
seed_card_store "running"
decoy_hermes sleep
sb_run -e DECOY_SLEEP=5 -e FLIGHT_TIMEOUT=1 -e STUB_GH_ISSUES_FILE="$SB_ROOT/tmp/issues.json" \
  'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null; RC=$?
assert_exit 0 $RC "3.4 run-watch 整轮 exit 0（hermes 挂死被超时收割，不拖死链路）"
case "$(claude_scan_calls)" in
  0) _fail "3.4 挂死视同失败走 fallback" "list 超时后未走 fallback（FLIGHT_TIMEOUT seam 未消费=No-op；在飞跳过支路说明超时未生效）" ;;
  *) _pass "3.4 list 超时 → fallback claude 被调（$(claude_scan_calls) 次）" ;;
esac
flight_exists && _fail "3.4 flight 已清" "超时视同失败应清 flight 登记" || _pass "3.4 flight 登记已清"
FBEV="$(ev_key_count -scan-card-fallback)"
case "$FBEV" in
  0) _fail "3.4 fallback 事件入账" "零 -scan-card-fallback 事件" ;;
  *) _pass "3.4 -scan-card-fallback 事件入账" ;;
esac
sb_cleanup

# =============================================================================
t_case "3.5 env -u 经 hermes_call 统一封装：healthcheck 路带毒 env → 三变量全 absent"
sb_new_or_die
decoy_hermes stderr   # 委托真身 stub（记录 anthropic-env.log）
sb_run -e ANTHROPIC_BASE_URL=https://evil.example -e ANTHROPIC_AUTH_TOKEN=sk-test-1 -e ANTHROPIC_API_KEY=sk-test-2 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck' >/dev/null; RC=$?
assert_exit 0 $RC "3.5 healthcheck exit"
ENVLOG="$SB_ROOT/stublog/anthropic-env.log"
if [ ! -s "$ENVLOG" ]; then
  _fail "3.5 env 观测记录" "$ENVLOG 缺失/空（hermes 未被调用？）"
else
  PRESENT_N="$(grep -c '=present' "$ENVLOG" || true)"
  assert_eq "$PRESENT_N" "0" "3.5 子进程 env present 计数=0（env -u 剥离必须经统一封装）"
fi
sb_cleanup

# =============================================================================
t_case "3.6 隔离：seam 测试全程 notify approvals 零新增"
sb_new_or_die
decoy_hermes stderr
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
run_card create --kind scan --title t2-iso3 --body-file "$SB_ROOT/tmp/body.md" >/dev/null
assert_eq "$(notify_approvals)" "0" "3.6 notify-state approvals 零新增"
sb_cleanup

t_finish
