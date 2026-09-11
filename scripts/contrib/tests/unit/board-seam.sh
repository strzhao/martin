#!/bin/bash
# board-seam.sh — Tier U：contrib 专用 board seam（T6）stub 测试矩阵
# 覆盖：
#   ① kanban_card.sh --board/KANBAN_BOARD seam：argv 顺序断言（--board 是 kanban 父级 flag，
#      必须插在子命令前——`hermes kanban --board X create`；尾部追加=unrecognized arguments
#      硬失败，且 stub 不校验未知参数→沙箱全绿生产全红的 trap，重审 I1）
#   ② 两态：KANBAN_BOARD 非空 → pin；空/缺省 → 零 --board（现状语义=回退态）
#   ③ 查询路径同源 pin：run-watch flight list / notify digest list / deepcheck harvest list
#   ④ 回退开关：入口不 export 时全链零 --board（default board 语义不变）
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN stub 沙箱隔离，零真实 hermes 调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "board-seam.sh"

[[ -f "$CONTRIB_TEST_TARGET/kanban_card.sh" ]] || { echo "FATAL: 找不到 $CONTRIB_TEST_TARGET/kanban_card.sh"; exit 1; }

# hermes_lines → calls.log 中全部 hermes 行
hermes_lines() { grep '^hermes|' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null || true; }

# assert_board_pinned <slug> <sub> <label>：calls.log 存在「kanban --board <slug> <sub>」顺序形态
# （父级 flag 位置 trap 的核心断言：--board 必须落在 kanban 与子命令之间）
assert_board_pinned() { # <slug> <sub> <label>
  if hermes_lines | grep -qE "kanban --board $1 $2( |$)"; then
    _pass "$3"
  else
    _fail "$3" "calls.log 无 [kanban --board $1 $2] 顺序形态（行样例: $(hermes_lines | grep 'kanban' | tail -1 | head -c 200)）"
  fi
}

# assert_unpinned <label>：全部 hermes 行零 --board（回退态）
assert_unpinned() { # <label>
  if hermes_lines | grep -q -- "--board"; then
    _fail "$1" "应零 --board 却出现（行样例: $(hermes_lines | grep -- '--board' | head -1 | head -c 200)）"
  else
    _pass "$1"
  fi
}

mk_body() { printf '红线占位 BOARD-SEAM-BODY\n' >"$SB_ROOT/seam-body.md"; }

# ---------------- ① kanban_card.sh create/healthcheck ----------------

t_case "kanban_card: KANBAN_BOARD=contrib → create argv 父级位置 pin（kanban --board contrib create）"
sb_new >/dev/null 2>&1
mk_body
sb_run -e "KANBAN_BOARD=contrib" \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/seam-body.md"' >/dev/null 2>&1
assert_exit 0 $?
assert_board_pinned "contrib" "create" "create argv 顺序=kanban --board contrib create（父级 flag 位置）"
assert_contains "$(hermes_lines | grep 'kanban --board' | tail -1)" "--assignee contrib" "pin 态下既有契约参数不丢（--assignee）"

t_case "kanban_card: --board 参数覆盖 env（显式优先）"
sb_new >/dev/null 2>&1
mk_body
sb_run -e "KANBAN_BOARD=contrib" \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --board explicit-b --title t --body-file "$MARTIN_DIR/seam-body.md"' >/dev/null 2>&1
assert_exit 0 $?
assert_board_pinned "explicit-b" "create" "--board 参数覆盖 KANBAN_BOARD env"

t_case "kanban_card: KANBAN_BOARD 空 → 零 --board（回退态语义）"
sb_new >/dev/null 2>&1
mk_body
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind scan --title t --body-file "$MARTIN_DIR/seam-body.md"' >/dev/null 2>&1
assert_exit 0 $?
assert_unpinned "KANBAN_BOARD 空 → create 零 --board（seam 空=不 pin）"

t_case "kanban_card: healthcheck 同步 pin（kanban --board contrib list）"
sb_new >/dev/null 2>&1
sb_run -e "KANBAN_BOARD=contrib" 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck' >/dev/null 2>&1
assert_exit 0 $?
assert_board_pinned "contrib" "list" "healthcheck argv 顺序=kanban --board contrib list"

# ---------------- ③ 查询路径同源 pin ----------------

# watch_sb/gh_issue：与 scan-cardify 同构的最小 run-watch 前置态
gh_issue() {
  jq -cn --argjson n "$1" --arg t "$2" \
    '{number:$n,title:$t,labels:[],pull_request:null,user:{login:"someone"},created_at:"2026-09-10T00:00:00Z",comments:0}'
}
watch_sb() {
  sb_new >/dev/null 2>&1
  printf '{"last_issue":2000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  { gh_issue 2001 "a"; } >"$SB_ROOT/gh.rows"
  jq -s . "$SB_ROOT/gh.rows" >"$SB_ROOT/gh-issues.json"
}
run_watch() {
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" \
    -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}
seed_scan_flight() { # <card_id> — 在飞登记 + 卡库同 id（驱动 flight list 查询分支）
  jq -n --arg id "$1" --arg bf "" --argjson e "$(date +%s)" \
    '{kind:"scan",card_id:$id,batch_file:$bf,created_epoch:$e}' \
    >"$SB_ROOT/contrib-data/kanban-flight-scan.json"
  printf '{"id":"%s","status":"running","assignee":"contrib","priority":0}\n' "$1" \
    >"$SB_ROOT/stublog/kanban-cards.jsonl"
}

t_case "run-watch: KANBAN_BOARD=contrib → flight 查询 pin（kanban --board contrib list，在飞跳过）"
watch_sb
seed_scan_flight "t_old"
run_watch "KANBAN_BOARD=contrib"
assert_exit 0 $?
assert_board_pinned "contrib" "list" "run-watch flight 查询 argv 顺序=kanban --board contrib list"
assert_stub_not_called claude "在飞跳过零 fallback（pin 态行为不变）"

t_case "run-watch: KANBAN_BOARD=contrib 无 flight → 建卡经 kanban_card 子进程继承 env 同步 pin"
watch_sb
run_watch "KANBAN_BOARD=contrib"
assert_exit 0 $?
assert_board_pinned "contrib" "create" "run-watch 建卡 argv 顺序=kanban --board contrib create（env 继承）"

t_case "run-watch: KANBAN_BOARD 显式空（回退开关）→ 查询与建卡全链零 --board（回退态回归）"
watch_sb
seed_scan_flight "t_old"
run_watch
assert_exit 0 $?
assert_unpinned "回退开关（外部 export KANBAN_BOARD=\"\"）→ run-watch 全链零 --board（入口 export 用 \${KANBAN_BOARD-contrib}：显式空串不被缺省吞掉）"

t_case "notify: KANBAN_BOARD=contrib → digest 卡状态查询 pin（kanban --board contrib list）"
sb_new >/dev/null 2>&1
sb_seed_event pipeline-failure "seam-digest-key" "叙事事件占位" contrib 0 false
mkdir -p "$SB_ROOT/contrib-data/pending"
snap="$SB_ROOT/contrib-data/pending/seam-digest-snap.json"
printf '[{"key":"seam-digest-key","class":"pipeline-failure","summary":"x"}]\n' >"$snap"
jq -n --arg id "t_dg" --arg bf "$snap" --argjson e "$(date +%s)" \
  '{kind:"digest",card_id:$id,batch_file:$bf,created_epoch:$e}' \
  >"$SB_ROOT/contrib-data/kanban-flight-digest.json"
printf '{"id":"t_dg","status":"running","assignee":"contrib","priority":0}\n' >"$SB_ROOT/stublog/kanban-cards.jsonl"
sb_run -e "KANBAN_BOARD=contrib" -e "NOTIFY_DRY_RUN=true" \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
assert_board_pinned "contrib" "list" "notify digest 查询 argv 顺序=kanban --board contrib list"

t_case "deepcheck: KANBAN_BOARD=contrib → harvest 查询 pin（kanban --board contrib list）"
sb_new >/dev/null 2>&1
jq -n --arg id "t_dc" --arg rq "rq-20260910-9001" --arg lane "deep" --argjson e "$(date +%s)" \
  '{kind:"deepcheck",card_id:$id,rq_id:$rq,lane:$lane,batch_file:"",created_epoch:$e}' \
  >"$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"
printf '{"id":"t_dc","status":"running","assignee":"contrib","priority":0}\n' >"$SB_ROOT/stublog/kanban-cards.jsonl"
sb_run -e "KANBAN_BOARD=contrib" 'bash "$MARTIN_DIR/scripts/contrib/deepcheck_card.sh" harvest' >/dev/null 2>&1
assert_exit 0 $?
assert_board_pinned "contrib" "list" "deepcheck harvest 查询 argv 顺序=kanban --board contrib list"

t_finish
