#!/bin/bash
# e2e-smoke.sh — e2e 冒烟独立入口：mktemp 沙箱 + 影子 stub 全链路（闸门→队列→推送→账本）
#
# 末行 JSON：{"transport_calls":N,"ledger_appends":N,"queue_transitions":N,
#            "prefix_preserved":bool,"all_lines_valid_json":bool,"stub_log":"<path>"[,"sandbox":"<path>"]}
# 旋钮：
#   E2E_STUB_FAIL=<cmd>  令指定 stub（hermes/claude/tunnel/osascript/gh）非零退出 → 冒烟必须非零退出
#                        且账本零新增成功记录（场景3.P2 / 场景7.P3）
#   E2E_KEEP=1           保留沙箱并在 JSON 报 sandbox 路径（场景3.P3 防伪对照 / 7.P3 账本计数）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$HERE"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

FAIL_REASON=""
smoke_fail() { FAIL_REASON="${1:-unknown}"; }

sb_new >/dev/null 2>&1 || { echo '{"error":"sandbox-fail"}'; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
QUEUE_FILE="$SB_ROOT/contrib-data/ready-queue.json"
TODAY="$(date +%F)"

# ---- 前置：既有已推行（字节级前缀锚点，python3 重序列化格式——与 flush 的账本重写格式一致）----
PREFIX_LINE="$(python3 -c 'import json; print(json.dumps({"ts": "2026-01-01T00:00:00+08:00", "class": "probe-premise-dead", "key": "smoke-prefix", "channel": "contrib", "summary": "既有已推行（前缀锚点）", "pushed": True, "attempts": 0, "pushed_at": None}, ensure_ascii=False))')"
printf '%s\n' "$PREFIX_LINE" >>"$EVENTS_FILE"

# ---- 链路：队列种子 → run-deepcheck（T4 卡化：建 preflight 卡主路）→ worker 收尾模拟 →
#      事件+flush（告警链）----
sb_seed_queue_item "rq-$(date +%Y%m%d)-7001" 7001 probe queued 40
sb_notify event own-pr-activity --key smoke-alert --summary "radar：自有 PR 收到维护者评论" >/dev/null 2>&1
DC_ID="rq-$(date +%Y%m%d)-7001"

STUB_FAIL_KNOB=""
if [[ -n "${E2E_STUB_FAIL:-}" ]]; then
  case "$E2E_STUB_FAIL" in
    hermes|claude|tunnel|osascript|gh) STUB_FAIL_KNOB="STUB_$(printf '%s' "$E2E_STUB_FAIL" | tr '[:lower:]' '[:upper:]')_FAIL=1" ;;
    *) smoke_fail "E2E_STUB_FAIL 非法值: $E2E_STUB_FAIL" ;;
  esac
fi

# 传输链（deepcheck 卡 / fallback 审批卡 + flush 告警），STUB_FAIL 注入到整条链。
# worker 收尾模拟：卡化后状态推进由 contrib worker 在卡内做（rq set deep-check），stub 世界
# 用 sb_rq 显式推进一格，代表 worker 已接单（queue_transitions 计数的数据基础）。
if [[ -z "$FAIL_REASON" ]]; then
  sb_run -e "NOTIFY_DRY_RUN=false" ${STUB_FAIL_KNOB:+"-e"} ${STUB_FAIL_KNOB:+"$STUB_FAIL_KNOB"} \
    "zsh \"\$MARTIN_DIR/scripts/contrib/run-deepcheck.sh\"
bash \"\$MARTIN_DIR/scripts/contrib/rq.sh\" set $DC_ID deep-check --note 'worker 收尾模拟' >/dev/null 2>&1 || true
bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" flush" >/dev/null 2>&1
fi

# ---- 计数器 ----
transport_calls="$(awk -F'|' 'NF >= 1 && $1 != "" { c++ } END { printf "%d", c + 0 }' "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
ledger_lines="$(grep -c . "$EVENTS_FILE" 2>/dev/null || true)"
ledger_appends=$(( ledger_lines - 1 ))   # 减去前缀锚点行
queue_transitions="$(jq -r '[.items[].history | length] | add // 0' "$QUEUE_FILE" 2>/dev/null || echo 0)"
SMOKE_STUB_LOG="$SB_ROOT/stublog/calls.log"   # 主链 stub 日志（卡化段换沙箱后仍指主链）

# prefix_preserved：既有行字节级不变（未被 flush 重写破坏/丢失）
if grep -qF -- "$PREFIX_LINE" "$EVENTS_FILE"; then
  prefix_preserved=true
else
  prefix_preserved=false
  [[ -z "$FAIL_REASON" ]] && smoke_fail "前缀行被破坏（账本重写伤及未批次行）"
fi

# all_lines_valid_json：events 每行 + 队列 + 状态文件全部可解析
all_lines_valid_json=true
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  printf '%s' "$line" | jq -e . >/dev/null 2>&1 || all_lines_valid_json=false
done <"$EVENTS_FILE"
jq -e . "$QUEUE_FILE" >/dev/null 2>&1 || all_lines_valid_json=false
jq -e . "$STATE_FILE" >/dev/null 2>&1 || all_lines_valid_json=false

# ---- 成功/失败账本判据（场景3.P2：stub 失败 → 冒烟非零退出且零新增成功记录）----
ok_count="$(jq -r --arg d "$TODAY" '[.approvals[$d].ok | to_entries[] | select(.value == true)] | length' "$STATE_FILE" 2>/dev/null || echo 0)"
pushed_count="$(jq -s '[.[] | select(.pushed == true)] | length - 1' "$EVENTS_FILE" 2>/dev/null || echo 0)"  # 减前缀行
fail_count="$(jq -r --arg d "$TODAY" '([.approvals[$d].fail | to_entries[] | select(.value >= 1)] | length)
  + ([inputs | select(.pushed == false and .attempts >= 1)] | length)' "$STATE_FILE" "$EVENTS_FILE" 2>/dev/null || echo 0)"

if [[ -z "$FAIL_REASON" ]]; then
  if [[ "${E2E_STUB_FAIL:-}" == "claude" ]]; then
    # T4 卡化语义：claude 降格为兜底层——注毒 claude 时主路（hermes 卡）交付仍达成，
    # 且深检主路零 claude（降格的自证）
    [[ "$transport_calls" -ge 1 ]] || smoke_fail "claude 注毒轮 transport_calls=$transport_calls < 1"
    [[ "$queue_transitions" -ge 1 ]] || smoke_fail "claude 注毒轮 queue_transitions=$queue_transitions < 1"
    [[ "$ok_count" -ge 1 || "$pushed_count" -ge 1 ]] || smoke_fail "claude 注毒轮零成功记录"
    claude_calls="$(awk -F'|' '$1 == "claude" { c++ } END { printf "%d", c + 0 }' "$SMOKE_STUB_LOG/calls.log" 2>/dev/null)"
    [[ "$claude_calls" -eq 0 ]] || smoke_fail "claude 注毒但建卡主路调了 claude $claude_calls 次（降格破约）"
  elif [[ -n "${E2E_STUB_FAIL:-}" ]]; then
    # 注毒轮：交付未达成 → 冒烟判失败（场景3.P2：exit!=0）
    smoke_fail "传输 stub $E2E_STUB_FAIL 非零退出 → 交付未达成"
    # 附加账实核验：零新增成功记录 + 至少一条失败记录（场景7.P3 账本按类型计数的数据基础）
    if [[ "$ok_count" != "0" || "$pushed_count" != "0" ]]; then
      smoke_fail "stub $E2E_STUB_FAIL 失败但账本出现成功记录（账面≠送达）"
    fi
    if [[ "$fail_count" -lt 1 ]]; then
      smoke_fail "stub $E2E_STUB_FAIL 失败但账本无失败记录"
    fi
  else
    # 正常轮：≥1 传输、≥1 账本追加、≥1 队列迁移、≥1 成功记录
    [[ "$transport_calls" -ge 1 ]] || smoke_fail "transport_calls=$transport_calls < 1"
    [[ "$ledger_appends" -ge 1 ]] || smoke_fail "ledger_appends=$ledger_appends < 1"
    [[ "$queue_transitions" -ge 1 ]] || smoke_fail "queue_transitions=$queue_transitions < 1"
    [[ "$ok_count" -ge 1 || "$pushed_count" -ge 1 ]] || smoke_fail "零成功记录（审批卡/告警均未送达）"
  fi
fi

# ---- T1 scan 卡化全链段（独立沙箱，不受 E2E_STUB_FAIL 影响；恒跑）----
# A: gate 命中 → 建卡 stub → flight 登记（主路零 claude / 零 hermes send 订阅语义）
# B: flight done → 清登记 → 本轮新命中另建新卡
# C: 注毒（hermes 全败）→ claude fallback 被调 + pipeline-failure 入账（账本零假成功）
card_fail=""
card_watch_seed() { # <cursor> — 预置游标与两个新 issue
  printf '{"last_issue":%s}\n' "$1" >"$SB_ROOT/contrib-data/scan-cursor.json"
  printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
  jq -cn --argjson a $(( $1 + 1 )) --argjson b $(( $1 + 2 )) '[
    {number:$a,title:"a",labels:[],pull_request:null,user:{login:"x"},created_at:"2026-09-09T00:00:00Z",comments:0},
    {number:$b,title:"b",labels:[],pull_request:null,user:{login:"x"},created_at:"2026-09-09T00:00:00Z",comments:0}]' \
    >"$SB_ROOT/gh-issues.json"
}
card_run_watch() {
  sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" ${1:+"-e"} ${1:+"$1"} \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}
if sb_new >/dev/null 2>&1; then
  card_watch_seed 2000
  card_run_watch
  CARD_FLIGHT="$SB_ROOT/contrib-data/kanban-flight-scan.json"
  c1="$(jq -r '.card_id // empty' "$CARD_FLIGHT" 2>/dev/null || true)"
  [[ "$(jq -r '.kind // empty' "$CARD_FLIGHT" 2>/dev/null)" == "scan" ]] || card_fail="A:flight 未登记"
  [[ -n "$c1" ]] || card_fail="A:$card_fail 建卡无 id"
  [[ "$(awk -F'|' '$1 == "claude"' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || card_fail="A:主路调了 claude"
  [[ "$(awk -F'|' '$1 == "hermes" && $0 ~ / send/' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || card_fail="A:卡路出现 hermes send（零订阅语义破）"
  # B 轮：flight done → 清 + 新卡
  card_watch_seed 2002
  card_run_watch "STUB_KANBAN_CARD_STATUS=done"
  c2="$(jq -r '.card_id // empty' "$CARD_FLIGHT" 2>/dev/null || true)"
  [[ -n "$c2" && "$c2" != "$c1" ]] || card_fail="B:$card_fail done 后未建新卡"
  [[ "$(awk -F'|' '$1 == "claude"' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || card_fail="B:done 路调了 claude"
  sb_cleanup >/dev/null 2>&1
else
  card_fail="卡化段 sandbox 失败"
fi
if sb_new >/dev/null 2>&1; then
  card_watch_seed 2000
  card_run_watch "STUB_HERMES_FAIL=1"
  [[ "$(awk -F'|' '$1 == "claude" && $0 ~ /contrib-watch scan/' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]] \
    || card_fail="C:注毒后 claude fallback 未被调"
  [[ "$(grep -c 'pipeline-failure' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true)" -ge 1 ]] \
    || card_fail="C:注毒后账本无 pipeline-failure"
  [[ "$(jq -r '[.approvals[]?.ok | to_entries[] | select(.value == true)] | length' \
      "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo 0)" == "0" ]] \
    || card_fail="C:注毒后账本出现假成功"
  sb_cleanup >/dev/null 2>&1
else
  card_fail="${card_fail} 卡化注毒段 sandbox 失败"
fi
# D: QC 开（未来 epoch）→ 建卡照常发起（QC 不挡建卡，T2 语义收窄）+ 注毒 fallback 被断路器
#    挡下（claude 零调用）+ -scan-fallback-skipped 幂等事件入账
if sb_new >/dev/null 2>&1; then
  card_watch_seed 2000
  printf '%s\n' "$(( $(date +%s) + 3600 ))" >"$SB_ROOT/contrib-data/.quota-circuit"
  card_run_watch "STUB_HERMES_FAIL=1"
  [[ "$(awk -F'|' '$1 == "hermes" && $0 ~ /kanban create/' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" -ge 1 ]] \
    || card_fail="D:QC 开闸建卡未照常发起"
  [[ "$(awk -F'|' '$1 == "claude" && $0 ~ /contrib-watch scan/' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || card_fail="D:QC 开闸 fallback 仍调了 claude"
  [[ "$(grep -c 'scan-fallback-skipped' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || true)" -ge 1 ]] \
    || card_fail="D:QC 挡兜底缺 -scan-fallback-skipped 事件"
  sb_cleanup >/dev/null 2>&1
else
  card_fail="${card_fail} QC 段 sandbox 失败"
fi
[[ -z "$card_fail" ]] || smoke_fail "scan 卡化链: $card_fail"

# ---- T3 mail/radar 卡化全链段（独立沙箱）----
# E: mail exit10 → 建卡（五键登记含 pending_max_id 快照，cursor 不动）→ 卡 done+快照一致 →
#    commit-cursor（cursor 推进+登记清）；radar 08 窗口 → 建卡登记 + 零旗标
if sb_new >/dev/null 2>&1; then
  printf '[]\n' >"$SB_ROOT/gh-issues.json"
  printf '{"last_issue":9000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  mkdir -p "$SB_ROOT/mailstub"
  printf '{"last_id":8000,"initialized":"t"}\n' >"$SB_ROOT/contrib-data/mail-cursor.json"
  jq -cn '{id:"8001",flags:[],subject:"Re: [NousResearch/hermes-agent] e2e",from:{name:"T",addr:"notifications@github.com"},to:{name:"x",addr:"hermes-agent@noreply.github.com"},date:"d",has_attachment:false}' \
    >"$SB_ROOT/mailstub/row.json"
  jq -s . "$SB_ROOT/mailstub/row.json" >"$SB_ROOT/mailstub/envelopes.json"
  printf 'From: a <n@github.com>\n\nbody\n\nMessage ID: <m8001@github.com>\n' >"$SB_ROOT/mailstub/read-8001.txt"
  sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" \
    -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    -e "RADAR_HOUR=08" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
  MAILF="$SB_ROOT/contrib-data/kanban-flight-mail.json"
  [[ "$(jq -r '.kind // empty' "$MAILF" 2>/dev/null)" == "mail" ]] || card_fail="E:mail flight 未登记"
  [[ "$(jq -r '.pending_max_id // 0' "$MAILF" 2>/dev/null)" == "8001" ]] || card_fail="E:$card_fail pending_max_id 快照缺"
  [[ "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" == "8000" ]] || card_fail="E:$card_fail cursor 提前推进"
  [[ "$(jq -r '.kind // empty' "$SB_ROOT/contrib-data/kanban-flight-radar.json" 2>/dev/null)" == "radar" ]] || card_fail="E:$card_fail radar flight 未登记"
  [[ ! -f "$SB_ROOT/contrib-data/pending-radar.flag" ]] || card_fail="E:$card_fail 建卡成功不应置旗标"
  [[ "$(awk -F'|' '$1 == "claude" && $0 ~ /contrib-watch (mail|radar)/' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || card_fail="E:$card_fail 主路调了 claude"
  # 第二轮：两卡 done → mail 快照守卫通过 commit-cursor；radar 非 08 done 只清不重建
  printf '[]\n' >"$SB_ROOT/mailstub/envelopes.json"
  sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/gh-issues.json" \
    -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    -e "RADAR_HOUR=14" -e "STUB_KANBAN_CARD_STATUS=done" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
  [[ "$(jq -r '.last_id' "$SB_ROOT/contrib-data/mail-cursor.json" 2>/dev/null)" == "8001" ]] || card_fail="E:$card_fail 卡 done 后 cursor 未异步推进"
  [[ ! -f "$MAILF" ]] || card_fail="E:$card_fail done 后 mail 登记未清"
  [[ "$(jq 'length' "$SB_ROOT/contrib-data/mail-pending.json" 2>/dev/null || echo '?')" == "0" ]] || card_fail="E:$card_fail pending 未随 commit 清空"
  sb_cleanup >/dev/null 2>&1
else
  card_fail="${card_fail} mail/radar 段 sandbox 失败"
fi
[[ -z "$card_fail" ]] || smoke_fail "mail/radar 卡化链: $card_fail"

# ---- T4 深检依赖卡链段（独立沙箱）----
# F: gate rc10 → 建 preflight 卡 + flight-deepcheck 六键（零 claude 主路）
# G: worker 收尾模拟（deep-check + verdict auto + awaiting-approval + 卡 done）→ 再跑 run-deepcheck
#    → harvest 链完成判定 → auto-gate rc0 → rq approved（L2-auto 桥接保留）→ 登记清；
#    execute 链在沙箱内 gh TTL 失败转 failed → gate 下轮 retry 重启新卡（失败重试闭环自证）
if sb_new >/dev/null 2>&1; then
  dc_fail=""
  DC2_ID="rq-$(date +%Y%m%d)-7101"
  sb_seed_queue_item "$DC2_ID" 7101 deep queued 40
  sb_run 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
  DC_FLIGHT="$SB_ROOT/contrib-data/kanban-flight-deepcheck.json"
  [[ "$(jq -r '.kind // empty' "$DC_FLIGHT" 2>/dev/null)" == "deepcheck" ]] || dc_fail="F:flight 未登记"
  [[ "$(jq -r '.rq_id // empty' "$DC_FLIGHT" 2>/dev/null)" == "$DC2_ID" ]] || dc_fail="$dc_fail F:rq_id 缺"
  [[ "$(jq -r '.lane // empty' "$DC_FLIGHT" 2>/dev/null)" == "deep" ]] || dc_fail="$dc_fail F:lane 缺"
  [[ "$(jq -r '.batch_file' "$DC_FLIGHT" 2>/dev/null)" == "" ]] || dc_fail="$dc_fail F:batch_file 非空串"
  [[ "$(awk -F'|' '$1 == "claude"' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || dc_fail="$dc_fail F:主路调了 claude"
  DC_CARD_1="$(jq -r '.card_id // empty' "$DC_FLIGHT" 2>/dev/null)"
  # G: worker 模拟收尾（卡内职责）→ preflight 卡 done
  # （09-10 drift 修：并行 goods-gate 升级（2e36e2c）后 auto-gate 硬条件 5 要求 verdict 必带
  #   goods.status——沙箱种子同步补 goods=none，否则 auto-gate fail-closed 桥接不 approved）
  # （09-10 二次同步：harvest 新增 .draft 自愈契约（卡 t_f5468b33）——链完成判定前置草稿检查，
  #   缺稿一律人工路不放行 auto-gate。worker 模拟补写约定位置成稿、交卡路自愈补注册：
  #   生产链序中卡 body 产出契约本就钉死 pending/<rq-id>.md 必产，此段同时自证自愈正例）
  sb_rq set "$DC2_ID" deep-check --note "worker 模拟" >/dev/null 2>&1
  mkdir -p "$SB_ROOT/contrib-data/runs/deep-check/$DC2_ID"
  printf '{"decision":"auto","confidence":"high","risk_level":"low","reasons":[],"goods":{"status":"none"}}\n' \
    >"$SB_ROOT/contrib-data/runs/deep-check/$DC2_ID/verdict.json"
  printf '# 深检成稿（worker 模拟）%s\n' "$DC2_ID" \
    >"$SB_ROOT/contrib-data/pending/$DC2_ID.md"
  sb_rq set "$DC2_ID" awaiting-approval --note "worker 模拟 final" >/dev/null 2>&1
  printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$DC_CARD_1" \
    >"$SB_ROOT/stublog/kanban-cards.jsonl"
  sb_run 'zsh "$MARTIN_DIR/scripts/contrib/run-deepcheck.sh"' >/dev/null 2>&1
  history="$(jq -r --arg id "$DC2_ID" '[.items[] | select(.id == $id) | .history[].event] | join(",")' \
    "$SB_ROOT/contrib-data/ready-queue.json" 2>/dev/null)"
  [[ "$history" == *"approved"* ]] || dc_fail="$dc_fail G:auto-gate 桥接未 approved（history=${history}）"
  [[ "$(awk -F'|' '$1 == "claude"' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || dc_fail="$dc_fail G:链收尾调了 claude"
  [[ -f "$DC_FLIGHT" ]] || dc_fail="$dc_fail G:失败重试闭环未重启新卡（flight 应重建）"
  sb_cleanup >/dev/null 2>&1
else
  dc_fail="deepcheck 段 sandbox 失败"
fi
[[ -z "$dc_fail" ]] || smoke_fail "deepcheck 卡化链: $dc_fail"

# ---- T5 notify digest 卡链段（独立沙箱）----
# H: flush 叙事批 → 建 digest 卡 + flight 四键 + 快照（零 claude 零 send）
# I: worker 收尾模拟（send-digest）→ 账本 pushed + 批次 sent:true
# J: 卡 done 消费轮 → 零账本动作（双写禁止）+ 清登记清快照 + 新攒事件不丢
if sb_new >/dev/null 2>&1; then
  dg_fail=""
  DG_EVENTS="$SB_ROOT/contrib-data/events.jsonl"   # 段内新沙箱路径（勿用全局 EVENTS_FILE——那是首个沙箱的）
  sb_notify event pipeline-failure --key dg-e2e --summary "digest 冒烟叙事事件" >/dev/null 2>&1
  sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
  DG_FLIGHT="$SB_ROOT/contrib-data/kanban-flight-digest.json"
  [[ "$(jq -r '.kind // empty' "$DG_FLIGHT" 2>/dev/null)" == "digest" ]] || dg_fail="H:flight 未登记"
  DG_SNAP="$(jq -r '.batch_file // empty' "$DG_FLIGHT" 2>/dev/null)"
  DG_CARD="$(jq -r '.card_id // empty' "$DG_FLIGHT" 2>/dev/null)"
  [[ -n "$DG_SNAP" && -f "$DG_SNAP" ]] || dg_fail="$dg_fail H:快照未落盘"
  [[ -n "$DG_CARD" ]] || dg_fail="$dg_fail H:card_id 缺"
  [[ "$(awk -F'|' '$1 == "claude"' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || dg_fail="$dg_fail H:主路调了 claude"
  [[ "$(awk -F'|' '$1 == "hermes" && $3 ~ /^send /' "$SB_ROOT/stublog/calls.log" 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] \
    || dg_fail="$dg_fail H:主路出现 hermes send（零订阅语义破）"
  # I: worker 收尾模拟：写摘要 → send-digest → OK + pushed + sent:true
  if [[ -n "$DG_SNAP" ]]; then
    DG_DIGEST="${DG_SNAP%.json}.digest.md"
    printf '🟠【contrib 告警】09-09\n\n冒烟摘要；无需动作。\n' >"$DG_DIGEST"
    dg_out="$(sb_run -e "NOTIFY_DRY_RUN=false" \
      "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DG_DIGEST' --batch '$DG_SNAP'")"
    [[ "$dg_out" == "OK" ]] || dg_fail="$dg_fail I:send-digest 输出非 OK（got=${dg_out}）"
    [[ "$(jq -r 'select(.key == "dg-e2e") | .pushed' "$DG_EVENTS" 2>/dev/null)" == "true" ]] \
      || dg_fail="$dg_fail I:账本未标 pushed"
    [[ "$(jq -rs '[.[] | select(.sent == true)] | length' "$DG_SNAP" 2>/dev/null)" == "1" ]] \
      || dg_fail="$dg_fail I:批次未回写 sent:true"
    # J: 消费轮（done + sent:true）→ 零账本动作 + 清登记清快照 + 新攒事件不丢
    printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$DG_CARD" \
      >"$SB_ROOT/stublog/kanban-cards.jsonl"
    sb_notify event pipeline-failure --key dg-e2e-2 --summary "消费轮新攒" >/dev/null 2>&1
    dg_pushed_before="$(jq -s '[.[] | select(.pushed == true)] | length' "$DG_EVENTS" 2>/dev/null)"
    sb_state_set '.last_flush_epoch = 0'
    sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
    [[ "$(jq -s '[.[] | select(.pushed == true)] | length' "$DG_EVENTS" 2>/dev/null)" == "$dg_pushed_before" ]] \
      || dg_fail="$dg_fail J:消费轮出现新增 pushed（双写破）"
    [[ ! -f "$DG_FLIGHT" ]] || dg_fail="$dg_fail J:登记未清"
    [[ ! -f "$DG_SNAP" ]] || dg_fail="$dg_fail J:快照未删"
    [[ "$(jq -r 'select(.key == "dg-e2e-2") | .pushed' "$DG_EVENTS" 2>/dev/null)" == "false" ]] \
      || dg_fail="$dg_fail J:新攒事件被越权消费"
  fi
  sb_cleanup >/dev/null 2>&1
else
  dg_fail="digest 段 sandbox 失败"
fi
[[ -z "$dg_fail" ]] || smoke_fail "digest 卡化链: $dg_fail"

# ---- 汇总 JSON（末行）----
sb_json_path="$SMOKE_STUB_LOG"
sandbox_key=""
if [[ "${E2E_KEEP:-}" == "1" ]]; then
  sandbox_key=",\"sandbox\":\"$SB_ROOT\""
  echo "e2e-smoke: 沙箱保留于 $SB_ROOT" >&2
else
  sb_cleanup
fi

if [[ -z "$FAIL_REASON" && "$all_lines_valid_json" == "true" && "$prefix_preserved" == "true" ]]; then
  exit_code=0
else
  exit_code=1
fi

card_ok=true
[[ -z "$card_fail" ]] || card_ok=false
printf '{"transport_calls":%d,"ledger_appends":%d,"queue_transitions":%d,"prefix_preserved":%s,"all_lines_valid_json":%s,"card_flow_ok":%s,"stub_log":"%s"%s}\n' \
  "$transport_calls" "$ledger_appends" "$queue_transitions" "$prefix_preserved" "$all_lines_valid_json" \
  "$card_ok" "$sb_json_path" "$sandbox_key"
if [[ -n "$FAIL_REASON" ]]; then
  echo "e2e-smoke FAIL: $FAIL_REASON" >&2
fi
exit "$exit_code"
