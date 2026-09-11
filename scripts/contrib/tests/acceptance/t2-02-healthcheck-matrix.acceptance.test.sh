#!/usr/bin/env bash
# =============================================================================
# t2-02-healthcheck-matrix.acceptance.test.sh — T2 验收矩阵②：kanban_card.sh healthcheck 5 态 + create 前置 gate
#   ①hermes 正常 → exit 0 + stdout 以 OK 开头 + down 计数文件清除
#   ②单败（第 1 次）→ exit 1 + stdout 以 FAIL 开头 + `-hermes-down` event 恰 1 条 + down=1
#   ③再败（连续第 2 次）→ exit 3 + down=2 + `-hermes-down` 仍恰 1 条（幂等）
#   ④down>=2 时 create → exit≠0 + 零 kanban create 调用（跳过主路走 fallback）
#   ⑤恢复 → healthcheck exit 0 + down 清零 + create 恢复正常
#   附加钉死点：exit 闭集 {0,1,3}；down 文件 $CONTRIB/.hermes-down 单整数；
#   create 前置 gate 读法 a——down=1（首次失败已告警）仍继续尝试建卡，且 create stdout
#   恒为一行 {id,status}（create 路径内 healthcheck 的 stdout 不得污染主 stdout）。
# 依据：state.md「## 设计文档」§1（healthcheck 子命令 + down 计数 + create 前置 gate）
#   + 任务级契约「healthcheck 输出闭集：exit 0=健康（stdout 以 OK 开头）/ exit 1=单次失败
#   （stdout 以 FAIL 开头，且首次失败 emit -hermes-down event）/ exit 3=连续>=2 次失败」
#   「down 计数 schema：$CONTRIB/.hermes-down = 单个整数字符串；仅由 healthcheck 读写；恢复即清零」
# 影子 stub 契约：tests/stubs/hermes 正常/STUB_HERMES_FAIL=1 失败；「list 坏 create 好」的
#   选择性失败用测试本地 decoy 包装实现（委托真身 stub，仅拦 kanban list）——不依赖蓝队新增旋钮。
# CONTRACT_AMBIGUOUS：
#   - down 计数跨天「不设 TTL」口径无法在秒级测试里做时间旅行——以「连续失败即 +1、
#     唯一清零条件=成功」的直测覆盖（2.2→2.3 连续性 + 2.6 成功清零）。
# 红队纪律：黑盒；每断言硬失败；无 skip。Mutation 自检：down 只增不清 → ①⑥红；
#   exit 3 误用 exit 2 → ③红；count>=2 仍建卡 → ④红；down=1 拒建卡 → ⑤红。
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

run_card() { # 黑盒调用沙箱内 kanban_card.sh
  local a snippet=""
  for a in "$@"; do snippet+="$(printf '%q ' "$a")"; done
  sb_run "bash \"\$MARTIN_DIR/scripts/contrib/kanban_card.sh\" $snippet"
}

decoy_hermes() { # <listfail> — 测试本地 decoy 包装：拦 kanban list 令其失败，其余委托真身 stub
  cp "$SB_ROOT/bin/hermes" "$SB_ROOT/tmp/hermes.real" || { _fail "decoy_hermes" "备份真身失败"; t_finish; }
  {
    printf '#!/bin/bash\n'
    printf '# t2-02 decoy：仅 kanban list 失败（healthcheck 探测路），create 走真身\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = "list" ]; then\n'
    printf '    echo "decoy: kanban list 不可用（healthcheck 注毒）" >&2\n'
    printf '    exit 1\n'
    printf '  fi\n'
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$SB_ROOT/tmp/hermes.real"
  } > "$SB_ROOT/bin/hermes"
  chmod +x "$SB_ROOT/bin/hermes"
}

restore_hermes() { cp "$CONTRIB_TEST_STUBS/hermes" "$SB_ROOT/bin/hermes"; }

down_path() { printf '%s/contrib-data/.hermes-down' "$SB_ROOT"; }
down_value() { tr -d '[:space:]' < "$(down_path)" 2>/dev/null || true; }
down_exists() { [ -f "$(down_path)" ]; }

hermes_create_calls() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'kanban create' || true; }
hermes_list_calls() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'kanban list' || true; }

ev_key_count() { # <key 后缀>
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

notify_approvals() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

sb_new_or_die() { sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }; }

# =============================================================================
t_case "2.1 hermes 正常 → exit 0 + stdout OK* + down 计数文件清除（预置 down=2 验证清零路径）"
sb_new_or_die
mkdir -p "$SB_ROOT/contrib-data"
printf '2\n' > "$(down_path)"   # 预置非零计数：成功必须 rm 而非留着
OUT="$(run_card healthcheck)"; RC=$?
assert_exit 0 $RC "2.1 exit 0=健康（输出闭集钉死）"
case "$OUT" in OK*) _pass "2.1 stdout 以 OK 开头" ;; *) _fail "2.1 stdout 以 OK 开头" "实得 [${OUT:0:80}]" ;; esac
down_exists && _fail "2.1 down 文件清除" "healthcheck 成功后 .hermes-down 仍存在（唯一清零条件=成功）" || _pass "2.1 down 文件已清除"
case "$(hermes_list_calls)" in
  0) _fail "2.1 探测形态" "healthcheck 零 kanban list 调用（未探测=假健康）" ;;
  *) _pass "2.1 探测经 hermes kanban list（$(hermes_list_calls) 次）" ;;
esac
sb_cleanup

# =============================================================================
t_case "2.2 第 1 次失败 → exit 1 + FAIL* + -hermes-down event 恰 1 条 + down=1"
sb_new_or_die
decoy_hermes
OUT="$(run_card healthcheck)"; RC=$?
assert_exit 1 $RC "2.2 exit 1=单次失败（输出闭集钉死，非 2/非 3）"
case "$OUT" in FAIL*) _pass "2.2 stdout 以 FAIL 开头" ;; *) _fail "2.2 stdout 以 FAIL 开头" "实得 [${OUT:0:80}]" ;; esac
down_exists && _pass "2.2 down 文件落盘" || _fail "2.2 down 文件落盘" ".hermes-down 未产出"
assert_eq "$(down_value)" "1" "2.2 down 计数=1（单整数 schema）"
assert_eq "$(ev_key_count -hermes-down)" "1" "2.2 -hermes-down event 恰 1 条（首次失败告警）"
sb_cleanup

# =============================================================================
t_case "2.3 连续第 2 次失败 → exit 3 + down=2 + -hermes-down 仍恰 1 条（不重复告警）"
sb_new_or_die
decoy_hermes
run_card healthcheck >/dev/null   # 第 1 次：exit 1 + down=1（前置，上用例已单独验证）
OUT="$(run_card healthcheck)"; RC=$?
assert_exit 3 $RC "2.3 exit 3=连续>=2 次失败（调用方应跳过主路的信号）"
assert_eq "$(down_value)" "2" "2.3 down 计数=2"
assert_eq "$(ev_key_count -hermes-down)" "1" "2.3 -hermes-down 仍恰 1 条（幂等 key，第 2 次失败不重复告警）"
sb_cleanup

# =============================================================================
t_case "2.4 down>=2 时 create → exit≠0 + 零 kanban create 调用（跳过建卡走 fallback）"
sb_new_or_die
printf '2\n' > "$(down_path)"   # 契约钉死的 down 文件路径/格式作为 fixture
decoy_hermes
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
run_card create --kind scan --title t2-skip --body-file "$SB_ROOT/tmp/body.md"; RC=$?
case "$RC" in
  0) _fail "2.4 down>=2 拒建卡" "连续不可用下 create 仍 exit 0（前置 gate 缺失=No-op）" ;;
  *) _pass "2.4 create exit≠0（rc=${RC}）" ;;
esac
assert_eq "$(hermes_create_calls)" "0" "2.4 零 kanban create 调用（exit≠0 且未发起建卡）"
ERR="$(sb_out 40 | tr -d '[:space:]')"
[ -n "$ERR" ] && _pass "2.4 stderr 含失败原因" || _fail "2.4 stderr 含失败原因" "stderr 为空"
sb_cleanup

# =============================================================================
t_case "2.5 down=1（首败已告警）时 create 仍尝试：exit 0 + stdout 恒一行 {id,status} + create 恰 1 次"
sb_new_or_die
decoy_hermes
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t2-probe1 --body-file "$SB_ROOT/tmp/body.md")"; RC=$?
assert_exit 0 $RC "2.5 down=1 仍继续尝试建卡（读法 a：首次失败告警不拦截）"
NLINES="$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "$NLINES" "1" "2.5 create stdout 恒一行（healthcheck 的 stdout 不得污染主 stdout）"
KEYS="$(printf '%s' "$OUT" | jq -cr 'keys | sort | join(",")' 2>/dev/null)"
assert_eq "$KEYS" "id,status" "2.5 键闭集恰 {id,status}（T1 契约不回归）"
assert_eq "$(hermes_create_calls)" "1" "2.5 kanban create 恰 1 次被调"
assert_eq "$(ev_key_count -hermes-down)" "1" "2.5 前置探测失败已 emit -hermes-down 恰 1 条"
assert_eq "$(down_value)" "1" "2.5 down 保持 1（探测失败计数；create 成功不清零）"
sb_cleanup

# =============================================================================
t_case "2.6 恢复 → healthcheck exit 0 + down 清零 + create 恢复正常（down>=2 后回到主路）"
sb_new_or_die
decoy_hermes
run_card healthcheck >/dev/null
run_card healthcheck >/dev/null   # 连续两败 → down=2（前置）
assert_eq "$(down_value)" "2" "2.6 前置：down=2"
restore_hermes                     # hermes 恢复（stub 回真身）
OUT="$(run_card healthcheck)"; RC=$?
assert_exit 0 $RC "2.6 恢复后 healthcheck exit 0"
down_exists && _fail "2.6 down 清零" "恢复成功后 .hermes-down 仍存在" || _pass "2.6 down 文件已清除（清零）"
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t2-recover --body-file "$SB_ROOT/tmp/body.md")"; RC=$?
assert_exit 0 $RC "2.6 create 恢复正常"
assert_eq "$(hermes_create_calls)" "1" "2.6 kanban create 被调（主路回归）"
NLINES="$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "$NLINES" "1" "2.6 create stdout 恒一行"
sb_cleanup

# =============================================================================
t_case "2.7 隔离：healthcheck/create 全程 notify approvals 零新增、事件只在沙箱账本"
sb_new_or_die
decoy_hermes
run_card healthcheck >/dev/null
run_card healthcheck >/dev/null
printf 'acc-t2 body marker\n' > "$SB_ROOT/tmp/body.md"
run_card create --kind scan --title t2-iso --body-file "$SB_ROOT/tmp/body.md" >/dev/null
assert_eq "$(notify_approvals)" "0" "2.7 notify-state approvals 零新增（零订阅零外发）"
CLASSES="$(jq -sr '[.[].class] | unique | join(",")' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null)"
assert_eq "$CLASSES" "pipeline-failure" "2.7 事件类闭集=pipeline-failure（无越权事件类）"
sb_cleanup

t_finish
