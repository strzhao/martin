#!/usr/bin/env bash
# =============================================================================
# t8-04-coder-upstream-snapshot-face.acceptance.test.sh — T8 验收（第三段红队 D4）：
#   coder 上游回馈闸门「已投递」判重面收窄：全量 fork refs 扫描 → own-PR snapshot 面
#   （headRefOid 直项 ∪ headRefName 派生 refs/heads/<name> ∪ refs/remotes/fork/<name>
#   精确 refname 本地解析项），含 fail-open 三态、for-each-ref 形态红锚、RO 诊断 hint、
#   判重面上界，黑盒沙箱矩阵
#
# 依据：kanban 卡 t_6827c2a4 设计文档 契约 12'-15'（SSOT；契约 16' 性能墙钟归 QA 编排器，
#   本文件不覆盖）+ 预注册谓词 Q5（fail-open 面全覆盖）+ 场景清单：
#   S1   面命中·refs/heads 解析项：snapshot 条目 headRefName=twina-shared-fix（本地
#        refs/heads/ 同 tree 异 message 孪生 commit：异 sha 同 patch-id；headRefOid 指
#        空 diff base 作对照直项）⇒ 命中、class=coder-upstream-delivered、
#        key=coder-upstream-<tid>、summary 含「已投递」+ 剥前缀短名 twina-shared-fix、
#        零建卡、游标收尾推进、零 gh（S10 零 gh 红线抽锚折入本场景）
#   S2   面命中·refs/remotes/fork 解析项：headRefName=twib-fork-side 仅 fork 有、heads 无
#        （夹具自检硬断言）；孪生 commit 挂 C1(HEAD~1)（实现若只比 HEAD 的 C2 则不命中）
#        ⇒ 命中 + 短名 fork/twib-fork-side（剥 refs/remotes/ 前缀、保留 fork/ 一级）
#   S3   面命中·headRefOid 直项：headRefName 派生 ref 本地两面均不存在（夹具自检硬断言）、
#        headRefOid=候选领先 commit 全 sha ⇒ 仍命中，显示名=headRefName（非空取 headRefName）
#   S3b  面命中·直项且 headRefName 空串 ⇒ 显示名回退 PR #108009（契约字面口径）
#   S4   fail-open·snapshot 文件缺失 ⇒ exit 0 + 照常建卡（create>=1、候选 key 恰 1 行）+
#        GLOG 逐候选留痕 task=<tid> + 零「已投递」标记 + 零全量扫描回退 + 游标推进
#   S5a  fail-open·snapshot 非 JSON ⇒ 同 S4 断言组
#   S5b  fail-open·.prs 为数组（非对象）⇒ 同 S4 断言组
#   S6   fail-open·snapshot 合法但判重面为空（headRef 字段全缺=旧 snapshot 形态 ∪ 全空串，
#        契约 14' 闸门侧）⇒ 同 S4 断言组
#   S7   禁止全量扫回归锚（git spy，t8-01 手法）：带 snapshot 命中形态 ⇒ for-each-ref
#        真实发生且全部 git 调用为只读闭集 {log 含 origin/main..HEAD / show <oid> 恰一参 /
#        patch-id --stable / for-each-ref 精确 refname（>=1 参）}；零裸家族参数
#        （refs/heads/contrib、refs/remotes/fork 单独成参）、零 *?[ 通配、零 git push
#   S8   RO 诊断：KANBAN_DB 指不存在路径 ⇒ exit 1（fail-closed 零回退）+ GLOG 含
#        kanban.db-wal / kanban.db-shm / 不可读 可定位 hint + 零建卡零事件零游标写
#   S9   命中态幂等复跑（S1 形态）⇒ 同 key 事件恰 1 行、create 增量 0、游标不回退；
#        游标回拨强化轮（条件 c 事件 key 已消费先挡双保险）
#   S11  硬上界 DEDUP_FACE_MAX_REFS=400：401 条 headRefOid+headRefName 双字段条目 ⇒
#        for-each-ref 精确 refname 参数总数 <=400 + GLOG 截断留痕
#   S12  面构造·仅 headRefName 条目（headRefOid 空串=契约 14' 缺省形态）仍须派生解析面：
#        name-only 条目指向本地可解析孪生 ref ⇒ 命中零建卡（契约 12' (i)∪(ii) 逐字段并集）
#
# 红队纪律：黑盒——未读 coder_upstream_gate.sh / own_pr_watch.sh 当前实现内容、未看其
#   git diff/history；只依据设计契约与既有测试 harness 手法（sb_new/sb_run/git spy 包装器/
#   夹具工厂，t8-01/t8-03 先例）；每断言硬失败（assert_eq/assert_exit/assert_contains/
#   negate 手法），零 skip 零软断言；「设计声明的降级路径」也硬断言降级行为本身；全部
#   sb_new 沙箱 + 影子 stub + git spy，零真实外发零真实数据。夹具 git 身份+日期 env 固定
#   （GIT_AUTHOR_DATE/GIT_COMMITTER_DATE），patch-id 只依赖 diff 文本、sha 确定性可复算。
#   判重命中一律用「同 tree 异 message 孪生 commit（异 sha 同 patch-id）」构造，可 kill
#   「sha 比对替代 patch-id 比对」变异。
#
# Mental Mutation（删哪段 ⇒ 哪组断言红）：
#   删 snapshot 面整体、退回全量家族扫描 ⇒ 所有跑闸门场景 git_spy_bad 白名单红
#     （for-each-ref 带裸家族参数 refs/heads/contrib|refs/remotes/fork 即 bad）；S7 三条
#     显式红锚（裸家族/通配/push）红
#   删 headRefName→refs/heads/<name> 派生解析 ⇒ S1 红（面少 heads 项→误建卡+无 delivered）
#   删 headRefName→refs/remotes/fork/<name> 派生解析 ⇒ S2 红
#   删 headRefOid 直项面 ⇒ S3/S3b 红（误建卡）
#   patch-id 比对退化成 sha 比对 ⇒ S1/S2/S9 红（孪生 commit 异 sha 不再命中→误建卡）
#   逐个领先 commit 比对退化成只比 HEAD ⇒ S2 红（命中面 patch-id 在 C1 非 C2）
#   summary 丢「已投递」⇒ S1/S2/S3/S3b 红；丢命中面项显示名 ⇒ 同红；
#   显示名不剥 refs/heads/|refs/remotes/ 前缀 ⇒ S1/S2 的 assert_not_contains 加严红；
#   直项显示名不按「headRefName 非空取 headRefName/否则 PR #N」口径 ⇒ S3/S3b 红
#   snapshot 缺失/损坏/空面误 fail-closed ⇒ S4/S5a/S5b/S6 的 exit/create/留痕红；
#   fail-open 逐候选留痕丢 task=<id> ⇒ S4/S5a/S5b/S6 的 GLOG 断言红；
#   fail-open 私自回退全量扫描 ⇒ S4/S5a/S5b/S6 白名单红；误标已投递 ⇒ negate 断言红
#   RO 失败 hint 缺失 ⇒ S8.P4 红；RO fail-closed 回退（exit!=1/建卡/写游标）⇒ S8 其余红
#   命中态幂等丢失 ⇒ S9 红（key 行数/create 增量涨）；游标回退 ⇒ S9.P4 红
#   闸门外呼 gh ⇒ S1 的 S10 断言红；git push ⇒ S7.P4 红
#   DEDUP_FACE_MAX_REFS 截断丢失 ⇒ S11.P2 红；截断不留痕 ⇒ S11.P3 红；
#   name-only 条目不入派生面 ⇒ S12 红（误建卡）
#
# 对旧实现（第二段，全量 fork 家族扫描形态）的红绿预判（断言按设计锁死，不因旧实现放水）：
#   git_spy_bad 白名单钉在每个跑闸门场景 ⇒ 旧实现全场景必红（其 for-each-ref 恒带
#   refs/heads/contrib refs/remotes/fork 裸家族参数）；若无该白名单，S2（fork 家族孪生
#   恰被旧全量扫描命中）与 S4-S6 的 exit0/建卡面对旧实现会假绿——白名单即真红锚。
# 暂存区实跑记录（2026-09-12，对当时 worktree 现状=蓝队 D4 未提交改动已入 worktree，
#   gate mtime 00:55）：末轮 136 断言 5 红零 skip——5 红全部集中在 S12（name-only 条目
#   在现实现下整条不入派生面 → 误建卡，恰 CONTRACT_AMBIGUOUS 4 裁决点，按红队纪律保持
#   硬红提请裁决，不放水）；S11 夹具改双字段条目后全绿（401 条派生面被截到 <=400 且
#   GLOG 有留痕，上界已达标）。首轮探针记录：401 条 name-only 夹具曾致 fer_cnt=0+无
#   留痕（2 红），据此拆分 S11（纯上界）/S12（name-only 资格）。任务简报「蓝队未合流
#   必然全红」前提与实跑不符，以实跑记录为准。
#
# CONTRACT_AMBIGUOUS（提请人审裁决，不留猜测断言）：
#   1) S11.P3 截断留痕字样：契约只说「超限截断+留痕」未钉字面——断言 GLOG 含
#      DEDUP_FACE_MAX_REFS 或 400 其一（均源自契约字面）；蓝队用第三种字样请裁决。
#   2) S11.P2 截断计数口径：按旋钮名 DEDUP_FACE_MAX_REFS=refs 钉「for-each-ref 精确
#      refname 参数总数 <=400」；若蓝队按 snapshot 条目数截断（一条目派生两 refname）
#      请裁决。
#   3) for-each-ref 闭集严格度：按契约 12' 字面钉「参数仅为精确 refname（>=1 参），无
#      --format 等附加参数」（for-each-ref 默认输出已含 objectname，无需 flag）；若蓝队
#      认为 flag 属机制细节请裁决。
#   4) S12 仅 headRefName 条目（headRefOid 空串）的派生面资格：契约 12' (i)∪(ii) 按
#      逐字段并集读法——headRefName 非空即入派生集，不以 headRefOid 非空为前提（14'
#      「缺省空串」仅指该字段自身缺省）；若蓝队按「条目级：无 oid 即整条不入面（旧
#      snapshot 形态 fail-open）」实现则 S12 红，请人审裁决口径。
#
# 约定：SB_ROOT=mktemp 沙箱根；CALLS=stublog/calls.log；EVENTS=contrib-data/events.jsonl；
#   CURSOR=contrib-data/coder-upstream-cursor.json；GLOG=contrib-data/logs/
#   coder-upstream-gate.log；SNAP=contrib-data/own-pr-watch-snapshot.json（契约 12' 面）。
#   events key 断言一律 jq -s 按 .key 精确匹配（紧凑/带空格双格式均成立）。全角标点相邻
#   变量一律 ${VAR} 花括号（gate.sh 全角门教训）。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin/.worktrees/t_6827c2a4)"
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
SNAP=""     # $SB_ROOT/contrib-data/own-pr-watch-snapshot.json（契约 12' 判重面）
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

# ---- git spy（t8-01 手法：沙箱 bin/git 包装器记账后 exec 真身）----

git_spy_lines() { cat "$SB_ROOT/stublog/git-calls.log" 2>/dev/null || true; }
git_spy_cnt() {
  local n
  n="$(git_spy_lines | grep -c . || true)"
  printf '%s' "${n:-0}"
}
git_spy_fer_cnt() { # for-each-ref 调用次数
  local n
  n="$(git_spy_lines | grep -c 'for-each-ref' || true)"
  printf '%s' "${n:-0}"
}
git_spy_fer_args_total() { # 全部 for-each-ref 行的 refname 参数总数（DEDUP_FACE_MAX_REFS 观测面）
  git_spy_lines | awk '
    {
      s = substr($0, 5)
      split(s, a, " ")
      i = 1
      if (a[1] == "-C") i = 3
      if (a[i] == "for-each-ref") {
        j = i + 1
        while (a[j] != "") { total++; j++ }
      }
    }
    END { print total + 0 }'
}
# git spy 全量形态校验（契约 12' 只读闭集 + for-each-ref 参数闭集）：每行（剥可选 -C <path>
# 前缀后）子命令必为 log（须含 origin/main..HEAD）/ show <oid>（恰一参）/ patch-id --stable
# （恰一参）/ for-each-ref（>=1 参且每参均为精确 refname：refs/heads/<name> 或
# refs/remotes/fork/<name>，非空 name；禁裸家族参数 refs/heads/contrib、refs/remotes/fork；
# 禁 *?[ 通配；禁 --format 等附加参数——CONTRACT_AMBIGUOUS 3）
git_spy_bad() {
  git_spy_lines | awk '
    {
      s = substr($0, 5)
      split(s, a, " ")
      i = 1
      if (a[1] == "-C") i = 3
      sub_cmd = a[i]
      ok = 0
      if (sub_cmd == "log" && index(s, "origin/main..HEAD") > 0) ok = 1
      else if (sub_cmd == "show" && a[i+1] != "" && a[i+2] == "") ok = 1
      else if (sub_cmd == "patch-id" && a[i+1] == "--stable" && a[i+2] == "") ok = 1
      else if (sub_cmd == "for-each-ref") {
        ok = 1
        j = i + 1
        n_args = 0
        while (a[j] != "") {
          n_args++
          arg = a[j]
          good = 0
          if (arg != "refs/heads/contrib" && arg != "refs/remotes/fork" &&
              index(arg, "*") == 0 && index(arg, "?") == 0 && index(arg, "[") == 0) {
            if (substr(arg, 1, 11) == "refs/heads/" && length(arg) > 11) good = 1
            else if (substr(arg, 1, 18) == "refs/remotes/fork/" && length(arg) > 18) good = 1
          }
          if (good == 0) ok = 0
          j++
        }
        if (n_args < 1) ok = 0
      }
      if (ok == 0) bad = 1
    }
    END { print (bad ? 1 : 0) }'
}
git_spy_bare_family_cnt() { # 裸家族参数显式红锚：refs/heads/contrib / refs/remotes/fork 单独成参
  local n
  n="$(git_spy_lines | grep 'for-each-ref' | grep -cE ' (refs/heads/contrib|refs/remotes/fork)( |$)' || true)"
  printf '%s' "${n:-0}"
}
git_spy_wildcard_cnt() { # for-each-ref 行内 * ? [ 通配参数显式红锚（-F 字面匹配，零 BRE 陷阱）
  local n
  n="$(git_spy_lines | grep 'for-each-ref' | grep -cF -e '*' -e '?' -e '[' || true)"
  printf '%s' "${n:-0}"
}
git_spy_push_cnt() { # 零 git push 红线
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

# ---- 事件/留痕断言 ----

assert_events_no_delivered() { # <label> — fail-open 面不得标记已投递（EVENTS 全文 negate）
  if [ -f "$EVENTS_F" ] && grep -qF '已投递' "$EVENTS_F" 2>/dev/null; then
    _fail "$1" "events.jsonl 出现「已投递」字样（fail-open 面不得标记已投递）"
  else
    _pass "$1"
  fi
}
assert_ro_hint() { # <label> — GLOG 含 WAL 三件套/不可读可定位 hint（契约 15' 两可选字样集并集）
  if [ -f "$GLOG" ] && grep -q -e 'kanban.db-wal' -e 'kanban.db-shm' -e '不可读' "$GLOG"; then
    _pass "$1"
  else
    _fail "$1" "GLOG(${GLOG}) 缺可定位 hint（kanban.db-wal / kanban.db-shm / 不可读 任一）"
  fi
}

# ---- 夹具工厂（宿主进程执行，不入沙箱 PATH）----

card_row() { # <id> <title> <workspace_path> [status=done] [assignee=coder] [done_epoch]
  jq -cn --arg id "$1" --arg title "$2" --arg ws "$3" --arg st "${4:-done}" \
    --arg as "${5:-coder}" --argjson "done" "${6:-$DONE_EPOCH}" \
    '{id: $id, title: $title, assignee: $as, status: $st, completed_at: $done, workspace_path: $ws}' >>"$ROWS"
}
make_db() { # 造夹具 kanban.db（schema 镜像真实库 tasks 全列，写入面仅本测试进程；t8-03 同款）
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
# 真实 diff file-<i>.txt；零 push：origin/main 追踪 ref 用 update-ref 直接落，t8-03 同款）
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
mk_twin_ref() { # <wt> <refname> [rev=HEAD] — 同 tree 异 message 孪生 commit（异 sha 同
# patch-id）挂 ref：判重命中构造手法；kill「sha 比对替代 patch-id 比对」变异
  local wt="$1" ref="$2" rev="${3:-HEAD}" base tree cmt
  base="$(git -C "$wt" rev-parse refs/remotes/origin/main)"
  tree="$(git -C "$wt" rev-parse "${rev}^{tree}")"
  cmt="$(git -C "$wt" commit-tree "$tree" -p "$base" -m "twin-$(basename "$wt")")"
  git -C "$wt" update-ref "$ref" "$cmt"
}
seed_snapshot_text() { # <raw-text> — 原样落盘 snapshot（S5a/S5b 损坏形态用）
  printf '%s\n' "$1" >"$SNAP"
}
seed_snapshot_prs() { # <prs-object-json> — 包装合法 snapshot（generated_at + prs，契约 14' 结构）
  jq -cn --argjson prs "$1" '{generated_at: "2026-09-12T00:00:00+08:00", prs: $prs}' >"$SNAP"
}
install_git_spy() { # 沙箱 bin 在 PATH 首位：git argv 记账 git|<argv> 后 exec 真身（t8-01 同款）
  local rgit
  rgit="$(command -v git)"
  cat >"$SB_ROOT/bin/git" <<EOF
#!/bin/bash
# 测试观测包装器：git argv 记账后 exec 真身（for-each-ref 形态红锚 + 零 push 红线观测面）
printf 'git|%s\n' "\$*" >>"\$STUB_LOG_DIR/git-calls.log"
exec "$rgit" "\$@"
EOF
  chmod +x "$SB_ROOT/bin/git"
}
new_sb() { # 每用例沙箱底座 + git spy 安装（黑盒观测面 = stub 记账 + 文件产物）
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  DB="$SB_ROOT/fixtures/kanban.db"
  ROWS="$SB_ROOT/fixtures/rows.txt"
  CALLS="$SB_ROOT/stublog/calls.log"
  CURSOR="$SB_ROOT/contrib-data/coder-upstream-cursor.json"
  EVENTS_F="$SB_ROOT/contrib-data/events.jsonl"
  GLOG="$SB_ROOT/contrib-data/logs/coder-upstream-gate.log"
  SNAP="$SB_ROOT/contrib-data/own-pr-watch-snapshot.json"
  WT_BASE="$SB_ROOT/fixtures/hermes-agent/.worktrees"
  mkdir -p "$SB_ROOT/fixtures"
  install_git_spy
}
run_gate() { # [额外 -e K=V]... — 单发无参数 zsh 调（镜像生产 zsh 侧，契约单发形态）
  sb_run "$@" 'zsh "$MARTIN_DIR/scripts/contrib/coder_upstream_gate.sh"'
}
seed_cursor() { printf '{"last_checked_epoch": %s}\n' "$1" >"$CURSOR"; }

# =============================================================================
t_case "S1 面命中·refs/heads 解析项（headRefOid 直项指空 diff base 作对照）⇒ 零建卡+delivered 事件+剥前缀短名+游标推进（契约 12'/命中语义沿用）"
new_sb
ID_S1="tsnap1"
WT_S1="$WT_BASE/$ID_S1"
make_repo "$WT_S1" 1
C0_S1="$(git -C "$WT_S1" rev-parse refs/remotes/origin/main)"   # base：空 diff，直项无 patch-id 不命中
mk_twin_ref "$WT_S1" "refs/heads/twina-shared-fix"              # 孪生 commit：异 sha 同 patch-id
card_row "$ID_S1" "fix: 快照 heads 解析面命中" "$WT_S1"          # 标题避开「已投递」字面：防泄漏污染 summary 断言
make_db
seed_cursor 0
PRS_S1="$(jq -cn --arg oid "$C0_S1" '{"108001": {number: 108001, title: "snapshot face pr A", headRefName: "twina-shared-fix", headRefOid: $oid}}')"
seed_snapshot_prs "$PRS_S1"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S1.P1 gate 单发无参数 exit 0（命中属正常闭值）"
assert_eq "$(key_cnt "coder-upstream-$ID_S1")" "1" "S1.P2 事件 key=coder-upstream-tsnap1 恰 1 行"
EV_S1="$(ev_row "coder-upstream-$ID_S1")"
assert_eq "$(ev_field "$EV_S1" class)" "coder-upstream-delivered" "S1.P2 class=coder-upstream-delivered（契约逐字）"
assert_eq "$(hermes_create_cnt)" "0" "S1.P3 零建卡（hermes create 计数 0，删面构造则红）"
assert_eq "$(cand_cnt)" "0" "S1 加演：零 coder-upstream-candidate 事件（命中不走建卡链）"
SUM_S1="$(ev_field "$EV_S1" summary)"
assert_contains "$SUM_S1" "已投递" "S1.P4 summary 明示已投递（字面「已投递」）"
assert_contains "$SUM_S1" "twina-shared-fix" "S1.P5 summary 含 heads 解析项短名 twina-shared-fix（剥 refs/heads/ 前缀）"
assert_not_contains "$SUM_S1" "refs/heads/" "S1.P5 加严：显示名零 refs/heads/ 前缀残留"
assert_cursor_advanced "$DONE_EPOCH" "S1.P6"
num_ge "$(git_spy_fer_cnt)" "1" "S1 前置：headRefName 派生精确 refname 必经 for-each-ref（>=1 次，契约 12'）"
assert_eq "$(git_spy_bad)" "0" "S1 git 只读闭集+for-each-ref 精确 refname 形态（契约 12'）"
assert_stub_not_called gh "S10 零 gh 调用（红线抽锚，命中场景）"
sb_cleanup

# =============================================================================
t_case "S2 面命中·refs/remotes/fork 解析项（heads 同名 ref 不存在；孪生挂 C1 非 HEAD）⇒ 命中+fork/ 短名（契约 12' 第二观测面+逐个比对）"
new_sb
ID_S2="tsnap2"
WT_S2="$WT_BASE/$ID_S2"
make_repo "$WT_S2" 2
C0_S2="$(git -C "$WT_S2" rev-parse refs/remotes/origin/main)"
mk_twin_ref "$WT_S2" "refs/remotes/fork/twib-fork-side" "HEAD~1"   # 孪生 C1（tree(HEAD~1)+parent base）
card_row "$ID_S2" "fix: 快照 fork 解析面命中" "$WT_S2"
make_db
seed_cursor 0
PRS_S2="$(jq -cn --arg oid "$C0_S2" '{"108002": {number: 108002, title: "snapshot face pr B", headRefName: "twib-fork-side", headRefOid: $oid}}')"
seed_snapshot_prs "$PRS_S2"
# 夹具自检（硬）：heads 同名 ref 不存在 → 命中只能来自 fork 解析面
git -C "$WT_S2" rev-parse -q --verify "refs/heads/twib-fork-side" >/dev/null 2>&1
assert_ne "$?" "0" "S2 夹具自检：refs/heads/twib-fork-side 不存在（fork 独有）"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S2.P1 gate exit 0"
assert_eq "$(hermes_create_cnt)" "0" "S2.P2 零建卡"
assert_eq "$(cand_cnt)" "0" "S2 加演：零 candidate 事件（命中不走建卡链）"
assert_eq "$(key_cnt "coder-upstream-$ID_S2")" "1" "S2.P3 key=coder-upstream-tsnap2 恰 1 行"
EV_S2="$(ev_row "coder-upstream-$ID_S2")"
assert_eq "$(ev_field "$EV_S2" class)" "coder-upstream-delivered" "S2 class=coder-upstream-delivered（契约逐字）"
SUM_S2="$(ev_field "$EV_S2" summary)"
assert_contains "$SUM_S2" "已投递" "S2.P4 summary contains 已投递"
assert_contains "$SUM_S2" "fork/twib-fork-side" "S2.P4 summary 含剥 refs/remotes/ 前缀短名 fork/twib-fork-side"
assert_not_contains "$SUM_S2" "refs/remotes/" "S2.P4 加严：显示名零 refs/remotes/ 前缀残留"
assert_cursor_advanced "$DONE_EPOCH" "S2.P5"
num_ge "$(git_spy_fer_cnt)" "1" "S2 前置：fork 派生 refname 必经 for-each-ref（>=1 次）"
assert_eq "$(git_spy_bad)" "0" "S2 git 只读闭集+精确 refname 形态（契约 12'）"
sb_cleanup

# =============================================================================
t_case "S3 面命中·headRefOid 直项（headRefName 派生 ref 本地两面均不存在）⇒ 仍命中+显示名取 headRefName（契约 12' 直项）"
new_sb
ID_S3="tsnap3"
WT_S3="$WT_BASE/$ID_S3"
make_repo "$WT_S3" 1
C1_S3="$(git -C "$WT_S3" rev-parse HEAD)"
card_row "$ID_S3" "fix: 快照直项 oid 命中" "$WT_S3"
make_db
seed_cursor 0
PRS_S3="$(jq -cn --arg oid "$C1_S3" '{"108003": {number: 108003, title: "snapshot face pr C", headRefName: "twic-ghost-branch", headRefOid: $oid}}')"
seed_snapshot_prs "$PRS_S3"
# 夹具自检（硬）：派生 refname 本地两面均不存在 → 命中只能来自 headRefOid 直项
git -C "$WT_S3" rev-parse -q --verify "refs/heads/twic-ghost-branch" >/dev/null 2>&1
assert_ne "$?" "0" "S3 夹具自检：refs/heads/twic-ghost-branch 不存在"
git -C "$WT_S3" rev-parse -q --verify "refs/remotes/fork/twic-ghost-branch" >/dev/null 2>&1
assert_ne "$?" "0" "S3 夹具自检：refs/remotes/fork/twic-ghost-branch 不存在"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S3.P1 gate exit 0"
assert_eq "$(hermes_create_cnt)" "0" "S3.P2 零建卡"
assert_eq "$(key_cnt "coder-upstream-$ID_S3")" "1" "S3.P3 key=coder-upstream-tsnap3 恰 1 行"
EV_S3="$(ev_row "coder-upstream-$ID_S3")"
assert_eq "$(ev_field "$EV_S3" class)" "coder-upstream-delivered" "S3 class=coder-upstream-delivered（契约逐字）"
SUM_S3="$(ev_field "$EV_S3" summary)"
assert_contains "$SUM_S3" "已投递" "S3.P4 summary contains 已投递"
assert_contains "$SUM_S3" "twic-ghost-branch" "S3.P4 直项显示名=headRefName（非空取 headRefName，契约口径）"
assert_cursor_advanced "$DONE_EPOCH" "S3.P5"
num_ge "$(git_spy_fer_cnt)" "1" "S3 前置：headRefName 派生 refname 解析必经 for-each-ref（>=1 次）"
assert_eq "$(git_spy_bad)" "0" "S3 git 只读闭集+精确 refname 形态（契约 12'）"
sb_cleanup

# =============================================================================
t_case "S3b 面命中·headRefOid 直项且 headRefName 空串 ⇒ 显示名回退 PR #<PR号>（契约 12' 显示名口径）"
new_sb
ID_S3B="tsnap3b"
WT_S3B="$WT_BASE/$ID_S3B"
make_repo "$WT_S3B" 1
C1_S3B="$(git -C "$WT_S3B" rev-parse HEAD)"
card_row "$ID_S3B" "fix: 快照直项空名回退" "$WT_S3B"
make_db
seed_cursor 0
PRS_S3B="$(jq -cn --arg oid "$C1_S3B" '{"108009": {number: 108009, title: "snapshot face pr D", headRefName: "", headRefOid: $oid}}')"
seed_snapshot_prs "$PRS_S3B"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S3b.P1 gate exit 0"
assert_eq "$(hermes_create_cnt)" "0" "S3b.P2 零建卡"
assert_eq "$(key_cnt "coder-upstream-$ID_S3B")" "1" "S3b.P3 key=coder-upstream-tsnap3b 恰 1 行"
EV_S3B="$(ev_row "coder-upstream-$ID_S3B")"
assert_eq "$(ev_field "$EV_S3B" class)" "coder-upstream-delivered" "S3b class=coder-upstream-delivered（契约逐字）"
SUM_S3B="$(ev_field "$EV_S3B" summary)"
assert_contains "$SUM_S3B" "已投递" "S3b.P4 summary contains 已投递"
assert_contains "$SUM_S3B" "PR #108009" "S3b.P4 headRefName 空 ⇒ 显示名回退 PR #108009（契约字面）"
assert_cursor_advanced "$DONE_EPOCH" "S3b.P5"
assert_eq "$(git_spy_bad)" "0" "S3b git 只读闭集+精确 refname 形态（契约 12'）"
sb_cleanup

# =============================================================================
t_case "S4 fail-open·snapshot 文件缺失 ⇒ 跳过判重照常建卡+逐候选 task=<id> 留痕+零全量扫描回退（契约 13'/Q5）"
new_sb
ID_S4="tsnap4"
WT_S4="$WT_BASE/$ID_S4"
make_repo "$WT_S4" 1
card_row "$ID_S4" "fix: 缺快照放行" "$WT_S4"
make_db
seed_cursor 0
rm -f "$SNAP"                              # snapshot 文件缺失前置
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S4.P1 snapshot 缺失不 fail-closed（exit 0）"
num_ge "$(hermes_create_cnt)" "1" "S4.P2 照常建卡（create >= 1，create 语义零回退）"
assert_eq "$(key_cnt "coder-upstream-$ID_S4")" "1" "S4.P2 候选事件 key=coder-upstream-tsnap4 恰 1 行（create 语义）"
assert_file_contains "$GLOG" "task=$ID_S4" "S4.P3 GLOG 逐候选留痕含 task=tsnap4（契约 13' 字面）"
assert_events_no_delivered "S4.P4 零已投递标记（EVENTS 全文 negate）"
assert_cursor_advanced "$DONE_EPOCH" "S4.P5"
assert_eq "$(git_spy_bad)" "0" "S4.P6 零全量扫描回退（for-each-ref 形态白名单仍过，契约 13' 绝不回退）"
sb_cleanup

# =============================================================================
t_case "S5a fail-open·snapshot 非 JSON（jq 校验失败）⇒ 照常建卡+留痕+零全量扫描回退（契约 13'/Q5）"
new_sb
ID_S5A="tsnap5a"
WT_S5A="$WT_BASE/$ID_S5A"
make_repo "$WT_S5A" 1
card_row "$ID_S5A" "fix: 坏快照放行" "$WT_S5A"
make_db
seed_cursor 0
seed_snapshot_text 'this is definitely not json {{{'
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S5a.P1 snapshot 损坏不 fail-closed（exit 0）"
num_ge "$(hermes_create_cnt)" "1" "S5a.P2 照常建卡（create >= 1）"
assert_eq "$(key_cnt "coder-upstream-$ID_S5A")" "1" "S5a.P2 候选事件 key 恰 1 行（create 语义）"
assert_file_contains "$GLOG" "task=$ID_S5A" "S5a.P3 GLOG 逐候选留痕含 task=tsnap5a"
assert_events_no_delivered "S5a.P4 零已投递标记（negate）"
assert_cursor_advanced "$DONE_EPOCH" "S5a.P5"
assert_eq "$(git_spy_bad)" "0" "S5a.P6 零全量扫描回退（白名单仍过）"
sb_cleanup

# =============================================================================
t_case "S5b fail-open·snapshot .prs 为数组（非对象，jq 校验失败）⇒ 照常建卡+留痕+零全量扫描回退（契约 13'/Q5）"
new_sb
ID_S5B="tsnap5b"
WT_S5B="$WT_BASE/$ID_S5B"
make_repo "$WT_S5B" 1
card_row "$ID_S5B" "fix: 数组快照放行" "$WT_S5B"
make_db
seed_cursor 0
seed_snapshot_text '{"generated_at": "2026-09-12T00:00:00+08:00", "prs": [{"number": 1}]}'
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S5b.P1 .prs 非对象不 fail-closed（exit 0）"
num_ge "$(hermes_create_cnt)" "1" "S5b.P2 照常建卡（create >= 1）"
assert_eq "$(key_cnt "coder-upstream-$ID_S5B")" "1" "S5b.P2 候选事件 key 恰 1 行（create 语义）"
assert_file_contains "$GLOG" "task=$ID_S5B" "S5b.P3 GLOG 逐候选留痕含 task=tsnap5b"
assert_events_no_delivered "S5b.P4 零已投递标记（negate）"
assert_cursor_advanced "$DONE_EPOCH" "S5b.P5"
assert_eq "$(git_spy_bad)" "0" "S5b.P6 零全量扫描回退（白名单仍过）"
sb_cleanup

# =============================================================================
t_case "S6 fail-open·snapshot 合法但判重面为空（headRef 字段全缺=旧 snapshot 形态 ∪ 全空串）⇒ 照常建卡+留痕（契约 13'/14'/Q5）"
new_sb
ID_S6="tsnap6"
WT_S6="$WT_BASE/$ID_S6"
make_repo "$WT_S6" 1
card_row "$ID_S6" "fix: 旧快照空面放行" "$WT_S6"
make_db
seed_cursor 0
PRS_S6="$(jq -cn '{"108006": {number: 108006, title: "old snapshot entry no head fields"}, "108007": {number: 108007, title: "empty head fields", headRefOid: "", headRefName: ""}}')"
seed_snapshot_prs "$PRS_S6"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S6.P1 空面不 fail-closed（exit 0）"
num_ge "$(hermes_create_cnt)" "1" "S6.P2 照常建卡（create >= 1）"
assert_eq "$(key_cnt "coder-upstream-$ID_S6")" "1" "S6.P2 候选事件 key 恰 1 行（create 语义）"
assert_file_contains "$GLOG" "task=$ID_S6" "S6.P3 GLOG 逐候选留痕含 task=tsnap6"
assert_events_no_delivered "S6.P4 零已投递标记（negate）"
assert_cursor_advanced "$DONE_EPOCH" "S6.P5"
assert_eq "$(git_spy_bad)" "0" "S6.P6 空字段不产生非法 git 调用（白名单仍过，契约 14' 字段缺失按缺省）"
sb_cleanup

# =============================================================================
t_case "S7 禁止全量扫回归锚（git spy）：带 snapshot 命中形态 ⇒ for-each-ref 恰精确 refname、零裸家族参数、零通配、零 push（契约 12' 红锚）"
new_sb
ID_S7="tsnap7"
WT_S7="$WT_BASE/$ID_S7"
make_repo "$WT_S7" 1
C0_S7="$(git -C "$WT_S7" rev-parse refs/remotes/origin/main)"
mk_twin_ref "$WT_S7" "refs/heads/twih-heads-side"
card_row "$ID_S7" "fix: 形态红锚命中形态" "$WT_S7"
make_db
seed_cursor 0
PRS_S7="$(jq -cn --arg oid "$C0_S7" '{"108004": {number: 108004, title: "snapshot face pr E", headRefName: "twih-heads-side", headRefOid: $oid}}')"
seed_snapshot_prs "$PRS_S7"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S7.P1 gate exit 0"
num_ge "$(git_spy_cnt)" "1" "S7 前置：git spy 可见 >= 1 次调用（观测面有效）"
num_ge "$(git_spy_fer_cnt)" "1" "S7.P2 for-each-ref 真实发生（>=1 次，使形态断言非平凡）"
assert_eq "$(git_spy_bad)" "0" "S7.P3 全部 git 调用=只读闭集且 for-each-ref 参数全为精确 refname（>=1 参）"
assert_eq "$(git_spy_bare_family_cnt)" "0" "S7.P3 零裸家族参数（refs/heads/contrib、refs/remotes/fork 单独成参）"
assert_eq "$(git_spy_wildcard_cnt)" "0" "S7.P3 零通配参数（* ? [ 字面）"
assert_eq "$(git_spy_push_cnt)" "0" "S7.P4 零 git push（绝不自动 push 红线）"
assert_eq "$(hermes_create_cnt)" "0" "S7 加演：命中形态零建卡"
assert_stub_not_called gh "S10 零 gh 调用（红线抽锚，形态场景）"
sb_cleanup

# =============================================================================
t_case "S8 RO 诊断：KANBAN_DB 指不存在路径 ⇒ exit 1+GLOG WAL/-shm 可定位 hint+零建卡零游标写（契约 15'）"
new_sb
MISSING_DB="$SB_ROOT/fixtures/absent-dir/kanban.db"   # 目录与文件均不存在 → mode=ro 打开失败
run_gate -e "KANBAN_DB=$MISSING_DB"
assert_exit 1 "$?" "S8.P1 fail-closed exit 1（零回退）"
assert_eq "$(hermes_create_cnt)" "0" "S8.P2 零建卡"
assert_eq "$(cand_cnt)" "0" "S8.P2 零 candidate 事件"
if [ -e "$CURSOR" ]; then
  _fail "S8.P3 零游标写" "游标文件不应存在: ${CURSOR}"
else
  _pass "S8.P3 零游标写"
fi
assert_ro_hint "S8.P4 GLOG 含 kanban.db-wal/kanban.db-shm/不可读 可定位 hint（契约 15'）"
sb_cleanup

# =============================================================================
t_case "S9 命中态幂等复跑（S1 形态）⇒ 同 key 事件恰 1 行、create 增量 0、游标不回退（命中语义沿用）"
new_sb
ID_S9="tsnap9"
WT_S9="$WT_BASE/$ID_S9"
make_repo "$WT_S9" 1
C0_S9="$(git -C "$WT_S9" rev-parse refs/remotes/origin/main)"
mk_twin_ref "$WT_S9" "refs/heads/twin9-side"
card_row "$ID_S9" "fix: 快照命中幂等复跑" "$WT_S9"
make_db
seed_cursor 0
PRS_S9="$(jq -cn --arg oid "$C0_S9" '{"108005": {number: 108005, title: "snapshot face pr F", headRefName: "twin9-side", headRefOid: $oid}}')"
seed_snapshot_prs "$PRS_S9"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S9 首轮 exit 0（S1 形态命中）"
assert_eq "$(ev_field "$(ev_row "coder-upstream-$ID_S9")" class)" "coder-upstream-delivered" "S9 前置锚：首轮事件 class=delivered（非 candidate，钉幂等对象）"
N1_S9="$(hermes_create_cnt)"
CUR1_S9="$(cursor_val)"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S9.P1 复跑 exit 0"
assert_eq "$(key_cnt "coder-upstream-$ID_S9")" "1" "S9.P2 同 key 事件仍恰 1 行（零重复追加）"
assert_eq "$(hermes_create_cnt)" "$N1_S9" "S9.P3 create 增量 0（${N1_S9} → 不变）"
num_ge "$(cursor_val)" "$CUR1_S9" "S9.P4 游标不回退（>= 首轮值 ${CUR1_S9}）"
# 强化轮（t8-03 S5 同款）：游标回拨 → 卡重回时间候选 → 条件 c（事件 key 已消费）先挡双保险
seed_cursor 0
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S9 强化轮（游标回拨复跑）exit 0"
assert_eq "$(key_cnt "coder-upstream-$ID_S9")" "1" "S9 强化：key 仍恰 1 行（条件 c 先挡）"
assert_eq "$(hermes_create_cnt)" "$N1_S9" "S9 强化：create 增量仍 0"
num_ge "$(cursor_val)" "$DONE_EPOCH" "S9 强化：游标重新推进（>= 卡 completed_at，未滞留回拨值 0）"
sb_cleanup

# =============================================================================
t_case "S11 硬上界 DEDUP_FACE_MAX_REFS=400：401 条 headRefOid+headRefName 双字段条目 ⇒ for-each-ref 精确 refname 总数 <=400+截断留痕（契约 12'）"
new_sb
ID_S11="tsnap11"
WT_S11="$WT_BASE/$ID_S11"
make_repo "$WT_S11" 1
C0_S11="$(git -C "$WT_S11" rev-parse refs/remotes/origin/main)"   # 空 diff base：直项无 patch-id 零命中
card_row "$ID_S11" "fix: 判重面上界" "$WT_S11"
make_db
seed_cursor 0
python3 - "$SNAP" "$C0_S11" <<'PY'
import json, sys
snap_path, base_oid = sys.argv[1], sys.argv[2]
prs = {}
for i in range(401):
    # 双字段条目（D4 正常 snapshot 形态）：oid 指空 diff base（直项零命中），name 派生
    # 802 个精确 refname（heads+fork 各 401+1 重叠不成立，实为 802）→ 硬上界 400 截断面
    prs[str(700000 + i)] = {"number": 700000 + i, "title": "cap entry %d" % i,
                            "headRefName": "cap-br-%d" % i, "headRefOid": base_oid}
json.dump({"generated_at": "2026-09-12T00:00:00+08:00", "prs": prs},
          open(snap_path, "w"), ensure_ascii=False)
PY
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S11.P1 gate exit 0"
num_ge "$(git_spy_fer_cnt)" "1" "S11 前置：派生面解析必经 for-each-ref（>=1 次，使上界断言非平凡）"
assert_eq "$(git_spy_bad)" "0" "S11 截断不破坏形态（参数仍全为精确 refname）"
num_le "$(git_spy_fer_args_total)" "400" "S11.P2 判重面 for-each-ref 精确 refname 参数总数 <= 400（DEDUP_FACE_MAX_REFS 硬上界）"
if [ -f "$GLOG" ] && grep -q -e 'DEDUP_FACE_MAX_REFS' -e '400' "$GLOG"; then
  _pass "S11.P3 超限截断留痕（GLOG 含 DEDUP_FACE_MAX_REFS/400 痕迹）"
else
  _fail "S11.P3 超限截断留痕" "GLOG(${GLOG}) 缺截断留痕（CONTRACT_AMBIGUOUS 1：字样未钉，见文件头）"
fi
sb_cleanup

# =============================================================================
t_case "S12 面构造·仅 headRefName 条目（headRefOid 空串=契约 14' 缺省形态）仍须派生解析面 ⇒ 命中零建卡（契约 12' (i)∪(ii) 逐字段并集，CONTRACT_AMBIGUOUS 4）"
new_sb
ID_S12="tsnap12"
WT_S12="$WT_BASE/$ID_S12"
make_repo "$WT_S12" 1
C0_S12="$(git -C "$WT_S12" rev-parse refs/remotes/origin/main)"
mk_twin_ref "$WT_S12" "refs/heads/twin12-side"   # name-only 条目指向的可解析孪生 ref
card_row "$ID_S12" "fix: 仅名字段派生面命中" "$WT_S12"
make_db
seed_cursor 0
PRS_S12="$(jq -cn --arg oid "$C0_S12" '{"108011": {number: 108011, title: "ghost name entry zero hit", headRefName: "ghost-nonexistent-xyz", headRefOid: ""}, "108012": {number: 108012, title: "name-only entry", headRefName: "twin12-side", headRefOid: ""}}')"
seed_snapshot_prs "$PRS_S12"
run_gate -e "KANBAN_DB=$DB"
assert_exit 0 "$?" "S12.P1 gate exit 0"
assert_eq "$(hermes_create_cnt)" "0" "S12.P2 name-only 条目派生面命中 ⇒ 零建卡（整条不入面则误建卡红）"
assert_eq "$(key_cnt "coder-upstream-$ID_S12")" "1" "S12.P3 key=coder-upstream-tsnap12 恰 1 行"
EV_S12="$(ev_row "coder-upstream-$ID_S12")"
assert_eq "$(ev_field "$EV_S12" class)" "coder-upstream-delivered" "S12 class=coder-upstream-delivered（契约逐字）"
SUM_S12="$(ev_field "$EV_S12" summary)"
assert_contains "$SUM_S12" "已投递" "S12.P4 summary contains 已投递"
assert_contains "$SUM_S12" "twin12-side" "S12.P4 summary 含 name-only 条目解析短名 twin12-side"
assert_cursor_advanced "$DONE_EPOCH" "S12.P5"
num_ge "$(git_spy_fer_cnt)" "1" "S12 前置：name-only 条目派生 refname 必经 for-each-ref（>=1 次）"
assert_eq "$(git_spy_bad)" "0" "S12 git 只读闭集+精确 refname 形态（契约 12'）"
sb_cleanup

t_finish
