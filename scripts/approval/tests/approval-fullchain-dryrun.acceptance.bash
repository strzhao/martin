#!/bin/bash
# 红队验收测试：T6 全链演练 dry-run（场景 8.P1 / 8.P2）+ 跨系统字段名连续性（工作规则 3）
# 仅依据 state.md「## 设计文档 T4/T5/T6」「## 验收场景 8」「## 验证方案（显式不做：真微信/真部署/gh 真写）」编写。
# 不读蓝队本次新写的实现代码；全链 = 发卡(dry) → 人读页 → decision(stub) → collect → execute(dry+drill)。
#
# target: scripts/approval/tests/approval-fullchain-dryrun.acceptance.bash
# 运行：bash scripts/approval/tests/approval-fullchain-dryrun.acceptance.bash
#
# 硬约束（场景 8.P1）：发送 stub 计数 == 0；正式账本（martin/approved.log 与 contrib-data/ready-queue.json）
# diff 为空且 mtime 不变（/usr/bin/diff 显式 pin，knowledge patterns.md:321）。
#
# 跨系统种子（与 tunnel-cli 侧 *.acceptance.test.ts 同一组字面量贯穿全链）：
#   slug=a3k7tq9m2z / code=K3MT9Q / verdict=approved / comment=红队种子意见：TTL 复验通过，占坑无新冲突
#   断言链：卡 URL key==K3MT9Q == rq 登记 code == decision stub --expect-code == C1 JSON matched/verdict
#   字段名（若实现把 C1 matched 改成别名 code_matched，collect 消费即断，本套件红）。

set -uo pipefail
# stdin 守卫（防 stub cat 继承交互 stdin 阻塞）
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
PROD_CONTRIB="$MARTIN_ROOT/contrib-data"
PROD_LEDGER="$MARTIN_ROOT/approved.log"

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
check_match() { if [[ "$3" =~ $2 ]]; then ok "$1"; else fail "$1" "no match /$2/: [$3]"; fi; }
ledger_lines() {
  if [[ ! -f "$1" ]]; then echo 0; return 0; fi
  grep -cv -e '^#' -e '^$' "$1" 2>/dev/null | tr -d ' '
}
settle_wait() {
  local deadline=$(( SECONDS + 25 )) s1="" s2=""
  while (( SECONDS < deadline )); do
    s1="$(stat -f '%m %z' "$SB" 2>/dev/null | cksum)"
    sleep 1
    s2="$(stat -f '%m %z' "$SB" 2>/dev/null | cksum)"
    if [[ "$s1" == "$s2" ]]; then
      sleep 1
      s2="$(stat -f '%m %z' "$SB" 2>/dev/null | cksum)"
      [[ "$s1" == "$s2" ]] && return 0
    fi
  done
  return 0
}

DIFF_BIN="/usr/bin/diff"
[[ -x "$DIFF_BIN" ]] || DIFF_BIN="$(command -v diff)"

# ── 正式账本快照（8.P1：演练零写入正式账本）──
PROD_LEDGER_BEFORE="$(mktemp "${TMPDIR:-/tmp}/prod-ledger-before.XXXXXX")"
PROD_QUEUE_BEFORE="$(mktemp "${TMPDIR:-/tmp}/prod-queue-before.XXXXXX")"
if [[ -f "$PROD_LEDGER" ]]; then cp "$PROD_LEDGER" "$PROD_LEDGER_BEFORE"; else : > "$PROD_LEDGER_BEFORE"; fi
if [[ -f "$PROD_CONTRIB/ready-queue.json" ]]; then cp "$PROD_CONTRIB/ready-queue.json" "$PROD_QUEUE_BEFORE"; else : > "$PROD_QUEUE_BEFORE"; fi
PROD_LEDGER_MTIME="$(stat -f '%m' "$PROD_LEDGER" 2>/dev/null || echo 0)"
PROD_QUEUE_MTIME="$(stat -f '%m' "$PROD_CONTRIB/ready-queue.json" 2>/dev/null || echo 0)"

# ── 演练沙箱（= 场景 8.P2 的「演练隔离目录」）──
SB="$(mktemp -d "${TMPDIR:-/tmp}/approval-drill.XXXXXX")"
CONTRIB="$SB/data"
STUBS="$SB/stubs"
DEC="$SB/decisions"
APPROVED_LOG="$SB/approved.log"
mkdir -p "$CONTRIB/pending" "$CONTRIB/logs" "$STUBS" "$DEC"
: > "$APPROVED_LOG"
cleanup() { rm -rf "$SB" "$PROD_LEDGER_BEFORE" "$PROD_QUEUE_BEFORE"; }
trap cleanup EXIT

cat > "$STUBS/tunnel" <<'STUB'
#!/bin/bash
LOG="${TUNNEL_CALL_LOG:?}"
{ printf '=== tunnel'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
if [[ "${1:-}" == "drops" && "${2:-}" == "decision" ]]; then
  f="${DECISION_DIR:?}/${3}.json"
  [[ -f "$f" ]] && { cat "$f"; exit 0; }
  exit 1
fi
exit 0
STUB
cat > "$STUBS/gh" <<'STUB'
#!/bin/bash
LOG="${GH_CALL_LOG:?}"
{ printf '=== gh'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
if [[ "${GH_FAIL:-0}" == "1" ]]; then exit 9; fi
case "$*" in
  *comments*) echo '[]' ;;
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
chmod +x "$STUBS/tunnel" "$STUBS/gh" "$STUBS/hermes" "$STUBS/osascript"

export MARTIN_DIR="$MARTIN_ROOT"
export CONTRIB_DATA_DIR="$CONTRIB"
export NOTIFY_LOCK="$SB/notify.lock"
export RQ_LOCKDIR="$SB/rq.lock"
export NOTIFY_SEND_LAST="$SB/send-last.json"
export HERMES_BIN="$STUBS/hermes"
export TUNNEL_BIN="$STUBS/tunnel"
export GH_BIN="$STUBS/gh"
export OSASCRIPT_BIN="$STUBS/osascript"
export APPROVED_LOG="$APPROVED_LOG"
export TUNNEL_CALL_LOG="$SB/tunnel-calls.log"
export GH_CALL_LOG="$SB/gh-calls.log"
export HERMES_CALL_LOG="$SB/hermes-calls.log"
export DECISION_DIR="$DEC"
export NOTIFY_DRY_RUN="true"
: > "$TUNNEL_CALL_LOG"
: > "$HERMES_CALL_LOG"
: > "$GH_CALL_LOG"

jq -n '{notify_dry_run: true, notify_target: "wechat:drill", approval_interactive: true,
  approval_ttl_hours: 48, max_approval_pushes_per_day: 10}' > "$CONTRIB/config.json"
bash "$RQ" init >/dev/null

# decision stub：C1 JSON（字段名 matched/verdict 逐字）；slug 键随发卡动态登记值落盘（值流同源）

printf '=== 阶段①：发卡（NOTIFY_DRY_RUN=true，只打印不发送）===\n'
ID="$(bash "$RQ" add --issue 103999 --disposition review-evidence --score 13 \
  --title "全链演练件（红队沙箱）" --lane deep \
  --premises-json '[{"claim":"演练 claim：仅遥测不落库","evidence":"演练 evidence：schema 直查无该列"}]')"
DRAFT="$CONTRIB/pending/$ID.md"
printf '<!-- PR-DRAFT id=%s generator=run-deepcheck -->\n## Verdict request\n\n演练稿正文（红队种子意见：TTL 复验通过，占坑无新冲突）。\n' "$ID" > "$DRAFT"
bash "$RQ" set-draft "$ID" "$DRAFT" >/dev/null
bash "$RQ" set "$ID" awaiting-approval >/dev/null
bash "$NOTIFY" approve "$ID" > "$SB/stage1-card.out" 2>"$SB/stage1-card.err"
RC1=$?
check_eq "阶段①: notify approve dry-run 退出码 0" "0" "$RC1"
check_contains "阶段①/8.P2: 审批卡文本已留存于演练目录" "?key=" "$(cat "$SB/stage1-card.out" 2>/dev/null)"
# 登记值（发卡侧 slug/code）→ 后续阶段同源贯穿
REG_SLUG="$(jq -r --arg id "$ID" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$CONTRIB/ready-queue.json")"
REG_CODE="$(jq -r --arg id "$ID" '.items[] | select(.id == $id) | .tunnel.code // ""' "$CONTRIB/ready-queue.json")"
CARD_URL_LINE="$(grep -F "?key=" "$SB/stage1-card.out" | head -1)"
check_contains "跨系统: 卡 URL 携带登记 code（?key=<code>）" "?key=${REG_CODE}" "${CARD_URL_LINE}"
check_contains "跨系统: 卡 URL slug == 登记 slug" "life/${REG_SLUG}" "${CARD_URL_LINE}"
check_match "跨系统: 登记 slug 匹配 C4 [a-z0-9]{10}" "^[a-z0-9]{10}$" "$REG_SLUG"
check_match "跨系统: 登记 code 匹配 C4 [a-km-np-z2-9]{6}" "^[a-km-np-z2-9]{6}$" "$REG_CODE"

printf '=== 阶段②：人读页生成（B1）===\n'
PAGE_FILE="$(find "$CONTRIB/pending" -maxdepth 1 -name '*page.md' -type f | head -1)"
if [[ -n "$PAGE_FILE" && -s "$PAGE_FILE" ]]; then
  ok "8.P2: 人读页演练件留存（${PAGE_FILE}）"
else
  fail "8.P2: 人读页演练件留存" "pending/*page.md 为空"
fi
check_contains "8.P2/跨系统: 人读页 decision stub 同源（提交名即短码）" "id: verdict" "$(cat "$PAGE_FILE" 2>/dev/null)"

printf '%s' "{\"slug\":\"${REG_SLUG}\",\"matched\":true,\"reason\":\"ok\",\"verdict\":\"approved\",\"comment\":\"红队种子意见：TTL 复验通过，占坑无新冲突\",\"submitted_at\":\"2026-09-06T08:00:00Z\",\"submissions_seen\":1}" > "$DEC/${REG_SLUG}.json"

printf '=== 阶段③：判定提取（decision stub，模拟名字=短码的提交）===\n'
STAGE3="$SB/stage3-decision.json"
bash "$STUBS/tunnel" drops decision "$REG_SLUG" --expect-code "$REG_CODE" > "$STAGE3" 2>/dev/null
RC3=$?
check_eq "阶段③: decision stub 退出码 0" "0" "$RC3"
check_eq "跨系统: decision JSON matched == true（C1 字段名）" "true" "$(jq -r '.matched' "$STAGE3" 2>/dev/null)"
check_eq "跨系统: decision JSON verdict == approved" "approved" "$(jq -r '.verdict' "$STAGE3" 2>/dev/null)"
check_contains "跨系统: decision 调用带登记值 --expect-code <登记code>（发卡→判定同源）" \
  "drops decision ${REG_SLUG} --expect-code ${REG_CODE}" "$(cat "$TUNNEL_CALL_LOG")"

printf '=== 阶段④：collect（APPROVAL_DRY_RUN=true 只打印）===\n'
env APPROVAL_DRY_RUN=true bash "$COLLECT" > "$SB/stage4-collect.out" 2>&1
RC4=$?
check_eq "阶段④: collect dry-run 退出码 0" "0" "$RC4"

printf '=== 阶段⑤：execute drill（-drill 件，跳过 gh 写与正式账本）===\n'
ID_DRILL="$(bash "$RQ" add --issue 103998 --disposition review-evidence --score 12 --title "drill 演练件" --lane deep --drill)"
DRAFT_D="$CONTRIB/pending/$ID_DRILL.md"
printf '<!-- PR-DRAFT id=%s -->\ndrill 演练稿正文。\n' "$ID_DRILL" > "$DRAFT_D"
bash "$RQ" set-draft "$ID_DRILL" "$DRAFT_D" >/dev/null
bash "$RQ" set "$ID_DRILL" awaiting-approval >/dev/null
bash "$RQ" set "$ID_DRILL" approved >/dev/null
bash "$EXECUTE" "$ID_DRILL" approved > "$SB/stage5-execute-drill.out" 2>&1
RC5=$?
printf '%s' "$RC5" > "$SB/stage5-execute-drill.rc"
check_eq "阶段⑤/C8: drill 不进台账（APPROVED_LOG 零新增）" "0" \
  "$(grep -cF "$ID_DRILL" "$APPROVED_LOG" 2>/dev/null | tr -d ' ')"
WRITE_HITS="$(grep -cE '=== gh .*(-X (POST|PATCH|PUT)| -f |-F |--field|--input|--method| (issue|pr) comment )' "$GH_CALL_LOG" 2>/dev/null | tr -d ' ')"
WRITE_HITS="${WRITE_HITS:-0}"
check_eq "阶段⑤/C8: drill 零 gh 写调用" "0" "$WRITE_HITS"

settle_wait

printf '=== 场景8.P1：零真实发送 + 正式账本零写入 ===\n'
HERMES_COUNT="$(grep -c '=== hermes' "$HERMES_CALL_LOG" 2>/dev/null | tr -d ' ')"; HERMES_COUNT="${HERMES_COUNT:-0}"
check_eq "8.P1: 发送 stub 计数 == 0（全程零真实微信）" "0" "$HERMES_COUNT"
if [[ -f "$PROD_LEDGER" ]]; then
  LEDGER_DIFF="$("$DIFF_BIN" "$PROD_LEDGER_BEFORE" "$PROD_LEDGER" 2>&1)"
else
  LEDGER_DIFF=""
fi
check_eq "8.P1: 正式账本 diff 为空（/usr/bin/diff pin）" "" "$LEDGER_DIFF"
LEDGER_MTIME_NOW="$(stat -f '%m' "$PROD_LEDGER" 2>/dev/null || echo 0)"
check_eq "8.P1: 正式账本 mtime 不变" "$PROD_LEDGER_MTIME" "$LEDGER_MTIME_NOW"
if [[ -f "$PROD_CONTRIB/ready-queue.json" ]]; then
  QUEUE_DIFF="$("$DIFF_BIN" "$PROD_QUEUE_BEFORE" "$PROD_CONTRIB/ready-queue.json" 2>&1)"
else
  QUEUE_DIFF=""
fi
check_eq "8.P1: 正式 ready-queue diff 为空（演练零触碰正式队列）" "" "$QUEUE_DIFF"
QUEUE_MTIME_NOW="$(stat -f '%m' "$PROD_CONTRIB/ready-queue.json" 2>/dev/null || echo 0)"
check_eq "8.P1: 正式 ready-queue mtime 不变" "$PROD_QUEUE_MTIME" "$QUEUE_MTIME_NOW"
# 演练件台账只进沙箱 APPROVED_LOG（seam），绝不落正式账本
if [[ -f "$PROD_LEDGER" ]] && grep -qF "$ID" "$PROD_LEDGER" 2>/dev/null; then
  fail "8.P1: 演练 rq-id 不得出现在正式账本" "$ID 命中正式账本"
else
  ok "8.P1: 演练 rq-id 不在正式账本"
fi

printf '=== 场景8.P2：演练隔离目录齐套留存各阶段演练件 ===\n'
# 阶段件：①审批卡文本 ②人读页 ③decision JSON ④collect 输出 ⑤execute drill 输出（+实现产出的 run/audit 记录）
ARTIFACTS=()
ARTIFACTS+=("$SB/stage1-card.out")
[[ -n "$PAGE_FILE" ]] && ARTIFACTS+=("$PAGE_FILE")
ARTIFACTS+=("$STAGE3")
ARTIFACTS+=("$SB/stage4-collect.out")
ARTIFACTS+=("$SB/stage5-execute-drill.out")
# CONTRACT_AMBIGUOUS：run 记录位置未冻结——logs/ 或 runs/ 下含 drill id 的审计文件也算演练件
while IFS= read -r rf; do ARTIFACTS+=("$rf"); done < <(grep -rlF "$ID_DRILL" "$CONTRIB/logs" "$CONTRIB/runs" 2>/dev/null)
N_OK=0
ART_DETAIL=""
for af in "${ARTIFACTS[@]}"; do
  if [[ -f "$af" && -s "$af" ]]; then
    N_OK=$((N_OK + 1))
    ART_DETAIL+=$'\n'"      ok: $af ($(wc -c < "$af" | tr -d ' ') bytes)"
  else
    ART_DETAIL+=$'\n'"      MISSING/EMPTY: $af"
  fi
done
if (( N_OK >= 4 )); then
  ok "8.P2: 各阶段演练件 exists && size > 0（${N_OK} 件）$ART_DETAIL"
else
  fail "8.P2: 各阶段演练件 exists && size > 0（需 >= 4）" "仅 ${N_OK} 件齐套$ART_DETAIL"
fi
if [[ "$SB" != "$PROD_CONTRIB" && "$SB" != "$MARTIN_ROOT" && "$SB" == "${TMPDIR:-/tmp}"* ]]; then
  ok "8.P2: 演练目录 != 正式目录（${SB}）"
else
  fail "8.P2: 演练目录 != 正式目录" "SB=$SB"
fi

printf '\n==== 汇总 ====\n'
printf 'PASS %d checks\n' "$PASS"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'FAIL %d checks:%s\n' "$FAIL" "$FAILED_NOTES"
  exit 1
fi
exit 0
