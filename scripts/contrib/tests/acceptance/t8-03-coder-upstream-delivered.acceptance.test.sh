#!/usr/bin/env bash
# =============================================================================
# t8-03-coder-upstream-delivered.acceptance.test.sh — T8 验收（第二段红队）：
#   coder done 卡闸门 patch-id「已投递」判重 + HERMES_KANBAN_DB 注入下 board pin 黑盒沙箱矩阵
#
# 依据：kanban 卡 t_6827c2a4 设计文档 契约 8-13 + 验收场景 1-6（SSOT，2026-09-11 生成器冻结）：
#   S1  场景1 patch-id 命中 refs/heads/contrib/* ⇒ 零建卡 + 事件 key=coder-upstream-<tid>
#       恰 1 行 + class=coder-upstream-delivered + summary 含「已投递」与 ref 短名
#       （剥 refs/heads/ 前缀）+ 游标照常推进 >= 该卡 completed_at（契约8/9）
#   S2  场景2 patch-id 未命中（contrib ref 指不同 diff 的无关 commit）⇒ 照常建卡
#       （create >= 1、--board contrib、候选事件 key 恰 1 行、游标推进；第一段回归，契约13）
#   S3  场景3 闸门进程注入 HERMES_KANBAN_DB=<decoy> 仍 board pin（契约11/D2 核心 kill）：
#       闸门运行的 KDBENV（stublog/kanban-db-env.log，stub 每调用一行 hermes|present|absent
#       形态——按设计声明由蓝队为 stub 新增，本测试只消费不构造）行全部 |absent（删 env -u
#       则红）；对照运行（不经闸门直调 kanban_card.sh create 携同一注入，与 scan-cardify.sh
#       anthropic-env.log 控制组同构）观测行 contains |present，证明注入链与观测面有效，
#       使 absent 断言非平凡；create 行仍含 --board contrib 且全程零 decoy 触碰
#   S4  场景4 判重不可用 ⇒ 留痕保守放行（契约10，唯一 fail-open 例外）：删候选 ahead
#       commit 的 tree 松散对象（R3 夹具陷阱：删 commit 对象会令 git log rc=128 被条件 b
#       先行过滤、场景不成立；删 tree 后 log rc=0 而 git show rc=128）⇒ exit 0、create >= 1、
#       GLOG 留痕可定位该项（contains <task_id>）、stdout 与 EVENTS 全文零「已投递」、游标推进
#   S5  场景5 命中态幂等复跑 ⇒ exit 0、同 key 仍恰 1 行（零重复事件）、create 增量 0、
#       游标不回退（契约9/13）；另含游标回拨强化轮（t8-01 C 同款手法）：条件 c 先挡双保险，
#       使 P2/P3 对「删幂等」变异真红而非被时间窗掩盖
#   S6  场景6 混合领先 commit 任一命中即过滤（refs/remotes/fork/* 家族，契约8 判重集并集）：
#       零建卡、key=coder-upstream-<tid> 恰 1 行、summary 含「已投递」与 ref 短名
#       fork/pidmix（剥 refs/remotes/ 前缀）、游标推进
#
# 红队纪律：黑盒——未读 coder_upstream_gate.sh 当前实现内容、未看 git diff、不猜实现细节；
#   每断言硬失败（assert_eq/assert_exit/assert_contains/negate 手法），零 skip 零软断言；
#   全部 sb_new 沙箱 + 影子 stub，零真实外发零真实数据。夹具 git 身份+日期 env 固定
#   （GIT_AUTHOR_DATE/GIT_COMMITTER_DATE），patch-id 只依赖 diff 文本、sha 确定性可复算。
#
# Mental Mutation（删哪段 ⇒ 哪组断言红）：
#   删 D1 条件 d 判重 ⇒ S1.P3/S1.class/S1.P4/S1.P5 与 S6.P2/S6.class/S6.P4 红
#     （照旧误建卡 + summary 是建卡语义非已投递语义）；
#   命中只跳过不入账（丢 delivered 事件）⇒ S1.P2/S6.P3 红；
#   summary 丢「已投递」字面 ⇒ S1.P4/S6.P4 红；丢 ref 短名 ⇒ S1.P5/S6.P4 红；
#   ref 短名不剥 refs/heads/ 或 refs/remotes/ 前缀 ⇒ S1.P5（contrib/pidhit）、
#     S6.P4（fork/pidmix）红；命中后游标不推进 ⇒ S1.P6/S6.P5 红；
#   判重不可用改 fail-closed（exit!=0/不建卡/不留痕）⇒ S4.P1/S4.P2/S4.P3 红；
#   判重跳过误标已投递 ⇒ S4.P4 红（stdout 与 EVENTS 双面 negate）；
#   删 D2 env -u HERMES_KANBAN_DB ⇒ S3.P3 红（对照运行 S3.P2 保证注入链可观测、非平凡）；
#   create 丢 --board contrib ⇒ S2.P3/S3.P4 红；create 链触碰 decoy 路径 ⇒ S3.P5 红；
#   删事件 key/幂等键双保险 ⇒ S5.P2/S5.P3 红；游标回退 ⇒ S5.P4 红；
#   未命中误拦（判重假阳性）⇒ S2.P2 红（零建卡则红）。
# 契约演进（2026-09-12 第三段 D4 判重面收窄，契约 12'）：判重集改为 own-PR snapshot 面——
#   仅 S1/S5/S6 夹具加性补 snapshot 种子（headRefName=命中分支名、headRefOid=命中 commit
#   全 sha，写 $SB_ROOT/contrib-data/own-pr-watch-snapshot.json），65 条断言文本零改动；
#   S2/S3/S4 不动（无 snapshot ⇒ 闸门逐候选 fail-open 放行，断言原样成立）。
# 约定：$SB_ROOT=mktemp 沙箱根；CALLS=stublog/calls.log；EVENTS=contrib-data/events.jsonl；
#   CURSOR=contrib-data/coder-upstream-cursor.json；GLOG=contrib-data/logs/
#   coder-upstream-gate.log；KDBENV=stublog/kanban-db-env.log。events key 断言一律 jq -s
#   按 .key 精确匹配（紧凑/带空格双格式均成立）。全角相邻变量一律 ${VAR} 花括号（gate.sh
#   全角门教训）。
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

# git 夹具身份（沙箱外宿主进程造仓用；日期固定 → sha 确定性、无 patch-id 漂移面）
export GIT_AUTHOR_NAME="redteam" GIT_AUTHOR_EMAIL="redteam@t.local"
export GIT_COMMITTER_NAME="redteam" GIT_COMMITTER_EMAIL="redteam@t.local"
export GIT_AUTHOR_DATE="2026-08-01T04:00:00+0000"
export GIT_COMMITTER_DATE="2026-08-01T04:00:00+0000"

# ---- 本文件专用工具 ----

epoch_local() { # <Y> <M> <D> → 本地时区当日 00:00:00 epoch
  python3 -c "from datetime import datetime; print(int(datetime($1, $2, $3).timestamp()))"
}
DONE_EPOCH="$(epoch_local 2026 8 1)"    # 夹具源卡 completed_at

DB=""       # 每用例重设：$SB_ROOT/fixtures/kanban.db
ROWS=""     # 每用例重设：夹具行文件
CALLS=""    # $SB_ROOT/stublog/calls.log
CURSOR=""   # $SB_ROOT/contrib-data/coder-upstream-cursor.json
EVENTS_F="" # $SB_ROOT/contrib-data/events.jsonl
GLOG=""     # $SB_ROOT/contrib-data/logs/coder-upstream-gate.log
KDBENV=""   # $SB_ROOT/stublog/kanban-db-env.log（设计声明蓝队为 stub 新增；只消费）
WT_BASE=""  # $SB_ROOT/fixtures/hermes-agent/.worktrees

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
kdbenv_lines() { cat "$KDBENV" 2>/dev/null || true; }   # 设计声明蓝队为 stub 新增；文件缺失=空（消费面零构造）
key_cnt() { # <key> → events.jsonl 中该 key 事件行数（jq -s 精确匹配，双格式均成立）
  jq -s --arg k "$1" '[.[] | select(.key == $k)] | length' "$EVENTS_F" 2>/dev/null || printf 0
}
cand_cnt() { # class=coder-upstream-candidate 事件行数
  jq -s '[.[] | select(.class == "coder-upstream-candidate")] | length' "$EVENTS_F" 2>/dev/null || printf 0
}
ev_row() { # <key> → 该 key 首条事件行（单行 JSON；无则空）
  jq -c --arg k "$1" 'select(.key == $k)' "$EVENTS_F" 2>/dev/null | head -1
}
ev_field() { # <row-json> <field> → 字段值（空行/缺字段 → 空）
  if [ -n "$1" ]; then
    printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // ""' 2>/dev/null || printf ''
  fi
}
cursor_val() { jq -r '.last_checked_epoch // empty' "$CURSOR" 2>/dev/null || true; }
cursor_schema_ok() {
  jq -e 'type == "object" and (keys == ["last_checked_epoch"]) and (.last_checked_epoch | type == "number")' \
    "$CURSOR" >/dev/null 2>&1
}
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
var_lines_cnt() { # <multiline-var> → 非空行数（空串=0）
  printf '%s\n' "$1" | grep -c . || true
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
make_repo() { # <worktree-abs-path> <n-ahead-commits> — 真实 git 造领先 worktree（每 commit
# 真实 diff file-<i>.txt；零 push：origin/main 追踪 ref 用 update-ref 直接落，语义等价）
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
mk_unrelated_ref() { # <wt> <refname> — 同仓 plumbing 造「不同 diff」无关 commit（树含
# unrelated.txt，与候选 file-N.txt diff 必异 patch-id）并挂 ref；不切换分支不动 HEAD
  local wt="$1" ref="$2" base blob tree cmt
  base="$(git -C "$wt" rev-parse refs/remotes/origin/main)"
  blob="$(printf 'unrelated-payload\n' | git -C "$wt" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tunrelated.txt\n' "$blob" | git -C "$wt" mktree)"
  cmt="$(git -C "$wt" commit-tree "$tree" -p "$base" -m unrelated-change)"
  git -C "$wt" update-ref "$ref" "$cmt"
}
break_show_del_tree() { # <wt> — 删领先头 commit 的 tree 松散对象（R3 陷阱规避：保 commit
# 对象 → git log origin/main..HEAD 仍 rc=0（条件 b 不拦）；git show rc=128 → 单项判重不可得）
  local wt="$1" tree common obj
  tree="$(git -C "$wt" rev-parse 'HEAD^{tree}')"
  common="$(git -C "$wt" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$wt/$common" ;; esac
  obj="$common/objects/${tree:0:2}/${tree:2}"
  rm -f "$obj"
}
new_sb() { # 每用例沙箱底座（无 spy 注入：黑盒观测面 = stub 记账 + 文件产物）
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  DB="$SB_ROOT/fixtures/kanban.db"
  ROWS="$SB_ROOT/fixtures/rows.txt"
  CALLS="$SB_ROOT/stublog/calls.log"
  CURSOR="$SB_ROOT/contrib-data/coder-upstream-cursor.json"
  EVENTS_F="$SB_ROOT/contrib-data/events.jsonl"
  GLOG="$SB_ROOT/contrib-data/logs/coder-upstream-gate.log"
  KDBENV="$SB_ROOT/stublog/kanban-db-env.log"
  WT_BASE="$SB_ROOT/fixtures/hermes-agent/.worktrees"
  mkdir -p "$SB_ROOT/fixtures"
}
run_gate() { # [额外 -e K=V]... — 单发无参数 zsh 调（镜像生产 zsh 侧，契约单发形态）
  sb_run "$@" 'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh"'
}
seed_cursor() { printf '{"last_checked_epoch": %s}\n' "$1" >"$CURSOR"; }

# =============================================================================
t_case "S1 场景1 patch-id 命中 refs/heads/contrib/* ⇒ 零建卡+delivered 事件+已投递 summary+游标推进（D3①/契约8/9）"
new_sb
ID_S1="tpidhit1"
WT_S1="$WT_BASE/$ID_S1"
make_repo "$WT_S1" 1
C1_S1="$(git -C "$WT_S1" rev-parse HEAD)"
git -C "$WT_S1" update-ref refs/heads/contrib/pidhit "$C1_S1"
# D4 加性种子（第三段）：snapshot own-PR 面 = 命中 ref（headRefName=contrib/pidhit、headRefOid=命中 commit 全 sha）
jq -n --arg oid "$C1_S1" '{generated_at: "2026-09-12T00:00:00Z", prs: {"103201": {updatedAt: "2026-09-12T00:00:00Z", mergeable: "MERGEABLE", reviewDecision: "", comments: 0, external_comments: 0, headRefOid: $oid, headRefName: "contrib/pidhit"}}}' >"$SB_ROOT/contrib-data/own-pr-watch-snapshot.json"
card_row "$ID_S1" "fix: 上游已有同款修复" "$WT_S1"   # 标题避开「已投递」字面：防泄漏污染 P4 summary 断言
make_db
seed_cursor 0                      # 游标 epoch=0；events 空（sb 底座）；env 无 HERMES_KANBAN_DB（sb_run env -i 白名单天然无）
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S1.P1 gate 单发无参数 exit 0（回扫到已投递候选属正常闭值）"
assert_eq "$(key_cnt "coder-upstream-$ID_S1")" "1" "S1.P2 与建卡同 key 事件恰 1 行（key=coder-upstream-tpidhit1）"
EV_S1="$(ev_row "coder-upstream-$ID_S1")"
assert_eq "$(ev_field "$EV_S1" class)" "coder-upstream-delivered" "S1 事件 class=coder-upstream-delivered（契约9 逐字）"
assert_eq "$(cnt "$CALLS" 'create')" "0" "S1.P3 零建卡（CALLS 零 create 行，删 D1 则红）"
assert_eq "$(hermes_create_cnt)" "0" "S1.P3 精确面：零 hermes create 调用"
assert_eq "$(cand_cnt)" "0" "S1 加演：零 coder-upstream-candidate 事件（命中不走建卡链）"
SUM_S1="$(ev_field "$EV_S1" summary)"
assert_contains "$SUM_S1" "已投递" "S1.P4 summary 明示已投递（字面「已投递」）"
assert_contains "$SUM_S1" "contrib/pidhit" "S1.P5 summary 含命中 ref 短名 contrib/pidhit（剥 refs/heads/ 前缀）"
assert_cursor_advanced "$DONE_EPOCH" "S1.P6"
assert_stub_not_called gh "S1 加演：零 gh 调用（闸门零外呼红线）"
sb_cleanup

# =============================================================================
t_case "S2 场景2 patch-id 未命中 ⇒ 照常建卡（D3② 第一段回归，契约13）"
new_sb
ID_S2="tnohit2"
WT_S2="$WT_BASE/$ID_S2"
make_repo "$WT_S2" 1
mk_unrelated_ref "$WT_S2" refs/heads/contrib/nohit2   # contrib ref 指不同 diff 无关 commit
card_row "$ID_S2" "fix: 未投递的新修复" "$WT_S2"
make_db
seed_cursor 0
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S2.P1 gate exit 0"
num_ge "$(hermes_create_cnt)" "1" "S2.P2 未命中照常 create 建卡（create >= 1）"
H_S2="$(hermes_lines | grep ' create ' | head -1)"
assert_contains "$H_S2" "--board contrib" "S2.P3 create 行含 --board contrib（board pin）"
assert_eq "$(key_cnt "coder-upstream-$ID_S2")" "1" "S2.P4 候选事件 key=coder-upstream-tnohit2 恰 1 行"
assert_cursor_advanced "$DONE_EPOCH" "S2.P5"
sb_cleanup

# =============================================================================
t_case "S3 场景3 HERMES_KANBAN_DB 注入下 board pin 仍成立（D3④/契约11/D2 核心 kill + 直调对照运行）"
new_sb
ID_S3="tpin3"
WT_S3="$WT_BASE/$ID_S3"
make_repo "$WT_S3" 1
mk_unrelated_ref "$WT_S3" refs/heads/contrib/nohit3   # 未命中候选 → 走建卡路径
card_row "$ID_S3" "fix: 注入下的 board pin" "$WT_S3"
make_db
mkdir -p "$SB_ROOT/decoy"
printf 'decoy-not-a-db\n' >"$SB_ROOT/decoy/injected.db"
DECOY_DB="$SB_ROOT/decoy/injected.db"
CTRL_BODY="$SB_ROOT/fixtures/ctrl-pin3.body.md"
printf '对照观测 body\n' >"$CTRL_BODY"
# --- 闸门运行（先）：其 stub 观测行 = KDBENV 此刻全文件（对照运行尚未发生）
run_gate -e "KANBAN_DB=$DB" -e "HERMES_KANBAN_DB=$DECOY_DB"
assert_exit 0 "$?" "S3.P1 注入存在 gate exit 0"
GATE_KDB_S3="$(kdbenv_lines)"      # 闸门段 KDBENV（对照运行尚未发生 = 全文件）
LGATE_S3="$(var_lines_cnt "$GATE_KDB_S3")"
num_ge "$LGATE_S3" "1" "S3.P3 前置：闸门运行产生 stub 观测行 >= 1（KDBENV 观测面已由 stub 落地）"
GATE_CALLS_S3="$(hermes_lines)"    # 闸门段 CALLS（对照运行污染前快照）
# --- 对照运行（后）：不经闸门直调 kanban_card.sh create 携同一注入（控制组，证观测面有效）
sb_run -e "KANBAN_DB=$DB" -e "HERMES_KANBAN_DB=$DECOY_DB" -e "CTRL_BODY=$CTRL_BODY" \
  'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" create --kind upstream --title "对照观测 注入直达" --body-file "$CTRL_BODY" --idempotency-key ctrl-pin3-obs'
assert_exit 0 "$?" "S3 夹具自检：对照运行直调 kanban_card.sh create exit 0"
CTRL_KDB_S3="$(kdbenv_lines | tail -n +"$((LGATE_S3 + 1))" || true)"   # 对照段 = 闸门段之后的行
NCTRL_S3="$(var_lines_cnt "$CTRL_KDB_S3")"
num_ge "$NCTRL_S3" "1" "S3.P2 前置：对照运行产生 stub 观测行 >= 1"
PRES_S3="$(printf '%s\n' "$CTRL_KDB_S3" | grep -c '|present' || true)"
num_ge "$PRES_S3" "1" "S3.P2 对照行 contains |present（注入链与 KDBENV 观测面有效，使 absent 断言非平凡）"
ABSENT_S3="$(printf '%s\n' "$GATE_KDB_S3" | grep -c '|absent' || true)"
assert_eq "$ABSENT_S3" "$LGATE_S3" "S3.P3 闸门运行的 KDBENV 行全部 |absent（删 env -u 则红）"
PRES_IN_GATE_S3="$(printf '%s\n' "$GATE_KDB_S3" | grep -c '|present' || true)"
assert_eq "$PRES_IN_GATE_S3" "0" "S3.P3 加严：闸门段零 |present 行"
H_S3="$(printf '%s\n' "$GATE_CALLS_S3" | grep ' create ' | head -1)"
assert_contains "$H_S3" "--board contrib" "S3.P4 注入下 create 行仍含 --board contrib"
assert_not_contains "$GATE_CALLS_S3" "decoy" "S3.P5 注入下 create 链零 decoy 路径触碰（闸门段 CALLS negate）"
assert_cursor_advanced "$DONE_EPOCH" "S3.P6"
sb_cleanup

# =============================================================================
t_case "S4 场景4 判重不可用（删 ahead commit tree 对象）⇒ 留痕保守放行（D3③/契约10/R3）"
new_sb
ID_S4="tdeg4"
WT_S4="$WT_BASE/$ID_S4"
make_repo "$WT_S4" 1
mk_unrelated_ref "$WT_S4" refs/heads/contrib/nohit4   # refs 无命中项
break_show_del_tree "$WT_S4"
# 夹具自检（硬断言）：log 仍 rc=0（条件 b 存活，未删 commit 对象）、show 已 rc!=0
git -C "$WT_S4" log --format=%H refs/remotes/origin/main..HEAD >/dev/null 2>&1
assert_exit 0 "$?" "S4 夹具自检：删 tree 后 git log 仍 rc=0（条件 b 不拦，R3 陷阱规避成立）"
git -C "$WT_S4" show HEAD >/dev/null 2>&1
assert_ne "$?" "0" "S4 夹具自检：git show 已失败（单项 patch-id 不可得前置成立）"
card_row "$ID_S4" "fix: 对象缺失的修复" "$WT_S4"
make_db
seed_cursor 0
OUT_S4="$(run_gate -e "KANBAN_DB=$DB")"
assert_exit 0 "$?" "S4.P1 判定不可得 gate 不失败退出（exit 0）"
num_ge "$(hermes_create_cnt)" "1" "S4.P2 判定不可得保守放行照常建卡（create >= 1）"
assert_file_contains "$GLOG" "$ID_S4" "S4.P3 GLOG 留痕可定位该项（contains tdeg4）"
assert_not_contains "$OUT_S4" "已投递" "S4.P4 stdout 不标记已投递（negate）"
if [ -f "$EVENTS_F" ] && grep -qF "已投递" "$EVENTS_F" 2>/dev/null; then
  _fail "S4.P4 EVENTS 全文不标记已投递（negate）" "events.jsonl 出现「已投递」字样"
else
  _pass "S4.P4 EVENTS 全文不标记已投递（negate）"
fi
assert_cursor_advanced "$DONE_EPOCH" "S4.P5"
sb_cleanup

# =============================================================================
t_case "S5 场景5 命中态幂等复跑 ⇒ 同 key 恰 1 行零重复卡零重复事件 + 游标不回退（契约9/13）"
new_sb
ID_S5="tpidhit5"
WT_S5="$WT_BASE/$ID_S5"
make_repo "$WT_S5" 1
C1_S5="$(git -C "$WT_S5" rev-parse HEAD)"
git -C "$WT_S5" update-ref refs/heads/contrib/pidhit5 "$C1_S5"   # 场景1 形态命中态
# D4 加性种子（第三段）：snapshot own-PR 面 = 命中 ref（headRefName=contrib/pidhit5、headRefOid=命中 commit 全 sha）
jq -n --arg oid "$C1_S5" '{generated_at: "2026-09-12T00:00:00Z", prs: {"103201": {updatedAt: "2026-09-12T00:00:00Z", mergeable: "MERGEABLE", reviewDecision: "", comments: 0, external_comments: 0, headRefOid: $oid, headRefName: "contrib/pidhit5"}}}' >"$SB_ROOT/contrib-data/own-pr-watch-snapshot.json"
card_row "$ID_S5" "fix: 命中态幂等回扫" "$WT_S5"
make_db
seed_cursor 0
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S5 首轮 exit 0（场景1 形态）"
N1_S5="$(hermes_create_cnt)"
CUR1_S5="$(cursor_val)"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S5.P1 复跑 exit 0"
assert_eq "$(key_cnt "coder-upstream-$ID_S5")" "1" "S5.P2 key 仍恰 1 行（零重复追加，删幂等则红）"
assert_eq "$(hermes_create_cnt)" "$N1_S5" "S5.P3 create 增量 0（$N1_S5 → 不变）"
num_ge "$(cursor_val)" "$CUR1_S5" "S5.P4 游标不回退（>= 首轮值 ${CUR1_S5}）"
# 强化轮（幂等双保险，t8-01 C 同款手法）：游标回拨 → 该卡重回时间候选 → 条件 c（事件 key
# 已消费）必须先挡；若删 key 幂等且判重也失守，此处 key 行数/create 计数必涨（真红）
seed_cursor 0
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S5 强化轮（游标回拨复跑）exit 0"
assert_eq "$(key_cnt "coder-upstream-$ID_S5")" "1" "S5 强化：key 仍恰 1 行（条件 c 先挡双保险）"
assert_eq "$(hermes_create_cnt)" "$N1_S5" "S5 强化：create 增量仍 0"
num_ge "$(cursor_val)" "$DONE_EPOCH" "S5 强化：游标重新推进（>= 卡 completed_at，未滞留回拨值 0）"
sb_cleanup

# =============================================================================
t_case "S6 场景6 混合领先 commit 任一命中即过滤（refs/remotes/fork/* 家族覆盖，契约8）"
new_sb
ID_S6="tmix6"
WT_S6="$WT_BASE/$ID_S6"
make_repo "$WT_S6" 2                # 两个领先 commit C1/C2
C1_S6="$(git -C "$WT_S6" rev-parse HEAD~1)"
git -C "$WT_S6" update-ref refs/remotes/fork/pidmix "$C1_S6"
# D4 加性种子（第三段）：snapshot own-PR 面 = fork 命中 ref（headRefName=pidmix、headRefOid=命中 commit 全 sha）
jq -n --arg oid "$C1_S6" '{generated_at: "2026-09-12T00:00:00Z", prs: {"103201": {updatedAt: "2026-09-12T00:00:00Z", mergeable: "MERGEABLE", reviewDecision: "", comments: 0, external_comments: 0, headRefOid: $oid, headRefName: "pidmix"}}}' >"$SB_ROOT/contrib-data/own-pr-watch-snapshot.json"
card_row "$ID_S6" "fix: 混合领先任一同款改动" "$WT_S6"   # 标题避开「已投递」字面：防泄漏污染 P4 summary 断言
make_db
seed_cursor 0
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S6.P1 gate exit 0"
assert_eq "$(cnt "$CALLS" 'create')" "0" "S6.P2 零建卡（CALLS 零 create 行，删 D1 则红）"
assert_eq "$(hermes_create_cnt)" "0" "S6.P2 精确面：零 hermes create 调用"
assert_eq "$(key_cnt "coder-upstream-$ID_S6")" "1" "S6.P3 key=coder-upstream-tmix6 恰 1 行"
EV_S6="$(ev_row "coder-upstream-$ID_S6")"
assert_eq "$(ev_field "$EV_S6" class)" "coder-upstream-delivered" "S6 事件 class=coder-upstream-delivered（契约9 逐字）"
SUM_S6="$(ev_field "$EV_S6" summary)"
assert_contains "$SUM_S6" "已投递" "S6.P4 summary contains 已投递"
assert_contains "$SUM_S6" "fork/pidmix" "S6.P4 summary contains fork/pidmix（剥 refs/remotes/ 前缀）"
assert_cursor_advanced "$DONE_EPOCH" "S6.P5"
sb_cleanup

t_finish
