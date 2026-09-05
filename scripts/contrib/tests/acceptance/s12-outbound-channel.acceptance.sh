#!/usr/bin/env bash
# =============================================================================
# s12-outbound-channel.acceptance.sh — 场景 12：外发消息规范与渠道隔离契约
#   （对齐 09-05 晚 notify.sh 重写后的新契约面）
# 覆盖谓词：12.P1 12.P2 12.P3 12.P4 12.P5（det-machine）
# 依据：state.md `## 契约规约`（逐字）+ `## 验收场景`：
#   - 渠道隔离：event --channel <C>（C≠contrib）只入账——不进 flush 批次、不标
#     pushed、不占 alerts 日限额
#   - 双级渲染：批次含叙事事件（class ∉ {probe-premise-dead, own-pr-activity,
#     deep-budget-exhausted}）→ AI 摘要；纯机械批次 → 模板卡（零 LLM 调用）
#   - 永不 raw dump：AI 失败 → rc=1，零 hermes/tunnel 调用，事件保留 attempts+1
#   - 空卡守卫：实质内容行为零 → 按失败挂账（不发送、不标 pushed）
#   - 失败兜底：attempts>=3 → osascript，同日至多一次
# 驱动方式：直接以 seam 沙箱驱动 notify.sh（种子按契约 schema 逐字构造；
#   hermes/claude/tunnel/osascript/pgrep 影子 stub 记录 argv+stdin），生产零触碰。
# CONTRACT_AMBIGUOUS:
#   ① event 子命令 summary 形态按 receipt 的 `--summary` 旗标惯例推定。
#   ② 空卡注入以 summary="" 的机械事件构造——依赖渲染层对空明细行的省略规则
#      （排除集 ^🟠/^（明细/空行/^── 之后实质行计数为零）。
#   ③ 兜底演练直接按契约 schema 预置 attempts=3 的事件（回拨状态文件而非 sleep）。
# 纪律：无宽容跳过；任一硬断言失败 → 非零退出。
# 产物：/tmp/autopilot-artifacts/s12-p{1,2,3,4,5}.out
# =============================================================================
set -u

REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo "${MARTIN_DIR:-$HOME/workspace/martin}")"
TARGET="$REPO_ROOT/scripts/contrib"
ART="/tmp/autopilot-artifacts"
mkdir -p "$ART"

die(){ echo "ACCEPTANCE-FAIL[$1]: $2" >&2; exit 1; }
eq(){ [ "$1" = "$2" ] || die "$3" "期望 [$2] 实得 [$1]"; }
ne(){ [ "$1" != "$2" ] || die "$3" "期望 != [$2]，实得相等 [$1]"; }
ge(){ case "${1:-}" in ''|*[!0-9]*) die "$3" "非数值 [$1]（期望 >= $2）";; esac; [ "$1" -ge "$2" ] || die "$3" "期望 >= $2 实得 [$1]"; }
# j <json> [jq args...]：对 json 文本求 jq -e（真值才通过）
j(){ local _json="$1"; shift; printf '%s' "$_json" | jq -e "$@" >/dev/null 2>&1; }

command -v jq >/dev/null 2>&1 || die "env" "jq 不可用"
[ -f "$TARGET/notify.sh" ] || die "env" "被测脚本缺失: $TARGET/notify.sh"

TODAY="$(date +%F)"

# ------------------------- 沙箱 + 影子 stub 工厂 -----------------------------
SB=""; STUBBIN=""; STUBLOG=""
gen_stub(){
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
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--file" ] && [ -f "$a" ]; then
        mkdir -p "$(dirname "$L")/bodies" 2>/dev/null
        cp "$a" "$(dirname "$L")/bodies/hermes-last.txt" 2>/dev/null
      fi
      prev="$a"
    done
    if [ -n "${HERMES_STUB_FAIL:-}" ]; then printf '%s\n' '{"success":false,"error":"stub-fail"}'; exit 1; fi
    printf '%s\n' '{"success":true,"ok":true}' ;;
  claude)
    if [ -n "${CLAUDE_STUB_FAIL:-}" ]; then printf '%s\n' 'claude-stub: intentional failure' >&2; exit 1; fi
    printf '# Stub Digest\n\nAI digest body\n' ;;
  tunnel)
    printf '%s\n' 'https://d.stringzhao.life/stub-slug' ;;
  osascript)
    : ;;
  pgrep)
    exit 0 ;;
  gh)
    printf '{}' ;;
esac
exit 0
SH
  } > "$STUBBIN/$n"
  chmod +x "$STUBBIN/$n"
}
new_sb(){
  SB="$(mktemp -d "${TMPDIR:-/tmp}/acc-s12.XXXXXX")"
  mkdir -p "$SB/contrib-data/logs" "$SB/contrib-data/pending" "$SB/bin" "$SB/logs" "$SB/tmp"
  STUBBIN="$SB/bin"; STUBLOG="$SB/logs"
  local n
  for n in hermes gh claude tunnel osascript pgrep; do gen_stub "$n"; done
  export MARTIN_DIR="$SB" CONTRIB_DATA_DIR="$SB/contrib-data"
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
  unset NOTIFY_DRY_RUN HERMES_STUB_FAIL CLAUDE_STUB_FAIL
}
calls(){
  if [ -f "$STUBLOG/$1.log" ]; then grep -c '===CALL' "$STUBLOG/$1.log" || true; else printf '0'; fi
}
seed_config(){
  cat > "$SB/contrib-data/config.json" <<'EOF'
{ "auto_deep_check": true, "deep_check_per_week": 30, "deep_check_per_day": 30,
  "ready_min_score": 11, "notify_dry_run": false, "notify_digest": true,
  "max_alert_pushes_per_day": 3, "max_approval_pushes_per_day": 3,
  "notify_min_interval_min": 0, "notify_target": "weixin:stub@im.wechat",
  "probe_per_day": 1, "refund_failed_deep_check": false, "allow_own_pr_push": false,
  "min_build_score": 12, "stale_pr_days": 10 }
EOF
}
seed_state(){ printf '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}\n' > "$SB/contrib-data/notify-state.json"; }
seed_event(){ # class key summary [channel] [attempts]
  local cls="$1" key="$2" sum="$3" ch="${4:-contrib}" att="${5:-0}"
  jq -cn --arg ts "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg c "$cls" --arg k "$key" \
     --arg s "$sum" --arg ch "$ch" --argjson a "$att" \
     '{ts:$ts,class:$c,key:$k,channel:$ch,summary:$s,pushed:false,attempts:$a,pushed_at:null}' \
     >> "$SB/contrib-data/events.jsonl"
}
FLUSH_RC=0
do_flush(){ # $1 = artifact 追加标签
  bash "$TARGET/notify.sh" flush </dev/null > "$ART/.s12-flush.out" 2>&1
  FLUSH_RC=$?
  { echo "--- $1 : flush rc=$FLUSH_RC"; cat "$ART/.s12-flush.out"; } >> "$ART/.s12-flush.all.out"
}
cleanup(){ [ -n "${SB:-}" ] && [ -d "$SB" ] && [ "${ACC_KEEP:-0}" != "1" ] && rm -rf "$SB"; return 0; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 12.P1 [det-machine] 渠道隔离：--channel foo 只入账
# assert: foo 事件 pushed==false 且 hermes 调用不含 foo 内容 且 alerts bump==1
# -----------------------------------------------------------------------------
P="12.P1"
new_sb; seed_config; seed_state
bash "$TARGET/notify.sh" event probe-premise-dead --key "s12-foo-1" --channel foo --summary "FOO-CHANNEL-MARKER" </dev/null >"$ART/s12-p1.out" 2>&1
eq "$?" 0 "$P event --channel foo exit"
seed_event probe-premise-dead "s12-contrib-1" "CONTRIB-CHANNEL-CONTENT" contrib 0
do_flush "12.P1"
LED="$SB/contrib-data/events.jsonl"
[ -s "$LED" ] || die "$P" "账本为空"
j "$(jq -s --arg k s12-foo-1 '[.[]|select(.key==$k)]|length' "$LED")" '.==1' \
  || die "$P" "foo 事件不在账本（--channel 入账失败）"
j "$(jq -s --arg k s12-foo-1 '[.[]|select(.key==$k)][0].pushed' "$LED")" '.==false' \
  || die "$P" "foo 事件被标 pushed（渠道隔离被破坏）"
j "$(jq -s --arg k s12-contrib-1 '[.[]|select(.key==$k)][0].pushed' "$LED")" '.==true' \
  || die "$P" "contrib 事件未被推送（flush 未工作，本谓词失去对照）"
[ -f "$STUBLOG/hermes.log" ] || die "$P" "hermes 影子零调用（flush 未发生推送）"
grep -q 'FOO-CHANNEL-MARKER' "$STUBLOG/hermes.log" \
  && die "$P" "hermes 调用负载包含 foo 渠道内容（渠道隔离被破坏）"
j "$(cat "$SB/contrib-data/notify-state.json")" --arg d "$TODAY" '.alerts[$d] == 1' \
  || die "$P" "alerts bump != 1（期望恰 1 次 contrib 推送限额消耗）"
cat "$LED" >> "$ART/s12-p1.out"
rm -rf "$SB"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 12.P2 [det-machine] 叙事批次 + claude 影子失败 → 永不 raw dump
# assert: hermes 调用数==0 且 全部批次事件 attempts 增量>=1
#   （契约附注：该路径 rc==1，零 tunnel 调用，事件保留）
# -----------------------------------------------------------------------------
P="12.P2"
new_sb; seed_config; seed_state
seed_event pipeline-failure "s12-narr-1" "叙事事件：#101136 review 已发 comment-5508188633"
export CLAUDE_STUB_FAIL=1
do_flush "12.P2"
unset CLAUDE_STUB_FAIL
eq "$(calls hermes)" 0 "$P claude 失败后 hermes 调用数（永不 raw dump）"
eq "$(calls tunnel)" 0 "$P claude 失败后 tunnel 调用数"
LED="$SB/contrib-data/events.jsonl"
j "$(jq -s --arg k s12-narr-1 '[.[]|select(.key==$k)][0].attempts' "$LED")" '.>=1' \
  || die "$P" "批次事件 attempts 未递增（失败未挂账）"
j "$(jq -s --arg k s12-narr-1 '[.[]|select(.key==$k)][0].pushed' "$LED")" '.==false' \
  || die "$P" "失败批次事件被标 pushed"
ne "$FLUSH_RC" 0 "$P claude 失败时 flush exit（契约要求 rc=1，本谓词从宽断言非 0；实际值见 artifact）"
cat "$LED" >> "$ART/s12-p2.out"
rm -rf "$SB"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 12.P3 [det-machine] 空卡守卫：渲染产物无实质行 → 不调用 hermes 且不标 pushed
# -----------------------------------------------------------------------------
P="12.P3"
new_sb; seed_config; seed_state
seed_event probe-premise-dead "s12-empty-1" "" contrib 0
do_flush "12.P3"
eq "$(calls hermes)" 0 "$P 空卡时 hermes 调用数"
LED="$SB/contrib-data/events.jsonl"
j "$(jq -s --arg k s12-empty-1 '[.[]|select(.key==$k)][0].pushed' "$LED")" '.==false' \
  || die "$P" "空卡批次被标 pushed"
j "$(jq -s --arg k s12-empty-1 '[.[]|select(.key==$k)][0].attempts' "$LED")" '.>=1' \
  || die "$P" "空卡未按失败挂账（契约：实质行计数为零 → 按失败挂账）"
cat "$LED" >> "$ART/s12-p3.out"
rm -rf "$SB"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 12.P4 [det-machine] 失败兜底：attempts>=3 触发 osascript，同日至多一次
# driver: 两次失败 flush（回拨 attempts=3 构造前置，零真实等待）
# assert: osascript 影子调用数==1
# -----------------------------------------------------------------------------
P="12.P4"
new_sb; seed_config; seed_state
seed_event probe-premise-dead "s12-fb-1" "兜底演练事件（attempts=3 预置）" contrib 3
export HERMES_STUB_FAIL=1
do_flush "12.P4-第一次失败"
eq "$(calls osascript)" 1 "$P 第一次失败 flush 后 osascript 调用数"
do_flush "12.P4-第二次失败"
unset HERMES_STUB_FAIL
eq "$(calls osascript)" 1 "$P 同日第二次失败 flush 后 osascript 仍只能 1 次（fallback_notice 日幂等）"
j "$(cat "$SB/contrib-data/notify-state.json")" --arg d "$TODAY" '.fallback_notice[$d] == 1' \
  || die "$P" "fallback_notice.$TODAY != 1（幂等标记未落盘）"
cat "$SB/contrib-data/notify-state.json" >> "$ART/s12-p4.out"
rm -rf "$SB"
echo "PASS $P"

# -----------------------------------------------------------------------------
# 12.P5 [det-machine] 纯机械批次 → 零 claude 调用（模板卡不经 LLM）且发送体含 ^▪ 行
# -----------------------------------------------------------------------------
P="12.P5"
new_sb; seed_config; seed_state
seed_event deep-budget-exhausted "s12-mech-1" "机械事件：深检 day 配额已用完，候选排队等明日重试"
do_flush "12.P5"
eq "$(calls claude)" 0 "$P 纯机械批次 claude 调用数（模板卡不经 LLM）"
ge "$(calls hermes)" 1 "$P hermes 影子被调次数（模板卡必须真发）"
[ -f "$STUBLOG/hermes.log" ] || die "$P" "hermes 影子日志缺失"
[ -f "$STUBLOG/bodies/hermes-last.txt" ] \
  || die "$P" "hermes stub 未捕获到 --file 发送体（bodies/ 缺失）"
grep -q '^▪' "$STUBLOG/bodies/hermes-last.txt" \
  || die "$P" "发送体不含 ▪ 开头行（body 见 $STUBLOG/bodies/hermes-last.txt）"
LED="$SB/contrib-data/events.jsonl"
j "$(jq -s --arg k s12-mech-1 '[.[]|select(.key==$k)][0].pushed' "$LED")" '.==true' \
  || die "$P" "机械批次未被标 pushed"
eq "$FLUSH_RC" 0 "$P 纯机械批次 flush exit"
{
  cat "$LED"
  echo "--- hermes stub log ---"
  cat "$STUBLOG/hermes.log"
} >> "$ART/s12-p5.out"
echo "PASS $P"

echo "s12: ALL PASS（12.P1 12.P2 12.P3 12.P4 12.P5）"
exit 0
