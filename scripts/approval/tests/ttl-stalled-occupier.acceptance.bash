#!/bin/bash
# =============================================================================
# 红队对抗性验收测试：审批链 TTL 守卫「停摆放行」（stalled-occupier）
# 被测孪生闸门：scripts/approval/execute.sh 执行路 TTL 复验第 2 项
#              scripts/contrib/notify.sh approve 发卡前轻复验
#
# 依据（SSOT，信息隔离下仅凭以下材料推导，未读本轮新增实现函数体）：
#   state.md「## 契约规约」契约 A-E + 冻结字面量 + 副作用清单
#   state.md「## 验收场景」场景 1-11（21 条预注册谓词，每条 ≥1 硬断言）
#   state.md「## 设计文档」终态设计/边界语义
#   变更前基线 cee516f（B_death 逐字节基线与既有 premise/veto 机制口径，非本轮实现）
#
# 黑盒驱动声明：只经 CLI 调 execute.sh <id> approved / notify.sh approve <id>，
#   经既有 env seam（CONTRIB_DATA_DIR/RQ_LOCKDIR/NOTIFY_LOCK/APPROVED_LOG/
#   GH_BIN/HERMES_BIN/TUNNEL_BIN/NOTIFY_SEND_LAST/NOTIFY_DRY_RUN/MARTIN_DIR）注入沙箱；
#   断言只观测 exit code、rq 队列 state/history note、域日志、stub 调用账。
#
# 零真实外发声明：gh/hermes/tunnel/claude 全部为 stub 替身（调用全落盘记账），
#   零真实 gh 写、零真实微信、零真实部署；生产 contrib-data/** 与 approved.log
#   零写入（末组以 pin 绝对路径 diff 只读复核）。
#
# 时间 fixture：BSD date -v-Nd 注入「运行时刻 − N 天」；21/22 天边界用 ±10 分钟
#   保护带（21 天侧 = now−(21d−10min) 仍 ≤ 截点；22 天侧 = now−(22d+10min) 仍 > 截点），
#   消解秒级竞态，严格不等词语义（>21×86400 才豁免）不受影响。
#
# 冻结谓词的两点实现化裁决（已在断言中显式落地，非弱化）：
#   ① 场景11.P1「记录 not contains -X POST」与场景 1/3.P2/4.P1「state == executed」
#     结构性冲突（放行必经既有投递 gh api -X POST …/issues/N/comments）。
#     裁决：写命令按运行期望分桶审计——期望拦截的运行中 -X POST 必须为 0；
#     期望放行的运行中 -X POST 只允许命中投递端点（/comments）且恰 1 次；
#     全局禁 pr create/edit/merge、issue comment/edit。负证前先正证记录非空含只读命令
#     （plan-reviewer 建议①，防「审计型零X谓词空转盲区」）。
#   ② 场景10.P2 要求 run.sh 输出全文 contains "release-gate"：静态+动态核实 run.sh
#     全文无该 token（蓝队套件无 release-gate 分流用例），该子谓词对 run.sh 输出不可
#     满足。裁决：对 run.sh 输出硬断言其余三 token + P1 全绿；「release-gate 跳过」
#     行为语义在本文件内自建硬断言覆盖（Egate 用例），缺口上报 QA。
#
# 断言全部硬断言：失败计 FAIL，末尾 PASS <n> checks，有 FAIL 则 exit 1。
# 运行：MARTIN_DIR=<martin根> bash ttl-stalled-occupier.acceptance.bash
# target: scripts/approval/tests/ttl-stalled-occupier.acceptance.bash
# =============================================================================

set -uo pipefail
# stdin 守卫：本脚本不读 stdin；防子进程（stub cat / gh 管线）继承交互 stdin 阻塞
exec 0</dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 定位 martin 根：MARTIN_DIR 优先 → 自身位置向上搜 10 层找 scripts/contrib/notify.sh
#    （staging 目录比最终 target 深，10 层覆盖两条落位）→ 兜底 $HOME/workspace/martin ──
MARTIN_ROOT="${MARTIN_DIR:-}"
if [[ -z "$MARTIN_ROOT" ]]; then
  d="$SCRIPT_DIR"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -f "$d/scripts/contrib/notify.sh" ]]; then MARTIN_ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi
if [[ -z "$MARTIN_ROOT" ]]; then
  MARTIN_ROOT="$HOME/workspace/martin"
fi
if [[ ! -f "$MARTIN_ROOT/scripts/contrib/notify.sh" ]]; then
  echo "FATAL: 无法定位 martin 根（未找到 scripts/contrib/notify.sh）；可设 MARTIN_DIR=<root>" >&2
  exit 1
fi
EXECUTE="$MARTIN_ROOT/scripts/approval/execute.sh"
NOTIFY="$MARTIN_ROOT/scripts/contrib/notify.sh"
RQ="$MARTIN_ROOT/scripts/contrib/rq.sh"
RUN_SUITE="$MARTIN_ROOT/scripts/approval/tests/run.sh"
for f in "$EXECUTE" "$NOTIFY" "$RQ" "$RUN_SUITE"; do
  if [[ ! -f "$f" ]]; then echo "FATAL: 被测/依赖脚本缺失: $f" >&2; exit 1; fi
done

PASS=0
FAIL=0
FAILED_NOTES=""

ok() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() {
  FAIL=$((FAIL + 1))
  FAILED_NOTES+=$'\n'"    - $1"
  printf '  NOT OK - %s\n' "$1"
  if [[ $# -gt 1 ]]; then printf '      %s\n' "$2"; fi
}
check_eq() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi
}
check_ne() { # <desc> <unexpected> <actual>
  if [[ "$2" != "$3" ]]; then ok "$1"; else fail "$1" "两值应不同却相同=[$2]"; fi
}
check_contains() { # <desc> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else fail "$1" "未找到 [$2]（实际前 200 字: ${3:0:200}）"; fi
}
check_not_contains() { # <desc> <needle> <haystack>
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else fail "$1" "不应出现却出现 [$2]"; fi
}
check_match() { # <desc> <ere> <value>
  if [[ "$3" =~ $2 ]]; then ok "$1"; else fail "$1" "值不匹配 /$2/: [$3]"; fi
}
check_zero() { # <desc> <n>
  if [[ "$2" == "0" ]]; then ok "$1"; else fail "$1" "应为 0，实际=[$2]"; fi
}

# pinned diff（knowledge patterns.md:321：第三方 diff 遮蔽系统命令 → 假绿盲区）
DIFF_BIN="/usr/bin/diff"
[[ -x "$DIFF_BIN" ]] || DIFF_BIN="$(command -v diff)"

# ── 审计存档区（跨用例持久；场景 11 用）与生产快照区 ──
AUDIT="$(mktemp -d "${TMPDIR:-/tmp}/rtq-audit.XXXXXX")"
PROD_SNAP="$(mktemp -d "${TMPDIR:-/tmp}/rtq-prodsnap.XXXXXX")"
DELIVER_CASES=""    # 期望最终放行投递的用例名（gh -X POST 恰 1 次且仅 /comments 端点）
NODELIVER_CASES=""  # 期望拦截的用例名（gh 零 -X POST）
SB=""
cleanup() {
  [[ -n "$SB" && -d "$SB" ]] && rm -rf "$SB"
  [[ -d "$AUDIT" ]] && rm -rf "$AUDIT"
  [[ -d "$PROD_SNAP" ]] && rm -rf "$PROD_SNAP"
  return 0
}
trap cleanup EXIT

# ── 生产零触碰基线（测试开始前快照；结束只读 diff 复核）──
PROD_TARGETS=("$MARTIN_ROOT/approved.log"
              "$MARTIN_ROOT/contrib-data/config.json"
              "$MARTIN_ROOT/contrib-data/ready-queue.json"
              "$MARTIN_ROOT/contrib-data/events.jsonl")
_i=0
for _f in "${PROD_TARGETS[@]}"; do
  if [[ -f "$_f" ]]; then
    cp "$_f" "$PROD_SNAP/prod-$_i.snap"
    stat -f '%m' "$_f" > "$PROD_SNAP/prod-$_i.mtime" 2>/dev/null || : > "$PROD_SNAP/prod-$_i.mtime"
  fi
  _i=$((_i + 1))
done

# ================= stub 替身（一次性生成；调用全落盘记账） =================
RT_STUBS="$(mktemp -d "${TMPDIR:-/tmp}/rtq-stubs.XXXXXX")"

# gh stub：fixture 目录驱动（RTQ_FIXTURES）——本测试自有参数化机制
#   prlist.json        → `pr list` 输出（缺省 []）
#   pr-view-<n>.json   → `pr view <n>` 输出（回退 pr-view.json；都缺省则 rc=7 可诊断失败）
#   pr-view.rc         → 存在则 `pr view` 以该 rc 失败（fail-closed 注入）
#   pr-view-empty      → 存在则 `pr view` 零输出退出 0（空输出 fail-closed 注入）
#   issue-view.json    → `issue view` 输出（缺省 {"state":"OPEN"}）
#   comments.json      → issue 近 5 评论拉取输出（缺省 []）
cat > "$RT_STUBS/gh" <<'STUB'
#!/bin/bash
LOG="${RTQ_GH_LOG:?RTQ_GH_LOG required}"
{ printf '=== gh'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
FIX="${RTQ_FIXTURES:?RTQ_FIXTURES required}"
cmd="${1:-}"; sub="${2:-}"
case "$cmd/$sub" in
  pr/list)
    if [[ -f "$FIX/prlist.json" ]]; then cat "$FIX/prlist.json"; else echo '[]'; fi
    exit 0 ;;
  pr/view)
    n="${3:-}"
    if [[ -f "$FIX/pr-view.rc" ]]; then
      echo "rt-gh-stub: forced pr view failure" >&2
      exit "$(cat "$FIX/pr-view.rc")"
    fi
    if [[ -f "$FIX/pr-view-empty" ]]; then exit 0; fi
    if [[ -f "$FIX/pr-view-$n.json" ]]; then cat "$FIX/pr-view-$n.json"; exit 0; fi
    if [[ -f "$FIX/pr-view.json" ]]; then cat "$FIX/pr-view.json"; exit 0; fi
    echo "rt-gh-stub: no fixture for pr view $n（测试 fixture 缺失）" >&2
    exit 7 ;;
  issue/view)
    if [[ -f "$FIX/issue-view.json" ]]; then cat "$FIX/issue-view.json"; else echo '{"state":"OPEN"}'; fi
    exit 0 ;;
esac
case "$*" in
  *"-X POST"*)
    echo '{"html_url":"https://github.com/NousResearch/hermes-agent/issues/771000#issuecomment-770001"}'
    exit 0 ;;
  *"comments?per_page"*)
    if [[ -f "$FIX/comments.json" ]]; then cat "$FIX/comments.json"; else echo '[]'; fi
    exit 0 ;;
esac
echo '{}'
exit 0
STUB

# hermes stub：send 记账（零真实微信）；--file 消息体落档
cat > "$RT_STUBS/hermes" <<'STUB'
#!/bin/bash
LOG="${RTQ_HERMES_LOG:?RTQ_HERMES_LOG required}"
{ printf '=== hermes'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
prev=""
for a in "$@"; do
  if [[ "$prev" == "--file" && -f "$a" ]]; then
    { printf -- '--- sent body ---\n'; cat "$a"; printf '\n'; } >> "$LOG"
  fi
  prev="$a"
done
printf '{"success":true,"message_id":"rt-stub-1"}\n' > "${NOTIFY_SEND_LAST:?NOTIFY_SEND_LAST required}"
echo '{"success":true,"message_id":"rt-stub-1"}'
exit 0
STUB

# tunnel stub：drops approve 打印部署 URL；rm 幂等（零真实部署）
cat > "$RT_STUBS/tunnel" <<'STUB'
#!/bin/bash
LOG="${RTQ_TUNNEL_LOG:?RTQ_TUNNEL_LOG required}"
{ printf '=== tunnel'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
cmd="${1:-}"; sub="${2:-}"
if [[ "$cmd" == "drops" && "$sub" == "approve" ]]; then
  slug=""; prev=""
  for a in "$@"; do
    [[ "$prev" == "--name" || "$prev" == "-n" ]] && slug="$a"
    prev="$a"
  done
  echo "https://pages.example/${slug:-noslug}"
  exit 0
fi
if [[ "$cmd" == "rm" ]]; then exit 0; fi
echo "rt-tunnel-stub: unsupported args: $*" >&2
exit 64
STUB

# claude stub：判读层替身（无输出 → ttl 判读链判不可用；绝不触真实 LLM）
cat > "$RT_STUBS/claude" <<'STUB'
#!/bin/bash
exit 1
STUB

# osascript / pgrep 替身（兜底通知与网关探测，防真实外溢）
cat > "$RT_STUBS/osascript" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$RT_STUBS/pgrep" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$RT_STUBS/gh" "$RT_STUBS/hermes" "$RT_STUBS/tunnel" "$RT_STUBS/claude" "$RT_STUBS/osascript" "$RT_STUBS/pgrep"

# ================= 沙箱工厂与用例脚手架 =================
RT_ISSUE_NEXT=771000   # 本测试独立 issue 编号段（771001+，与蓝队 fixture 无关）
PR_MAIN=88001          # 主占用 PR
PR_SECOND=88003        # 混合占用第二 PR
OCC_AUTHOR="stale-occupier-auth"   # 占坑 PR 作者 login
P3_LOGIN="drive-by-commenter"      # 第三方（非作者）login

rt_case_begin() { # rt_case_begin —— 新沙箱 + 默认 fixtures + 域日志清零
  SB="$(mktemp -d "${TMPDIR:-/tmp}/rtq-case.XXXXXX")"
  mkdir -p "$SB/data/pending" "$SB/data/logs" "$SB/data/runs/deep-check" "$SB/locks" "$SB/fixtures"
  jq -n '{repo:"NousResearch/hermes-agent", deep_check_per_week:30, deep_check_per_day:30,
          max_alert_pushes_per_day:3, max_approval_pushes_per_day:10, approval_ttl_hours:48,
          notify_min_interval_min:20, notify_dry_run:true, notify_target:"weixin:rt-sandbox@im.wechat",
          notify_digest:true, approval_interactive:true}' > "$SB/data/config.json"
  printf '{"version":1,"updated":"","items":[]}\n' > "$SB/data/ready-queue.json"
  jq -n '{limits:{week:30,day:10},days:{},weeks:{},probes:{}}' > "$SB/data/budget.json"
  : > "$SB/data/events.jsonl"
  printf '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}\n' > "$SB/data/notify-state.json"
  # 默认 fixtures（用例可覆盖）：issue OPEN、无评论、无占用
  printf '{"state":"OPEN"}\n' > "$SB/fixtures/issue-view.json"
  printf '[]\n' > "$SB/fixtures/comments.json"
  printf '[]\n' > "$SB/fixtures/prlist.json"
  : > "$SB/calls-gh.log"; : > "$SB/calls-hermes.log"; : > "$SB/calls-tunnel.log"
}

rt_case_end() { # <用例名> <deliver|nodeliver> —— 存档调用账 → 进审计桶 → 销毁沙箱
  local name="$1" bucket="$2"
  [[ -f "$SB/calls-gh.log" ]] && cp "$SB/calls-gh.log" "$AUDIT/$name.gh.log"
  [[ -f "$SB/calls-hermes.log" ]] && cp "$SB/calls-hermes.log" "$AUDIT/$name.hermes.log"
  [[ -f "$SB/calls-tunnel.log" ]] && cp "$SB/calls-tunnel.log" "$AUDIT/$name.tunnel.log"
  if [[ "$bucket" == "deliver" ]]; then
    DELIVER_CASES="$DELIVER_CASES $name"
  else
    NODELIVER_CASES="$NODELIVER_CASES $name"
  fi
  rm -rf "$SB"; SB=""
}

rt_rq() { # <rq 子命令…> —— 沙箱内 rq.sh
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/data" RQ_LOCKDIR="$SB/locks/rq" \
      TUNNEL_BIN="$RT_STUBS/tunnel" MARTIN_DIR="$MARTIN_ROOT" \
      bash "$RQ" "$@" )
}

# 稿件必含 4 空格缩进 goods 行：rq.sh set-draft 在 set -e/pipefail 下 grep 无命中会
# 静默杀死（09-12 基线实证，沙箱机制性规避，同 run.sh make_item 手法）
RT_PREM_DEFAULT='[{"claim":"停摆闸门验收前提","evidence":"acceptance-fixture:ttl-stalled-occupier"}]'
rt_make_item() { # <issue> <disposition> [premises_json] → RT_ITEM_ID（推进到 awaiting-approval + 稿）
  local issue="$1" disp="$2"
  local prem="${3:-$RT_PREM_DEFAULT}"
  local lane="probe"; [[ "$disp" == "review-evidence" ]] && lane="deep"
  RT_ISSUE_NEXT=$((RT_ISSUE_NEXT + 1))
  [[ "$issue" == "$RT_ISSUE_NEXT" ]] || { echo "FATAL: issue 序号错位 $issue != $RT_ISSUE_NEXT" >&2; exit 1; }
  RT_ITEM_ID="$(rt_rq add --issue "$issue" --disposition "$disp" --score 12 --lane "$lane" \
    --source manual --title "红队停摆闸门演练 $issue" --premises-json "$prem")"
  local draft="$SB/data/pending/$RT_ITEM_ID.md"
  printf '# 红队沙箱稿 %s\n\n正文：停摆占坑闸门验收用稿（沙箱内部件，禁止外发）。\n\n    goods: 无（红队沙箱演练稿；此行仅供 rq set-draft 的 goods 回退抓取）\n' "$RT_ITEM_ID" > "$draft"
  rt_rq set-draft "$RT_ITEM_ID" "$draft" >/dev/null
  rt_rq set "$RT_ITEM_ID" awaiting-approval >/dev/null
}

rt_to_approved() { # <id> —— 模拟 collect 消费后的 approved 态
  rt_rq set "$1" approved >/dev/null
}

rt_run_execute() { # <id> → RT_RC（env seam 全指向沙箱 + stub PATH）
  RT_RC=0
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/data" RQ_LOCKDIR="$SB/locks/rq" NOTIFY_LOCK="$SB/locks/notify" \
      APPROVED_LOG="$SB/approved.log" APPROVAL_DRY_RUN=false NOTIFY_DRY_RUN=true \
      MARTIN_DIR="$MARTIN_ROOT" \
      GH_BIN="$RT_STUBS/gh" TUNNEL_BIN="$RT_STUBS/tunnel" HERMES_BIN="$RT_STUBS/hermes" \
      OSASCRIPT_BIN="$RT_STUBS/osascript" GATEWAY_PROBE_BIN="$RT_STUBS/pgrep" \
      NOTIFY_SEND_LAST="$SB/send-last.json" \
      PATH="$RT_STUBS:$PATH" \
      RTQ_FIXTURES="$SB/fixtures" RTQ_GH_LOG="$SB/calls-gh.log" \
      RTQ_HERMES_LOG="$SB/calls-hermes.log" RTQ_TUNNEL_LOG="$SB/calls-tunnel.log" \
      bash "$EXECUTE" "$1" approved ) > "$SB/out.txt" 2> "$SB/err.txt" || RT_RC=$?
}

rt_run_notify() { # <id> → RT_RC（非 dry：发卡前轻复验真实执行；外发全 stub）
  RT_RC=0
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/data" RQ_LOCKDIR="$SB/locks/rq" NOTIFY_LOCK="$SB/locks/notify" \
      NOTIFY_SEND_LAST="$SB/send-last.json" NOTIFY_DRY_RUN=false \
      MARTIN_DIR="$MARTIN_ROOT" \
      GH_BIN="$RT_STUBS/gh" TUNNEL_BIN="$RT_STUBS/tunnel" HERMES_BIN="$RT_STUBS/hermes" \
      OSASCRIPT_BIN="$RT_STUBS/osascript" GATEWAY_PROBE_BIN="$RT_STUBS/pgrep" \
      PATH="$RT_STUBS:$PATH" \
      RTQ_FIXTURES="$SB/fixtures" RTQ_GH_LOG="$SB/calls-gh.log" \
      RTQ_HERMES_LOG="$SB/calls-hermes.log" RTQ_TUNNEL_LOG="$SB/calls-tunnel.log" \
      bash "$NOTIFY" approve "$1" ) > "$SB/out.txt" 2> "$SB/err.txt" || RT_RC=$?
}

# ── 沙箱观测 ──
rt_state() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' "$SB/data/ready-queue.json"; }
rt_note_of() { # <id> <event> → 该迁移 history note（rq set 的 event=state 名）
  jq -r --arg id "$1" --arg ev "$2" \
    '.items[] | select(.id == $id) | [.history[] | select(.event == $ev) | (.note // "")] | join(" | ")' \
    "$SB/data/ready-queue.json"
}
rt_exec_log() { cat "$SB/data/logs/approval-execute.log" 2>/dev/null || true; }
rt_notify_log() { cat "$SB/data/logs/notify.log" 2>/dev/null || true; }
rt_events() { cat "$SB/data/events.jsonl" 2>/dev/null || true; }
rt_gh_calls() { cat "$SB/calls-gh.log" 2>/dev/null || true; }
rt_count_in() { grep -cF -- "$2" <<<"$1" 2>/dev/null || true; }

# ── 时间 fixture（BSD date -v；边界保护带见头部说明）──
iso_ago() { # <days> —— 恰 N 天前
  date -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ'
}
iso_ago_lt() { # <days> —— N 天前再早 10 分钟（停摆 >N 天侧，边界放行组用）
  date -v-"$1"d -v-10M '+%Y-%m-%dT%H:%M:%SZ'
}
iso_ago_gt() { # <days> —— N 天前再晚 10 分钟（停摆 <N 天侧，边界拦截组用）
  date -v-"$1"d -v+10M '+%Y-%m-%dT%H:%M:%SZ'
}

# ── pr view fixture 写手（契约 D 数据结构：anchor = commits ∪ 作者本人评论；updatedAt ∉ 锚）──
rt_write_view() { # <file> <作者login> <commit_iso|-> <作者评论_iso|-> <updatedAt_iso> [三方login 三方评论_iso]
  local f="$1" login="$2" c="$3" oc="$4" u="$5" p3l="${6:-}" p3c="${7:-}"
  jq -n --arg login "$login" --arg c "$c" --arg oc "$oc" --arg u "$u" --arg p3l "$p3l" --arg p3c "$p3c" '
    {author: {login: $login}, updatedAt: $u,
     commits: (if $c == "-" then [] else [{committedDate: $c}] end),
     comments: ([if $oc == "-" then empty else {author: {login: $login}, createdAt: $oc} end]
              + [if $p3l == "" then empty else {author: {login: $p3l}, createdAt: $p3c} end])}' > "$f"
}

rt_set_prlist() { # <PR号…> —— 占用 PR 集合（pr list fixture）
  local out="[" first=1 p
  for p in "$@"; do
    (( first )) && first=0 || out+=","
    out+="{\"number\":$p}"
  done
  printf '%s]\n' "$out" > "$SB/fixtures/prlist.json"
}

# 冻结豁免 note 正则（契约规约冻结字面量：stalled-occupier 豁免：#<n> 停摆 <D> 天（anchor=<ISO>，updatedAt=<ISO>））
re_exempt() { # <PR号> <D 天数> → stdout 正则
  printf 'stalled-occupier 豁免：#%s 停摆 %s 天（anchor=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z，updatedAt=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z）' "$1" "$2"
}

echo "===== 场景 1：execute 路停摆占坑放行并留痕（作者锚 30 天）====="
rt_case_begin
ISS_S1=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S1" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S1_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S1_ID"
check_eq "1.P1: 停摆 30 天占用 → execute 放行 exit == 0" "0" "$RT_RC"
check_eq "1.P1: 队列终态 executed" "executed" "$(rt_state "$S1_ID")"
EXLOG="$(rt_exec_log)"
check_contains "1.P2: 日志留可 grep 豁免痕迹（stalled-occupier 豁免）" "stalled-occupier 豁免" "$EXLOG"
check_match "1.P2: 豁免 note 逐字骨架（#88001 停摆 30 天 anchor/updatedAt ISO）" "$(re_exempt "$PR_MAIN" 30)" "$EXLOG"
rt_case_end "S1" "deliver"

echo "===== 场景 2：notify 路同契约（30 / 恰 22 / 恰 21 天）====="
rt_case_begin
ISS_S2A=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S2A" probe-salvage
S2A_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_notify "$S2A_ID"
check_eq "2.P1: 停摆 30 天 → notify approve exit == 0" "0" "$RT_RC"
check_eq "2.P1: 终态维持 awaiting-approval" "awaiting-approval" "$(rt_state "$S2A_ID")"
HERMES_N="$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
TUNNEL_N="$(rt_count_in "$(cat "$SB/calls-tunnel.log" 2>/dev/null)" "drops approve")"
check_eq "2.P1: 卡推送 stub 记账 == 1" "1" "$HERMES_N"
check_eq "2.P1: 审批页部署 stub 记账 == 1" "1" "$TUNNEL_N"
NTLOG="$(rt_notify_log)"
check_contains "2.P2: notify 日志留豁免痕迹" "stalled-occupier 豁免" "$NTLOG"
check_match "2.P2: 豁免 note 逐字骨架（#$PR_MAIN 停摆 30 天）" "$(re_exempt "$PR_MAIN" 30)" "$NTLOG"
rt_case_end "S2a" "nodeliver"

rt_case_begin
ISS_S2B=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S2B" probe-salvage
S2B_ID="$RT_ITEM_ID"
C22="$(iso_ago_lt 22)"; U1="$(iso_ago 1)"   # 停摆 22 天 + 10 分钟 > 截点
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C22" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_notify "$S2B_ID"
check_eq "2.P3: 恰 22 天（>21）→ 发卡放行 exit == 0" "0" "$RT_RC"
check_eq "2.P3: 终态 awaiting-approval" "awaiting-approval" "$(rt_state "$S2B_ID")"
HERMES_N="$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
check_eq "2.P3: 卡推送记账 == 1" "1" "$HERMES_N"
check_contains "2.P3: 豁免痕迹（停摆 22 天）" "停摆 22 天" "$(rt_notify_log)"
rt_case_end "S2b" "nodeliver"

rt_case_begin
ISS_S2C=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S2C" probe-salvage
S2C_ID="$RT_ITEM_ID"
C21="$(iso_ago_gt 21)"; U1="$(iso_ago 1)"   # 停摆 21 天 − 10 分钟 ≤ 截点
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C21" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_notify "$S2C_ID"
check_eq "2.P4: 恰 21 天（未超过）→ 拦截不发卡（hermes 记账 0）" "0" \
  "$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
check_eq "2.P4: 审批页部署记账 0" "0" "$(rt_count_in "$(cat "$SB/calls-tunnel.log" 2>/dev/null)" "drops approve")"
check_eq "2.P4: 终态 rejected" "rejected" "$(rt_state "$S2C_ID")"
DEATH_NOTE="$(rt_note_of "$S2C_ID" "rejected")"
check_contains "2.P4: rejected note 含判死占坑文案" "已被 PR $PR_MAIN 占坑" "$DEATH_NOTE"
check_contains "2.P4: 判死 log 冻结字面量逐字（approve <id>: premise 死亡…——置 rejected，不发卡）" \
  "approve $S2C_ID: premise 死亡（issue #$ISS_S2C 已被 PR $PR_MAIN 占坑）——置 rejected，不发卡" "$(rt_notify_log)"
check_not_contains "2.P4: 日志无豁免字样" "stalled-occupier 豁免" "$(rt_notify_log)"
check_contains "2.P4: premise-dead 事件入账" "premise-dead" "$(rt_events)"
rt_case_end "S2c" "nodeliver"

echo "===== 场景 3：execute 路停摆边界 21/22 天（硬切换点）====="
rt_case_begin
ISS_S3A=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S3A" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S3A_ID="$RT_ITEM_ID"
C21="$(iso_ago_gt 21)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C21" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S3A_ID"
check_eq "3.P1: 恰 21 天（未超过）→ exit == 1" "1" "$RT_RC"
check_eq "3.P1: 终态 failed" "failed" "$(rt_state "$S3A_ID")"
S3A_NOTE="$(rt_note_of "$S3A_ID" "failed")"
# B_death 冻结字面量 = issue #<ISSUE> 已有在途 PR（<csv> ）占坑；rq failed note 携带
# 变更前既有前缀「TTL 复验未过: 」（cee516f 基线同款，零回归一并锁字节）
check_eq "3.P1: reason == 前缀 + B_death（逐字节）" \
  "TTL 复验未过: issue #$ISS_S3A 已有在途 PR（ $PR_MAIN ）占坑" "$S3A_NOTE"
check_contains "3.P1: 日志含 B_death 文案" "已有在途 PR（ $PR_MAIN ）占坑" "$(rt_exec_log)"
check_not_contains "3.P1: 日志无豁免字样" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S3a" "nodeliver"

rt_case_begin
ISS_S3B=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S3B" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S3B_ID="$RT_ITEM_ID"
C22="$(iso_ago_lt 22)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C22" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S3B_ID"
check_eq "3.P2: 恰 22 天（>21）→ exit == 0" "0" "$RT_RC"
check_eq "3.P2: 终态 executed" "executed" "$(rt_state "$S3B_ID")"
check_contains "3.P2: 日志留豁免痕迹" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S3b" "deliver"

echo "===== 场景 4：第三方评论顶新 updatedAt，作者锚 40 天——锚口径红锚 ====="
rt_case_begin
ISS_S4=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S4" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S4_ID="$RT_ITEM_ID"
C50="$(iso_ago 50)"; OC40="$(iso_ago 40)"; U1="$(iso_ago 1)"; P3C1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C50" "$OC40" "$U1" "$P3_LOGIN" "$P3C1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S4_ID"
check_eq "4.P1: updatedAt=1 天前（三方顶新）+ 作者锚 40 天 → 仍放行 exit == 0" "0" "$RT_RC"
check_eq "4.P1: 终态 executed" "executed" "$(rt_state "$S4_ID")"
EXLOG="$(rt_exec_log)"
check_contains "4.P1: 日志留豁免痕迹" "stalled-occupier 豁免" "$EXLOG"
check_match "4.P1: 豁免 note 按作者锚计 40 天" "$(re_exempt "$PR_MAIN" 40)" "$EXLOG"
check_contains "4.P1: note 的 updatedAt 字段 = 被顶新的新鲜值（updatedAt 仅留痕不作锚）" "updatedAt=$U1" "$EXLOG"
rt_case_end "S4" "deliver"

echo "===== 场景 5：作者本人 3 天前评论刷新锚——停摆重算后维持判死 ====="
rt_case_begin
ISS_S5=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S5" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S5_ID="$RT_ITEM_ID"
C60="$(iso_ago 60)"; OC3="$(iso_ago 3)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C60" "$OC3" "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S5_ID"
check_eq "5.P1: 作者本人评论 3 天前（锚 ≤21）→ exit == 1" "1" "$RT_RC"
check_eq "5.P1: 终态 failed" "failed" "$(rt_state "$S5_ID")"
S5_NOTE="$(rt_note_of "$S5_ID" "failed")"
check_eq "5.P1: reason == 前缀 + B_death（逐字节）" \
  "TTL 复验未过: issue #$ISS_S5 已有在途 PR（ $PR_MAIN ）占坑" "$S5_NOTE"
check_not_contains "5.P1: 日志无豁免字样" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S5" "nodeliver"

echo "===== 场景 6：fail-closed——gh 取证失败（两路同契约）====="
rt_case_begin
ISS_S6A=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S6A" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S6A_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
printf '3\n' > "$SB/fixtures/pr-view.rc"   # 注入 gh pr view rc=3
rt_run_execute "$S6A_ID"
S6A_NOTE="$(rt_note_of "$S6A_ID" "failed")"
check_ne "6.P1: gh 取证失败 → 拦截（exit != 0）" "0" "$RT_RC"
check_eq "6.P1: 终态 failed" "failed" "$(rt_state "$S6A_ID")"
check_ne "6.P1: 终态绝非 executed" "executed" "$(rt_state "$S6A_ID")"
check_not_contains "6.P2: reason 不等于 B_death（不误判死亡）" "已有在途 PR" "$S6A_NOTE"
check_not_contains "6.P2: 日志无豁免痕迹" "stalled-occupier 豁免" "$(rt_exec_log)"
check_contains "6.P2: reason 可诊断（fail-closed 明示）" "fail-closed" "$S6A_NOTE"
check_contains "6.P2: reason 带 rc 码（取证失败（rc=3））" "rc=3" "$S6A_NOTE"
rt_case_end "S6a" "nodeliver"

rt_case_begin
ISS_S6B=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S6B" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S6B_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
: > "$SB/fixtures/pr-view-empty"           # 注入 gh pr view 空输出（rc=0）
rt_run_execute "$S6B_ID"
S6B_NOTE="$(rt_note_of "$S6B_ID" "failed")"
check_ne "6.P1(空输出变体): 拦截（exit != 0）" "0" "$RT_RC"
check_eq "6.P1(空输出变体): 终态 failed" "failed" "$(rt_state "$S6B_ID")"
check_not_contains "6.P1(空输出变体): 不误判死亡（reason 无 B_death）" "已有在途 PR" "$S6B_NOTE"
check_match "6.P1(空输出变体): reason 可诊断（取证失败/形状异常/fail-closed 三选一）" \
  "取证失败|形状异常|fail-closed" "$S6B_NOTE"
check_not_contains "6.P1(空输出变体): 日志无豁免痕迹" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S6b" "nodeliver"

rt_case_begin
ISS_S6C=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S6C" probe-salvage
S6C_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
printf '3\n' > "$SB/fixtures/pr-view.rc"
rt_run_notify "$S6C_ID"
check_eq "6.P3: notify 取证失败 → 终态 rejected" "rejected" "$(rt_state "$S6C_ID")"
S6C_NOTE="$(rt_note_of "$S6C_ID" "rejected")"
check_not_contains "6.P3: 不误报 premise 死亡（note 无占坑判死文案）" "已被 PR" "$S6C_NOTE"
check_contains "6.P3: note 明写 fail-closed" "fail-closed" "$S6C_NOTE"
NTLOG="$(rt_notify_log)"
check_contains "6.P3: log 含 fail-closed 诊断" "fail-closed" "$NTLOG"
check_contains "6.P3: log 诊断带 rc 码（取证失败（rc=3））" "rc=3" "$NTLOG"
check_not_contains "6.P3: log 无判死冻结字面量" "premise 死亡" "$NTLOG"
check_eq "6.P3: 零卡推送" "0" "$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
check_eq "6.P3: 零审批页部署" "0" "$(rt_count_in "$(cat "$SB/calls-tunnel.log" 2>/dev/null)" "drops approve")"
check_contains "6.P3: 事件注明 fail-closed（不误报 premise 死亡）" "fail-closed" "$(rt_events)"
rt_case_end "S6c" "nodeliver"

echo "===== 场景 7：fail-closed——无锚（无 commit 也无作者评论）====="
rt_case_begin
ISS_S7A=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S7A" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S7A_ID="$RT_ITEM_ID"
U1="$(iso_ago 1)"; P3C1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" - - "$U1" "$P3_LOGIN" "$P3C1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S7A_ID"
S7A_NOTE="$(rt_note_of "$S7A_ID" "failed")"
check_eq "7.P1: 锚缺失 → exit == 1" "1" "$RT_RC"
check_eq "7.P1: 终态 failed" "failed" "$(rt_state "$S7A_ID")"
check_not_contains "7.P1: 不误判死亡（reason 无 B_death）" "已有在途 PR" "$S7A_NOTE"
check_contains "7.P1: reason 可诊断（停摆锚不可算）" "锚不可算" "$S7A_NOTE"
check_not_contains "7.P1: 日志无豁免痕迹" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S7a" "nodeliver"

rt_case_begin
ISS_S7B=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S7B" probe-salvage
S7B_ID="$RT_ITEM_ID"
U1="$(iso_ago 1)"; P3C1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" - - "$U1" "$P3_LOGIN" "$P3C1"
rt_set_prlist "$PR_MAIN"
rt_run_notify "$S7B_ID"
check_eq "7.P2: notify 锚缺失 → 终态 rejected" "rejected" "$(rt_state "$S7B_ID")"
NTLOG="$(rt_notify_log)"
check_not_contains "7.P2: 日志无豁免痕迹" "stalled-occupier 豁免" "$NTLOG"
check_contains "7.P2: log 含 fail-closed 诊断" "fail-closed" "$NTLOG"
check_eq "7.P2: 零卡推送" "0" "$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
check_eq "7.P2: 零审批页部署" "0" "$(rt_count_in "$(cat "$SB/calls-tunnel.log" 2>/dev/null)" "drops approve")"
rt_case_end "S7b" "nodeliver"

echo "===== 场景 8：fail-closed——日期不可解析 / 畸形 JSON（execute 路）====="
rt_case_begin
ISS_S8A=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S8A" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S8A_ID="$RT_ITEM_ID"
U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "not-a-github-timestamp" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S8A_ID"
S8A_NOTE="$(rt_note_of "$S8A_ID" "failed")"
check_eq "8.P1: 作者动作时间不可解析 → exit == 1" "1" "$RT_RC"
check_eq "8.P1: 终态 failed" "failed" "$(rt_state "$S8A_ID")"
check_not_contains "8.P1: reason 无 B_death" "已有在途 PR" "$S8A_NOTE"
check_contains "8.P1: reason 可诊断（日期不可解析）" "不可解析" "$S8A_NOTE"
check_not_contains "8.P1: 日志无豁免痕迹" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S8a" "nodeliver"

rt_case_begin
ISS_S8B=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S8B" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S8B_ID="$RT_ITEM_ID"
printf '这不是JSON{{{（非法负载）\n' > "$SB/fixtures/pr-view-$PR_MAIN.json"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S8B_ID"
S8B_NOTE="$(rt_note_of "$S8B_ID" "failed")"
check_eq "8.P2: gh 返回非法 JSON → exit == 1" "1" "$RT_RC"
check_eq "8.P2: 终态 failed" "failed" "$(rt_state "$S8B_ID")"
check_not_contains "8.P2: 日志无豁免痕迹" "stalled-occupier 豁免" "$(rt_exec_log)"
check_not_contains "8.P2: 不误判死亡（reason 无 B_death）" "已有在途 PR" "$S8B_NOTE"
rt_case_end "S8b" "nodeliver"

echo "===== 场景 9：豁免不旁路其余机械复验（issue CLOSE / premises 抽验 / 否决评论）====="
rt_case_begin
ISS_S9A=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S9A" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S9A_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
printf '{"state":"CLOSED"}\n' > "$SB/fixtures/issue-view.json"   # 注入 issue 已关闭
rt_run_execute "$S9A_ID"
check_ne "9.P1: 豁免成立 + issue CLOSED → 仍拦截（exit != 0）" "0" "$RT_RC"
check_eq "9.P1: 终态 failed" "failed" "$(rt_state "$S9A_ID")"
check_ne "9.P1: 终态绝非 executed" "executed" "$(rt_state "$S9A_ID")"
check_contains "9.P1: 拦截原因是 issue 非 OPEN（豁免未旁路第 1 项）" "非 OPEN" "$(rt_exec_log)"
check_not_contains "9.P1: 日志无豁免字样" "stalled-occupier 豁免" "$(rt_exec_log)"
rt_case_end "S9a" "nodeliver"

rt_case_begin
ISS_S9B=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S9B" probe-salvage \
  '[{"claim":"占用存活前提","evidence":""}]'
rt_to_approved "$RT_ITEM_ID"
S9B_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$S9B_ID"
check_ne "9.P2: 豁免成立 + premises 抽验不过 → 仍拦截（exit != 0）" "0" "$RT_RC"
check_eq "9.P2: 终态 failed" "failed" "$(rt_state "$S9B_ID")"
check_ne "9.P2: 终态绝非 executed" "executed" "$(rt_state "$S9B_ID")"
check_contains "9.P2: 拦截原因是 premises 抽验失败" "premises 抽验失败" "$(rt_exec_log)"
# 注：占用 PR 确已停摆，豁免 note 属取证留痕；拦截由后续 premises 闸完成（谓词只锁 exit/state）
rt_case_end "S9b" "nodeliver"

rt_case_begin
ISS_S9C=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_S9C" probe-salvage
rt_to_approved "$RT_ITEM_ID"
S9C_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
# 注入否决信号评论（机械哨兵关键词 wontfix）；判读层全 stub 不可用 → 机械兜底 fail-closed 拦截
printf '[{"body":"wontfix，closing as duplicate","created_at":"%s","author":{"login":"maintainer-x"}}]\n' \
  "$(iso_ago 2)" > "$SB/fixtures/comments.json"
rt_run_execute "$S9C_ID"
S9C_NOTE="$(rt_note_of "$S9C_ID" "failed")"
check_ne "9.P3: 豁免成立 + 评论否决信号 → 仍拦截（exit != 0）" "0" "$RT_RC"
check_eq "9.P3: 终态 failed" "failed" "$(rt_state "$S9C_ID")"
check_ne "9.P3: 终态绝非 executed" "executed" "$(rt_state "$S9C_ID")"
check_match "9.P3: 拦截原因是否决信号（否决/BLOCK）" "否决|BLOCK" "$S9C_NOTE"
# 注：同 9.P2，豁免 note 属取证留痕；拦截由评论否决闸完成
rt_case_end "S9c" "nodeliver"

echo "===== 契约 B/例：一停一活混合占用（任一活跃即死）——execute 与 notify 双路 ====="
rt_case_begin
ISS_EMIX=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_EMIX" probe-salvage
rt_to_approved "$RT_ITEM_ID"
EMIX_ID="$RT_ITEM_ID"
C40="$(iso_ago 40)"; C3="$(iso_ago 3)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json"  "$OCC_AUTHOR" "$C40" - "$U1"
rt_write_view "$SB/fixtures/pr-view-$PR_SECOND.json" "$OCC_AUTHOR" "$C3"  - "$U1"
rt_set_prlist "$PR_MAIN" "$PR_SECOND"
rt_run_execute "$EMIX_ID"
EMIX_NOTE="$(rt_note_of "$EMIX_ID" "failed")"
check_eq "契约B: 一停(40天)一活(3天) → exit == 1" "1" "$RT_RC"
check_eq "契约B: 终态 failed" "failed" "$(rt_state "$EMIX_ID")"
check_eq "契约B: reason == 前缀 + B_death 含全部占用 PR（逐字节）" \
  "TTL 复验未过: issue #$ISS_EMIX 已有在途 PR（ $PR_MAIN, $PR_SECOND ）占坑" "$EMIX_NOTE"
rt_case_end "Emix" "nodeliver"

rt_case_begin
ISS_NMIX=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_NMIX" probe-salvage
NMIX_ID="$RT_ITEM_ID"
C40="$(iso_ago 40)"; C3="$(iso_ago 3)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json"  "$OCC_AUTHOR" "$C40" - "$U1"
rt_write_view "$SB/fixtures/pr-view-$PR_SECOND.json" "$OCC_AUTHOR" "$C3"  - "$U1"
rt_set_prlist "$PR_MAIN" "$PR_SECOND"
rt_run_notify "$NMIX_ID"
check_eq "契约B(notify): 一停一活 → 终态 rejected" "rejected" "$(rt_state "$NMIX_ID")"
check_contains "契约B(notify): 判死 log 含全部占用 PR" "已被 PR $PR_MAIN,$PR_SECOND 占坑" "$(rt_notify_log)"
# 注：一停一活时实现按 PR 逐个落停摆 note（#PR_MAIN 停摆）后因 #PR_SECOND 活跃判死——
# 豁免 note 属取证留痕，不构成放行；终态/reason 断言已锁死任一活跃即死。
check_eq "契约B(notify): 零卡推送" "0" "$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
rt_case_end "Nmix" "nodeliver"

echo "===== 契约 D notify 侧变体：第三方评论顶新 updatedAt + 作者锚 40 天 → 仍发卡 ====="
rt_case_begin
ISS_ND=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_ND" probe-salvage
ND_ID="$RT_ITEM_ID"
C50="$(iso_ago 50)"; OC40="$(iso_ago 40)"; U1="$(iso_ago 1)"; P3C1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C50" "$OC40" "$U1" "$P3_LOGIN" "$P3C1"
rt_set_prlist "$PR_MAIN"
rt_run_notify "$ND_ID"
check_eq "契约D(notify): updatedAt 新鲜 + 作者锚 40 天 → exit == 0" "0" "$RT_RC"
check_eq "契约D(notify): 终态 awaiting-approval" "awaiting-approval" "$(rt_state "$ND_ID")"
check_eq "契约D(notify): 卡推送记账 == 1" "1" \
  "$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
check_contains "契约D(notify): 豁免 note 按作者锚计 40 天" "停摆 40 天" "$(rt_notify_log)"
rt_case_end "ND" "nodeliver"

echo "===== 契约 E：范围不变量（review-evidence 免检 / release-gate 跳过）====="
rt_case_begin
ISS_EREV=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_EREV" review-evidence
rt_to_approved "$RT_ITEM_ID"
EREV_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_execute "$EREV_ID"
check_eq "契约E: review-evidence 遇占用 PR 仍免检放行（exit == 0）" "0" "$RT_RC"
check_eq "契约E: review-evidence 终态 executed" "executed" "$(rt_state "$EREV_ID")"
rt_case_end "Erev" "deliver"

rt_case_begin
ISS_EGATE=$((RT_ISSUE_NEXT + 1))
rt_make_item "$ISS_EGATE" release-gate
EGATE_ID="$RT_ITEM_ID"
C30="$(iso_ago 30)"; U1="$(iso_ago 1)"
rt_write_view "$SB/fixtures/pr-view-$PR_MAIN.json" "$OCC_AUTHOR" "$C30" - "$U1"
rt_set_prlist "$PR_MAIN"
rt_run_notify "$EGATE_ID"
check_contains "契约E: release-gate 项跳过 gh premise 复验（不进占坑判定）" "release-gate 项跳过" "$(rt_notify_log)"
check_eq "契约E: release-gate 即便占用 PR 在途也发卡（终态 awaiting-approval）" "awaiting-approval" "$(rt_state "$EGATE_ID")"
check_eq "契约E: release-gate 卡推送记账 == 1" "1" \
  "$(rt_count_in "$(cat "$SB/calls-hermes.log" 2>/dev/null)" "=== hermes send")"
rt_case_end "Egate" "nodeliver"

echo "===== 场景 10：既有沙箱套件零回归（全量跑 run.sh）====="
RUN_OUT="$AUDIT/run-suite.out"
SUITE_RC=0
(
  cd "$MARTIN_ROOT" && env -u CONTRIB_DATA_DIR -u RQ_LOCKDIR -u NOTIFY_LOCK -u APPROVED_LOG \
    -u NOTIFY_SEND_LAST -u HERMES_BIN -u TUNNEL_BIN -u GH_BIN -u NOTIFY_DRY_RUN \
    -u RTQ_FIXTURES -u RTQ_GH_LOG -u RTQ_HERMES_LOG -u RTQ_TUNNEL_LOG -u STUB_STATE \
    MARTIN_DIR="$MARTIN_ROOT" bash "$RUN_SUITE"
) > "$RUN_OUT" 2>&1 || SUITE_RC=$?
SUMMARY_LINE="$(grep '^##SUMMARY' "$RUN_OUT" | tail -1)"
SUITE_FAILED="$(sed -n 's/.*"failed":\([0-9]*\).*/\1/p' <<<"$SUMMARY_LINE")"
check_eq "10.P1: 既有套件 run.sh exit == 0" "0" "$SUITE_RC"
check_eq "10.P1: 既有套件 ##SUMMARY failed == 0" "0" "$SUITE_FAILED"
RUN_TEXT="$(cat "$RUN_OUT")"
check_contains "10.P2: 套件输出含 review-evidence 用例" "review-evidence" "$RUN_TEXT"
check_contains "10.P2: 套件输出含 own-PR 用例" "own-PR" "$RUN_TEXT"
check_contains "10.P2: 套件输出含 stalled-occupier 用例" "stalled-occupier" "$RUN_TEXT"
# 裁决②：run.sh 全文无 release-gate 用例（蓝队套件覆盖缺口，已上报）——
# 「release-gate 跳过」行为语义已由上方 Egate 用例硬断言覆盖。
if grep -q "release-gate" "$RUN_OUT"; then
  ok "10.P2: 套件输出含 release-gate token（若蓝队后续补用例则本检查自然通过）"
  PASS=$((PASS - 1))   # 信息性检查不计入断言数
else
  printf '  INFO - 10.P2: run.sh 输出无 release-gate token（蓝队套件无该分流用例；行为覆盖见 Egate 用例；缺口已上报 QA）\n'
fi

echo "===== 场景 11：全 stub 沙箱零副作用（stub 调用账审计）====="
ALL_GH="$(cat "$AUDIT"/*.gh.log 2>/dev/null || true)"
ALL_HERMES="$(cat "$AUDIT"/*.hermes.log 2>/dev/null || true)"
ALL_TUNNEL="$(cat "$AUDIT"/*.tunnel.log 2>/dev/null || true)"
# 正证先行（防空转假绿）：记录非空且含只读子命令
check_contains "11.P1 正证: stub gh 调用记录非空且含只读 pr list" "=== gh pr list" "$ALL_GH"
check_contains "11.P1 正证: 含只读 pr view（停摆取证）" "=== gh pr view" "$ALL_GH"
check_contains "11.P1 正证: 含只读 issue view" "=== gh issue view" "$ALL_GH"
# 负证：全量记录禁写子命令
check_not_contains "11.P1 负证: 无 pr create" "pr create" "$ALL_GH"
check_not_contains "11.P1 负证: 无 pr edit" "pr edit" "$ALL_GH"
check_not_contains "11.P1 负证: 无 pr merge" "pr merge" "$ALL_GH"
check_not_contains "11.P1 负证: 无 issue comment" "issue comment" "$ALL_GH"
check_not_contains "11.P1 负证: 无 issue edit" "issue edit" "$ALL_GH"
# -X POST 分桶裁决（见头部裁决①）：拦截桶零 POST；放行桶仅投递端点且恰 1 次
_bad_post=""
for _c in $NODELIVER_CASES; do
  if [[ -f "$AUDIT/$_c.gh.log" ]] && grep -q -- "-X POST" "$AUDIT/$_c.gh.log"; then
    _bad_post+=" $_c"
  fi
done
check_eq "11.P1 负证: 期望拦截的运行零 -X POST（[$_bad_post ] 应为空）" "" "$_bad_post"
_post_ok=1
for _c in $DELIVER_CASES; do
  [[ -f "$AUDIT/$_c.gh.log" ]] || { _post_ok=0; continue; }
  _n="$(grep -c -- "-X POST" "$AUDIT/$_c.gh.log" || true)"
  [[ "$_n" == "1" ]] || { _post_ok=0; printf '      用例 %s POST 次数=%s\n' "$_c" "$_n"; }
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    [[ "$_line" == *"/comments"* ]] || { _post_ok=0; printf '      用例 %s POST 非投递端点: %s\n' "$_c" "$_line"; }
  done < <(grep -- "-X POST" "$AUDIT/$_c.gh.log" || true)
done
check_eq "11.P1 裁决: 放行运行的 -X POST 仅投递端点且各恰 1 次" "1" "$_post_ok"
# 11.P2：hermes/tunnel 外呼走替身并留本地记录
check_contains "11.P2: hermes stub 留本地调用记录（零真实微信）" "=== hermes send" "$ALL_HERMES"
check_contains "11.P2: tunnel stub 留本地调用记录（零真实部署）" "drops approve" "$ALL_TUNNEL"

echo "===== 生产零触碰自证（只读 diff）====="
_prod_bad=0
_i=0
for _f in "${PROD_TARGETS[@]}"; do
  if [[ -f "$PROD_SNAP/prod-$_i.snap" && -f "$_f" ]]; then
    if ! "$DIFF_BIN" -q "$PROD_SNAP/prod-$_i.snap" "$_f" >/dev/null 2>&1; then
      fail "生产零触碰: $_f 被改动" "内容 diff 不一致"
      _prod_bad=1
    fi
  fi
  _i=$((_i + 1))
done
if ((_prod_bad == 0)); then ok "生产零触碰: approved.log 与 contrib-data/** 全程零变更（pinned diff）"; fi

echo
echo "==== 汇总 ===="
printf 'PASS %d checks\n' "$PASS"
if (( FAIL > 0 )); then
  printf 'FAIL %d checks:%s\n' "$FAIL" "$FAILED_NOTES"
  exit 1
fi
exit 0
