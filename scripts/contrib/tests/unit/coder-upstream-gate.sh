#!/bin/bash
# coder-upstream-gate.sh — Tier U：coder 卡 → 上游回馈评估闸门（coder_upstream_gate.sh）stub 测试矩阵
# 覆盖（设计用例矩阵）：
#   ① 三条件过滤：hermes-agent worktree + 领先 origin/main = 命中；零领先/目录缺失/martin
#      worktree/事件 key 已在账（jq 紧凑与 json.dumps 带空格双格式）= 过滤
#   ② 命中建卡：hermes calls.log 含 kanban create + --idempotency-key coder-upstream-<id>
#      （--kind upstream 由 kanban_card 消费、不入 hermes argv——kind 闭集另设专案断言）；
#      events.jsonl 出现该 key；游标=该卡 completed_at；card.json 落盘
#   ③ 幂等复跑：建卡调用数不变
#   ④ fail-closed：hermes 失败 stub → exit 1 零事件零游标；KANBAN_DB 不存在路径 → exit 1
#      零游标写零 hermes 调用
#   ⑤ 游标损坏重建：视同缺失 → init 2026-07-01 本地 epoch 底座（严格大于：恰等于 init 的行不回扫）
#   ⑥ body 文件内容：源卡 id/标题、红线「gh 只读」、verdict 双分支、收尾要求
#   ⑦ 带参数 exit 2；kanban_card --kind 闭集扩展专案；run-watch 段 2.6 静态锚
# 全部经 KANBAN_DB/CONTRIB_DATA_DIR/HERMES_BIN stub 沙箱隔离，零真实 hermes/gh 调用。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "coder-upstream-gate.sh"

GATE="$CONTRIB_TEST_TARGET/coder_upstream_gate.sh"

# 游标 init 底座：2026-07-01 00:00:00 本地时区 epoch（与被测脚本同一 python3 口径）
INIT_EPOCH="$(python3 -c 'import datetime; print(int(datetime.datetime(2026, 7, 1, 0, 0, 0).timestamp()))')"

# completed_at 定值（全部 > 2026-07-01；t_hit 为最大值 → 收尾游标恰为命中卡 completed_at）
EHIT="1789000100"
EBEHIND="1789000001"
EGHOST="1789000002"
EDUP="1789000003"
EDUP2="1789000004"
EMARTIN="1789000005"

DATA=""; GATE_DB=""; CURSOR=""; EVENTS=""; GLOG=""; CALLS=""; BODIES=""
new_sb() {
  sb_new >/dev/null 2>&1
  DATA="$SB_ROOT/contrib-data"
  GATE_DB="$SB_ROOT/kanban.db"
  CURSOR="$DATA/coder-upstream-cursor.json"
  EVENTS="$DATA/events.jsonl"
  GLOG="$DATA/logs/coder-upstream-gate.log"
  CALLS="$SB_ROOT/stublog/calls.log"
  BODIES="$DATA/card-bodies"
  mk_gate_db "$GATE_DB"
}

# ---------------- 夹具 ----------------

mk_gate_db() { # <db_path> — tasks 表只含被测所需列
  python3 - "$1" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "CREATE TABLE tasks (id TEXT, title TEXT, assignee TEXT, status TEXT,"
    " completed_at INTEGER, workspace_path TEXT)")
conn.commit()
conn.close()
PYEOF
}

add_row() { # <db> <id> <title> <completed_at> <workspace_path>
  python3 - "$@" <<'PYEOF'
import sqlite3, sys
db, tid, title, ts, ws = sys.argv[1:6]
conn = sqlite3.connect(db)
conn.execute(
    "INSERT INTO tasks (id, title, assignee, status, completed_at, workspace_path)"
    " VALUES (?, ?, 'coder', 'done', ?, ?)", (tid, title, int(ts), ws))
conn.commit()
conn.close()
PYEOF
}

mk_repo() { # <path> <ahead_n> — 真实 git 仓：origin/main 指基线，ahead_n 个本地领先 commit
  mkdir -p "$1"
  git init -q "$1" 2>/dev/null
  git -C "$1" -c user.email=t@example -c user.name=t commit -q --allow-empty -m base 2>/dev/null
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  local i=0
  while [ "$i" -lt "$2" ]; do
    git -C "$1" -c user.email=t@example -c user.name=t commit -q --allow-empty -m "ahead-$i" 2>/dev/null
    i=$((i + 1))
  done
}

seed_fixtures() { # 七行矩阵夹具 + t_dup/t_dup2 事件 key 双格式预置
  mk_repo "$SB_ROOT/ws/hermes-agent/.worktrees/t_hit" 1
  mk_repo "$SB_ROOT/ws/hermes-agent/.worktrees/t_behind" 0
  mk_repo "$SB_ROOT/ws/hermes-agent/.worktrees/t_dup" 2
  mk_repo "$SB_ROOT/ws/hermes-agent/.worktrees/t_dup2" 1
  mk_repo "$SB_ROOT/ws/hermes-agent/.worktrees/t_old" 1
  mk_repo "$SB_ROOT/ws/martin/.worktrees/t_martin" 3
  # t_ghost 目录刻意不建（worktree 缺失过滤探针）
  add_row "$GATE_DB" t_old "old below floor" "$INIT_EPOCH" "$SB_ROOT/ws/hermes-agent/.worktrees/t_old"
  add_row "$GATE_DB" t_behind "behind card" "$EBEHIND" "$SB_ROOT/ws/hermes-agent/.worktrees/t_behind"
  add_row "$GATE_DB" t_ghost "ghost card" "$EGHOST" "$SB_ROOT/ws/hermes-agent/.worktrees/t_ghost"
  add_row "$GATE_DB" t_dup "dup card" "$EDUP" "$SB_ROOT/ws/hermes-agent/.worktrees/t_dup"
  add_row "$GATE_DB" t_dup2 "dup2 card" "$EDUP2" "$SB_ROOT/ws/hermes-agent/.worktrees/t_dup2"
  add_row "$GATE_DB" t_martin "martin card" "$EMARTIN" "$SB_ROOT/ws/martin/.worktrees/t_martin"
  add_row "$GATE_DB" t_hit "the hit card" "$EHIT" "$SB_ROOT/ws/hermes-agent/.worktrees/t_hit"
  sb_seed_event coder-upstream-candidate "coder-upstream-t_dup" "seeded compact" contrib 0 false
  printf '{"ts": "2026-01-01T00:00:00+08:00", "class": "coder-upstream-candidate", "key": "coder-upstream-t_dup2", "channel": "contrib", "summary": "seeded spaced", "pushed": false, "attempts": 0, "pushed_at": null}\n' >>"$EVENTS"
}

# run_gate <kanban_db_path> [K=V ...] — 沙箱内 zsh 调闸门（镜像生产 run-watch 段 2.6 形态）
run_gate() {
  local db="$1"; shift
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"
    extra[${#extra[@]}]="$kv"
  done
  sb_run "${extra[@]+"${extra[@]}"}" -e "KANBAN_DB=$db" \
    'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh"'
}

create_calls() { # hermes stub 的 kanban create 调用数（healthcheck list 不计）
  awk -F'|' '$1 == "hermes"' "$CALLS" 2>/dev/null | grep -c ' create ' || true
}
event_key_present() { # <key> — notify.sh cmd_event 同款双格式 grep
  [[ -f "$EVENTS" ]] || return 1
  grep -qF "\"key\":\"$1\"" "$EVENTS" 2>/dev/null && return 0
  grep -qF "\"key\": \"$1\"" "$EVENTS" 2>/dev/null
}
cursor_val() { jq -r '.last_checked_epoch // empty' "$CURSOR" 2>/dev/null || true; }
num_lt() { # <a> <b> — 双数值才比较（grep 落空 → 判 false 不炸）
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -lt "$2" ]
}

# ---------------- ①+②+⑥ 三条件过滤 + 命中建卡 + body 内容 ----------------

t_case "过滤矩阵 + 命中建卡：恰 1 卡、事件入账、游标推进、card.json/body 落盘"
new_sb
seed_fixtures
out="$(run_gate "$GATE_DB")"
assert_exit 0 $?
assert_contains "$out" "hits=1" "stdout 一行摘要含命中数"
case "$out" in
  *$'\n'*) _fail "stdout 单行摘要" "多行: [$out]" ;;
  '') _fail "stdout 单行摘要" "空输出" ;;
  *) _pass "stdout 单行摘要" ;;
esac
assert_eq "$(create_calls)" "1" "恰 1 次 kanban create（6 张过滤卡零建卡）"
assert_file_contains "$CALLS" "--idempotency-key coder-upstream-t_hit" "create 携带幂等键 coder-upstream-t_hit"
for tid in t_behind t_ghost t_dup t_dup2 t_martin t_old; do
  assert_eq "$(grep -cF "coder-upstream-${tid}" "$CALLS" 2>/dev/null || true)" "0" \
    "过滤面零建卡痕迹: ${tid}"
done
event_key_present "coder-upstream-t_hit"
assert_exit 0 $? "events.jsonl 出现 coder-upstream-t_hit"
assert_eq "$(wc -l <"$EVENTS" | tr -d ' ')" "3" "事件账本恰 3 行（2 种子 + 1 新入账）"
assert_contains "$(tail -1 "$EVENTS")" '"class":"coder-upstream-candidate"' "新事件 class 精确串"
assert_eq "$(cursor_val)" "$EHIT" "游标推进=命中卡 completed_at"
jq -e 'type == "object" and (.last_checked_epoch | type == "number")' "$CURSOR" >/dev/null 2>&1
assert_exit 0 $? "游标文件为合法 JSON（last_checked_epoch 为数值）形态"
assert_file_contains "$GLOG" "评估卡已建 coder-upstream-t_hit" "自有日志留痕"
[[ -f "$GATE" && -x "$GATE" ]] && _pass "gate 脚本可执行（run-watch [[ -x ]] 守卫前提）" \
  || _fail "gate 脚本可执行（run-watch [[ -x ]] 守卫前提）" "$GATE 缺失或非可执行"

t_case "body 文件内容：源卡信息 + 红线 + verdict 双分支 + 领先 commit 列表（⑥）"
BODY="$BODIES/coder-upstream-t_hit.body.md"
assert_file_contains "$BODY" "源卡 id: t_hit" "body 含源卡 id"
assert_file_contains "$BODY" "源卡标题: the hit card" "body 含源卡标题"
assert_file_contains "$BODY" "$SB_ROOT/ws/hermes-agent/.worktrees/t_hit" "body 含 worktree 路径"
assert_file_contains "$BODY" "ahead-0" "body 列出领先 origin/main 的 commit"
assert_file_contains "$BODY" "gh 只读" "body 含红线「gh 只读」"
assert_file_contains "$BODY" "verdict=值得" "body 含 verdict=值得 分支"
assert_file_contains "$BODY" "verdict=不值得" "body 含 verdict=不值得 分支"
assert_file_contains "$BODY" "kanban_complete" "body 含收尾要求"
stubbody="$(stub_last_body hermes)"
if [[ -n "$stubbody" ]]; then
  assert_file_contains "$stubbody" "上游回馈评估卡" "hermes 收到的 body 副本同源"
else
  _fail "hermes 收到的 body 副本同源" "stub bodies 无 hermes 副本"
fi

# ---------------- ③ 幂等复跑 ----------------

t_case "幂等复跑：建卡调用数不变（③）"
before="$(create_calls)"
ev_before="$(wc -l <"$EVENTS" | tr -d ' ')"
run_gate "$GATE_DB" >/dev/null
assert_exit 0 $?
assert_eq "$(create_calls)" "$before" "建卡调用数不变"
assert_eq "$(wc -l <"$EVENTS" | tr -d ' ')" "$ev_before" "事件账本零新增"
assert_eq "$(cursor_val)" "$EHIT" "游标不回退不漂移"
run_gate "$GATE_DB" >/dev/null
assert_exit 0 $? "第三轮仍 exit 0（游标后零行）"

# ---------------- ④ fail-closed ----------------

t_case "fail-closed：hermes 失败 stub → exit 1 零事件零游标（④a）"
new_sb
seed_fixtures
run_gate "$GATE_DB" "STUB_HERMES_FAIL=1" >/dev/null
assert_exit 1 $?
if event_key_present "coder-upstream-t_hit"; then
  _fail "hermes 失败零事件入账" "events.jsonl 不应出现 coder-upstream-t_hit"
else
  _pass "hermes 失败零事件入账"
fi
if [[ -f "$CURSOR" ]]; then
  _fail "hermes 失败零游标写" "游标文件不应存在: $CURSOR"
else
  _pass "hermes 失败零游标写"
fi

t_case "fail-closed：KANBAN_DB 不存在路径 → exit 1 零游标写零 hermes 调用（④b）"
new_sb
run_gate "$SB_ROOT/missing.db" >/dev/null
assert_exit 1 $?
if [[ -f "$CURSOR" ]]; then
  _fail "查询失败零游标写" "游标文件不应存在: $CURSOR"
else
  _pass "查询失败零游标写"
fi
assert_stub_not_called hermes "查询失败零建卡链调用"

# ---------------- ⑤ 游标损坏重建 ----------------

t_case "游标损坏重建：视同缺失 → init 07-01 底座严格回扫 + 推进点重建（⑤）"
new_sb
seed_fixtures
printf 'GARBAGE-NOT-JSON{{{' >"$CURSOR"
run_gate "$GATE_DB" >/dev/null
assert_exit 0 $?
assert_eq "$(create_calls)" "1" "损坏视同缺失：从 07-01 底座回扫并命中 t_hit"
assert_eq "$(grep -cF 'coder-upstream-t_old' "$CALLS" 2>/dev/null || true)" "0" \
  "底座严格大于：completed_at 恰等于 init epoch 的 t_old 不被回扫"
assert_eq "$(cursor_val)" "$EHIT" "损坏游标在推进点重建为合法值"

# ---------------- ⑦ 用法错误 + kanban_card 闭集 + run-watch 静态锚 ----------------

t_case "用法错误：带任何参数 → exit 2（⑦）"
new_sb
sb_run 'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh" unexpected-arg' >/dev/null 2>&1
assert_exit 2 $?

t_case "kanban_card 闭集扩展：--kind upstream 接受、非法 kind 仍拒、usage 行文本与行数锚"
new_sb
printf '# upstream kind probe\n' >"$SB_ROOT/kc-body.md"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind upstream --title t --body-file "$MARTIN_DIR/kc-body.md"' >/dev/null 2>&1
assert_exit 0 $? "闭集接受 --kind upstream（create 路径通）"
assert_stub_called hermes 2 "upstream 卡真实经 hermes healthcheck+create"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind bogus --title t --body-file "$MARTIN_DIR/kc-body.md"' >/dev/null 2>&1
assert_exit 1 $? "闭集仍拒非法 kind"
assert_contains "$(sed -n '5p' "$CONTRIB_TEST_TARGET/kanban_card.sh")" "digest|upstream" \
  "usage 头第 5 行 kind 闭集文本含 upstream"
assert_eq "$(sed -n '2,9p' "$CONTRIB_TEST_TARGET/kanban_card.sh" | wc -l | tr -d ' ')" "8" \
  "usage 打印窗 2..9 行数不漂移"

t_case "run-watch 段 2.6 静态锚：形态逐字 + 位于 own-PR 段后、通知层前"
RW="$CONTRIB_TEST_TARGET/run-watch.sh"
assert_file_contains "$RW" 'run_phase 120 zsh "$UPSTREAM_GATE"' "段 2.6 run_phase 120 zsh 形态锚"
assert_file_contains "$RW" 'coder_upstream_gate 上游回馈闸门 exit=' "段 2.6 rc 日志行锚"
assert_file_contains "$RW" 'UPSTREAM_GATE="$MARTIN/scripts/contrib/coder_upstream_gate.sh"' "段 2.6 脚本路径锚"
ln_own="$(grep -n 'own_pr_watch own-PR 盯梢 exit' "$RW" 2>/dev/null | head -1 | cut -d: -f1)"
ln_gate="$(grep -n 'coder_upstream_gate 上游回馈闸门 exit' "$RW" 2>/dev/null | head -1 | cut -d: -f1)"
ln_flush="$(grep -n -- '--- 3. 通知层' "$RW" 2>/dev/null | head -1 | cut -d: -f1)"
if num_lt "$ln_own" "$ln_gate" && num_lt "$ln_gate" "$ln_flush"; then
  _pass "2.6 段位于 own-PR 段后、通知层前（own=${ln_own} < gate=${ln_gate} < flush=${ln_flush}）"
else
  _fail "2.6 段位于 own-PR 段后、通知层前" "ln_own=$ln_own ln_gate=$ln_gate ln_flush=$ln_flush"
fi

t_finish
