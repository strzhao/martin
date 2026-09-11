#!/usr/bin/env bash
# =============================================================================
# t8-01-coder-upstream-gate.acceptance.test.sh — T8 验收：coder done 卡 → 上游回馈评估 零 LLM 闸门
#   黑盒沙箱矩阵（验收场景 P3/P4 + 契约 1/2/3/4/5/7 + body 内容契约）：
#   A   P3 正命中（hermes-agent worktree 领先 + key 未消费）→ 经 kanban_card.sh 建 upstream 卡
#       + notify 事件入账 + 游标推进 + body 契约全字面；零 gh / git 只 log / db 零写
#   B   P4 同沙箱复跑 → 建卡调用次数不变（幂等）
#   C   契约7 游标回退（回拨 init epoch）复跑 → 不重复建卡（事件 key 消费挡）
#   D   契约7 游标重建（删文件）复跑 → 不重复建卡
#   E   过滤矩阵：martin worktree（路径不含 /hermes-agent/.worktrees/）不命中
#   F   过滤矩阵：无领先 commit（origin/main..HEAD 空）不命中
#   G   过滤矩阵：workspace 目录缺失不命中
#   H   过滤矩阵：事件 key 已消费（紧凑 "key":"K" 形态）不命中
#   I   过滤矩阵：事件 key 已消费（带空格 "key": "K" 形态）不命中（契约7 双格式 grep）
#   J   游标时间窗上界：last_checked=now → 旧 done 卡不是候选（游标推进语义锚）
#   K   契约2 游标损坏重建 → init 2026-07-01 本地 epoch（回扫存量：07-01 后完成的卡可命中）
#   L   契约2 零候选（空 tasks 表）+ 缺失游标 → exit 0 且零游标落盘（SSOT 设计文档字面：无任何行则不写游标）
#   M   契约1 用法错误：带任何参数 → exit 2 且零副作用（零建卡/零事件/零游标写）
#   N   fail-closed：KANBAN_DB 指不存在路径 → exit 1 且零游标写/零建卡/零事件
#   O   契约2 建卡失败（hermes 全挂）→ exit 1 本轮中止 + 游标不推进 + 零 coder-upstream 事件
# 依据：kanban 卡 t_6827c2a4 契约规约 1-7 + body 内容契约 + 验收场景 P3/P4（SSOT）
# CONTRACT_AMBIGUOUS（本文件内自裁口径，供人审复核）：
#   1) P3 谓词「calls.log 含 --kind upstream」：既有 kanban_card.sh 只把 --kind 用于自身校验/
#      默认 idem key（hermes argv 无 --kind 转发）。为让谓词字面可观测，本测试在沙箱内对
#      kanban_card.sh 装 tee 观测包装器（argv 记入同一 calls.log 后 exec 真身）——不改被测
#      生产文件，纯夹具注入（t7-08 E1-E3 同款留痕：E3=实现达标后 A 用例该组断言 PASS）。
#   2) J 用例「游标=now → 旧卡过滤」：契约未逐字写「completed_at > last_checked 才是候选」，
#      但 init 值 07-01 与「游标推进」仅在有 completed_at 时间窗语义时才有作用面（否则游标
#      无意义）。若蓝队按「仅事件 key 去重、游标只记账」实现，J 红待人审裁决窗口语义。
#   3) 契约 4 要求 kind=upstream，而既有 kanban_card.sh --kind 闭集为 scan|mail|radar|
#      deepcheck|digest —— 蓝队须扩闭集收 upstream；A 用例 --kind upstream 断言即钉此面。
#   4) 「init=07-01」字面值在「推进即覆盖写」实现下无直接文件观测面，改行为等价钉死：
#      K（损坏游标 + 07-01 后完成的存量卡可回扫命中）+ J（now 游标下同卡被过滤）夹出窗口。
# 红队纪律：黑盒（未读 coder_upstream_gate.sh / 未读蓝队对 run-watch、kanban_card 的本次改动 /
#   未看 git diff）；每断言硬失败；无 skip；全部 sb_new 沙箱 + 影子 stub + spy 包装器，零真实外发。
# Mental Mutation：gate 缺失/不建卡→A 红；建卡不走 kanban_card（hermes 直调）→A 计数相等断言红；
#   缺 --board contrib pin→A 红；事件缺 class/key/channel 或非 notify 8 键形态→A 红；游标不推进
#   或 schema 多键/缺键→A/L 红；body 缺四维/verdict 两分支/红线/commit 列表→A 红；幂等丢→
#   B/C/D 红；双格式 grep 只会一种→H/I 其一红；时间窗丢→J 红；init 被设为 now→K 红；
#   fail-open（db 缺失仍 exit 0 或写游标）→N 红；建卡失败仍推游标→O 红；带参数不 exit 2 或
#   有副作用→M 红；gate 顺手 git push/非 log 子命令→A 的 git spy 断言红；gate 写 db→A 的
#   sha256/journal 断言红。
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

# git 夹具身份（沙箱外宿主进程造仓用）
export GIT_AUTHOR_NAME="redteam" GIT_AUTHOR_EMAIL="redteam@t.local"
export GIT_COMMITTER_NAME="redteam" GIT_COMMITTER_EMAIL="redteam@t.local"

# ---- 本文件专用工具 ----

epoch_local() { # <Y> <M> <D> → 本地时区当日 00:00:00 epoch（与契约 init 口径同机同时区）
  python3 -c "from datetime import datetime; print(int(datetime($1, $2, $3).timestamp()))"
}
INIT_EPOCH="$(epoch_local 2026 7 1)"    # 契约：游标缺失/损坏 init = 2026-07-01 本地 epoch
DONE_EPOCH="$(epoch_local 2026 8 1)"    # 夹具源卡 completed_at（介于 07-01 与今之间）

DB=""      # 每用例重设：$SB_ROOT/fixtures/kanban.db
ROWS=""    # 每用例重设：夹具行（每行一个 JSON 对象）
CALLS=""   # $SB_ROOT/stublog/calls.log
CURSOR=""  # $SB_ROOT/contrib-data/coder-upstream-cursor.json
EVENTS_F="" # $SB_ROOT/contrib-data/events.jsonl
WT_BASE="" # $SB_ROOT/fixtures/hermes-agent/.worktrees

cnt() { # <file> <fixed-string> → 出现行数（文件缺失按 0）
  local n
  n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}
hermes_lines() { grep '^hermes|' "$CALLS" 2>/dev/null || true; }
hermes_create_cnt() {
  local n
  n="$(hermes_lines | grep -c ' create ' || true)"
  printf '%s' "${n:-0}"
}
kbc_create_cnt() { cnt "$CALLS" 'kanban_card|create'; }
git_spy_lines() { cat "$SB_ROOT/stublog/git-calls.log" 2>/dev/null || true; }
git_spy_cnt() {
  local n
  n="$(git_spy_lines | grep -c . || true)"
  printf '%s' "${n:-0}"
}
# git spy 全量形态校验：每行（剥可选 -C <path> 前缀后）子命令必为 log，且带
# origin/main..HEAD 与 --oneline（契约5：git 只跑 log origin/main..HEAD --oneline）
git_spy_bad() {
  git_spy_lines | awk '
    {
      s = substr($0, 5)
      split(s, a, " ")
      i = 1
      if (a[1] == "-C") i = 3
      if (a[i] != "log") bad = 1
      if (index(s, "origin/main..HEAD") == 0) bad = 1
      if (index(s, "--oneline") == 0) bad = 1
    }
    END { print (bad ? 1 : 0) }'
}
git_spy_push_cnt() {
  git_spy_lines | awk '
    {
      s = substr($0, 5)
      split(s, a, " ")
      i = 1
      if (a[1] == "-C") i = 3
      if (a[i] == "push") bad = 1
    }
    END { print (bad ? 1 : 0) }'
}

cand_total() {
  jq -s '[.[] | select(.class == "coder-upstream-candidate")] | length' "$EVENTS_F" 2>/dev/null || echo 0
}
cand_key() { # <key> → 该 coder-upstream 候选 key 的事件条数
  jq -s --arg k "$1" '[.[] | select(.class == "coder-upstream-candidate" and .key == $k)] | length' \
    "$EVENTS_F" 2>/dev/null || echo 0
}
cursor_val() { jq -r '.last_checked_epoch // empty' "$CURSOR" 2>/dev/null || true; }
cursor_schema_ok() {
  jq -e 'type == "object" and (keys == ["last_checked_epoch"]) and (.last_checked_epoch | type == "number")' \
    "$CURSOR" >/dev/null 2>&1
}
db_sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null; }

num_ge() { # <got> <min> <label>
  case "$1" in ''|*[!0-9-]*) _fail "$3" "非数值 [$1]" ;; *)
    [ "$1" -ge "$2" ] && _pass "$3" || _fail "$3" "实得 $1 < 期望 >= $2" ;; esac
}
num_le() { # <got> <max> <label>
  case "$1" in ''|*[!0-9-]*) _fail "$3" "非数值 [$1]" ;; *)
    [ "$1" -le "$2" ] && _pass "$3" || _fail "$3" "实得 $1 > 期望 <= $2" ;; esac
}
assert_cursor_advanced() { # <min-epoch> <label-prefix> — 游标存在/恰 schema/值落在窗口内
  local min_ep="$1" p="$2" now val
  [ -f "$CURSOR" ] && _pass "$p 游标文件存在" || { _fail "$p 游标文件存在" "$CURSOR 未产出"; return 0; }
  assert_eq "$(cursor_schema_ok && echo yes || echo no)" "yes" "$p 游标 schema 恰为单键 last_checked_epoch"
  val="$(cursor_val)"
  num_ge "$val" "$min_ep" "$p 游标值 >= $min_ep"
  now="$(date +%s)"
  num_le "$val" "$(( now + 120 ))" "$p 游标值 <= now+120s（本轮推进值而非远古值）"
}
assert_db_unmodified() { # <sha-before> <label-prefix> — 零写连接黑盒面：sha 不变 + 零 journal 残留
  assert_eq "$(db_sha "$DB")" "$1" "$2 fixture db 零写入（sha256 不变）"
  local w=0 sfx
  for sfx in -wal -shm -journal; do
    [ -e "$DB$sfx" ] && w=1
  done
  assert_eq "$w" "0" "$2 零 sqlite wal/shm/journal 残留（只读连接面）"
}
assert_board_pinned_contrib() { # <label> — gate 语境缺省 pin contrib（KANBAN_BOARD 空仍出父级 flag）
  if hermes_lines | grep -qE 'kanban --board contrib create( |$)'; then
    _pass "$1"
  else
    _fail "$1" "calls.log 无 [kanban --board contrib create] 形态（行样例: $(hermes_lines | grep ' create ' | head -1 | head -c 200)）"
  fi
}

# ---- 夹具工厂（宿主进程执行，不入沙箱 PATH）----

card_row() { # <id> <title> <workspace_path> [status=done] [assignee=coder] [done_epoch]
  jq -cn --arg id "$1" --arg title "$2" --arg ws "$3" --arg st "${4:-done}" \
    --arg as "${5:-coder}" --argjson "done" "${6:-$DONE_EPOCH}" \
    '{id: $id, title: $title, assignee: $as, status: $st, completed_at: $done, workspace_path: $ws}' >>"$ROWS"
}
make_db() { # 造夹具 kanban.db（schema 镜像真实库 tasks 全列，写入面仅本测试进程）
  python3 - "$DB" "$ROWS" <<'PY'
import json, sqlite3, sys
db, rowsf = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(rowsf) if l.strip()]
con = sqlite3.connect(db)
con.execute("""CREATE TABLE tasks (
    id                   TEXT PRIMARY KEY,
    title                TEXT NOT NULL,
    body                 TEXT,
    assignee             TEXT,
    status               TEXT NOT NULL,
    priority             INTEGER DEFAULT 0,
    created_by           TEXT,
    created_at           INTEGER NOT NULL,
    started_at           INTEGER,
    completed_at         INTEGER,
    workspace_kind       TEXT NOT NULL DEFAULT 'scratch',
    workspace_path       TEXT,
    claim_lock           TEXT,
    claim_expires        INTEGER,
    tenant               TEXT,
    result               TEXT,
    idempotency_key      TEXT,
    spawn_failures       INTEGER NOT NULL DEFAULT 0,
    worker_pid           INTEGER,
    last_spawn_error     TEXT,
    max_runtime_seconds  INTEGER,
    last_heartbeat_at    INTEGER,
    current_run_id       INTEGER,
    workflow_template_id TEXT,
    current_step_key     TEXT,
    skills               TEXT,
    branch_name          TEXT,
    project_id           TEXT,
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    last_failure_error   TEXT,
    max_retries          INTEGER,
    model_override       TEXT,
    goal_mode            INTEGER NOT NULL DEFAULT 0,
    goal_max_turns       INTEGER,
    session_id           TEXT,
    block_kind           TEXT,
    block_recurrences    INTEGER NOT NULL DEFAULT 0,
    provider_override    TEXT,
    reasoning_effort     TEXT,
    completion_contract  TEXT,
    resources            TEXT
)""")
for r in rows:
    con.execute(
        "INSERT INTO tasks (id,title,assignee,status,priority,created_by,created_at,"
        "completed_at,workspace_kind,workspace_path) VALUES (?,?,?,?,?,?,?,?,?,?)",
        (r["id"], r["title"], r["assignee"], r["status"], 0, "redteam",
         r["completed_at"] - 3600, r["completed_at"], "worktree", r["workspace_path"]))
con.commit()
con.close()
PY
}
make_repo() { # <worktree-abs-path> <n-ahead-commits> — 真实 git 造领先 worktree（零 push：
  # 本机 remote helper 被 block，且 origin/main 追踪 ref 用 update-ref 直接落，语义等价）
  local wt="$1" n="$2" tag seed i
  tag="$(basename "$wt")"
  seed="$SB_ROOT/fixtures/seed-$tag"
  git init -q -b main "$seed"
  git -C "$seed" commit -q --allow-empty -m base
  git -C "$seed" update-ref refs/remotes/origin/main refs/heads/main
  mkdir -p "$(dirname "$wt")"
  git -C "$seed" worktree add -q -b "feat-$tag" "$wt"
  for ((i = 1; i <= n; i++)); do
    printf 'x\n' >"$wt/file-$i.txt"
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "up-fix-$i"
  done
}
install_spies() { # 沙箱内观测包装器（纯夹具，exec 真身；不触生产文件）
  local real="$SB_ROOT/scripts/contrib/kanban_card.sh.real" rgit
  mv "$SB_ROOT/scripts/contrib/kanban_card.sh" "$real"
  cat >"$SB_ROOT/scripts/contrib/kanban_card.sh" <<EOF
#!/bin/bash
# 测试观测包装器：kanban_card.sh argv 记账后 exec 真身（P3 谓词 --kind upstream 观测面）
printf 'kanban_card|%s\n' "\$*" >>"$CALLS"
exec bash "$real" "\$@"
EOF
  chmod +x "$SB_ROOT/scripts/contrib/kanban_card.sh"
  rgit="$(command -v git)"
  cat >"$SB_ROOT/bin/git" <<EOF
#!/bin/bash
# 测试观测包装器（沙箱 bin 在 PATH 首位）：git argv 记账后 exec 真身（零 push 红线观测面）
printf 'git|%s\n' "\$*" >>"\$STUB_LOG_DIR/git-calls.log"
exec "$rgit" "\$@"
EOF
  chmod +x "$SB_ROOT/bin/git"
}
new_sb() { # 每用例沙箱底座 + spy 安装
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  DB="$SB_ROOT/fixtures/kanban.db"
  ROWS="$SB_ROOT/fixtures/rows.txt"
  CALLS="$SB_ROOT/stublog/calls.log"
  CURSOR="$SB_ROOT/contrib-data/coder-upstream-cursor.json"
  EVENTS_F="$SB_ROOT/contrib-data/events.jsonl"
  WT_BASE="$SB_ROOT/fixtures/hermes-agent/.worktrees"
  mkdir -p "$SB_ROOT/fixtures"
  install_spies
}
run_gate() { # [额外 -e K=V]... — 单发无参数 zsh 调（契约1/镜像生产 zsh 侧）
  sb_run "$@" 'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh"'
}
seed_cursor() { printf '{"last_checked_epoch": %s}\n' "$1" >"$CURSOR"; }
seed_event_compact() { # <key> — 紧凑形态（jq 追加形态）已消费行
  printf '%s\n' "{\"ts\":\"2026-09-10T08:00:00+08:00\",\"class\":\"coder-upstream-candidate\",\"key\":\"$1\",\"channel\":\"contrib\",\"summary\":\"seeded\",\"pushed\":true,\"attempts\":1,\"pushed_at\":\"2026-09-10T08:00:00+08:00\"}" >>"$EVENTS_F"
}
seed_event_spaced() { # <key> — 带空格形态（flush 账本重写形态）已消费行
  printf '%s\n' "{\"ts\": \"2026-09-10T08:00:00+08:00\", \"class\": \"coder-upstream-candidate\", \"key\": \"$1\", \"channel\": \"contrib\", \"summary\": \"seeded\", \"pushed\": true, \"attempts\": 1, \"pushed_at\": \"2026-09-10T08:00:00+08:00\"}" >>"$EVENTS_F"
}
assert_zero_side_effect() { # <label-prefix> — 零建卡/零 coder-upstream 事件（过滤/失败用例公共面）
  assert_eq "$(kbc_create_cnt)" "0" "$1 零建卡调用（kanban_card create 未发生）"
  assert_eq "$(cand_total)" "0" "$1 零 coder-upstream-candidate 事件入账"
}

# =============================================================================
t_case "A P3 正命中 → 建卡+事件+游标推进+body 契约（git 只 log / gh 零调 / db 零写）"
new_sb
ID_A="t_c0dea001"
WT_A="$WT_BASE/$ID_A"
make_repo "$WT_A" 2
card_row "$ID_A" "fix: gateway 5xx 重试风暴" "$WT_A"
make_db
SHA_BEFORE="$(db_sha "$DB")"
run_gate -e "KANBAN_DB=$DB"
RC=$?
assert_exit 0 "$RC" "A gate 单发无参数 exit 0（契约1 正常闭值）"
# --- 建卡调用面：--kind upstream + --idempotency-key + title + body 文件路径（经 kanban_card.sh）
num_ge "$(kbc_create_cnt)" 1 "A calls.log 含 kanban_card.sh create 调用"
KBC_LINE="$(grep '^kanban_card|create' "$CALLS" 2>/dev/null | head -1)"
assert_contains "$KBC_LINE" "--kind upstream" "A kanban_card argv 含 --kind upstream（P3 谓词字面）"
assert_contains "$KBC_LINE" "--idempotency-key coder-upstream-$ID_A" "A kanban_card argv 含幂等键 coder-upstream-<源id>（契约4）"
assert_contains "$KBC_LINE" "contrib 上游回馈评估 $ID_A" "A kanban_card argv 含契约标题字面（契约4）"
assert_contains "$KBC_LINE" "card-bodies/coder-upstream-$ID_A.body.md" "A kanban_card argv 指向契约 body 文件路径（契约4）"
# --- hermes 调用面：board pin + 幂等键透传 + assignee contrib；且建卡唯一经 kanban_card.sh
num_ge "$(hermes_create_cnt)" 1 "A calls.log 含 hermes kanban create 调用"
H_LINE="$(hermes_lines | grep ' create ' | head -1)"
assert_contains "$H_LINE" "--idempotency-key coder-upstream-$ID_A" "A hermes argv 幂等键透传（P3 谓词字面）"
assert_contains "$H_LINE" "--assignee contrib" "A hermes argv assignee=contrib（契约4）"
assert_board_pinned_contrib "A gate 语境缺省 pin contrib（kanban --board contrib create 父级位置，契约4）"
assert_eq "$(kbc_create_cnt)" "$(hermes_create_cnt)" "A 建卡唯一经 kanban_card.sh（wrapper 数 == hermes create 数，契约5 零直调）"
assert_not_contains "$H_LINE" "card_event" "A hermes 无事件类直调杂音"
# --- 事件面：notify.sh 8 键形态恰 1 条，class/key/channel 契约字面
assert_eq "$(cand_total)" "1" "A coder-upstream-candidate 事件恰 1 条"
EV_ROW="$(jq -c 'select(.class == "coder-upstream-candidate")' "$EVENTS_F" 2>/dev/null | head -1)"
assert_eq "$(jq -r '.key // ""' <<<"$EV_ROW")" "coder-upstream-$ID_A" "A 事件 key=coder-upstream-<源id>（契约3）"
assert_eq "$(jq -r '.channel // ""' <<<"$EV_ROW")" "contrib" "A 事件 channel=contrib（契约3）"
assert_eq "$(jq -c 'keys' <<<"$EV_ROW" 2>/dev/null)" '["attempts","channel","class","key","pushed","pushed_at","summary","ts"]' "A 事件行恰 notify.sh event 8 键形态（契约3 唯一入账出口）"
assert_ne "$(jq -r '.summary // ""' <<<"$EV_ROW")" "" "A 事件 summary 非空"
# --- 游标面：推进 >= 源卡 completed_at，schema 恰单键
assert_cursor_advanced "$DONE_EPOCH" "A"
# --- body 契约面：文件路径 + 全字面
BODY_F="$SB_ROOT/contrib-data/card-bodies/coder-upstream-$ID_A.body.md"
[ -f "$BODY_F" ] && _pass "A body 文件存在（card-bodies/coder-upstream-<id>.body.md）" || _fail "A body 文件存在" "$BODY_F 缺失"
assert_file_contains "$BODY_F" "$ID_A" "A body 含源卡 id"
assert_file_contains "$BODY_F" "gateway 5xx 重试风暴" "A body 含源卡标题"
assert_file_contains "$BODY_F" "$WT_A" "A body 含 worktree 路径"
assert_file_contains "$BODY_F" "up-fix-1" "A body 含领先 commit 列表（第 1 条 subject）"
assert_file_contains "$BODY_F" "up-fix-2" "A body 含领先 commit 列表（第 2 条 subject）"
assert_file_contains "$BODY_F" "域契合" "A body 评估维度：域契合"
assert_file_contains "$BODY_F" "单关注点可剥离" "A body 评估维度：单关注点可剥离"
assert_file_contains "$BODY_F" "上游空间占用" "A body 评估维度：上游空间占用"
assert_file_contains "$BODY_F" "cherry-pick" "A body 评估维度：干净 cherry-pick"
assert_file_contains "$BODY_F" "forge" "A body verdict 值得分支：forge/L2 awaiting-approval"
assert_file_contains "$BODY_F" "awaiting-approval" "A body verdict 值得分支：awaiting-approval"
assert_file_contains "$BODY_F" "绝不允许自动 push" "A body 红线：绝不允许自动 push"
assert_file_contains "$BODY_F" "L2 闸门不豁免" "A body 红线：L2 闸门不豁免"
assert_file_contains "$BODY_F" "expired" "A body verdict 不值得分支：expired"
assert_file_contains "$BODY_F" "shelved" "A body verdict 不值得分支：shelved"
assert_file_contains "$BODY_F" "gh 只读" "A body 红线：gh 只读"
# --- 送达面：hermes --body 内联副本含 body 关键字面（stub 会把 argv 换行平化为空格，副本
# 无法逐字节比对；正文全字面已在 body 文件断言，此处钉「确实送达 hermes」面）
BB="$(stub_last_body hermes)"
if [ -n "$BB" ] && [ -f "$BB" ]; then
  assert_file_contains "$BB" "源卡 id: $ID_A" "A hermes 送达 body 含源卡 id"
  assert_file_contains "$BB" "域契合" "A hermes 送达 body 含评估维度"
  assert_file_contains "$BB" "绝不允许自动 push" "A hermes 送达 body 含自动 push 红线"
  assert_file_contains "$BB" "gh 只读" "A hermes 送达 body 含 gh 只读红线"
else
  _fail "A hermes 送达 body 关键字面" "stub body 副本缺失"
fi
# --- 只读红线面
assert_stub_not_called gh "A 零 gh 调用（契约5）"
num_ge "$(git_spy_cnt)" 1 "A git 扫描真实发生（spy 可见 >= 1 次调用）"
assert_eq "$(git_spy_bad)" "0" "A git 全部调用均为 log origin/main..HEAD --oneline 形态（契约5）"
assert_eq "$(git_spy_push_cnt)" "0" "A 零 git push（绝不自动 push 红线）"
assert_db_unmodified "$SHA_BEFORE" "A"
sb_cleanup

# =============================================================================
t_case "B P4 同沙箱复跑 → 建卡调用次数不变（幂等）"
new_sb
ID_B="t_c0dea001"
WT_B="$WT_BASE/$ID_B"
make_repo "$WT_B" 1
card_row "$ID_B" "fix: parser 崩溃修复" "$WT_B"
make_db
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "B 首轮 exit 0"
N1="$(kbc_create_cnt)"
E1="$(cand_key "coder-upstream-$ID_B")"
num_ge "$N1" 1 "B 首轮建卡发生（前置）"
run_gate -e "KANBAN_DB=$DB"
RC2=$?
assert_exit 0 "$RC2" "B 复跑 exit 0（幂等跳过属正常闭值，契约1）"
assert_eq "$(kbc_create_cnt)" "$N1" "B 复跑建卡调用次数不变（P4 幂等）"
assert_eq "$(cand_key "coder-upstream-$ID_B")" "$E1" "B 复跑事件不重复入账"
assert_cursor_advanced "$DONE_EPOCH" "B"
sb_cleanup

# =============================================================================
t_case "C 契约7 游标回退（回拨 init epoch）复跑 → 不重复建卡"
new_sb
ID_C="t_c0dea001"
WT_C="$WT_BASE/$ID_C"
make_repo "$WT_C" 1
card_row "$ID_C" "fix: 竞态修补" "$WT_C"
make_db
run_gate -e "KANBAN_DB=$DB"
N1="$(kbc_create_cnt)"
num_ge "$N1" 1 "C 首轮建卡发生（前置）"
seed_cursor "$INIT_EPOCH"   # 模拟游标被回退到 init 时刻 → 该卡重新成为时间候选
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "C 回退后复跑 exit 0"
assert_eq "$(kbc_create_cnt)" "$N1" "C 游标回退复跑不重复建卡（事件 key 已消费挡，契约7）"
assert_eq "$(cand_key "coder-upstream-$ID_C")" "1" "C 事件仍恰 1 条（不重复入账）"
sb_cleanup

# =============================================================================
t_case "D 契约7 游标重建（删文件）复跑 → 不重复建卡"
new_sb
ID_D="t_c0dea001"
WT_D="$WT_BASE/$ID_D"
make_repo "$WT_D" 1
card_row "$ID_D" "fix: 边界条件修补" "$WT_D"
make_db
run_gate -e "KANBAN_DB=$DB"
N1="$(kbc_create_cnt)"
num_ge "$N1" 1 "D 首轮建卡发生（前置）"
rm -f "$CURSOR"             # 模拟游标文件丢失 → 重建 init 07-01 → 卡重回时间候选
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "D 游标重建后复跑 exit 0"
assert_eq "$(kbc_create_cnt)" "$N1" "D 游标重建复跑不重复建卡（契约7 双保险：事件 key + 幂等键）"
assert_cursor_advanced "$DONE_EPOCH" "D"
sb_cleanup

# =============================================================================
t_case "E 过滤矩阵：martin worktree（路径不含 /hermes-agent/.worktrees/）不命中"
new_sb
ID_E="t_c0dea002"
WT_E="$SB_ROOT/fixtures/martin-space/.worktrees/$ID_E"
make_repo "$WT_E" 1         # 其余条件全满足（目录在、领先 1 commit、key 未消费），唯路径不匹配
card_row "$ID_E" "feat: martin 侧改动" "$WT_E"
make_db
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "E exit 0（全过滤属正常闭值，契约1）"
assert_zero_side_effect "E"
assert_cursor_advanced "$DONE_EPOCH" "E"
sb_cleanup

# =============================================================================
t_case "F 过滤矩阵：无领先 commit（origin/main..HEAD 空）不命中"
new_sb
ID_F="t_c0dea003"
WT_F="$WT_BASE/$ID_F"
make_repo "$WT_F" 0         # hermes-agent 路径命中但零领先 commit
card_row "$ID_F" "chore: 无上游价值改动" "$WT_F"
make_db
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "F exit 0"
assert_zero_side_effect "F"
assert_cursor_advanced "$DONE_EPOCH" "F"
sb_cleanup

# =============================================================================
t_case "G 过滤矩阵：workspace 目录缺失不命中"
new_sb
ID_G="t_c0dea009"
WT_G="$WT_BASE/$ID_G"       # 不建目录、不建仓
card_row "$ID_G" "fix: 幽灵 worktree" "$WT_G"
make_db
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "G exit 0（目录缺失按过滤而非整轮失败，契约1 正常闭值）"
assert_zero_side_effect "G"
assert_cursor_advanced "$DONE_EPOCH" "G"
sb_cleanup

# =============================================================================
t_case "H 过滤矩阵：事件 key 已消费（紧凑形态）不命中"
new_sb
ID_H="t_c0dea004"
WT_H="$WT_BASE/$ID_H"
make_repo "$WT_H" 1
card_row "$ID_H" "fix: 已回馈过的修复" "$WT_H"
make_db
seed_cursor "$INIT_EPOCH"   # 时间窗敞开 → 唯一过滤变量 = 事件 key 已消费
seed_event_compact "coder-upstream-$ID_H"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "H exit 0"
assert_eq "$(kbc_create_cnt)" "0" "H 零建卡（紧凑 key 已消费挡，双格式 grep 契约7）"
assert_eq "$(cand_key "coder-upstream-$ID_H")" "1" "H 事件仍只有种子那 1 条（不重复入账）"
sb_cleanup

# =============================================================================
t_case "I 过滤矩阵：事件 key 已消费（带空格形态）不命中"
new_sb
ID_I="t_c0dea005"
WT_I="$WT_BASE/$ID_I"
make_repo "$WT_I" 1
card_row "$ID_I" "fix: 账本重写后的重复扫描" "$WT_I"
make_db
seed_cursor "$INIT_EPOCH"
seed_event_spaced "coder-upstream-$ID_I"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "I exit 0"
assert_eq "$(kbc_create_cnt)" "0" "I 零建卡（带空格 key 形态也判已消费，契约7 双格式）"
assert_eq "$(cand_key "coder-upstream-$ID_I")" "1" "I 事件仍只有种子那 1 条"
sb_cleanup

# =============================================================================
t_case "J 游标时间窗上界：last_checked=now → 旧 done 卡不是候选（CONTRACT_AMBIGUOUS 见头注2）"
new_sb
ID_J="t_c0dea006"
WT_J="$WT_BASE/$ID_J"
make_repo "$WT_J" 1
card_row "$ID_J" "fix: 时间窗语义锚" "$WT_J"
make_db
J_SEED="$(date +%s)"
seed_cursor "$J_SEED"       # 游标=now > 卡 completed_at(08-01) → 不得再命中（否则游标无作用面）
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "J exit 0"
assert_zero_side_effect "J"
assert_cursor_advanced "$J_SEED" "J"   # 下界=注入值（闸门不得回拨），上界由 now+120 钉鲜度
sb_cleanup

# =============================================================================
t_case "K 契约2 游标损坏重建 → init 2026-07-01 回扫存量（07-01 后完成的卡可命中）"
new_sb
ID_K="t_c0dea007"
WT_K="$WT_BASE/$ID_K"
make_repo "$WT_K" 1
card_row "$ID_K" "fix: 存量回扫目标" "$WT_K" "done" "coder" "$DONE_EPOCH"
make_db
printf 'not-json{{{\n' >"$CURSOR"   # 损坏游标
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "K exit 0"
assert_eq "$(kbc_create_cnt)" "1" "K 损坏游标重建后存量卡（completed_at > 07-01）被回扫命中（init 非.now）"
assert_eq "$(cand_key "coder-upstream-$ID_K")" "1" "K 事件入账恰 1 条"
assert_cursor_advanced "$DONE_EPOCH" "K"
[ -f "$SB_ROOT/contrib-data/card-bodies/coder-upstream-$ID_K.body.md" ] \
  && _pass "K body 文件随命中产出" || _fail "K body 文件随命中产出" "缺失"
sb_cleanup

# =============================================================================
# [红队测试修订留痕 2026-09-11] 原断言「缺失游标+零候选 → 游标重建落盘为 INIT」与设计文档
#   SSOT 字面矛盾——设计文档明写「无候选/全部被过滤 → 游标推进到本轮见到的 max(completed_at)
#   （无任何行则不写游标）」。证据链（auto-fix §6 例外 E1-E3）：E1=设计文档零行豁免字面在案；
#   E2=实现按设计采用内存 init 不落盘（蓝队自检留痕）；E3=两语义生产等价（init 常量每轮确定
#   重算、事件 key 幂等兜底重复卡、空结果查询成本恒零）。依例外修订本断言为设计字面，未放宽
#   任何其他断言。
t_case "L 契约2 零候选+缺失游标 → exit 0 且零游标落盘（设计文档字面）"
new_sb
: >"$ROWS"
make_db                     # 空 tasks 表：无任何行
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "L exit 0"
assert_zero_side_effect "L"
[ -e "$CURSOR" ] && _fail "L 零行不写游标（设计文档 SSOT 字面）" "零行轮却产出游标文件" || _pass "L 零行不写游标（设计文档 SSOT 字面）"
sb_cleanup

# =============================================================================
t_case "M 契约1 用法错误：带任何参数 → exit 2 且零副作用"
new_sb
: >"$ROWS"
make_db
sb_run -e "KANBAN_DB=$DB" 'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh" --help'
assert_exit 2 "$?" "M exit 2（单参数 --help）"
sb_run -e "KANBAN_DB=$DB" 'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh" foo bar'
assert_exit 2 "$?" "M exit 2（双位置参数）"
assert_zero_side_effect "M"
[ -e "$CURSOR" ] && _fail "M 零游标写" "用法错误却写出游标文件" || _pass "M 零游标写"
sb_cleanup

# =============================================================================
t_case "N fail-closed：KANBAN_DB 指不存在路径 → exit 1 且零游标写零建卡零事件"
new_sb
run_gate -e "KANBAN_DB=$SB_ROOT/fixtures/absent/kanban.db"
assert_exit 1 "$?" "N exit 1（有失败本轮中止，契约1；fail-closed 契约）"
assert_zero_side_effect "N"
[ -e "$CURSOR" ] && _fail "N 零游标写" "db 缺失却写出游标" || _pass "N 零游标写"
sb_cleanup

# =============================================================================
t_case "O 契约2 建卡失败（hermes 全挂）→ exit 1 本轮中止 + 游标不推进 + 零事件"
new_sb
ID_O="t_c0dea008"
WT_O="$WT_BASE/$ID_O"
make_repo "$WT_O" 1
card_row "$ID_O" "fix: hermes 挂死下的中止语义" "$WT_O"
make_db
seed_cursor "$INIT_EPOCH"   # 预置游标 → 失败后必须原值不动
run_gate -e "KANBAN_DB=$DB" -e "STUB_HERMES_FAIL=1"
assert_exit 1 "$?" "O exit 1（有失败本轮中止，契约1）"
assert_eq "$(cand_total)" "0" "O 零 coder-upstream-candidate 事件（建卡+事件未双成功）"
assert_eq "$(cursor_val)" "$INIT_EPOCH" "O 游标不推进（原值保持，契约2 只在双成功后推进）"
sb_cleanup

t_finish
