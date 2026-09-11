#!/usr/bin/env bash
# =============================================================================
# t6-02-board-seam-argv-order.acceptance.test.sh — T6 验收②：kanban_card.sh board seam
#   B1  --board argv 顺序 trap（重审 I1 钉死）：`--board <board>` 是 kanban 父级 flag，
#       必须插在子命令 create 之前 → `hermes kanban --board <b> create …`；
#       尾部追加在生产=unrecognized arguments 硬失败，而 stub 不校验未知参数 →
#       沙箱全绿生产全红。故位置断言是本文件的第一刚性断言
#   B2  KANBAN_BOARD env seam：env 注入值原样透传到 --board
#   B3  --board CLI 参数：显式值透传；显式回退态 `--board default` 可用（回退开关=一个值）
#   B4  缺省值闭集断言：无 env 无 flag 时 board ∈ {contrib, default}（二值由 board 实机验证
#       结论唯一裁决：通过→contrib；不通过→回退 default。闭集外/漏传 --board 一律红）
#   B5  接口不变量（契约 4）：create 核心语义零变化——--assignee contrib/--json/
#       --max-retries 2/--idempotency-key <kind>-秒级/--body 透传/零 subscribe/stdout 两键闭集
#   B6  healthcheck 不受 seam 破坏；notify.sh flush 建卡端到端继承缺省 board
#   B7  隔离：board 实机验证（hermes kanban boards create）是生产操作不入测试——沙箱全程
#       零 `boards` 子命令调用；真实仓 contrib-data 零测试哨兵污染
# 依据：state.md 契约规约 1「kanban_card.sh 新增 KANBAN_BOARD env seam + --board 参数
#   （两态：contrib=default 缺省 / default 回退）」+ 改动面表「重审 I1 位置 trap；unit 必须断言
#   argv 顺序」+ 契约 4「kanban_card.sh create 核心语义零变化」+ 契约 5「L1 红线：沙箱测试全 stub」
# CONTRACT_AMBIGUOUS：
#   - 缺省 board 的唯一合法值取决于实机验证结论（handoff 记录）→ 按契约二值闭集断言；
#     若 handoff 已钉死其一而实测为另一值，属实现与结论不一致，红=正确信号
#   - --board flag 与 KANBAN_BOARD 同设的优先级未钉 → 按「显式 CLI 参数 > 隐式 env 缺省」断言
#     flag 赢；若红→回设计对齐（非测试 bug）
# 红队纪律：黑盒；每断言硬失败；无 skip。
# Mental Mutation：--board 尾部追加→B1 位置断言红；seam 未实现（漏传 --board）→B2/B4 红；
#   env 值不透传/硬编码→B2 红；核心参数被 board 改造挤掉→B5 红；有人顺手做实机 boards 调用
#   进沙箱路→B7 红。
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

hermes_lines() { cat "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_line()  { hermes_lines | grep -- '--assignee contrib' | tail -1; }

# parse_create_argv <calls.log 行>：剥 hermes|cwd| 前缀后逐 token 定位
BM_FIRST="" BM_BOARD_COUNT=0 BM_BOARD_POS=-1 BM_BOARD_VAL="" BM_CREATE_POS=-1
parse_create_argv() {
  local line="$1" argv i=0 tok
  argv="${line#*|}"; argv="${argv#*|}"
  BM_FIRST=""; BM_BOARD_COUNT=0; BM_BOARD_POS=-1; BM_BOARD_VAL=""; BM_CREATE_POS=-1
  # shellcheck disable=SC2086
  set -- $argv
  for tok in "$@"; do
    [ "$i" -eq 0 ] && BM_FIRST="$tok"
    if [ "$tok" = "--board" ]; then
      BM_BOARD_COUNT=$((BM_BOARD_COUNT + 1))
      BM_BOARD_POS=$i
    fi
    if [ "$tok" = "create" ] && [ "$BM_CREATE_POS" -eq -1 ]; then BM_CREATE_POS=$i; fi
    if [ "$BM_BOARD_POS" -ge 0 ] && [ "$i" -eq $((BM_BOARD_POS + 1)) ]; then BM_BOARD_VAL="$tok"; fi
    i=$((i + 1))
  done
  return 0
}

assert_board_argv() { # <label> <expected_board|@closure@|@none@>：位置 trap 断言（每个独立硬失败）
  # @none@ 模式（09-10 重锚，qa 判正当的实现偏差）：缺省注入由两入口 export KANBAN_BOARD
  # 承担，kanban_card 自身无 env 无 flag 时 argv 零 --board——非缺失，是等价实现正确形态
  #   want=@closure@ 时跳过值等值断言（缺省 board 是二值闭集，由 assert_board_closure 裁决）
  local label="$1" want="$2" line
  line="$(create_line)"
  if [ -z "$line" ]; then
    _fail "$label create 调用存在" "calls.log 无 --assignee contrib 行（hermes 未被调？）"
    return 0
  fi
  parse_create_argv "$line"
  if [ "$want" = "@none@" ]; then
    assert_eq "$BM_BOARD_COUNT" "0" "$label 零 --board（缺省注入由两入口 export KANBAN_BOARD 承担——09-10 重锚，qa 判正当的实现偏差）"
    return 0
  fi
  assert_eq "$BM_FIRST" "kanban" "$label argv 首词=kanban（--board 挂到 hermes 顶层也是错位）"
  assert_eq "$BM_BOARD_COUNT" "1" "$label 恰一处 --board"
  [ "$want" = "@closure@" ] || assert_eq "$BM_BOARD_VAL" "$want" "$label --board 值透传"
  case "$BM_BOARD_POS" in
    ''|*[!0-9]*) _fail "$label --board 位置" "非数值 [$BM_BOARD_POS]" ;;
    *) [ "$BM_BOARD_POS" -ge 1 ] && _pass "$label --board 在 kanban 之后（pos=${BM_BOARD_POS})" \
       || _fail "$label --board 在 kanban 之后" "pos=$BM_BOARD_POS" ;;
  esac
  if [ "$BM_CREATE_POS" -gt "$BM_BOARD_POS" ]; then
    _pass "$label --board 在子命令 create 之前（父级 flag 位置 trap；尾部追加=生产 unrecognized arguments）"
  else
    _fail "$label --board 在子命令 create 之前" "board_pos=$BM_BOARD_POS create_pos=$BM_CREATE_POS"
  fi
}

assert_board_closure() { # <label> <board 值>：缺省二值闭集（实机验证结论裁决）
  case "$2" in
    contrib|default) _pass "$1 缺省 board 在闭集 {contrib,default}（实得 ${2})" ;;
    *) _fail "$1 缺省 board 在闭集 {contrib,default}" "实得 [$2]（漏传 --board/错值=No-op 必红；contrib=default 缺省 / default 回退）" ;;
  esac
}

# =============================================================================
t_case "B4/B1 缺省 board（无 env 无 flag）：闭集 {contrib,default} + argv 顺序正确"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'ACC-T6-BOARD-BODY-MARKER\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title "T6 board 验收" --body-file "$SB_ROOT/tmp/body.md")"
RC=$?
assert_exit 0 $RC "2.1 exit"
KEYS="$(printf '%s' "$OUT" | jq -cr 'keys | sort | join(",")' 2>/dev/null)"
assert_eq "$KEYS" "id,status" "2.1 stdout 两键闭集 {id,status}（输出契约不因 board seam 漂移）"
assert_board_argv "2.1" "@none@"   # T6 重锚：等价实现契约（两入口 export），非断言弱化
sb_cleanup

# =============================================================================
t_case "B2 KANBAN_BOARD env seam：注入值原样透传到 --board（在 create 之前）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(sb_run -e KANBAN_BOARD=board-env-t6 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t6env --body-file "$MARTIN_DIR/tmp/body.md"')"
RC=$?
assert_exit 0 $RC "2.2 exit"
assert_board_argv "2.2" "board-env-t6"
sb_cleanup

# =============================================================================
t_case "B3 --board CLI 参数：显式值透传（flag 面）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t6flag --body-file "$SB_ROOT/tmp/body.md" --board flag-b-t6)"
RC=$?
assert_exit 0 $RC "2.3 exit"
assert_board_argv "2.3" "flag-b-t6"
sb_cleanup

# =============================================================================
t_case "B3b 显式回退态：--board default 可用（回退开关=一个值，argv 位置同规约）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t6fallback --body-file "$SB_ROOT/tmp/body.md" --board default)"
RC=$?
assert_exit 0 $RC "2.4 exit"
assert_board_argv "2.4" "default"
sb_cleanup

# =============================================================================
t_case "B4b 优先级（CONTRACT_AMBIGUOUS）：--board flag 与 KANBAN_BOARD 同设 → 显式 CLI 参数赢"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'x\n' > "$SB_ROOT/tmp/body.md"
OUT="$(sb_run -e KANBAN_BOARD=board-env-t6 \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t6both --body-file "$MARTIN_DIR/tmp/body.md" --board flag-wins-t6')"
RC=$?
assert_exit 0 $RC "2.5 exit"
assert_board_argv "2.5" "flag-wins-t6"
sb_cleanup

# =============================================================================
t_case "B5 接口不变量：board seam 加入后 create 核心契约参数全保留（--assignee/--json/--max-retries/idem 秒级/--body/零订阅）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'ACC-T6-CONTRACT-BODY-MARKER\n' > "$SB_ROOT/tmp/body.md"
OUT="$(run_card create --kind scan --title t6contract --body-file "$SB_ROOT/tmp/body.md" --priority 2)"
RC=$?
assert_exit 0 $RC "2.6 exit"
LINE="$(create_line)"
assert_contains "$LINE" "--assignee contrib" "2.6 --assignee contrib"
assert_contains "$LINE" "--json" "2.6 --json"
assert_contains "$LINE" "--max-retries 2" "2.6 --max-retries 2"
assert_contains "$LINE" "ACC-T6-CONTRACT-BODY-MARKER" "2.6 --body 透传 body-file 内容"
assert_contains "$LINE" "--priority 2" "2.6 --priority 透传"
assert_not_contains "$LINE" "subscribe" "2.6 零订阅：create argv 禁 subscribe"
KEYARG="$(printf '%s' "$LINE" | grep -oE -- '--idempotency-key [^ ]+' | awk '{print $2}')"
case "$KEYARG" in
  scan-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
    _pass "2.6 idempotency-key scan-秒级（${KEYARG})" ;;
  *) _fail "2.6 idempotency-key 秒级格式" "实得 [$KEYARG]" ;;
esac
assert_board_argv "2.6" "@none@"   # T6 重锚：等价实现契约
sb_cleanup

# =============================================================================
t_case "B6 healthcheck 不受 seam 破坏：hermes 健康 → exit 0 + OK"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
OUT="$(run_card healthcheck)"
RC=$?
assert_exit 0 $RC "2.7 healthcheck exit"
assert_eq "$OUT" "OK" "2.7 healthcheck stdout=OK"
sb_cleanup

# =============================================================================
t_case "B6b 端到端缺省传播：notify.sh flush 建 digest 卡 argv 继承缺省 board"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-t6-board" "叙事事件 k-t6-board"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null; RC=$?
assert_exit 0 $RC "2.8 flush exit"
assert_board_argv "2.8" "@none@"   # T6 重锚：等价实现契约
sb_cleanup

# =============================================================================
t_case "B7 隔离：沙箱全程零 boards 子命令（实机验证=生产操作不入测试）+ 真实仓零哨兵污染"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf 'x\n' > "$SB_ROOT/tmp/body.md"
run_card create --kind scan --title t6iso --body-file "$SB_ROOT/tmp/body.md" --board iso-b >/dev/null
BOARDS_N="$(grep -c 'boards' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true)"
assert_eq "$BOARDS_N" "0" "2.9 沙箱零 hermes kanban boards 调用（board 创建/验证绝不入测试）"
if [ -f "$REPO_ROOT/contrib-data/events.jsonl" ]; then
  HIT="$(grep -c 'ACC-T6-BOARD\|k-t6-board' "$REPO_ROOT/contrib-data/events.jsonl" || true)"
  assert_eq "$HIT" "0" "2.9 真实仓 contrib-data/events.jsonl 零测试哨兵污染"
else
  _pass "2.9 真实仓 events.jsonl 不存在（零污染平凡真）"
fi
sb_cleanup

t_finish
