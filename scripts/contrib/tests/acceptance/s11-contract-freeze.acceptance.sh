#!/usr/bin/env bash
# =============================================================================
# s11-contract-freeze.acceptance.sh — 场景 11：对外 API 契约冻结与黑洞/否定变体
# 覆盖谓词：11.P1 11.P2 11.P3 11.P4 11.P5（det-machine）
# 依据：state.md `## 验收场景` + `## 契约规约`（逐字）：
#   - rq.sh 子命令闭集 / notify.sh 子命令闭集（SKILL.md 消费）
#   - deep_check_gate exit 契约：0=无可跑项；10=有候选且 target 文件
#     "<rq-id> <lane>"（lane ∈ {deep,probe}）
#   - DRY_RUN 优先级：NOTIFY_DRY_RUN(env) > config.notify_dry_run > "true"；
#     DRY_RUN=true 时 _send 不得调用 HERMES_BIN/TUNNEL_BIN，stdout 含 [dry-run]
#   - 真发成功判据：rc==0 且 .success==true → pushed:true + 配额 bump
#   - notify-state.json schema；run-deepcheck.sh 黑洞契约（正常路径恒 0）
# 隔离：全部直接驱动走 seam（MARTIN_DIR/CONTRIB_DATA_DIR/各 *_BIN/各锁与 /tmp 写点
#   全部重定向进 mktemp 沙箱），生产 contrib-data 零触碰。
# CONTRACT_AMBIGUOUS:
#   ① notify.sh approve 无生产调用方文档（SKILL.md 仅用 receipt）——按
#      `approve <rq-id> --summary "<...>"` 驱动；若签名不符本测试红，属契约缺口信号。
#   ② notify.sh event 的 summary 形态按 receipt 的 `--summary` 旗标惯例推定。
#   ③ deep_check_gate 的候选资格判据未冻结——种子按生产 ready-queue 真实 queued
#      项形状建模（state=queued/lane=deep/score>=ready_min_score/premises 非空）。
#   ④ run-deepcheck.sh 按测绘结论以 zsh 解释器驱动（3 个 zsh 脚本之一）。
#   ⑤ 11.P1 契约守卫读取 hermes 侧 SKILL.md（$HOME/.hermes/...）——本文件声明该
#      环境依赖，缺失即 FAIL（不允许静默跳过）。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s11-p{1,2,3,4,5}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
SUITE="$REPO_ROOT/scripts/contrib/tests"
TARGET="$REPO_ROOT/scripts/contrib"
ART="/tmp/autopilot-artifacts"
SKILL_HERMES="$HOME/.hermes/skills/github/hermes-contrib-l2/SKILL.md"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
jlast(){ tail -n 1 "$1"; }
# j <json> [jq args...]：对 json 文本求 jq -e（真值才通过）
j(){ local _json="$1"; shift; printf '%s' "$_json" | jq -e "$@" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
for f in notify.sh rq.sh deep_check_gate.sh run-deepcheck.sh; do
  [ -f "$TARGET/$f" ] || die "env" "被测脚本缺失: $TARGET/$f"
done
[ -f "$SKILL_HERMES" ] || die "env" "hermes 侧 SKILL.md 缺失（11.P1 契约守卫的输入之一）: $SKILL_HERMES"

ZSH_BIN="$(command -v zsh 2>/dev/null || echo /bin/zsh)"
TODAY="$(date +%F)"

# ------------------------- 沙箱 + 影子 stub 工厂 -----------------------------
SB=""; STUBBIN=""; STUBLOG=""
gen_stub(){ # $1 = stub 名
  local n="$1"
  {
    echo '#!/bin/sh'
    printf 'STUB_NAME="%s"\n' "$n"
    printf 'L="%s"\n' "$STUBLOG/$n.log"
    cat <<'SH'
{ printf '===CALL===\n'; for a in "$@"; do printf '%s\n' "$a"; done; } >>"$L" 2>&1
if [ ! -t 0 ]; then printf -- '---STDIN---\n' >>"$L"; cat >>"$L" 2>/dev/null; printf -- '---END-STDIN---\n' >>"$L"; fi
case "$STUB_NAME" in
  hermes)
    if [ -n "${HERMES_STUB_FAIL:-}" ]; then printf '%s\n' '{"success":false,"error":"stub-fail"}'; exit 1; fi
    printf '%s\n' '{"success":true,"ok":true}' ;;
  claude)
    if [ -n "${CLAUDE_STUB_FAIL:-}" ]; then printf '%s\n' 'claude-stub: intentional failure' >&2; exit 1; fi
    printf '# Stub Draft\n\n▪ stub-draft-line\n' ;;
  gh)
    case "$*" in
      *issue*) printf '{"state":"OPEN"}' ;;
      *pulls*|*"pr list"*) printf '[]' ;;
      *) printf '{}' ;;
    esac ;;
  tunnel)
    printf '%s\n' 'https://d.stringzhao.life/stub-slug' ;;
  osascript)
    : ;;
  pgrep)
    exit 0 ;;
esac
exit 0
SH
  } > "$STUBBIN/$n"
  chmod +x "$STUBBIN/$n"
}
new_sb(){
  SB="$(mktemp -d "${TMPDIR:-/tmp}/acc-s11.XXXXXX")"
  mkdir -p "$SB/contrib-data/pending" "$SB/bin" "$SB/logs" "$SB/tmp"
  STUBBIN="$SB/bin"; STUBLOG="$SB/logs"
  local n
  for n in hermes gh claude tunnel osascript pgrep; do gen_stub "$n"; done
  # ---- seam 全量注入（默认值语义由实现保证等于现状；测试只提供沙箱值）----
  export MARTIN_DIR="$SB"
  export CONTRIB_DATA_DIR="$SB/contrib-data"
  export NOTIFY_LOCK="$SB/tmp/contrib-notify.lock"
  export NOTIFY_SEND_LAST="$SB/tmp/contrib-send-last.json"
  export RQ_LOCKDIR="$SB/tmp/contrib-rq.lock"
  export DEEPCHECK_TARGET_FILE="$SB/tmp/deepcheck-target"
  export DEEPCHECK_LOCK="$SB/tmp/contrib-deepcheck.lock"
  export WATCH_LOCK="$SB/tmp/contrib-watch.lock"
  export HERMES_BIN="$STUBBIN/hermes" GH_BIN="$STUBBIN/gh" TUNNEL_BIN="$STUBBIN/tunnel"
  export OSASCRIPT_BIN="$STUBBIN/osascript" GATEWAY_PROBE_BIN="$STUBBIN/pgrep"
  export CLAUDE_BIN="$STUBBIN/claude"
  export PATH="$STUBBIN:$PATH"
}
calls(){ # $1 = stub 名 → 调用次数
  if [ -f "$STUBLOG/$1.log" ]; then grep -c '===CALL' "$STUBLOG/$1.log" || true; else printf '0'; fi
}

# ------------------------------ 种子数据 -------------------------------------
seed_config(){ # $1 = notify_dry_run（bool 字面量）
  local dr="${1:-false}"
  cat > "$SB/contrib-data/config.json" <<EOF
{ "auto_deep_check": true, "deep_check_per_week": 30, "deep_check_per_day": 30,
  "ready_min_score": 11, "notify_dry_run": $dr, "notify_digest": true,
  "max_alert_pushes_per_day": 3, "max_approval_pushes_per_day": 3,
  "notify_min_interval_min": 0, "notify_target": "weixin:stub@im.wechat",
  "probe_per_day": 1, "refund_failed_deep_check": false, "allow_own_pr_push": false,
  "min_build_score": 12, "stale_pr_days": 10, "stale_pr_author_exclude": ["teknium1"] }
EOF
}
seed_state(){ printf '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}\n' > "$SB/contrib-data/notify-state.json"; }
seed_budget(){ printf '{"limits":{"week":30,"day":30},"days":{},"weeks":{},"probes":{}}\n' > "$SB/contrib-data/budget.json"; }
seed_event(){ # class key summary [channel] [attempts]
  local cls="$1" key="$2" sum="$3" ch="${4:-contrib}" att="${5:-0}"
  jq -cn --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg c "$cls" --arg k "$key" \
     --arg s "$sum" --arg ch "$ch" --argjson a "$att" \
     '{ts:$ts,class:$c,key:$k,channel:$ch,summary:$s,pushed:false,attempts:$a,pushed_at:null}' \
     >> "$SB/contrib-data/events.jsonl"
}
seed_queue_item(){ # id lane state
  local id="$1" lane="${2:-deep}" st="${3:-queued}"
  jq -n --arg id "$id" --arg lane "$lane" --arg st "$st" --arg day "$TODAY" '
    {version:1,updated:"stub",items:[{
      id:$id, issue:103271, pr:null, title:"stub title",
      disposition:"own-PR", lane:$lane, score:15, priority:106, source:"stub",
      state:$st,
      premises:[{claim:"stub claim",evidence:"stub file:line",verified_at:$day,status:"alive"}],
      ammo:["stub ammo"], draft:null,
      tunnel:{url:null,slug:null,deployed_at:null,removed_at:null},
      budget:{week:"stub-week",day:$day},
      queued_at:"stub", queued_epoch:0, awaiting_at:null, awaiting_epoch:null,
      history:[{ts:"stub",event:"queued",note:"stub"}]}]}' > "$SB/contrib-data/ready-queue.json"
}
seed_queue_empty(){ printf '{"version":1,"updated":"stub","items":[]}\n' > "$SB/contrib-data/ready-queue.json"; }

cleanup(){ [ -n "${SB:-}" ] && [ -d "$SB" ] && [ "${ACC_KEEP:-0}" != "1" ] && rm -rf "$SB"; return 0; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 11.P1 [det-machine] 契约漂移守卫（static 维度）
# assert: 守卫绿（默认 target 全套件 exit==0，缺失子命令数==0）
# 负向：临时删除一个 SKILL.md 引用的 case 分支（tunnel-removed，hermes 侧 SKILL.md §5
#       引用）的副本上，守卫必须非零。
# -----------------------------------------------------------------------------
P="11.P1"
grep -q 'tunnel-removed' "$SKILL_HERMES" || die "$P" "前置失效：hermes SKILL.md 未引用 tunnel-removed，负向变异无法锚定"
( cd "$REPO_ROOT" && bash scripts/contrib/tests/run.sh </dev/null ) >"$ART/s11-p1.out" 2>&1
RC_POS=$?
eq "$RC_POS" 0 "$P 交付态全套件 exit（契约守卫须绿，缺失子命令数==0）"

MUT="$(mktemp -d "${TMPDIR:-/tmp}/acc-s11-mut.XXXXXX")"
cp -R "$REPO_ROOT/scripts/contrib/." "$MUT/" || die "$P" "复制被测目录失败"
[ -f "$MUT/rq.sh" ] || die "$P" "副本缺 rq.sh"
grep -q 'tunnel-removed' "$MUT/rq.sh" || die "$P" "前置失效：rq.sh 副本无 tunnel-removed token（无法删除 case 分支）"
grep -v 'tunnel-removed' "$TARGET/rq.sh" > "$MUT/rq.sh" || die "$P" "case 分支删除失败"
if diff -q "$TARGET/rq.sh" "$MUT/rq.sh" >/dev/null 2>&1; then
  die "$P" "负向变异是空操作（mutated==pristine），守卫测试无意义"
fi
( cd "$REPO_ROOT" && CONTRIB_TEST_TARGET="$MUT" bash scripts/contrib/tests/run.sh </dev/null ) >>"$ART/s11-p1.out" 2>&1
RC_NEG=$?
rm -rf "$MUT"
ne "$RC_NEG" 0 "$P 负向：删除 SKILL.md 引用的 case 分支后守卫竟然 exit 0"
echo "PASS $P（正=0 / 负=$RC_NEG，tunnel-removed 分支删除可被守卫捕获）"

# -----------------------------------------------------------------------------
# 11.P2 [det-machine] deep_check_gate exit 契约 + target 文件格式
# assert: 有候选 → exit==10 且 target 匹配 ^rq-[0-9]{8}-[0-9]+ (deep|probe)$
#         无候选 → exit==0
# -----------------------------------------------------------------------------
P="11.P2"
new_sb; seed_config true; seed_budget; seed_state; seed_queue_item "rq-${TODAY//-}-000001" deep queued
bash "$TARGET/deep_check_gate.sh" </dev/null >"$ART/s11-p2.out" 2>&1
RC_G=$?
eq "$RC_G" 10 "$P 有候选时 deep_check_gate exit（期望 10）"
[ -s "$DEEPCHECK_TARGET_FILE" ] || die "$P" "有候选但 target 文件为空/不存在: $DEEPCHECK_TARGET_FILE"
TGT="$(cat "$DEEPCHECK_TARGET_FILE")"
printf '%s\n' "$TGT" | grep -Eq '^rq-[0-9]{8}-[0-9]+ (deep|probe)$' \
  || die "$P" "target 内容不匹配 ^rq-[0-9]{8}-[0-9]+ (deep|probe)\$ : [$TGT]"
echo "--- 有候选: exit=10 target=[$TGT]" >> "$ART/s11-p2.out"
SB1="$SB"   # 保留 A 沙箱路径供 artifact 记录

# 无候选分支（独立沙箱）
new_sb; seed_config true; seed_budget; seed_state; seed_queue_empty
bash "$TARGET/deep_check_gate.sh" </dev/null >>"$ART/s11-p2.out" 2>&1
RC_G0=$?
eq "$RC_G0" 0 "$P 无候选时 deep_check_gate exit（期望 0）"
echo "--- 无候选: exit=0" >> "$ART/s11-p2.out"
rm -rf "$SB1"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 11.P3 [det-machine] DRY_RUN 否定变体（优先级：NOTIFY_DRY_RUN env > config）
# config.notify_dry_run=false + NOTIFY_DRY_RUN=true → flush 与 approve 必须
# 对 HERMES_BIN/TUNNEL_BIN 影子零调用且 stdout 含 [dry-run]
# -----------------------------------------------------------------------------
P="11.P3"
new_sb; seed_config false; seed_state; seed_budget
seed_event probe-premise-dead "s11p3-mech" "机械事件（dry-run 否定变体）"
seed_queue_item "rq-${TODAY//-}-000002" deep awaiting-approval
printf 'stub draft body\n' > "$SB/contrib-data/pending/rq-${TODAY//-}-000002.md"

unset NOTIFY_DRY_RUN
export NOTIFY_DRY_RUN=true
bash "$TARGET/notify.sh" flush </dev/null >"$ART/.s11-p3.flush.out" 2>&1
RC_F=$?
H1="$(calls hermes)"; T1="$(calls tunnel)"
eq "$H1" 0 "$P flush 在 DRY_RUN 下 hermes 调用数"
eq "$T1" 0 "$P flush 在 DRY_RUN 下 tunnel 调用数"
grep -Fq '[dry-run]' "$ART/.s11-p3.flush.out" || die "$P" "flush stdout 不含 [dry-run]: $(cat "$ART/.s11-p3.flush.out")"

# approve（CONTRACT_AMBIGUOUS：签名按 approve <rq-id> --summary 推定）
bash "$TARGET/notify.sh" approve "rq-${TODAY//-}-000002" --summary "stub approval card" </dev/null >"$ART/.s11-p3.approve.out" 2>&1
RC_A=$?
H2="$(calls hermes)"; T2="$(calls tunnel)"
eq "$H2" 0 "$P approve 在 DRY_RUN 下 hermes 调用数"
eq "$T2" 0 "$P approve 在 DRY_RUN 下 tunnel 调用数"
grep -Fq '[dry-run]' "$ART/.s11-p3.approve.out" || die "$P" "approve stdout 不含 [dry-run]（rc=$RC_A）: $(cat "$ART/.s11-p3.approve.out")"
{
  echo "--- flush rc=$RC_F hermes=$H1 tunnel=$T1"
  cat "$ART/.s11-p3.flush.out"
  echo "--- approve rc=$RC_A hermes=$H2 tunnel=$T2"
  cat "$ART/.s11-p3.approve.out"
} > "$ART/s11-p3.out"
unset NOTIFY_DRY_RUN
rm -rf "$SB"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 11.P4 [det-machine] 真发完成后 notify-state.json schema
# 前置：hermes 影子 success:true（真发成功判据满足）→ flush
# assert: last_flush_epoch int>0、alerts.<today> int>=1、approvals/receipts 为
#         object、fallback_notice 为 object 或 null
# -----------------------------------------------------------------------------
P="11.P4"
new_sb; seed_config false; seed_state; seed_budget
seed_event probe-premise-dead "s11p4-mech" "机械事件（真发 happy path）"
bash "$TARGET/notify.sh" flush </dev/null >"$ART/s11-p4.out" 2>&1
RC_F=$?
eq "$RC_F" 0 "$P 真发 flush exit"
ge "$(calls hermes)" 1 "$P hermes 影子被调次数（真发必须发生，防 no-op 假绿）"
S="$SB/contrib-data/notify-state.json"
[ -s "$S" ] || die "$P" "notify-state.json 缺失: $S"
jq -e '.last_flush_epoch | type=="number" and . > 0' "$S" >/dev/null || die "$P" "last_flush_epoch 非 int>0: $(cat "$S")"
jq -e --arg d "$TODAY" '.alerts[$d] | type=="number" and . >= 1' "$S" >/dev/null || die "$P" "alerts.$TODAY 非 int>=1: $(cat "$S")"
jq -e '.approvals | type=="object"' "$S" >/dev/null || die "$P" "approvals 非 object: $(cat "$S")"
jq -e '.receipts | type=="object"' "$S" >/dev/null || die "$P" "receipts 非 object: $(cat "$S")"
jq -e '(.fallback_notice | type=="object") or (.fallback_notice | type=="null")' "$S" >/dev/null \
  || die "$P" "fallback_notice 非 object|null（惰性键契约）: $(cat "$S")"
cat "$S" >> "$ART/s11-p4.out"
rm -rf "$SB"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 11.P5 [det-machine] run-deepcheck.sh 黑洞契约
# assert: gate exit 0 输入 与 gate exit 10 + claude 影子成功 输入，两种情况均 exit==0
# -----------------------------------------------------------------------------
P="11.P5"
# 输入一：gate exit 0（空队列）
new_sb; seed_config true; seed_budget; seed_state; seed_queue_empty
"$ZSH_BIN" "$TARGET/run-deepcheck.sh" </dev/null >"$ART/s11-p5.out" 2>&1
RC_A5=$?
eq "$RC_A5" 0 "$P run-deepcheck 在 gate exit 0 输入下的 exit"
echo "--- 输入一(gate=0) exit=$RC_A5" >> "$ART/s11-p5.out"
rm -rf "$SB"

# 输入二：gate exit 10 + claude 影子成功
new_sb; seed_config true; seed_budget; seed_state; seed_queue_item "rq-${TODAY//-}-000003" deep queued
bash "$TARGET/deep_check_gate.sh" </dev/null >>"$ART/.s11-p5.gate.out" 2>&1
RC_GATE=$?
eq "$RC_GATE" 10 "$P 输入二前置：gate 应产候选 exit 10"
"$ZSH_BIN" "$TARGET/run-deepcheck.sh" </dev/null >>"$ART/s11-p5.out" 2>&1
RC_B5=$?
eq "$RC_B5" 0 "$P run-deepcheck 在 gate exit 10 + 深检成功输入下的 exit"
echo "--- 输入二(gate=10, claude stub 成功) exit=$RC_B5" >> "$ART/s11-p5.out"
echo "PASS $P"

echo "s11: ALL PASS（11.P1 11.P2 11.P3 11.P4 11.P5）"
exit 0
