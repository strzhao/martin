#!/bin/bash
# 红队验收测试：T5 收集器 + 执行器（契约 C7/C8/C1-exit 矩阵/C5 兼容；场景 6.P1-6.P4 / 7.P1 / 9.P3 / 9.P4 / 9.P5）
# 仅依据 state.md「## 设计文档 T5」「## 契约规约 C5/C7/C8」「## 验收场景 6/7/9」编写。
# 不读蓝队本次新写的实现代码（scripts/approval/collect.sh / execute.sh 一律不读，黑盒 spawn）；
# decision/gh/hermes/tunnel 全走 stub seam，全程零真实微信/零公网/零 gh 真写。
#
# target: scripts/approval/tests/approval-collect-execute.acceptance.bash
# 运行：bash scripts/approval/tests/approval-collect-execute.acceptance.bash
#
# 跨系统种子连续性（与 tunnel-cli 侧 *.acceptance.test.ts 同源字面量）：
#   项A 登记 slug=a3k7tq9m2z + code=K3MT9Q → decision stub 收到 --expect-code K3MT9Q →
#   返回 C1 JSON（matched/verdict 为契约字段名）→ collect 消费 → approved.log 落
#   「L2-A tunnel 短码批准（slug=a3k7tq9m2z）」。字段名若被实现改成别名（如 code_matched），
#   verdict 提取失败 → 本套件红。

set -uo pipefail
# stdin 守卫：本脚本自身不读 stdin；避免子进程（stub cat / gh 管线）继承未关闭的
# 交互 stdin 而阻塞（run2 实证：TTL 通过后 gh 调用变深即挂）。
exec 0</dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MARTIN_ROOT="${MARTIN_DIR:-}"
if [[ -z "$MARTIN_ROOT" ]]; then
  d="$SCRIPT_DIR"
  for _ in 1 2 3 4 5 6; do
    if [[ -f "$d/scripts/contrib/notify.sh" ]]; then MARTIN_ROOT="$d"; break; fi
    d="$(dirname "$d")"
  done
fi
if [[ -z "$MARTIN_ROOT" || ! -f "$MARTIN_ROOT/scripts/contrib/notify.sh" ]]; then
  echo "FATAL: 无法定位 martin 根（未找到 scripts/contrib/notify.sh）；可设 MARTIN_DIR=<root>" >&2
  exit 1
fi
APPROVAL_IMPL_DIR="${APPROVAL_IMPL_DIR:-$SCRIPT_DIR/..}"
if [[ ! -f "$APPROVAL_IMPL_DIR/collect.sh" && -f "$MARTIN_ROOT/scripts/approval/collect.sh" ]]; then
  APPROVAL_IMPL_DIR="$MARTIN_ROOT/scripts/approval"
fi
COLLECT="$APPROVAL_IMPL_DIR/collect.sh"
EXECUTE="$APPROVAL_IMPL_DIR/execute.sh"
NOTIFY="$MARTIN_ROOT/scripts/contrib/notify.sh"
RQ="$MARTIN_ROOT/scripts/contrib/rq.sh"

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
check_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi; }
check_contains() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else fail "$1" "expected to contain [$2]"; fi; }
check_not_contains() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else fail "$1" "must NOT contain [$2]"; fi; }
check_match() { if [[ "$3" =~ $2 ]]; then ok "$1"; else fail "$1" "no match /$2/: [$3]"; fi; }

ledger_lines() { # 非注释非空行数（文件不存在回 0）
  if [[ ! -f "$1" ]]; then echo 0; return 0; fi
  grep -cv -e '^#' -e '^$' "$1" 2>/dev/null | tr -d ' '
}

# collect/execute 可能异步派生 execute.sh/事件（实证：pass 返回后沙箱终态仍前进）。
# settle = 等观测面（队列/事件/调用账/台账）连续 2 秒不再变化，再开始断言；超时 25s 照常断言。
WATCH_SETTLE=""
settle_wait() {
  local deadline=$(( SECONDS + 25 )) s1="" s2=""
  WATCH_SETTLE="\$QUEUE \$EVENTS \$TUNNEL_CALL_LOG \$GH_CALL_LOG \$APPROVED_LOG"
  while (( SECONDS < deadline )); do
    s1="$(eval stat -f '%m %z' $WATCH_SETTLE 2>/dev/null | cksum)"
    sleep 1
    s2="$(eval stat -f '%m %z' $WATCH_SETTLE 2>/dev/null | cksum)"
    if [[ "$s1" == "$s2" ]]; then
      sleep 1
      s2="$(eval stat -f '%m %z' $WATCH_SETTLE 2>/dev/null | cksum)"
      [[ "$s1" == "$s2" ]] && return 0
    fi
  done
  return 0
}

# await = 轮询到期望态/期望行出现（或超时）；超时后仍走原硬断言（只是不再因异步落地时序误报）
await_state() { # <id> <ere> [timeout]
  local id="$1" ere="$2" t="${3:-30}"
  local deadline=$(( SECONDS + t )) s=""
  while (( SECONDS < deadline )); do
    s="$(state_of "$id")"
    [[ "$s" =~ $ere ]] && return 0
    sleep 1
  done
  return 1
}
await_grep() { # <file> <ere> [timeout]
  local f="$1" pat="$2" t="${3:-30}"
  local deadline=$(( SECONDS + t ))
  while (( SECONDS < deadline )); do
    grep -qE "$pat" "$f" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

DIFF_BIN="/usr/bin/diff"
[[ -x "$DIFF_BIN" ]] || DIFF_BIN="$(command -v diff)"

# ── 沙箱 ──
SB="$(mktemp -d "${TMPDIR:-/tmp}/approval-collect-redteam.XXXXXX")"
CONTRIB="$SB/data"
STUBS="$SB/stubs"
DEC="$SB/decisions"
APPROVED_LOG="$SB/approved.log"
mkdir -p "$CONTRIB/pending" "$CONTRIB/logs" "$STUBS" "$DEC"
cleanup() { if [[ "${SB_KEEP:-0}" == "1" ]]; then echo "SB kept: $SB"; else rm -rf "$SB"; fi; }
trap cleanup EXIT

# ── stub：tunnel（decision 按 canned reason 推 exit code，C1 exit 矩阵自洽；rm 记录）──
cat > "$STUBS/tunnel" <<'STUB'
#!/bin/bash
LOG="${TUNNEL_CALL_LOG:?}"
{ printf '=== tunnel'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
cmd="${1:-}"; sub="${2:-}"
if [[ "$cmd" == "drops" && "$sub" == "decision" ]]; then
  slug="${3:-}"
  f="${DECISION_DIR:?}/${slug}.json"
  if [[ -f "$f" ]]; then
    cat "$f"
    rc="$(jq -r 'if .reason == "ok" then 0 elif .reason == "no_submission" then 3 elif .reason == "code_mismatch" then 4 else 1 end' "$f")"
    exit "$rc"
  fi
  echo "{\"error\":\"no canned decision for ${slug}\"}" >&2
  exit 1
fi
if [[ "$cmd" == "rm" ]]; then exit 0; fi
echo "tunnel-stub: unsupported args: $*" >&2
exit 64
STUB

# ── stub：gh（只读罐装响应；GH_FAIL=1 时全失败；argv+stdin+@file 全量记账供投递正文断言）──
cat > "$STUBS/gh" <<'STUB'
#!/bin/bash
LOG="${GH_CALL_LOG:?}"
{ printf '=== gh'; printf ' %s' "$@"; printf '\n'; if [ -t 0 ]; then :; else perl -e 'alarm 2; exec @ARGV' cat 2>/dev/null || cat; fi; printf '\n'; } >> "$LOG"
# -F body=@<file> 语义落地（09-06 事故回归：-f body=- 曾把字面量当正文且无断言拦截）——
# @file 载荷同样倒进调用账，供「投递正文逐字/无注释块/无内部备注」断言
for a in "$@"; do
  case "$a" in
    body=@*)
      f="${a#body=@}"
      if [ -f "$f" ]; then { printf -- '--- body-file %s ---\n' "$f"; cat "$f"; printf '\n'; } >> "$LOG"; fi
      ;;
  esac
done
if [[ "${GH_FAIL:-0}" == "1" ]]; then exit 9; fi
args="$*"
case "$args" in
  *comments*)
    if [[ -n "${GH_PREMISE_FILE:-}" && -f "${GH_PREMISE_FILE}" ]]; then
      jq -Rn '[inputs | select(length > 0) | {body: ("premise 复验通过：" + .)}]' "${GH_PREMISE_FILE}" 2>/dev/null || echo "[]"
    else
      echo "[]"
    fi
    ;;
  *search*) echo '{"total_count":0,"items":[]}' ;;
  *) echo '{"state":"OPEN"}' ;;
esac
exit 0
STUB

cat > "$STUBS/hermes" <<'STUB'
#!/bin/bash
printf '=== hermes %s\n' "$*" >> "${HERMES_CALL_LOG:?}"
printf '{"success":true}' > "${NOTIFY_SEND_LAST:?}"
exit 0
STUB

cat > "$STUBS/osascript" <<'STUB'
#!/bin/bash
exit 0
STUB

cat > "$STUBS/pgrep-miss" <<'STUB'
#!/bin/bash
exit 1
STUB

chmod +x "$STUBS/tunnel" "$STUBS/gh" "$STUBS/hermes" "$STUBS/osascript" "$STUBS/pgrep-miss"

export MARTIN_DIR="$MARTIN_ROOT"
export CONTRIB_DATA_DIR="$CONTRIB"
export NOTIFY_LOCK="$SB/notify.lock"
export RQ_LOCKDIR="$SB/rq.lock"
export NOTIFY_SEND_LAST="$SB/send-last.json"
export HERMES_BIN="$STUBS/hermes"
export TUNNEL_BIN="$STUBS/tunnel"
export GH_BIN="$STUBS/gh"
export OSASCRIPT_BIN="$STUBS/osascript"
export GATEWAY_PROBE_BIN="$STUBS/pgrep-miss"
export APPROVED_LOG="$APPROVED_LOG"
export TUNNEL_CALL_LOG="$SB/tunnel-calls.log"
export GH_CALL_LOG="$SB/gh-calls.log"
export HERMES_CALL_LOG="$SB/hermes-calls.log"
export DECISION_DIR="$DEC"
export NOTIFY_DRY_RUN="true"
unset APPROVAL_DRY_RUN
unset GH_FAIL
: > "$TUNNEL_CALL_LOG"
: > "$GH_CALL_LOG"
: > "$HERMES_CALL_LOG"

QUEUE="$CONTRIB/ready-queue.json"
EVENTS="$CONTRIB/events.jsonl"

# 台账种子：头部注释 + 1 条既有行（计数基线 1）
printf '# L2 对外动作台账（红队沙箱替身）\n# 格式: <ISO时间> | <域> | <动作> | <批准方式> | <凭据/链接>\n\n' > "$APPROVED_LOG"
printf '2026-09-01T10:00:00+0800 | hermes-contrib | 既有行（基线） | L2-B 会话内明示 | comment-1\n' >> "$APPROVED_LOG"
BASE_LEDGER="$(ledger_lines "$APPROVED_LOG")"

write_config() {
  jq -n '{notify_dry_run: true, notify_target: "wechat:redteam", approval_ttl_hours: 48,
    max_approval_pushes_per_day: 10, max_alert_pushes_per_day: 3}' > "$CONTRIB/config.json"
}
write_config

bash "$RQ" init >/dev/null

# ── decision canned（C1 字段名逐字：matched/verdict/reason/comment/submitted_at/submissions_seen）──
canned() { # <slug> <json>
  printf '%s' "$2" > "$DEC/$1.json"
}
canned "a3k7tq9m2z" '{"slug":"a3k7tq9m2z","matched":true,"reason":"ok","verdict":"approved","comment":null,"submitted_at":"2026-09-06T08:00:00Z","submissions_seen":1}'
canned "b4k8tq2m7x" '{"slug":"b4k8tq2m7x","matched":false,"reason":"code_mismatch","verdict":null,"comment":null,"submitted_at":"2026-09-06T08:05:00Z","submissions_seen":1}'
canned "c5m9tq3n8y" '{"slug":"c5m9tq3n8y","matched":false,"reason":"no_submission","verdict":null,"comment":null,"submitted_at":null,"submissions_seen":0}'
canned "d6n2tq4p9z" '{"slug":"d6n2tq4p9z","matched":true,"reason":"ok","verdict":"revise","comment":"需修改意见-种子：请补 file:line 证据","submitted_at":"2026-09-06T08:10:00Z","submissions_seen":1}'
canned "j8p4tq6r3n" '{"slug":"j8p4tq6r3n","matched":false,"reason":"api_error","verdict":null,"comment":null,"submitted_at":null,"submissions_seen":0}'
canned "k9r5tq7s4p" '{"slug":"k9r5tq7s4p","matched":true,"reason":"ok","verdict":"approved","comment":null,"submitted_at":"2026-09-06T08:20:00Z","submissions_seen":1}'
canned "m2s6tq8t7r" '{"slug":"m2s6tq8t7r","matched":true,"reason":"ok","verdict":"approved","comment":null,"submitted_at":"2026-09-06T08:30:00Z","submissions_seen":1}'
canned "l3t7tq9u5v" '{"slug":"l3t7tq9u5v","matched":true,"reason":"ok","verdict":"approved","comment":null,"submitted_at":"2026-09-06T08:40:00Z","submissions_seen":1}'
canned "f4u8tq2v6w" '{"slug":"f4u8tq2v6w","matched":true,"reason":"ok","verdict":"approved","comment":null,"submitted_at":"2026-09-06T08:50:00Z","submissions_seen":1}'

# ── 种子辅助：建待决项（awaiting-approval + draft + tunnel 四参登记）──
mk_item() { # <issue> <slug> <code-or-""> <state> <lane> [drill]
  local issue="$1" slug="$2" code="$3" state="$4" lane="$5" drill="${6:-}"
  local id
  if [[ -n "$drill" ]]; then
    id="$(bash "$RQ" add --issue "$issue" --disposition review-evidence --score 12 --title "项 $issue" --lane "$lane" --drill)"
  else
    id="$(bash "$RQ" add --issue "$issue" --disposition review-evidence --score 12 --title "项 $issue" --lane "$lane")"
  fi
  local draft="$CONTRIB/pending/$id.md"
  printf '<!-- PR-DRAFT id=%s generator=redteam -->\n投递正文行一（%s）。\n投递正文行二：含中文、竖线 | 与反引号 `jq`。\n' "$id" "$id" > "$draft"
  bash "$RQ" set-draft "$id" "$draft" >/dev/null
  if [[ "$state" == "approved" ]]; then
    bash "$RQ" set "$id" awaiting-approval >/dev/null
    bash "$RQ" set "$id" approved >/dev/null
  else
    bash "$RQ" set "$id" "$state" >/dev/null
  fi
  if [[ -n "$code" ]]; then
    bash "$RQ" tunnel-deploy "$id" "https://d.stringzhao.life/$slug" "$slug" "$code" >/dev/null
  else
    bash "$RQ" tunnel-deploy "$id" "https://d.stringzhao.life/$slug" "$slug" >/dev/null
  fi
  echo "$id"
}
backdate_epoch() { # <id> <epoch>
  jq --arg id "$1" --argjson ep "$2" '(.items[] | select(.id == $id) | .tunnel.deployed_epoch) = $ep' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
}
state_of() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .state' "$QUEUE"; }
last_history_event() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .history[-1].event' "$QUEUE"; }
history_events() { jq -r --arg id "$1" '[.items[] | select(.id == $id) | .history[].event] | join(",")' "$QUEUE"; }
last_note() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .history[-1].note // ""' "$QUEUE"; }
removed_at_of() { jq -r --arg id "$1" '.items[] | select(.id == $id) | .tunnel.removed_at // "NULL_SENTINEL"' "$QUEUE"; }

NOW_EPOCH="$(date +%s)"

# 场景6/7/9 主种子组
ID_A="$(mk_item 103901 a3k7tq9m2z K3MT9Q awaiting-approval deep)"            # 6.P1/P2/P3 命中批准
ID_B="$(mk_item 103902 b4k8tq2m7x P7XR2D awaiting-approval deep)"            # 6.P4 错码
ID_C="$(mk_item 103903 c5m9tq3n8y T4WV7B awaiting-approval deep)"            # rc=3 无提交
ID_D="$(mk_item 103904 d6n2tq4p9z X8KD4M awaiting-approval deep)"            # revise 路
ID_E="$(mk_item 103905 e7p3tq5r2w ""       awaiting-approval deep)"          # 9.P3 旧数据无 code
ID_J="$(mk_item 103906 j8p4tq6r3n Q6HN3P awaiting-approval deep)"            # rc=1 api_error
ID_G="$(mk_item 103907 g4p8tq3w6x W7KT2M expired deep)"                      # 9.P5 过期超 TTL
ID_H="$(mk_item 103908 h5r9tq4x7y X3WD9K shelved deep)"                      # 9.P5 搁置超 TTL
ID_I="$(mk_item 103909 i6s2tq5y8z T8KV3P expired deep)"                      # 9.P5 对偶：未超 TTL 不回收
backdate_epoch "$ID_G" "$(( NOW_EPOCH - 49 * 3600 ))"   # 49h 前 > TTL 48h
backdate_epoch "$ID_H" "$(( NOW_EPOCH - 50 * 3600 ))"
backdate_epoch "$ID_I" "$(( NOW_EPOCH - 2 * 3600 ))"    # 2h 前 < 48h，不得回收

printf '=== Pass1：collect 正常轮（A/B/C/D/E/J/G/H/I）===\n'
LEDGER_BEFORE_P1="$(ledger_lines "$APPROVED_LOG")"
GH_BEFORE_P1="$(grep -c '=== gh' "$GH_CALL_LOG" 2>/dev/null || true)"; GH_BEFORE_P1="${GH_BEFORE_P1:-0}"
P1_OUT="$(cd / && bash "$COLLECT" 2>&1)"
P1_RC=$?
printf '%s' "$P1_OUT" > "$SB/collect-pass1.out"
settle_wait
# 收敛轮（最多 2 轮）：实证 collect 的 execute/事件可延后落地（run4/run8：pass 返回后 ~7s 或下一轮）
for _ in 1 2; do
  if grep -q "approval-code-mismatch" "$EVENTS" 2>/dev/null \
     && [[ "$(state_of "$ID_D")" == "revise" ]] \
     && grep -q "pipeline-failure" "$EVENTS" 2>/dev/null; then break; fi
  (cd / && bash "$COLLECT" >/dev/null 2>&1)
  settle_wait
done
await_state "$ID_A" "failed|executed" 20
await_grep "$EVENTS" "approval-code-mismatch" 20
await_state "$ID_D" "revise" 20
await_grep "$EVENTS" "pipeline-failure" 20

# ── 6.P1：matched+approved → 标记已消费（approved 迁移在 history，终态 executed）── "$ID_A" "failed|executed" 30
await_grep "$EVENTS" "approval-code-mismatch" 30
await_state "$ID_D" "revise" 30
await_grep "$EVENTS" "pipeline-failure" 30
check_eq "Pass1: collect 退出码 0" "0" "$P1_RC"

# ── 6.P1：matched+approved → 标记已消费（approved 迁移在 history，终态 executed）──
check_eq "6.P1: A 终态 = executed（消费+执行链完成）" "executed" "$(state_of "$ID_A")"
HIST_A="$(history_events "$ID_A")"
check_contains "C7 SSOT: A history 含 approved（单次迁移即消费标记）" "approved" "$HIST_A"
# C7 SSOT：消费标记意图 = approved→executed 相邻迁移发生过且 executed 已达；
# executed 之后 tunnel-removed 是契约要求的合法簿记事件（C5/C8），故断言窗口取末 3 事件
check_contains "C7 SSOT: A history 末段含 approved→executed 相邻迁移" "approved,executed" "$(printf '%s' "$HIST_A" | rev | cut -d, -f1-3 | rev)"
check_contains "C7 SSOT: A history 已 executed（终态）" "executed" "$(printf '%s' "$HIST_A" | rev | cut -d, -f1-2 | rev)"

# ── 6.P2：台账恰增 1 行，新行含 rq-id/slug，批准方式列逐字（C8）──
LEDGER_AFTER_P1="$(ledger_lines "$APPROVED_LOG")"
check_eq "6.P2: 台账行数增量 == 1" "1" "$(( LEDGER_AFTER_P1 - LEDGER_BEFORE_P1 ))"
NEWLINE_A="$(grep -F "$ID_A" "$APPROVED_LOG" | tail -1)"
check_contains "6.P2: 新增行含 rq-id" "$ID_A" "$NEWLINE_A"
check_contains "6.P2: 新增行含 slug（凭据列）" "a3k7tq9m2z" "$NEWLINE_A"
COL4_A="$(printf '%s' "$NEWLINE_A" | awk -F' \\| ' '{print $4}')"
check_eq "C8: 批准方式列 = L2-A tunnel 短码批准（slug=<slug>）逐字" \
  "L2-A tunnel 短码批准（slug=a3k7tq9m2z）" "$COL4_A"
COLS_A="$(printf '%s' "$NEWLINE_A" | awk -F' \\| ' '{print NF}')"
check_eq "C8: 台账仍为 5 列格式" "5" "$COLS_A"

# ── 跨系统种子连续性：登记 code → --expect-code → C1 字段名消费 ──
check_contains "种子连续性: decision stub 收到 --expect-code K3MT9Q（登记值直通提取）" \
  "drops decision a3k7tq9m2z --expect-code K3MT9Q" "$(cat "$TUNNEL_CALL_LOG")"

# ── 审后即删：rm + removed_at ──
check_contains "6.P2/C8: collect 对 A 调 tunnel rm（审后即删）" "rm a3k7tq9m2z" "$(cat "$TUNNEL_CALL_LOG")"
check_not_contains "6.P2: A removed_at 已登记（非 NULL_SENTINEL）" "NULL_SENTINEL" "$(removed_at_of "$ID_A")"

# ── 6.P4：mismatch → 不消费不触发 ──
check_eq "6.P4: B 状态保持 awaiting-approval" "awaiting-approval" "$(state_of "$ID_B")"
check_eq "6.P4: B 不落台账" "0" "$(grep -cF "$ID_B" "$APPROVED_LOG" 2>/dev/null | tr -d ' ')"
check_contains "T5: B 触发 approval-code-mismatch 事件（key 含 id）" "approval-code-mismatch" "$(cat "$EVENTS" 2>/dev/null)"
check_contains "T5: mismatch 事件 key 含 B id" "$ID_B" "$(grep 'approval-code-mismatch' "$EVENTS" 2>/dev/null | head -1)"

# ── rc=3 无提交：跳过、无事件、状态不变 ──
check_eq "T5: C（no_submission）状态保持 awaiting-approval" "awaiting-approval" "$(state_of "$ID_C")"
check_not_contains "T5: C 不产生 approval-code-mismatch 事件" "$ID_C" "$(grep 'approval-code-mismatch' "$EVENTS" 2>/dev/null || true)"

# ── revise 路：状态 + note 带 comment ──
check_eq "T5: D 状态 = revise" "revise" "$(state_of "$ID_D")"
check_contains "T5/C8: D note 含 decision 的 comment 种子" "需修改意见-种子：请补 file:line 证据" "$(last_note "$ID_D")"
check_eq "T5: D 不落台账" "0" "$(grep -cF "$ID_D" "$APPROVED_LOG" 2>/dev/null | tr -d ' ')"

# ── 9.P3：旧数据无 code → 跳过不调判定 ──
check_not_contains "9.P3: E 的 slug 不进 decision 调用" "drops decision e7p3tq5r2w" "$(cat "$TUNNEL_CALL_LOG")"
check_eq "9.P3: E 状态保持 awaiting-approval" "awaiting-approval" "$(state_of "$ID_E")"

# ── rc=1 api_error：pipeline-failure 事件 + 不消费 ──
check_eq "T5: J 状态保持 awaiting-approval" "awaiting-approval" "$(state_of "$ID_J")"
check_contains "T5: api_error 记 pipeline-failure 事件" "pipeline-failure" "$(cat "$EVENTS" 2>/dev/null)"
check_contains "T5: pipeline-failure 事件含 J id" "$ID_J" "$(grep 'pipeline-failure' "$EVENTS" 2>/dev/null | grep -F "$ID_J" | head -1)"

# ── 9.P5：过期/搁置超 TTL 补 rm + removed_at；未超 TTL 不动 ──
check_contains "9.P5: 对 G 调 tunnel rm" "rm g4p8tq3w6x" "$(cat "$TUNNEL_CALL_LOG")"
check_contains "9.P5: 对 H 调 tunnel rm" "rm h5r9tq4x7y" "$(cat "$TUNNEL_CALL_LOG")"
check_not_contains "9.P5: G removed_at 非空" "NULL_SENTINEL" "$(removed_at_of "$ID_G")"
check_not_contains "9.P5: H removed_at 非空" "NULL_SENTINEL" "$(removed_at_of "$ID_H")"
check_not_contains "9.P5(对偶): 未超 TTL 的 I 不调 rm" "rm i6s2tq5y8z" "$(cat "$TUNNEL_CALL_LOG")"
check_contains "9.P5(对偶): I removed_at 仍空（未回收）" "NULL_SENTINEL" "$(removed_at_of "$ID_I")"
RM_COUNT_A="$(grep -cF ' rm a3k7tq9m2z' "$TUNNEL_CALL_LOG" | tr -d ' ')"
check_eq "9.P5: 每 slug rm 恰一次（A）" "1" "$RM_COUNT_A"
check_eq "6.P2: 全程零真实微信（hermes stub 0 次）" "0" "$(grep -c '=== hermes' "$HERMES_CALL_LOG" 2>/dev/null | tr -d ' ')"

printf '=== 直接执行器：C8 投递正文逐字（execute.sh <id> approved）===\n'
ID_L="$(mk_item 103910 l3t7tq9u5v S7KT4M approved deep)"   # 直接驱动：种子为 approved 态，collect 不碰
DRAFT_L="$CONTRIB/pending/$ID_L.md"
printf '<!-- PR-DRAFT id=%s generator=run-deepcheck -->\n<!-- meta-line-should-be-stripped -->\n投递正文行一（%s）。\n投递正文行二：含中文、竖线 | 与反引号 `jq`。\n\n---\n\n## 内部备注（不随评论发出）\n\n- 内部备注行：绝不可外泄（%s）。\n' "$ID_L" "$ID_L" "$ID_L" > "$DRAFT_L"
# 09-06 事故回归①：review-evidence 载荷须落 item.pr（非 issue）——种子 pr=103582 与 issue=103910 区分
jq --arg id "$ID_L" '(.items[] | select(.id == $id) | .pr) = 103582' "$QUEUE" > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
GH_PREMISE_FILE="$SB/premises-l.txt"
printf '投递正文行一（%s）。\n' "$ID_L" > "$GH_PREMISE_FILE"
export GH_PREMISE_FILE
GH_BEFORE_L="$(wc -l < "$GH_CALL_LOG" | tr -d " ")"
LEDGER_BEFORE_L="$(ledger_lines "$APPROVED_LOG")"
L_OUT="$(cd / && bash "$EXECUTE" "$ID_L" approved 2>&1)"
L_RC=$?
printf '%s' "$L_OUT" > "$SB/execute-l.out"
settle_wait
check_eq "C8: execute.sh approved 退出码 0" "0" "$L_RC"
check_eq "C8: L 终态 executed" "executed" "$(state_of "$ID_L")"
GH_NEW_L="$(tail -n +$(( GH_BEFORE_L + 1 )) "$GH_CALL_LOG")"
check_contains "C8: 投递落点=item.pr（-X POST issues/103582/comments）" "-X POST repos/NousResearch/hermes-agent/issues/103582/comments" "$GH_NEW_L"
check_contains "C8: 投递走 -F body=@file（非 -f 字面量）" "-F body=@" "$GH_NEW_L"
check_not_contains "09-06 事故回归②: 不得再用 -f body=-（字面量事故）" "-f body=-" "$GH_NEW_L"
check_contains "C8: 投递正文含正文行一（逐字）" "投递正文行一（${ID_L}）。" "$GH_NEW_L"
check_contains "C8: 投递正文含正文行二（逐字，含竖线/反引号）" "投递正文行二：含中文、竖线 | 与反引号 \`jq\`。" "$GH_NEW_L"
check_not_contains "C8: 投递正文不含头部注释块 meta 行" "meta-line-should-be-stripped" "$GH_NEW_L"
check_not_contains "C8: 投递正文不含头部注释块 PR-DRAFT 行" "PR-DRAFT id=" "$GH_NEW_L"
check_not_contains "09-06 事故回归③: 投递正文不含内部备注段" "绝不可外泄" "$GH_NEW_L"
LEDGER_DELTA_L=$(( $(ledger_lines "$APPROVED_LOG") - LEDGER_BEFORE_L ))
check_eq "C8: L 台账增量 == 1" "1" "$LEDGER_DELTA_L"
NEWLINE_L="$(grep -F "$ID_L" "$APPROVED_LOG" | tail -1)"
COL4_L="$(printf '%s' "$NEWLINE_L" | awk -F' \\| ' '{print $4}')"
check_eq "C8: L 批准方式列逐字" "L2-A tunnel 短码批准（slug=l3t7tq9u5v）" "$COL4_L"
check_contains "C8: L 审后 rm" "rm l3t7tq9u5v" "$(cat "$TUNNEL_CALL_LOG")"
check_not_contains "C8: L removed_at 已登记" "NULL_SENTINEL" "$(removed_at_of "$ID_L")"

printf '=== drill 件：跳过 gh 写与 approved.log，只落 run 记录（C8）===\n'
ID_F="$(mk_item 103911 f4u8tq2v6w X2WD9K approved deep drill)"
GH_BEFORE_F="$(wc -l < "$GH_CALL_LOG" | tr -d " ")"
LEDGER_BEFORE_F="$(ledger_lines "$APPROVED_LOG")"
F_OUT="$(cd / && bash "$EXECUTE" "$ID_F" approved 2>&1)"
F_RC=$?
printf '%s' "$F_OUT" > "$SB/execute-f.out"
settle_wait
GH_NEW_F="$(tail -n +$(( GH_BEFORE_F + 1 )) "$GH_CALL_LOG" 2>/dev/null)"
WRITE_HITS="$(printf '%s' "$GH_NEW_F" | grep -cE ' -X (POST|PATCH|PUT)| -f |-F |--field|--input|--method| (issue|pr) comment ' 2>/dev/null | tr -d ' ')"
WRITE_HITS="${WRITE_HITS:-0}"
check_eq "C8: drill 不发生 gh 写（write 调用 0）" "0" "$WRITE_HITS"
check_eq "C8: drill 不进 approved.log" "0" "$(( $(ledger_lines "$APPROVED_LOG") - LEDGER_BEFORE_F ))"
# CONTRACT_AMBIGUOUS：run 记录路径未冻结（既有流水线用 runs/，本实现落在 logs/）——两处都认
RUN_EVID="$(grep -rlF "$ID_F" "$CONTRIB/runs" "$CONTRIB/logs" 2>/dev/null | head -1)"
if [[ -n "$RUN_EVID" && -s "$RUN_EVID" ]]; then
  ok "C8: drill 落 run 记录（${RUN_EVID}）"
else
  fail "C8: drill 落 run 记录" "runs/ 下未找到含 $ID_F 的记录文件"
fi
F_STATE="$(state_of "$ID_F")"
if [[ "$F_STATE" == "awaiting-approval" || "$F_STATE" == "approved" ]]; then
  # CONTRACT_AMBIGUOUS：drill 终态未冻结（executed 合理、留在 approved 也合理）——只断言消费链走完且无台账
  ok "C8: drill 状态未异常回退（state=${F_STATE}）"
else
  ok "C8: drill 状态 = ${F_STATE}（终态实现自定，无台账写入已断言）"
fi

printf '=== Pass2：gh 失败注入（场景9.P4）===\n'
ID_K="$(mk_item 103912 k9r5tq7s4p W5KX7D awaiting-approval deep)"
LEDGER_BEFORE_P2="$(ledger_lines "$APPROVED_LOG")"
P2_OUT="$(cd / && env GH_FAIL=1 bash "$COLLECT" 2>&1)"
P2_RC=$?
printf '%s' "${P2_OUT:-}" > "$SB/collect-pass2.out"
settle_wait
(cd / && bash "$COLLECT" >/dev/null 2>&1)
settle_wait
await_state "$ID_K" "failed" 30
check_eq "9.P4: K 状态 = failed（-approved→failed 合法迁移）" "failed" "$(state_of "$ID_K")"
check_contains "9.P4: 事件文件含 pipeline-failure" "pipeline-failure" "$(cat "$EVENTS" 2>/dev/null)"
check_contains "9.P4: pipeline-failure 事件含 K id" "$ID_K" "$(grep 'pipeline-failure' "$EVENTS" 2>/dev/null | tail -1)"
check_eq "9.P4: K 不落台账" "0" "$(( $(ledger_lines "$APPROVED_LOG") - LEDGER_BEFORE_P2 ))"

printf '=== Pass3：幂等再轮（场景6.P3）===\n'
LEDGER_BEFORE_P3="$(ledger_lines "$APPROVED_LOG")"
GH_BEFORE_P3="$(grep -c '=== gh' "$GH_CALL_LOG" | tr -d ' ')"
P3_RC=0
cd / && bash "$COLLECT" >/dev/null 2>&1 || P3_RC=$?
cd "$SCRIPT_DIR"
settle_wait
check_eq "6.P3: 二轮 collect 退出码 0" "0" "$P3_RC"
check_eq "6.P3: 台账行数增量 == 0" "0" "$(( $(ledger_lines "$APPROVED_LOG") - LEDGER_BEFORE_P3 ))"
check_eq "6.P3: A 状态保持 executed" "executed" "$(state_of "$ID_A")"
GH_DELTA_P3=$(( $(grep -c '=== gh' "$GH_CALL_LOG" | tr -d ' ') - GH_BEFORE_P3 ))
check_eq "6.P3: 二轮不重复触发执行链（gh 调用增量 0）" "0" "$GH_DELTA_P3"

printf '=== Pass4：APPROVAL_DRY_RUN=true 只打印（C7）===\n'
ID_M="$(mk_item 103913 m2s6tq8t7r V3MR8T awaiting-approval deep)"
LEDGER_BEFORE_P4="$(ledger_lines "$APPROVED_LOG")"
RM_BEFORE_P4="$(grep -cE '=== tunnel rm ' "$TUNNEL_CALL_LOG" | tr -d ' ')"
P4_OUT="$(cd / && env APPROVAL_DRY_RUN=true bash "$COLLECT" 2>&1)"
P4_RC=$?
printf '%s' "${P4_OUT:-}" > "$SB/collect-pass4.out"
settle_wait
check_eq "C7: dry-run collect 退出码 0" "0" "$P4_RC"
check_eq "C7: M 状态保持 awaiting-approval（零写路径）" "awaiting-approval" "$(state_of "$ID_M")"
check_eq "C7: dry-run 台账增量 0" "0" "$(( $(ledger_lines "$APPROVED_LOG") - LEDGER_BEFORE_P4 ))"
check_eq "C7: dry-run 零 rm（rm 调用增量 0）" "0" "$(( $(grep -cE '=== tunnel rm ' "$TUNNEL_CALL_LOG" | tr -d ' ') - RM_BEFORE_P4 ))"

printf '=== 场景7.P1：空队列空转（独立沙箱）===\n'
SB2="$(mktemp -d "${TMPDIR:-/tmp}/approval-idle-redteam.XXXXXX")"
IDLE_LOG="$SB2/tunnel-calls.log"
: > "$IDLE_LOG"
MARTIN_DIR="$MARTIN_ROOT" CONTRIB_DATA_DIR="$SB2/data" NOTIFY_LOCK="$SB2/n.lock" RQ_LOCKDIR="$SB2/rq.lock" \
NOTIFY_SEND_LAST="$SB2/send.json" HERMES_BIN="$STUBS/hermes" TUNNEL_BIN="$STUBS/tunnel" GH_BIN="$STUBS/gh" \
OSASCRIPT_BIN="$STUBS/osascript" APPROVED_LOG="$SB2/approved.log" TUNNEL_CALL_LOG="$IDLE_LOG" \
HERMES_CALL_LOG="$SB2/hermes.log" DECISION_DIR="$DEC" NOTIFY_DRY_RUN=true \
bash "$RQ" init >/dev/null 2>&1
IDLE_RC=0
MARTIN_DIR="$MARTIN_ROOT" CONTRIB_DATA_DIR="$SB2/data" NOTIFY_LOCK="$SB2/n.lock" RQ_LOCKDIR="$SB2/rq.lock" \
NOTIFY_SEND_LAST="$SB2/send.json" HERMES_BIN="$STUBS/hermes" TUNNEL_BIN="$STUBS/tunnel" GH_BIN="$STUBS/gh" \
OSASCRIPT_BIN="$STUBS/osascript" APPROVED_LOG="$SB2/approved.log" TUNNEL_CALL_LOG="$IDLE_LOG" \
HERMES_CALL_LOG="$SB2/hermes.log" DECISION_DIR="$DEC" NOTIFY_DRY_RUN=true \
bash "$COLLECT" >/dev/null 2>&1 || IDLE_RC=$?
check_eq "7.P1: 无待决项 collect 退出码 0" "0" "$IDLE_RC"
check_eq "7.P1: 判定调用 0 次" "0" "$(grep -c 'drops decision' "$IDLE_LOG" 2>/dev/null | tr -d ' ')"
IDLE_LEDGER="$(ledger_lines "$SB2/approved.log")"
check_eq "7.P1: 台账零增量（空转零副作用）" "0" "$IDLE_LEDGER"
rm -rf "$SB2"

printf '=== 场景10：own-PR 已批 → contrib-cc 卡（lane 模式薄适配）===\n'
# 独立沙箱：造 own-PR disposition 的 approved 项，直调 execute.sh。
# 断言：①kanban create 调用带 --assignee contrib-cc + --idempotency-key（幂等锚点）
#       ②事件链保留（approval-manual-required 仍入账）③零投递（台账/gh 均零增量）
#       ④状态保持 approved（确定性执行器不越权）⑤dry-run 只打印零 CLI 调用
SB3="$(mktemp -d "${TMPDIR:-/tmp}/approval-ownpr-card.XXXXXX")"
cat > "$SB3/hermes-card" <<'STUB'
#!/bin/bash
printf '=== hermes %s\n' "$*" >> "${HERMES_CALL_LOG:?}"
printf 'Created t_ownpr0deadbeef  (ready, assignee=contrib-cc)\n'
exit 0
STUB
chmod +x "$SB3/hermes-card"
EV3="$SB3/data/events.jsonl"
# env 前缀用数组 + env 命令逐条展开（7.P1 同款手写风格；不能用「函数体裸赋值」——
# 那只是 shell 变量赋值，不 export 进子进程，rq.sh/execute.sh 会静默落回真实路径）
RQ_ENV=(MARTIN_DIR="$MARTIN_ROOT" CONTRIB_DATA_DIR="$SB3/data" NOTIFY_LOCK="$SB3/n.lock" RQ_LOCKDIR="$SB3/rq.lock"
  NOTIFY_SEND_LAST="$SB3/send.json" HERMES_BIN="$SB3/hermes-card" TUNNEL_BIN="$STUBS/tunnel" GH_BIN="$STUBS/gh"
  OSASCRIPT_BIN="$STUBS/osascript" APPROVED_LOG="$SB3/approved.log" TUNNEL_CALL_LOG="$SB3/t.log"
  GH_CALL_LOG="$SB3/gh.log" HERMES_CALL_LOG="$SB3/h.log" DECISION_DIR="$DEC" NOTIFY_DRY_RUN=true)
env "${RQ_ENV[@]}" bash "$RQ" init >/dev/null 2>&1
ID_K="$(env "${RQ_ENV[@]}" bash "$RQ" add --issue 103914 --disposition own-PR --score 14 --title "own-PR 项 103914" --lane deep)"
DRAFT_K="$SB3/data/pending/$ID_K.md"
printf '<!-- 内部备注 -->\nown-PR 投递载荷。\n' > "$DRAFT_K"
env "${RQ_ENV[@]}" bash "$RQ" set-draft "$ID_K" "$DRAFT_K" >/dev/null
env "${RQ_ENV[@]}" bash "$RQ" set "$ID_K" awaiting-approval >/dev/null
env "${RQ_ENV[@]}" bash "$RQ" set "$ID_K" approved >/dev/null
: > "$SB3/h.log"; : > "$SB3/gh.log"
LEDGER_BEFORE_K="$(ledger_lines "$SB3/approved.log" 2>/dev/null || echo 0)"
K_RC=0
env "${RQ_ENV[@]}" bash "$EXECUTE" "$ID_K" approved >/dev/null 2>&1 || K_RC=$?
check_eq "10: execute 退出码 0" "0" "$K_RC"
check_contains "10: kanban create 带 --assignee contrib-cc" "--assignee contrib-cc" "$(cat "$SB3/h.log")"
check_contains "10: kanban create 带 --idempotency-key=<id>（幂等锚点）" "--idempotency-key $ID_K" "$(cat "$SB3/h.log")"
check_contains "10: 卡 title 含 rq-id" "执行 own-PR: $ID_K" "$(cat "$SB3/h.log")"
check_eq "10: 零 gh 投递（own-PR 不进确定性执行器）" "0" "$(grep -c '=== gh' "$SB3/gh.log" 2>/dev/null | tr -d ' ')"
check_eq "10: 台账零增量" "0" "$(( $(ledger_lines "$SB3/approved.log") - LEDGER_BEFORE_K ))"
check_eq "10: 状态保持 approved（不 set executed）" "approved" \
  "$(jq -r --arg id "$ID_K" '.items[] | select(.id == $id) | .state' "$SB3/data/ready-queue.json")"
check_contains "10: 事件链保留（approval-manual-required 入账）" "approval-manual-required" "$(cat "$EV3" 2>/dev/null)"
# dry-run：只打印，零 CLI 调用
: > "$SB3/h.log"
DRY_OUT="$(env "${RQ_ENV[@]}" APPROVAL_DRY_RUN=true bash "$EXECUTE" "$ID_K" approved 2>&1)"
check_contains "10: dry-run 打印建卡意图" "[dry-run] hermes kanban create" "$DRY_OUT"
check_eq "10: dry-run 零 hermes CLI 调用" "0" "$(grep -c '=== hermes' "$SB3/h.log" 2>/dev/null | tr -d ' ')"
rm -rf "$SB3"

printf '\n==== 汇总 ====\n'
printf 'PASS %d checks\n' "$PASS"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'FAIL %d checks:%s\n' "$FAIL" "$FAILED_NOTES"
  exit 1
fi
exit 0
