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

# ---------------- 新增夹具 helper（第二段 D1/D2 用例；并行新增，不改既有 helper） ----------------

EHITD="1789000101"    # ① 已投递命中卡 completed_at
EDEGA="1789000102"    # ③a 退化候选卡 completed_at（同用例两卡同值）
EDEGB="1789000103"    # ③b 对象缺失候选卡 completed_at
EEMP="1789000104"     # ③c 空 diff 候选卡 completed_at
EEVENT="1789000105"   # ⑥ 事件失败候选卡 completed_at
EPIN="1789000106"     # ④a board pin 候选卡 completed_at
ENOHIT="1789000107"   # ② 未命中候选卡 completed_at

mk_repo_change() { # <path> <filename> <content> — mk_repo 形态底座 + 1 个真实 diff 领先 commit
  mk_repo "$1" 0
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@example -c user.name=t commit -q -m "real-fix-$2"
}

mk_deliv_twin() { # <ws> <refname> — 同 tree 异 message 孪生 commit（异 sha 同 patch-id）挂 ref
  local ws="$1" ref="$2" tree base twin
  tree="$(git -C "$ws" rev-parse 'HEAD^{tree}')"
  base="$(git -C "$ws" rev-parse refs/remotes/origin/main)"
  twin="$(git -C "$ws" -c user.email=o@example -c user.name=other \
    commit-tree "$tree" -p "$base" -m "twin-$ref")"
  git -C "$ws" update-ref "$ref" "$twin"
}

mk_unrelated_ref() { # <ws> <refname> — 不同 diff 的无关 commit 挂 ref（判重未命中探针）
  local ws="$1" ref="$2" orig base
  orig="$(git -C "$ws" rev-parse HEAD)"
  base="$(git -C "$ws" rev-parse refs/remotes/origin/main)"
  git -C "$ws" checkout -q -b unrel-tmp "$base"
  printf 'unrelated\n' >"$ws/unrelated.txt"
  git -C "$ws" add -A
  git -C "$ws" -c user.email=t@example -c user.name=t commit -q -m unrelated
  git -C "$ws" update-ref "$ref" HEAD
  git -C "$ws" checkout -q "$orig"
  git -C "$ws" branch -q -D unrel-tmp
}

mk_git_shim_no_patchid() { # 沙箱 shim git 换包装器：仅 patch-id 子命令 exit 1，其余 exec 真身
  local real
  real="$(command -v git)"
  rm -f "$SB_ROOT/shim/git"   # 先摘符号链接（rm 只断链不碰真身），再落包装器
  cat >"$SB_ROOT/shim/git" <<EOF
#!/bin/bash
# 测试注入：patch-id 子命令一律失败（其余透传真身）——判重退化放行用例
if [ "\${1:-}" = "patch-id" ]; then
  exit 1
fi
exec "$real" "\$@"
EOF
  chmod +x "$SB_ROOT/shim/git"
}

del_tree_of() { # <ws> — 删 HEAD commit 的 tree 对象（log rc=0 而 git show rc=128 的陷阱注入）
  local ws="$1" tree
  tree="$(git -C "$ws" rev-parse 'HEAD^{tree}')"
  rm -f "$ws/.git/objects/${tree:0:2}/${tree:2}"
}

event_row_by_key() { # <key> → 该 key 首行事件 JSON（无=空）
  jq -c --arg k "$1" 'select(.key == $k)' "$EVENTS" 2>/dev/null | head -1
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

# ---------------- 第二段增补用例（D1 patch-id 判重 + D2 board pin；契约 8-13） ----------------

t_case "已投递命中：patch-id 命中 refs/heads/contrib 孪生 ⇒ 零建卡+delivered 事件+summary 已投递+ref 短名+游标收尾推进（D1①）"
new_sb
mk_repo_change "$SB_ROOT/ws/hermes-agent/.worktrees/t_pidhit" fix.txt "real change A"
mk_deliv_twin "$SB_ROOT/ws/hermes-agent/.worktrees/t_pidhit" refs/heads/contrib/pidhit
add_row "$GATE_DB" t_pidhit "pid hit card" "$EHITD" "$SB_ROOT/ws/hermes-agent/.worktrees/t_pidhit"
out="$(run_gate "$GATE_DB")"
assert_exit 0 $?
assert_eq "$(create_calls)" "0" "命中已投递零建卡（删条件 d 则红）"
assert_contains "$out" "delivered=1" "stdout 摘要含 delivered=1 计数"
DELIV_ROW="$(event_row_by_key coder-upstream-t_pidhit)"
assert_eq "$(jq -r '.class // ""' <<<"$DELIV_ROW" 2>/dev/null)" "coder-upstream-delivered" "事件 class=coder-upstream-delivered"
assert_contains "$DELIV_ROW" "已投递" "事件 summary 明示已投递"
assert_contains "$DELIV_ROW" "contrib/pidhit" "事件 summary 含命中 ref 短名（剥 refs/heads/）"
assert_eq "$(jq -s '[.[] | select(.key == "coder-upstream-t_pidhit")] | length' "$EVENTS" 2>/dev/null)" "1" "同 key 事件恰 1 行（与建卡同 key 幂等锚）"
assert_eq "$(cursor_val)" "$EHITD" "零建卡行游标经收尾 max_seen 推进"
assert_file_contains "$GLOG" "已投递跳过建卡: task=t_pidhit" "命中留痕可定位"

t_case "判重未命中：refs/remotes/fork ref 指不同 diff ⇒ 照常建卡 hits 语义不变（D1②回归）"
new_sb
mk_repo_change "$SB_ROOT/ws/hermes-agent/.worktrees/t_nohit" fix.txt "real change B"
mk_unrelated_ref "$SB_ROOT/ws/hermes-agent/.worktrees/t_nohit" refs/remotes/fork/contrib/other
add_row "$GATE_DB" t_nohit "no hit card" "$ENOHIT" "$SB_ROOT/ws/hermes-agent/.worktrees/t_nohit"
out="$(run_gate "$GATE_DB")"
assert_exit 0 $?
assert_contains "$out" "hits=1" "未命中照常建卡（hits=1 语义不变）"
assert_contains "$out" "delivered=0" "未命中零 delivered 计数"
assert_eq "$(create_calls)" "1" "未命中恰 1 次建卡"
NOHIT_ROW="$(event_row_by_key coder-upstream-t_nohit)"
assert_eq "$(jq -r '.class // ""' <<<"$NOHIT_ROW" 2>/dev/null)" "coder-upstream-candidate" "事件 class 仍 coder-upstream-candidate"
assert_eq "$(cursor_val)" "$ENOHIT" "游标推进=命中卡 completed_at"

t_case "判重退化：git patch-id 不可用 ⇒ 留痕整轮恰一次、两候选保守放行照常建卡（D1③a）"
new_sb
mk_repo_change "$SB_ROOT/ws/hermes-agent/.worktrees/t_deg_a1" fix.txt "real change C1"
mk_repo_change "$SB_ROOT/ws/hermes-agent/.worktrees/t_deg_a2" fix.txt "real change C2"
add_row "$GATE_DB" t_deg_a1 "deg a1" "$EDEGA" "$SB_ROOT/ws/hermes-agent/.worktrees/t_deg_a1"
add_row "$GATE_DB" t_deg_a2 "deg a2" "$EDEGA" "$SB_ROOT/ws/hermes-agent/.worktrees/t_deg_a2"
mk_git_shim_no_patchid
run_gate "$GATE_DB" >/dev/null
assert_exit 0 $?
assert_eq "$(create_calls)" "2" "退化放行：两候选照常建卡"
assert_eq "$(grep -cF '判重退化放行' "$GLOG" 2>/dev/null || true)" "1" "退化留痕整轮恰一次（探测一次性）"
assert_eq "$(cursor_val)" "$EDEGA" "退化轮游标照常收尾推进"

t_case "判重单项对象缺失：删 tree 后 git show 失败 ⇒ 该项跳过留痕、保守放行照常建卡（D1③b）"
new_sb
WS_B="$SB_ROOT/ws/hermes-agent/.worktrees/t_deg_b"
mk_repo_change "$WS_B" fix.txt "real change D"
del_tree_of "$WS_B"
add_row "$GATE_DB" t_deg_b "deg b" "$EDEGB" "$WS_B"
run_gate "$GATE_DB" >/dev/null
assert_exit 0 $?
assert_eq "$(create_calls)" "1" "单项不可得仍保守放行建卡"
assert_file_contains "$GLOG" "判重单项跳过" "跳过留痕存在"
assert_file_contains "$GLOG" "task=t_deg_b" "留痕可定位到该卡（含 sha）"
assert_eq "$(cursor_val)" "$EDEGB" "放行轮游标照常推进"

t_case "空 diff commit + 孪生空 ref：双侧空 patch-id 跳过 ⇒ 照常建卡（D1③c，既有 mk_repo 形态不误伤）"
new_sb
WS_C="$SB_ROOT/ws/hermes-agent/.worktrees/t_empty"
mk_repo "$WS_C" 1                                   # 空 diff ahead commit（既有形态；HEAD=空 commit）
mk_deliv_twin "$WS_C" refs/remotes/fork/contrib/emptytwin   # 孪生空 ref（异 sha 同空 diff）
printf 'real change\n' >"$WS_C/fix.txt"             # 再叠 1 个真实 diff ahead commit：
git -C "$WS_C" add -A                               # 候选集非空 ⇒ ref 侧空 diff 跳过路径可达
git -C "$WS_C" -c user.email=t@example -c user.name=t commit -q -m real-fix
add_row "$GATE_DB" t_empty "empty diff card" "$EEMP" "$WS_C"
run_gate "$GATE_DB" >/dev/null
assert_exit 0 $?
assert_eq "$(create_calls)" "1" "空 patch-id 不误伤：照常建卡"
assert_file_contains "$GLOG" "判重单项跳过" "候选侧空 diff 跳过留痕"
assert_file_contains "$GLOG" "判重 ref 头跳过" "ref 侧空 diff 跳过留痕"

t_case "board pin 对照（④b）：直调 kanban_card.sh create 携 HERMES_KANBAN_DB 注入 ⇒ stub 观测 present"
new_sb
printf '# board pin probe\n' >"$SB_ROOT/kcdb-body.md"
sb_run -e "HERMES_KANBAN_DB=$SB_ROOT/decoy/injected.db" \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind upstream --title t --body-file "$MARTIN_DIR/kcdb-body.md"' >/dev/null 2>&1
assert_exit 0 $?
assert_file_contains "$SB_ROOT/stublog/kanban-db-env.log" "hermes|present" \
  "对照运行 stub 观测 HERMES_KANBAN_DB present（观测面有效，使 ④a 非平凡）"

t_case "board pin 闸门注入（④a）：HERMES_KANBAN_DB 注入下 create 仍 --board contrib 且 stub env 观测 absent（D2 核心 kill）"
new_sb
WS_P="$SB_ROOT/ws/hermes-agent/.worktrees/t_pin4"
mk_repo_change "$WS_P" fix.txt "real change E"
add_row "$GATE_DB" t_pin4 "pin card" "$EPIN" "$WS_P"
run_gate "$GATE_DB" "HERMES_KANBAN_DB=$SB_ROOT/decoy/injected.db" >/dev/null
assert_exit 0 $?
assert_eq "$(create_calls)" "1" "注入下照常建卡（走建卡路）"
assert_file_contains "$CALLS" "--board contrib" "注入存在 create argv 仍含 --board contrib"
assert_file_contains "$SB_ROOT/stublog/kanban-db-env.log" "hermes|absent" \
  "闸门路 stub 观测 HERMES_KANBAN_DB absent（env -u 剥离生效，删则红）"
assert_not_contains "$(cat "$CALLS" 2>/dev/null)" "decoy" "建卡链不触碰注入 decoy 路径"
assert_eq "$(cursor_val)" "$EPIN" "注入下建卡游标照常推进"

t_case "delivered 事件入账失败 ⇒ exit 1 零游标推进（⑥ fail-closed 补齐）"
new_sb
WS_F="$SB_ROOT/ws/hermes-agent/.worktrees/t_evfail"
mk_repo_change "$WS_F" fix.txt "real change F"
mk_deliv_twin "$WS_F" refs/heads/contrib/evfail
add_row "$GATE_DB" t_evfail "event fail card" "$EEVENT" "$WS_F"
mkdir "$DATA/logs/notify.log"   # 实测选定注入：notify.log 置目录 ⇒ notify.sh event 末行 log 失败 rc=1
run_gate "$GATE_DB" >/dev/null
assert_exit 1 $?
assert_eq "$(create_calls)" "0" "delivered 路径零建卡（事件失败也不建卡，契约 9）"
if [[ -f "$CURSOR" ]]; then
  _fail "事件失败零游标推进" "游标文件不应存在: $CURSOR"
else
  _pass "事件失败零游标推进"
fi
assert_file_contains "$GLOG" "事件入账失败" "fail-closed 留痕"

t_finish
