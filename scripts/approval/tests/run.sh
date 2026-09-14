#!/bin/bash
# run.sh — L2-A 短码审批链沙箱集成测试（全 stub / 全 dry 外发 / 可重复执行）
#
# 覆盖（设计 P8 + 验收场景 5/6/7/8/9）:
#   A 组 卡 v2 + 人读页: C6 逐行断言 / slug·短码字符集（C4）/ 截止与降级行 / 两项相异性（5.P3）
#        / 人读页 fence+BLUF+证据表+verbatim 附录 / 机器稿零改动 / 旧路回退（approval_interactive 缺省）
#   B 组 collect→execute 全链: matched 消费+台账+1+幂等第二轮零增量（6.P1-3）/ mismatch 不消费（6.P4）
#        / 空转（7.P1）/ 旧数据无 code 跳过（9.P3）/ 搁置过期回收 rm（9.P5）/ execute 失败→failed+事件（9.P4）
#        / drill 跳过 gh 与 approved.log / APPROVAL_DRY_RUN 只打印
#   C 组 静态门 + 正式产物零触碰: 全角标点 regex 门 / bash -n / plist 契约 / 正式账本 diff 显式 pin /usr/bin/diff（8.P1）
#
# 红线：绝不真调 tunnel deploy / 绝不真发微信（HERMES_BIN stub + NOTIFY_DRY_RUN=true）/ 绝不 gh 真写；
#       APPROVED_LOG 永远指向沙箱替身；正式 contrib-data 只读（末组用 /usr/bin/diff 断言零变更）。
set -uo pipefail

MARTIN="${MARTIN_DIR:-$HOME/workspace/martin}"
RQ="$MARTIN/scripts/contrib/rq.sh"
NOTIFY="$MARTIN/scripts/contrib/notify.sh"
COLLECT="$MARTIN/scripts/approval/collect.sh"
EXECUTE="$MARTIN/scripts/approval/execute.sh"
PLIST="$MARTIN/scripts/approval/com.stringzhao.approval-collect.plist"
REAL_APPROVED_LOG="$MARTIN/approved.log"
REAL_CONFIG="$MARTIN/contrib-data/config.json"
REAL_QUEUE="$MARTIN/contrib-data/ready-queue.json"
REAL_EVENTS="$MARTIN/contrib-data/events.jsonl"
# diff 显式 pin 绝对路径（第三方 diff 遮蔽系统命令 → 假绿盲区，knowledge patterns.md:321）
DIFF_BIN="/usr/bin/diff"
[[ -x "$DIFF_BIN" ]] || DIFF_BIN="$(command -v diff)"

PASS=0
FAIL=0
FAILED_NAMES=""
SB=""

say_pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
say_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES="${FAILED_NAMES} [${1}]"; echo "FAIL $1 :: $2"; }
check_eq() { if [[ "$2" == "$3" ]]; then say_pass "$1"; else say_fail "$1" "actual=[$2] expected=[$3]"; fi; }
check_ne() { if [[ "$2" != "$3" ]]; then say_pass "$1"; else say_fail "$1" "两值应不同却相同=[$2]"; fi; }
check_contains() { if [[ "$1" == *"$2"* ]]; then say_pass "$3"; else say_fail "$3" "未找到 [$2]（实际前 200 字: ${1:0:200}）"; fi; }
check_not_contains() { if [[ "$1" != *"$2"* ]]; then say_pass "$3"; else say_fail "$3" "不应出现却出现 [$2]"; fi; }
check_regex() { if [[ "$2" =~ $3 ]]; then say_pass "$1"; else say_fail "$1" "值 [$2] 不匹配 [$3]"; fi; }

# ---------------- 沙箱工厂 ----------------
write_stubs() {
  cat > "$SB/bin/tunnel" <<'STUB'
#!/bin/bash
# 沙箱 stub tunnel：调用记录 → ${STUB_STATE}/calls/tunnel.log；decision 行为按 <slug>.{rc,json} 驱动
LOG_DIR="${STUB_STATE:?STUB_STATE required}/calls"
mkdir -p "$LOG_DIR"
printf '%s\n' "$*" >> "$LOG_DIR/tunnel.log"
cmd="${1:-}"; sub="${2:-}"
if [[ "$cmd" == "drops" && "$sub" == "approve" ]]; then
  printf 'https://pages.example/%s\n' "${5:-noslug}"
  exit 0
fi
if [[ "$cmd" == "drops" && "$sub" == "decision" ]]; then
  slug="$3"
  st="$STUB_STATE/decision/$slug"
  if [[ -f "$st.rc" ]]; then
    cat "$st.json" 2>/dev/null
    exit "$(cat "$st.rc")"
  fi
  printf '{"slug":"%s","matched":false,"reason":"no_submission","verdict":null,"comment":null,"submitted_at":null,"submissions_seen":0}\n' "$slug"
  exit 3
fi
if [[ "$cmd" == "rm" ]]; then
  printf '%s\n' "$*" >> "$LOG_DIR/tunnel-rm.log"
  if [[ -f "$STUB_STATE/rm-fail" ]]; then
    echo "stub tunnel: rm forced failure" >&2
    exit 1
  fi
  exit 0
fi
if [[ "$cmd" == "list" ]]; then
  # slug 存在性复核用（collect.sh slug_gone）；list.txt 缺省 = list 不可用（exit 1）
  if [[ -f "$STUB_STATE/list.txt" ]]; then cat "$STUB_STATE/list.txt"; exit 0; fi
  echo "stub tunnel: list unavailable" >&2
  exit 1
fi
if [[ "$cmd" == "deploy" ]]; then
  printf 'https://pages.example/legacy\n'
  exit 0
fi
echo "stub tunnel: 未知参数 $*" >&2
exit 1
STUB

  cat > "$SB/bin/gh" <<'STUB'
#!/bin/bash
# 沙箱 stub gh：调用记录（argv + stdin）→ ${STUB_STATE}/calls/gh.log；GH_STUB_MODE=fail 注毒全失败
LOG_DIR="${STUB_STATE:?STUB_STATE required}/calls"
mkdir -p "$LOG_DIR"
{ printf '=== gh %s\n' "$*"; if [ -t 0 ]; then :; else perl -e 'alarm 2; exec @ARGV' cat 2>/dev/null || cat; printf '\n'; fi; } >> "$LOG_DIR/gh.log"
# -F body=@<file> 载荷倾倒（09-06 事故回归：投递正文断言不得依赖 stdin 单通道）
for a in "$@"; do
  case "$a" in
    body=@*)
      f="${a#body=@}"
      if [ -f "$f" ]; then { printf -- '--- body-file %s ---\n' "$f"; cat "$f"; printf '\n'; } >> "$LOG_DIR/gh.log"; fi
      ;;
  esac
done
if [[ "${GH_STUB_MODE:-ok}" == "fail" ]]; then
  echo "gh stub: forced failure" >&2
  exit 1
fi
case "$*" in
  *"issue view"*)        echo '{"state":"OPEN"}' ;;
  *"pr list"*)           echo '[]' ;;
  *"comments?per_page"*) echo '[]' ;;
  *"-X POST"*)           echo '{"html_url":"https://github.com/NousResearch/hermes-agent/issues/60001#issuecomment-999"}' ;;
  *)                     echo '{}' ;;
esac
exit 0
STUB

  cat > "$SB/bin/hermes" <<'STUB'
#!/bin/bash
# 沙箱 stub hermes：notify.sh _send 以 stdout 落 NOTIFY_SEND_LAST 并要求 .success==true
LOG_DIR="${STUB_STATE:?STUB_STATE required}/calls"
mkdir -p "$LOG_DIR"
printf '%s\n' "$*" >> "$LOG_DIR/hermes.log"
if [[ "${1:-}" == "send" ]]; then
  # 解析 --file <path>，复制消息体副本（非 dry 路 stdout 不落卡，测试改断言消息体）
  prev=""
  for a in "$@"; do
    if [[ "$prev" == "--file" && -f "$a" ]]; then cp "$a" "$LOG_DIR/hermes-last-body.txt"; fi
    prev="$a"
  done
  echo '{"success":true,"message_id":"stub-1"}'
else
  echo '{}'
fi
exit 0
STUB
  chmod +x "$SB/bin/tunnel" "$SB/bin/gh" "$SB/bin/hermes"
}

sb_new() { # sb_new [interactive:true|false] → 新沙箱
  local interactive="${1:-true}"
  SB="$(mktemp -d "${TMPDIR:-/tmp}/approval-sb.XXXXXX")"
  mkdir -p "$SB/contrib-data/pending" "$SB/contrib-data/logs" "$SB/bin" "$SB/stub/decision" "$SB/locks"
  cat > "$SB/contrib-data/config.json" <<EOF
{
  "repo": "NousResearch/hermes-agent",
  "deep_check_per_week": 30,
  "deep_check_per_day": 30,
  "max_alert_pushes_per_day": 3,
  "max_approval_pushes_per_day": 3,
  "approval_ttl_hours": 48,
  "notify_min_interval_min": 20,
  "notify_dry_run": true,
  "notify_target": "weixin:sandbox-target@im.wechat",
  "notify_digest": true,
  "approval_interactive": ${interactive}
}
EOF
  printf '{"version":1,"updated":"","items":[]}\n' > "$SB/contrib-data/ready-queue.json"
  jq -n '{limits:{week:3,day:1},days:{},weeks:{},probes:{}}' > "$SB/contrib-data/budget.json"
  : > "$SB/contrib-data/events.jsonl"
  printf '{"last_flush_epoch":0,"alerts":{},"approvals":{},"receipts":{}}\n' > "$SB/contrib-data/notify-state.json"
  write_stubs
}

sb_done() { [[ -n "$SB" && -d "$SB" ]] && rm -rf "$SB"; SB=""; }

# 被测命令包装（全部经 seam 注入 stub + 沙箱锁；绝不触真实服务）
rq() {
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" TUNNEL_BIN="$SB/bin/tunnel" \
      bash "$RQ" "$@" )
}
notify_cmd() {
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" NOTIFY_LOCK="$SB/locks/notify" \
      TUNNEL_BIN="$SB/bin/tunnel" HERMES_BIN="$SB/bin/hermes" NOTIFY_SEND_LAST="$SB/send-last.json" \
      NOTIFY_DRY_RUN="${NDRY:-true}" GH_BIN="$SB/bin/gh" STUB_STATE="$SB/stub" bash "$NOTIFY" "$@" )
}
collect_cmd() {
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" APPROVAL_LOCKDIR="$SB/locks/collect" \
      TUNNEL_BIN="$SB/bin/tunnel" GH_BIN="$SB/bin/gh" APPROVED_LOG="$SB/approved.log" STUB_STATE="$SB/stub" \
      APPROVAL_DRY_RUN="${ADRY:-false}" NOTIFY_DRY_RUN=true GH_STUB_MODE="${GHMODE:-ok}" bash "$COLLECT" )
}

# 沙箱读取
q_field() { jq -r --arg id "$1" ".items[] | select(.id == \$id) | ${2}" "$SB/contrib-data/ready-queue.json"; }
ledger_lines() { if [[ -f "$SB/approved.log" ]]; then wc -l < "$SB/approved.log" | tr -d ' '; else echo 0; fi; }
stub_count() { # <tool> [needle] → 调用行数
  local f="$SB/stub/calls/$1.log"
  if [[ ! -f "$f" ]]; then echo 0; return 0; fi
  if [[ -n "${2:-}" ]]; then grep -cF -- "$2" "$f" || true; else wc -l < "$f" | tr -d ' '; fi
}
rm_count() { # tunnel rm 次数（专用日志，防 slug 随机含 "rm" 子串的假计数）
  local f="$SB/stub/calls/tunnel-rm.log"
  if [[ ! -f "$f" ]]; then echo 0; return 0; fi
  wc -l < "$f" | tr -d ' '
}

# 造一项并推进到 awaiting-approval（含机器稿）；ID/DRAFT 为全局出口
NEXT_ISSUE=60000
make_item() { # <disposition> <lane> [--drill]
  local disp="$1" lane="$2" drillflag="${3:-}"
  NEXT_ISSUE=$((NEXT_ISSUE + 1))
  local args=(--issue "$NEXT_ISSUE" --disposition "$disp" --score 12 --lane "$lane" --source manual
    --title "审批链演练标题${NEXT_ISSUE}：测试项"
    --premises-json '[{"claim":"turn_usage 前提仍成立","evidence":"run_usage.py:111-116 receipt"}]')
  [[ -n "$drillflag" ]] && args+=(--drill)
  ID="$(rq add "${args[@]}")"
  DRAFT="$SB/contrib-data/pending/$ID.md"
  cat > "$DRAFT" <<EOF
<!-- 内部备注：沙箱测试稿，禁止外发；头部注释块投递时应被剥离 -->
# 审批对象 ${ID}

正文第一段：这是 ${ID} 的机器稿正文，投递时须逐字保留。

- premise 引用行：run_usage.py:111-116

    goods: 无（沙箱演练稿；此行仅供 rq set-draft 的 goods 回退抓取——rq.sh set -e 下
    grep 无命中会静默杀死 set-draft，09-12 基线修复实证，见 state.md）
EOF
  rq set-draft "$ID" "$DRAFT" >/dev/null
  rq set "$ID" awaiting-approval >/dev/null
}

# 按 C1 罐装 decision 结果
stub_decision() { # <slug> <rc> <matched> <verdict> <comment>
  local slug="$1" rc="$2" matched="$3" verdict="$4" comment="$5"
  printf '%s' "$rc" > "$SB/stub/decision/$slug.rc"
  jq -n --arg slug "$slug" --argjson matched "$matched" --arg verdict "$verdict" --arg comment "$comment" '
    {slug: $slug, matched: $matched,
     reason: (if $matched then "ok" elif $verdict == "" then "code_mismatch" else "code_mismatch" end),
     verdict: (if $verdict == "" then null else $verdict end),
     comment: (if $comment == "" then null else $comment end),
     submitted_at: "2026-09-05T23:59:00+08:00", submissions_seen: 1}' > "$SB/stub/decision/$slug.json"
}

# ---------------- 生产零触碰基线（场景 8.P1，整组跑完复核） ----------------
BASELINE="$(mktemp -d "${TMPDIR:-/tmp}/approval-baseline.XXXXXX")"
snapshot_production() {
  for f in "$REAL_APPROVED_LOG" "$REAL_CONFIG" "$REAL_QUEUE" "$REAL_EVENTS"; do
    [[ -f "$f" ]] && cp "$f" "$BASELINE/$(basename "$f").snap" || true
  done
  stat -f '%m' "$REAL_APPROVED_LOG" > "$BASELINE/approved.log.mtime" 2>/dev/null || echo 0 > "$BASELINE/approved.log.mtime"
}
assert_production_untouched() {
  local name="8.P1 正式产物零触碰（/usr/bin/diff pin）" bad=0 f base
  for f in "$REAL_APPROVED_LOG" "$REAL_CONFIG" "$REAL_QUEUE" "$REAL_EVENTS"; do
    base="$BASELINE/$(basename "$f").snap"
    [[ -f "$base" ]] || continue
    if ! "$DIFF_BIN" -q "$base" "$f" >/dev/null 2>&1; then
      say_fail "$name" "正式文件被改动: $f"
      bad=1
    fi
  done
  if (( bad == 0 )); then say_pass "$name"; fi
}

# ================= A 组：卡 v2 + 人读页（场景 5） =================
echo "===== A 组：卡 v2 + 人读页 ====="
sb_new true
make_item review-evidence deep
A_ID="$ID"; A_ISSUE="$NEXT_ISSUE"
A_DRAFT="$DRAFT"
A_DRAFT_SHA="$(shasum -a 256 "$A_DRAFT" | awk '{print $1}')"
OUT="$SB/out-approve.txt"
notify_cmd approve "$A_ID" > "$OUT" 2> "$SB/out-approve.err"
A_SLUG="$(q_field "$A_ID" '.tunnel.slug')"
A_CODE="$(q_field "$A_ID" '.tunnel.code')"
A_URL="$(q_field "$A_ID" '.tunnel.url')"
CARD_LINE1="$(grep -m1 '🟡【L2 审批' "$OUT" || true)"
OUT_TEXT="$(cat "$OUT")"

check_eq "C4 短码已登记（6 字符）" "$(q_field "$A_ID" '.tunnel.code' | wc -c | tr -d ' ')" "7"
check_regex "C4 slug 字符集 [a-z0-9]{10}" "$A_SLUG" '^[a-z0-9]{10}$'
check_regex "C4 短码字符集 [a-km-np-z2-9]{6}（去 0/o/1/l）" "$A_CODE" '^[a-km-np-z2-9]{6}$'
check_eq "C4 dry-run 登记 url=合成值" "$A_URL" "https://d.stringzhao.life/${A_SLUG}"
check_eq "5.P1 卡 line1 = 🟡【L2 审批 #id】disposition 表述（硬编码修正①）" \
  "$CARD_LINE1" "🟡【L2 审批 #${A_ID}】evidence 评审"
check_contains "$OUT_TEXT" "目标: NousResearch/hermes-agent#${A_ISSUE} · 12/15 · strategist+红队双审" "C6 line2 目标/分/审核轮次（硬编码修正②）"
check_contains "$OUT_TEXT" "概要: 审批链演练标题${A_ISSUE}：测试项" "C6 line3 概要取自项数据"
check_contains "$OUT_TEXT" "✅ 点开即批（短码已自动填入）: https://d.stringzhao.life/${A_SLUG}?key=${A_CODE}" "5.P1 C6 line4 ?key= 可点链接"
check_contains "$OUT_TEXT" "前有效（48h），超时自动搁置" "5.P2 C6 line5 截止时间行"
check_regex "5.P2 截止时间为 MM-DD HH:MM 形态" "$(grep -oE '⏱ [0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} 前有效' "$OUT" | head -1)" '^⏱ [0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} 前有效$'
check_contains "$OUT_TEXT" "💬 微信备用: 批/否 #${A_ID}；改 #${A_ID}: 意见" "5.P2 C6 line6 降级微信指令"

# 人读页断言
PAGE="${A_DRAFT}.page.md"
check_eq "T4 page.md 路径 = draft+.page.md" "$( [[ -f "$PAGE" ]] && echo yes || echo no )" "yes"
PAGE_TEXT="$(cat "$PAGE")"
check_contains "$PAGE_TEXT" '<!-- twq:submit-here -->' "09-06 二轮：提交栏定点指令（组件之后、正文之前）"
check_contains "$PAGE_TEXT" '```interactive' "C8 页首含 interactive fence"
check_contains "$PAGE_TEXT" "id: verdict" "C2 radio id:verdict"
check_contains "$PAGE_TEXT" "type: radio" "C2 radio type"
check_contains "$PAGE_TEXT" "id: comment" "C2 text id:comment"
check_regex "C2 三选项固定顺序 批准→否决→需修改" \
  "$(printf '%s' "$PAGE_TEXT" | tr -d '\n' | grep -oE '  - 批准.*  - 否决.*  - 需修改' | head -1)" '.*  - 批准.*  - 否决.*  - 需修改.*'
check_contains "$PAGE_TEXT" "# 审批：在" "B1 人话动作标题（09-06 决策单重构）"
check_contains "$PAGE_TEXT" "[issue #${A_ISSUE}](https://github.com/NousResearch/hermes-agent/issues/${A_ISSUE})" "B1 复核锚点目标链接"
check_contains "$PAGE_TEXT" "前有效（逾期自动搁置）" "B1 时效行"
check_contains "$PAGE_TEXT" "这条评论说了什么" "B1 L1 中文摘要节"
check_contains "$PAGE_TEXT" "| 结论 | 依据 |" "B1 复核锚点表头"
check_contains "$PAGE_TEXT" "turn_usage 前提仍成立" "B1 锚点表 claim 行取自 rq premises"
check_contains "$PAGE_TEXT" "run_usage.py:111-116 receipt" "B1 锚点表 evidence 行"
check_contains "$PAGE_TEXT" "英文原文附录（批准后将逐字发出" "B1 ④原文附录标题（details 折叠）"
check_contains "$PAGE_TEXT" "这是 ${A_ID} 的机器稿正文，投递时须逐字保留。" "B1 ④机器稿全文 verbatim 入附录"
check_eq "红线④ 机器稿本体未被加 fence（sha 不变）" "$(shasum -a 256 "$A_DRAFT" | awk '{print $1}')" "$A_DRAFT_SHA"
check_not_contains "$(cat "$A_DRAFT")" '```interactive' "红线④ 机器稿本体无 interactive fence"

# 两项相异性（5.P3）
make_item probe-salvage probe
B_ID="$ID"; B_ISSUE="$NEXT_ISSUE"; B_DRAFT="$DRAFT"
OUT2="$SB/out-approve2.txt"
notify_cmd approve "$B_ID" > "$OUT2" 2>/dev/null
OUT2_TEXT="$(cat "$OUT2")"
B_SLUG="$(q_field "$B_ID" '.tunnel.slug')"
B_CODE="$(q_field "$B_ID" '.tunnel.code')"
check_ne "5.P3 slug_A != slug_B" "$A_SLUG" "$B_SLUG"
check_ne "5.P3 code_A != code_B" "$A_CODE" "$B_CODE"
check_contains "$OUT2_TEXT" "🟡【L2 审批 #${B_ID}】probe 取证" "5.P3 项B disposition 表述取自自身数据"
check_contains "$OUT2_TEXT" "目标: NousResearch/hermes-agent#${B_ISSUE} · 12/15 · strategist 单轮" "5.P3 项B lane 审核轮次按 lane 渲染"
check_contains "$OUT2_TEXT" "?key=${B_CODE}" "5.P3 项B 短码取自自身登记"
check_not_contains "$(cat "$B_DRAFT")" '```interactive' "红线④ 项B 机器稿仍无 fence"
sb_done

# 旧路回退：approval_interactive 缺省（=false）→ 旧文本卡
sb_new false
make_item review-evidence deep
L_ID="$ID"; L_DRAFT="$DRAFT"
OUT3="$SB/out-approve3.txt"
notify_cmd approve "$L_ID" > "$OUT3" 2>/dev/null
check_contains "$(cat "$OUT3")" "审阅:" "降级路 卡保留旧模板审阅行"
check_contains "$(cat "$OUT3")" "回复「批 #" "降级路 卡保留旧模板回复指令"
check_not_contains "$(cat "$OUT3")" "?key=" "降级路 卡无短码链接"
check_eq "降级路 不生成 page.md" "$( [[ -f "${L_DRAFT}.page.md" ]] && echo yes || echo no )" "no"
check_eq "降级路 不登记短码（C5 code=null）" "$(q_field "$L_ID" '.tunnel.code')" "null"
sb_done

# 非 dry 交互路：tunnel stub 真接（仍是 stub，无公网）
sb_new true
make_item review-evidence deep
ND_ID="$ID"
ND_OUT="$SB/out-approve4.txt"
NDRY=false notify_cmd approve "$ND_ID" > "$ND_OUT" 2>/dev/null
check_contains "$(cat "$SB/stub/calls/hermes-last-body.txt" 2>/dev/null)" "?key=" "非 dry 交互路 卡带短码链接（hermes 收到的消息体）"
check_regex "非 dry 交互路 url 取自 tunnel stub 输出" "$(q_field "$ND_ID" '.tunnel.url')" '^https://pages\.example/[a-z0-9]{10}$'
check_eq "非 dry 交互路 tunnel approve 被调 1 次" "$(stub_count tunnel 'drops approve')" "1"
check_eq "非 dry 交互路 hermes stub 发送 1 次（无真实微信）" "$(stub_count hermes 'send')" "1"
check_regex "非 dry 交互路 page.md 由机器稿派生" "$(q_field "$ND_ID" '.draft')" '.+'
sb_done

# 回归（09-06 drill 事故）：rq 登记相对路径 draft 时，notify 须锚定工作区根转绝对再调 tunnel——
# 真实 tunnel bin 会先 cd 到 tunnel-cli 仓再 exec，相对参数会被错解析致静默降级旧卡路
sb_new true
make_item review-evidence deep
REL_ID="$ID"
rq set-draft "$REL_ID" "contrib-data/pending/$REL_ID.md" >/dev/null   # 相对形式（agent 侧 set-draft 曾真实出现）
NDRY=false notify_cmd approve "$REL_ID" > /dev/null 2>&1
check_eq "回归 相对 draft 转绝对后 tunnel approve 被调" "$(stub_count tunnel 'drops approve')" "1"
check_contains "$(cat "$SB/stub/calls/tunnel.log")" "drops approve $SB/contrib-data/pending/$REL_ID.md.page.md" "回归 tunnel 收到绝对路径 page"
check_regex "回归 相对 draft 交互路登记成功（未降级）" "$(q_field "$REL_ID" '.tunnel.url')" '^https://pages\.example/[a-z0-9]{10}$'
sb_done

# ================= B 组：collect → execute 全链（场景 6/7/9） =================
echo "===== B 组：collect → execute 全链 ====="

# 6.P1/6.P2/6.P3 matched 消费 + 幂等
sb_new true
make_item review-evidence deep
C_ID="$ID"
notify_cmd approve "$C_ID" >/dev/null 2>&1
C_SLUG="$(q_field "$C_ID" '.tunnel.slug')"
stub_decision "$C_SLUG" 0 true approved "批准，请投递"
collect_cmd > "$SB/collect1.out" 2>&1
check_eq "6.P1 matched→消费（终态 executed）" "$(q_field "$C_ID" '.state')" "executed"
check_contains "$(rq show "$C_ID")" "approved" "6.P1 history 含 approved 迁移"
check_eq "6.P2 台账恰 +1 行" "$(ledger_lines)" "1"
check_contains "$(cat "$SB/approved.log")" "$C_ID" "6.P2 台账行含 rq-id"
check_contains "$(cat "$SB/approved.log")" "L2-A tunnel 短码批准（slug=${C_SLUG}）" "C8 批准方式列格式"
check_contains "$(cat "$SB/approved.log")" "comment-999" "C8 末列含投递 URL"
D1="$(stub_count tunnel 'drops decision')"
collect_cmd > "$SB/collect2.out" 2>&1
check_eq "6.P3 第二轮决策调用零增量" "$(stub_count tunnel 'drops decision')" "$D1"
check_eq "6.P3 第二轮台账零增量" "$(ledger_lines)" "1"
check_eq "6.P3 状态保持" "$(q_field "$C_ID" '.state')" "executed"
check_eq "C8 审后即删 tunnel rm 恰 1 次" "$(rm_count)" "1"
check_ne "C8 removed_at 已登记" "$(q_field "$C_ID" '.tunnel.removed_at')" "null"
check_eq "C8 gh 投递恰 1 次" "$(stub_count gh '-X POST')" "1"
check_contains "$(cat "$SB/stub/calls/gh.log" 2>/dev/null)" \
  "正文第一段：这是 ${C_ID} 的机器稿正文，投递时须逐字保留。" "C8 投递正文经 stdin 逐字到达 gh（空 body 文件从此不再假绿）"
check_not_contains "$(cat "$SB/stub/calls/gh.log" 2>/dev/null)" \
  "内部备注：沙箱测试稿" "C8 头部注释块已剥离（不进投递正文）"
sb_done

# 6.P4 mismatch 不消费
sb_new true
make_item review-evidence deep
M_ID="$ID"
notify_cmd approve "$M_ID" >/dev/null 2>&1
M_SLUG="$(q_field "$M_ID" '.tunnel.slug')"
stub_decision "$M_SLUG" 4 false "" ""
collect_cmd > "$SB/collect3.out" 2>&1
check_eq "6.P4 mismatch 状态不变" "$(q_field "$M_ID" '.state')" "awaiting-approval"
check_eq "6.P4 台账零增量" "$(ledger_lines)" "0"
check_eq "6.P4 执行链未触发" "$(stub_count gh '-X POST')" "0"
check_contains "$(cat "$SB/contrib-data/events.jsonl")" "approval-code-mismatch" "6.P4 mismatch 事件入账"
check_contains "$(cat "$SB/contrib-data/events.jsonl")" "${M_ID}-$(date +%F)" "6.P4 事件 key 幂等形态"
sb_done

# 7.P1 空转
sb_new true
collect_cmd > "$SB/collect4.out" 2>&1
check_eq "7.P1 空转 exit 0" "$?" "0"
check_eq "7.P1 空转判定调用 0" "$(stub_count tunnel 'drops decision')" "0"
check_eq "7.P1 空转台账零增量" "$(ledger_lines)" "0"
sb_done

# 9.P3 旧数据 code=null 跳过
sb_new true
make_item review-evidence deep
O_ID="$ID"
rq set-draft "$O_ID" "$DRAFT" >/dev/null 2>&1
jq --arg id "$O_ID" '.items |= map(if .id == $id then .tunnel.slug = "legacyslug1" | .tunnel.code = null else . end)' \
  "$SB/contrib-data/ready-queue.json" > "$SB/q.tmp" && mv "$SB/q.tmp" "$SB/contrib-data/ready-queue.json"
collect_cmd > "$SB/collect5.out" 2>&1
check_eq "9.P3 旧数据判定调用 0" "$(stub_count tunnel 'drops decision')" "0"
check_eq "9.P3 旧数据状态保持" "$(q_field "$O_ID" '.state')" "awaiting-approval"
check_eq "9.P3 旧数据台账零增量" "$(ledger_lines)" "0"
sb_done

# 9.P5 搁置/过期页面回收
sb_new true
make_item review-evidence deep
E_ID="$ID"
notify_cmd approve "$E_ID" >/dev/null 2>&1
E_SLUG="$(q_field "$E_ID" '.tunnel.slug')"
rq set "$E_ID" shelved >/dev/null 2>&1
jq --arg id "$E_ID" --argjson ep "$(( $(date +%s) - 3 * 86400 ))" \
  '.items |= map(if .id == $id then .tunnel.deployed_epoch = $ep else . end)' \
  "$SB/contrib-data/ready-queue.json" > "$SB/q.tmp" && mv "$SB/q.tmp" "$SB/contrib-data/ready-queue.json"
collect_cmd > "$SB/collect6.out" 2>&1
check_eq "9.P5 回收 rm 恰 1 次" "$(rm_count)" "1"
check_ne "9.P5 removed_at 登记" "$(q_field "$E_ID" '.tunnel.removed_at')" "null"
check_contains "$(cat "$SB/stub/calls/tunnel-rm.log")" "$E_SLUG" "9.P5 rm 的是登记 slug"
sb_done

# 9.P5b 幽灵 slug 幂等回收（rm 报错但 slug 已不在 → 幂等成功终态，不得死循环；
# 生产实证：c0i5s6514x 每 90s 重试 4125 次/5 天）
sb_new true
make_item review-evidence deep
P_ID="$ID"
notify_cmd approve "$P_ID" >/dev/null 2>&1
rq set "$P_ID" shelved >/dev/null 2>&1
jq --arg id "$P_ID" --argjson ep "$(( $(date +%s) - 3 * 86400 ))" \
  '.items |= map(if .id == $id then .tunnel.deployed_epoch = $ep else . end)' \
  "$SB/contrib-data/ready-queue.json" > "$SB/q.tmp" && mv "$SB/q.tmp" "$SB/contrib-data/ready-queue.json"
printf '1\n' > "$SB/stub/rm-fail"                 # rm 恒败（模拟 slug 已在远端消失的报错形态）
printf 'other-slug\tmd\n' > "$SB/stub/list.txt"   # list 可用且不含本 slug → 页不在
collect_cmd > "$SB/collect-r1.out" 2>&1
check_eq "9.P5b 幽灵 slug 幂等成功 removed_at 登记" "$(q_field "$P_ID" '.tunnel.removed_at' | grep -c null)" "0"
collect_cmd > "$SB/collect-r2.out" 2>&1
check_eq "9.P5b 第二轮不再重试 rm（恰 1 次）" "$(rm_count)" "1"
check_contains "$(cat "$SB/contrib-data/logs/approval-collect.log")" "幂等成功" "9.P5b 日志留幂等痕迹"
sb_done

# 9.P5c 真失败仍重试（rm 失败 + slug 还在 → 保持候选，下轮再试）
sb_new true
make_item review-evidence deep
Q_ID="$ID"
notify_cmd approve "$Q_ID" >/dev/null 2>&1
rq set "$Q_ID" shelved >/dev/null 2>&1
jq --arg id "$Q_ID" --argjson ep "$(( $(date +%s) - 3 * 86400 ))" \
  '.items |= map(if .id == $id then .tunnel.deployed_epoch = $ep else . end)' \
  "$SB/contrib-data/ready-queue.json" > "$SB/q.tmp" && mv "$SB/q.tmp" "$SB/contrib-data/ready-queue.json"
printf '1\n' > "$SB/stub/rm-fail"
printf '%s\tmd\n' "$(q_field "$Q_ID" '.tunnel.slug')" > "$SB/stub/list.txt"  # slug 还在
collect_cmd > "$SB/collect-f1.out" 2>&1
check_eq "9.P5c slug 仍在 → 不标 removed_at" "$(q_field "$Q_ID" '.tunnel.removed_at')" "null"
collect_cmd > "$SB/collect-f2.out" 2>&1
check_eq "9.P5c 下轮仍重试 rm（恰 2 次）" "$(rm_count)" "2"
sb_done

# 9.P4 execute 失败 → failed + pipeline-failure 事件
sb_new true
make_item review-evidence deep
F_ID="$ID"
notify_cmd approve "$F_ID" >/dev/null 2>&1
F_SLUG="$(q_field "$F_ID" '.tunnel.slug')"
stub_decision "$F_SLUG" 0 true approved ""
GHMODE=fail collect_cmd > "$SB/collect7.out" 2>&1
check_eq "9.P4 gh 失败 → 项置 failed" "$(q_field "$F_ID" '.state')" "failed"
check_contains "$(cat "$SB/contrib-data/events.jsonl")" "pipeline-failure" "9.P4 pipeline-failure 事件入账"
check_contains "$(cat "$SB/contrib-data/events.jsonl")" "$F_ID" "9.P4 事件含该项 id"
check_eq "9.P4 台账零增量（未投递不入账）" "$(ledger_lines)" "0"
sb_done

# drill 件跳过 gh 与 approved.log
sb_new true
make_item review-evidence deep --drill
DR_ID="$ID"
notify_cmd approve "$DR_ID" >/dev/null 2>&1
DR_SLUG="$(q_field "$DR_ID" '.tunnel.slug')"
stub_decision "$DR_SLUG" 0 true approved ""
collect_cmd > "$SB/collect8.out" 2>&1
check_eq "T6 drill 件终态 executed" "$(q_field "$DR_ID" '.state')" "executed"
check_eq "T6 drill 件 gh 调用 0" "$(stub_count gh '')" "0"
check_eq "T6 drill 件不进 approved.log（文件不存在）" "$( [[ -f "$SB/approved.log" ]] && echo yes || echo no )" "no"
check_eq "T6 drill 件审后仍回收" "$(rm_count)" "1"
sb_done

# APPROVAL_DRY_RUN 只打印
sb_new true
make_item review-evidence deep
Y_ID="$ID"
notify_cmd approve "$Y_ID" >/dev/null 2>&1
Y_SLUG="$(q_field "$Y_ID" '.tunnel.slug')"
stub_decision "$Y_SLUG" 0 true approved ""
ADRY=true collect_cmd > "$SB/collect9.out" 2>&1
check_contains "$(cat "$SB/collect9.out")" "[dry-run] rq.sh set ${Y_ID} approved" "C7 dry-run 打印消费动作"
check_contains "$(cat "$SB/collect9.out")" "[dry-run] execute.sh ${Y_ID} approved" "C7 dry-run 打印执行动作"
check_eq "C7 dry-run 状态不变" "$(q_field "$Y_ID" '.state')" "awaiting-approval"
check_eq "C7 dry-run 台账零增量" "$(ledger_lines)" "0"
check_eq "C7 dry-run 判定命令照常（只读）" "$(stub_count tunnel 'drops decision')" "1"
check_eq "C7 dry-run 无 rm" "$(rm_count)" "0"
sb_done

# rejected / revise 两路
sb_new true
make_item review-evidence deep
R_ID="$ID"
notify_cmd approve "$R_ID" >/dev/null 2>&1
R_SLUG="$(q_field "$R_ID" '.tunnel.slug')"
stub_decision "$R_SLUG" 0 true rejected "方向不对"
collect_cmd > "$SB/collect10.out" 2>&1
check_eq "C8 rejected 路 状态=rejected" "$(q_field "$R_ID" '.state')" "rejected"
check_eq "C8 rejected 路不进 approved.log" "$(ledger_lines)" "0"
check_eq "C8 rejected 路 审后即删" "$(rm_count)" "1"
sb_done

sb_new true
make_item review-evidence deep
V_ID="$ID"
notify_cmd approve "$V_ID" >/dev/null 2>&1
V_SLUG="$(q_field "$V_ID" '.tunnel.slug')"
stub_decision "$V_SLUG" 0 true revise "第 2 段证据请补 file:line"
collect_cmd > "$SB/collect11.out" 2>&1
check_eq "T5 revise 路 状态=revise" "$(q_field "$V_ID" '.state')" "revise"
check_contains "$(jq -r --arg id "$V_ID" '.items[] | select(.id == $id) | [.history[] | select(.event == "revise") | .note] | join(" ")' "$SB/contrib-data/ready-queue.json")" \
  "第 2 段证据请补 file:line" "T5 revise 意见入 rq note"
check_eq "T5 revise 路不进 approved.log" "$(ledger_lines)" "0"
sb_done

# ================= D 组：auto-gate 确定性闸门（09-06 默认自动/例外升级） =================
echo "===== D 组：auto-gate 自动批准闸门 ====="

GATE="$MARTIN/scripts/approval/auto-gate.sh"
gate_run() { # <id> → 全局 GATE_RC/GATE_OUT
  GATE_OUT="$(cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" MARTIN_DIR="$SB/martin" \
    bash "$GATE" "$1" 2>&1)"; GATE_RC=$?
}
write_verdict() { # <id> <decision> <confidence> <risk> [reasons-json] [goods-status]
  local d="$SB/contrib-data/runs/deep-check/$1"
  mkdir -p "$d"
  jq -n --arg dec "$2" --arg conf "$3" --arg risk "$4" --argjson reasons "${5:-[]}" --arg goods "${6:-offered}" \
    '{decision:$dec, confidence:$conf, risk_level:$risk, reasons:$reasons,
      goods: (if $goods == "__missing__" then null else {status:$goods, note:"test"} end)}' > "$d/verdict.json"
}

# D1: verdict 缺失 → 升级（无意见不自动）
sb_new true
make_item review-evidence deep
gate_run "$ID"
check_eq "D1 verdict 缺失 → rc=1 升级" "1" "$GATE_RC"
check_contains "$GATE_OUT" "verdict.json 缺失" "D1 升级原因写明缺 verdict"

# D2: 全条件满足 → 自动放行
write_verdict "$ID" auto high low
gate_run "$ID"
check_eq "D2 auto+high+low+评论类+12分 → rc=0" "0" "$GATE_RC"
check_contains "$GATE_OUT" "AUTO|" "D2 输出 AUTO 标记"

# D3: own-PR 永不自动（即使 LLM 判 auto/high/low）
make_item own-PR deep
write_verdict "$ID" auto high low
gate_run "$ID"
check_eq "D3 own-PR → rc=1（push 闸门不破）" "1" "$GATE_RC"
check_contains "$GATE_OUT" "own-PR" "D3 原因点明 own-PR"

# D4: 低分 → 升级
make_item review-evidence deep
jq --arg id "$ID" '(.items[] | select(.id == $id) | .score) = 10' \
  "$SB/contrib-data/ready-queue.json" > "$SB/contrib-data/ready-queue.json.tmp" \
  && mv "$SB/contrib-data/ready-queue.json.tmp" "$SB/contrib-data/ready-queue.json"
write_verdict "$ID" auto high low
gate_run "$ID"
check_eq "D4 score=10 < 12 → rc=1" "1" "$GATE_RC"

# D5: LLM 判 escalate + reasons → 升级且理由透传
make_item review-evidence deep
write_verdict "$ID" escalate medium medium '["拿不准维护者对 breaking change 的容忍度"]'
gate_run "$ID"
check_eq "D5 LLM escalate → rc=1" "1" "$GATE_RC"
check_contains "$GATE_OUT" "拿不准维护者" "D5 升级理由人话透传"

# D6: 置信/风险不达双门槛 → 升级
make_item review-evidence deep
write_verdict "$ID" auto medium low
gate_run "$ID"
check_eq "D6 auto 但 confidence=medium → rc=1" "1" "$GATE_RC"

# D7: 总开关关闭 → 一切升级
jq '. + {auto_approve: false}' "$SB/contrib-data/config.json" > "$SB/contrib-data/config.json.tmp" \
  && mv "$SB/contrib-data/config.json.tmp" "$SB/contrib-data/config.json"
make_item review-evidence deep
write_verdict "$ID" auto high low
gate_run "$ID"
check_eq "D7 auto_approve=false → rc=1" "1" "$GATE_RC"
sb_done

# D7b/D7c/D7d: goods 三态闸（09-09 commit 进仓优先升级：fail-closed）
sb_new true
# D7b: goods 字段缺失 → 升级（深检没走 Goods 判定 = 流程不完整）
make_item review-evidence deep
write_verdict "$ID" auto high low '[]' __missing__
gate_run "$ID"
check_eq "D7b goods 缺失 → rc=1" "1" "$GATE_RC"
check_contains "$GATE_OUT" "goods.status" "D7b 升级原因点明 goods 闸"
# D7c: goods=none（不可修纯 review）→ 仍可自动（none 合法，只计数）
make_item review-evidence deep
write_verdict "$ID" auto high low '[]' none
gate_run "$ID"
check_eq "D7c goods=none → rc=0（纯 review 合法）" "0" "$GATE_RC"
check_contains "$GATE_OUT" "goods=none" "D7c 放行理由带 goods 状态"
# D7d: goods=forge-lane → 仍可自动
make_item review-evidence deep
write_verdict "$ID" auto high low '[]' forge-lane
gate_run "$ID"
check_eq "D7d goods=forge-lane → rc=0" "0" "$GATE_RC"
# D7e: goods 计数落账（三次调用各入一档；counters 总和=3 且 keys 正确）
MET="$SB/contrib-data/goods-metrics.json"
check_eq "D7e goods-metrics counters 总和=3" "3" "$(jq -r '[.counters[]] | add' "$MET")"
check_eq "D7e counters 含 missing/none/forge-lane 三档" "missing none forge-lane" \
  "$(jq -r '.counters | keys_unsorted | join(" ")' "$MET")"
sb_done

# D8/D9: 占坑语义分 disposition（104067b 误杀回归：review-evidence 的 PR 引用是评论对象，不是威胁）
sb_new true
# 沙箱 gh stub：pr list 返回一个外人占坑 PR（覆盖默认 [] 行为）
cat > "$SB/bin/gh-occupier" <<'STUB'
#!/bin/bash
LOG_DIR="${STUB_STATE:?}/calls"; mkdir -p "$LOG_DIR"
printf '=== gh %s\n' "$*" >> "$LOG_DIR/gh-occ.log"
for a in "$@"; do
  case "$a" in body=@*) f="${a#body=@}"; [ -f "$f" ] && { printf -- '--- body-file %s ---\n' "$f"; cat "$f"; printf '\n'; } >> "$LOG_DIR/gh-occ.log" ;; esac
done
case "$*" in
  *"issue view"*)        echo '{"state":"OPEN"}' ;;
  *"pr list"*)           echo '[{"number":99999}]' ;;   # 外人占坑 PR 恒在
  *"comments?per_page"*) echo '[]' ;;
  *"-X POST"*)           echo '{"html_url":"https://github.com/NousResearch/hermes-agent/issues/1#issuecomment-1"}' ;;
  *)                     echo '{}' ;;
esac
STUB
chmod +x "$SB/bin/gh-occupier"

exec_in_sb() { # <id> —— execute.sh 走全真链路（stub 命令 + 沙箱台账）
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" \
      NOTIFY_LOCK="$SB/locks/notify2" TUNNEL_BIN="$SB/bin/tunnel" GH_BIN="$SB/bin/gh-occupier" \
      HERMES_BIN="$SB/bin/hermes" NOTIFY_SEND_LAST="$SB/send-last.json" NOTIFY_DRY_RUN=true \
      APPROVED_LOG="$SB/approved.log" STUB_STATE="$SB/stub" \
      bash "$MARTIN/scripts/approval/execute.sh" "$1" approved ) >/dev/null 2>&1
  return 0
}

# D8: review-evidence + 外人占坑 PR → 必须照常投递（PR 是评论对象）
make_item review-evidence deep
rq set "$ID" approved >/dev/null
exec_in_sb "$ID"
check_eq "D8 review-evidence 遇占坑 PR 仍执行（104067b 误杀回归）" \
  "$(cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" TUNNEL_BIN="$SB/bin/tunnel" bash "$RQ" show "$ID" --json | jq -r .state)" "executed"
check_contains "$(cat "$SB/stub/calls/gh-occ.log" 2>/dev/null)" "-X POST" "D8 评论已真实投递"

# D9: probe-salvage + 外人占坑 PR → 必须拦截（占坑语义保留）
make_item probe-salvage probe
rq set "$ID" approved >/dev/null
exec_in_sb "$ID"
check_ne "D9 probe-salvage 遇占坑 PR 不执行" \
  "$(cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" TUNNEL_BIN="$SB/bin/tunnel" bash "$RQ" show "$ID" --json | jq -r .state)" "executed"
sb_done

# ================= D 组续：stalled-occupier 停摆豁免（卡 t_b8ef4f58） =================
echo "===== D 组续：stalled-occupier 停摆豁免（execute/notify 孪生门） ====="

# 可参数化占坑 gh stub：OCC_LIST_JSON（pr list 输出）/ OCC_VIEW_JSON[_<PR号>]（pr view 输出文件）
# / OCC_VIEW_RC（pr view 失败注入）；其余行为同 bin/gh 默认 stub
sb_new true
cat > "$SB/bin/gh-occupier-param" <<'STUB'
#!/bin/bash
# 参数化占坑 stub（卡 t_b8ef4f58 停摆豁免用例）：
#   OCC_LIST_JSON         → `pr list` 输出（缺省恒 [{"number":99999}]，外人占坑 PR）
#   OCC_VIEW_JSON         → `pr view` 输出文件路径（缺省回 {}）
#   OCC_VIEW_JSON_<PR号>  → 按 PR 号覆盖输出文件（多占用 PR 用例）
#   OCC_VIEW_RC           → 非空则 `pr view` 以该 rc 失败（fail-closed 注入）
LOG_DIR="${STUB_STATE:?STUB_STATE required}/calls"; mkdir -p "$LOG_DIR"
printf '=== gh %s\n' "$*" >> "$LOG_DIR/gh-occ.log"
for a in "$@"; do
  case "$a" in body=@*) f="${a#body=@}"; [ -f "$f" ] && { printf -- '--- body-file %s ---\n' "$f"; cat "$f"; printf '\n'; } >> "$LOG_DIR/gh-occ.log" ;; esac
done
case "$*" in
  *"issue view"*)
    echo '{"state":"OPEN"}' ;;
  *"pr list"*)
    if [[ -n "${OCC_LIST_JSON:-}" ]]; then printf '%s\n' "$OCC_LIST_JSON"; else echo '[{"number":99999}]'; fi ;;
  *"pr view"*)
    if [[ -n "${OCC_VIEW_RC:-}" ]]; then
      echo "gh-occupier-param: forced pr view failure" >&2
      exit "${OCC_VIEW_RC}"
    fi
    _vf="${OCC_VIEW_JSON:-}"
    if [[ $# -ge 3 ]]; then
      _by_num="OCC_VIEW_JSON_${3}"
      [[ -n "${!_by_num:-}" ]] && _vf="${!_by_num}"
    fi
    if [[ -n "$_vf" && -f "$_vf" ]]; then cat "$_vf"; else echo '{}'; fi
    ;;
  *"comments?per_page"*)
    echo '[]' ;;
  *"-X POST"*)
    echo '{"html_url":"https://github.com/NousResearch/hermes-agent/issues/1#issuecomment-1"}' ;;
  *)
    echo '{}' ;;
esac
exit 0
STUB
chmod +x "$SB/bin/gh-occupier-param"

exec_occ() { # <id> [KEY=VAL...] —— execute.sh 走参数化占坑 stub（OCC_* 经 env 参数注入）
  local id="$1"; shift
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" \
      NOTIFY_LOCK="$SB/locks/notify2" TUNNEL_BIN="$SB/bin/tunnel" GH_BIN="$SB/bin/gh-occupier-param" \
      HERMES_BIN="$SB/bin/hermes" NOTIFY_SEND_LAST="$SB/send-last.json" NOTIFY_DRY_RUN=true \
      APPROVED_LOG="$SB/approved.log" STUB_STATE="$SB/stub" "$@" \
      bash "$MARTIN/scripts/approval/execute.sh" "$id" approved ) >/dev/null 2>&1
  return 0
}
notify_occ() { # <id> [KEY=VAL...] —— notify approve 走参数化占坑 stub（缺省非 dry 使轻复验真实执行）
  local id="$1"; shift
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" NOTIFY_LOCK="$SB/locks/notify" \
      TUNNEL_BIN="$SB/bin/tunnel" HERMES_BIN="$SB/bin/hermes" NOTIFY_SEND_LAST="$SB/send-last.json" \
      NOTIFY_DRY_RUN="${NDRY:-false}" GH_BIN="$SB/bin/gh-occupier-param" STUB_STATE="$SB/stub" "$@" \
      bash "$NOTIFY" approve "$id" ) >/dev/null 2>&1
  return 0
}
rq_state() { # <id> → 沙箱队列状态
  ( cd "$SB" && env CONTRIB_DATA_DIR="$SB/contrib-data" RQ_LOCKDIR="$SB/locks/rq" TUNNEL_BIN="$SB/bin/tunnel" \
      bash "$RQ" show "$1" --json | jq -r .state )
}
occ_view_json() { # <file> <commit_iso> <updated_iso> [作者login] [作者评论iso] [三方login] [三方评论iso]
  local f="$1" c="$2" u="$3" login="${4:-occupier-nanami}" oc="${5:-}" p3="${6:-}" c3="${7:-}"
  jq -n --arg c "$c" --arg u "$u" --arg login "$login" --arg oc "$oc" --arg p3 "$p3" --arg c3 "$c3" '
    {author: {login: $login}, updatedAt: $u,
     commits: (if $c == "" then [] else [{committedDate: $c}] end),
     comments: ([if $oc == "" then empty else {author: {login: $login}, createdAt: $oc} end]
      + [if $p3 == "" then empty else {author: {login: $p3}, createdAt: $c3} end])}' > "$f"
}
EXEC_LOG="$SB/contrib-data/logs/approval-execute.log"
NOTIFY_LOG="$SB/contrib-data/logs/notify.log"
occ_reset_logs() { # 用例间隔离：stub 调用账与域日志清零（防跨用例累积假阳/假阴）
  [[ -d "$(dirname "$EXEC_LOG")" ]] && : > "$EXEC_LOG"
  [[ -d "$(dirname "$NOTIFY_LOG")" ]] && : > "$NOTIFY_LOG"
  local _f
  for _f in gh-occ.log hermes.log tunnel.log tunnel-rm.log; do
    [[ -f "$SB/stub/calls/$_f" ]] && : > "$SB/stub/calls/$_f"
  done
  return 0
}

# D10 旧锚放行：作者锚 40 天前（updatedAt 1 天前=被第三方顶新的真实形态）→ 豁免投递
make_item probe-salvage probe
D10_ID="$ID"
rq set "$D10_ID" approved >/dev/null
occ_view_json "$SB/occ-view.json" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
exec_occ "$D10_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "D10 停摆 40 天占用 → 豁免放行（终态 executed）" "$(rq_state "$D10_ID")" "executed"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "stalled-occupier 豁免：#99999" "D10 豁免 note 落 execute 日志（可 grep）"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "stalled-occupier 豁免放行" "D10 复验放行行落日志"
check_contains "$(cat "$SB/stub/calls/gh-occ.log" 2>/dev/null)" "-X POST" "D10 评论已真实投递"

# D11 新锚拦截：作者锚 3 天前（活跃占坑）→ 维持判死，reason 原文案
make_item probe-salvage probe
D11_ID="$ID"
rq set "$D11_ID" approved >/dev/null
occ_view_json "$SB/occ-view.json" "$(date -v-3d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
exec_occ "$D11_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "D11 活跃占坑 3 天 → 维持拦截（终态 failed）" "$(rq_state "$D11_ID")" "failed"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "已有在途 PR（ 99999 ）占坑" "D11 reason 含原占坑文案（一字不改）"
check_not_contains "$(cat "$SB/stub/calls/gh-occ.log" 2>/dev/null)" "-X POST" "D11 未投递"

# D12 gh 取证失败 → fail-closed 拦截，reason 可诊断
make_item probe-salvage probe
D12_ID="$ID"
rq set "$D12_ID" approved >/dev/null
occ_view_json "$SB/occ-view.json" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
exec_occ "$D12_ID" "OCC_VIEW_JSON=$SB/occ-view.json" "OCC_VIEW_RC=3"
check_eq "D12 gh pr view 失败 → fail-closed 拦截" "$(rq_state "$D12_ID")" "failed"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "取证失败（rc=3），占坑判定 fail-closed" "D12 fail-closed reason 可诊断"
check_not_contains "$(cat "$SB/stub/calls/gh-occ.log" 2>/dev/null)" "-X POST" "D12 未投递"

# D13 回归锚（锁死「不得回退 updatedAt 口径」）：commit 50 天前 + 作者本人评论 40 天前 + 第三方评论 1 天前
# （updatedAt 被顶到 1 天前）→ 锚=40 天前仍放行；第三方评论与 updatedAt 均不作锚
make_item probe-salvage probe
D13_ID="$ID"
rq set "$D13_ID" approved >/dev/null
occ_view_json "$SB/occ-view.json" "$(date -v-50d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')" \
  "occupier-nanami" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "reviewer-x" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
exec_occ "$D13_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "D13 第三方评论顶新 updatedAt + 作者锚 40 天 → 仍放行（updatedAt 口径回归锚）" "$(rq_state "$D13_ID")" "executed"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "stalled-occupier 豁免：#99999" "D13 豁免 note 落日志"

# D14 混合占用：一停摆（99999）一活跃（99998）→ 任一活跃即判死，原文案含两个 PR
make_item probe-salvage probe
D14_ID="$ID"
rq set "$D14_ID" approved >/dev/null
occ_view_json "$SB/occ-view-99999.json" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_view_json "$SB/occ-view-99998.json" "$(date -v-3d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
exec_occ "$D14_ID" "OCC_LIST_JSON=[{\"number\":99999},{\"number\":99998}]" \
  "OCC_VIEW_JSON_99999=$SB/occ-view-99999.json" "OCC_VIEW_JSON_99998=$SB/occ-view-99998.json"
check_eq "D14 一停一活 → 维持判死" "$(rq_state "$D14_ID")" "failed"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "已有在途 PR（ 99999, 99998 ）占坑" "D14 原文案含全部占用 PR"

# D15 既无 commit 也无作者评论 → 锚不可算 fail-closed
make_item probe-salvage probe
D15_ID="$ID"
rq set "$D15_ID" approved >/dev/null
occ_view_json "$SB/occ-view.json" "" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')" "occupier-nanami" "" "reviewer-x" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
exec_occ "$D15_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "D15 无 commit 无作者评论 → fail-closed 拦截" "$(rq_state "$D15_ID")" "failed"
check_contains "$(cat "$EXEC_LOG" 2>/dev/null)" "既无 commit 也无作者评论（停摆锚不可算）" "D15 reason 可诊断"
sb_done

# ---- notify 发卡路孪生用例（approve 轻复验；NDRY=false 使轻复验真实执行） ----
sb_new true
cat > "$SB/bin/gh-occupier-param" <<'STUB'
#!/bin/bash
LOG_DIR="${STUB_STATE:?STUB_STATE required}/calls"; mkdir -p "$LOG_DIR"
printf '=== gh %s\n' "$*" >> "$LOG_DIR/gh-occ.log"
case "$*" in
  *"issue view"*)
    echo '{"state":"OPEN"}' ;;
  *"pr list"*)
    if [[ -n "${OCC_LIST_JSON:-}" ]]; then printf '%s\n' "$OCC_LIST_JSON"; else echo '[{"number":99999}]'; fi ;;
  *"pr view"*)
    if [[ -n "${OCC_VIEW_RC:-}" ]]; then
      echo "gh-occupier-param: forced pr view failure" >&2
      exit "${OCC_VIEW_RC}"
    fi
    _vf="${OCC_VIEW_JSON:-}"
    if [[ $# -ge 3 ]]; then
      _by_num="OCC_VIEW_JSON_${3}"
      [[ -n "${!_by_num:-}" ]] && _vf="${!_by_num}"
    fi
    if [[ -n "$_vf" && -f "$_vf" ]]; then cat "$_vf"; else echo '{}'; fi
    ;;
  *"comments?per_page"*)
    echo '[]' ;;
  *"-X POST"*)
    echo '{"html_url":"https://github.com/NousResearch/hermes-agent/issues/1#issuecomment-1"}' ;;
  *)
    echo '{}' ;;
esac
exit 0
STUB
chmod +x "$SB/bin/gh-occupier-param"
NOTIFY_LOG="$SB/contrib-data/logs/notify.log"   # 沙箱已换新，重钉日志路径（EXEC_LOG 同理）
EXEC_LOG="$SB/contrib-data/logs/approval-execute.log"
make_item probe-salvage probe
N1_ID="$ID"
occ_view_json "$SB/occ-view.json" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
notify_occ "$N1_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "N1 notify 停摆 40 天占用 → 豁免发卡（状态不被置 rejected）" "$(rq_state "$N1_ID")" "awaiting-approval"
check_eq "N1 审批卡真实推送 1 次（hermes stub 记账）" "$(stub_count hermes 'contrib L2 审批')" "1"
check_eq "N1 审批页部署 1 次（tunnel stub 记账）" "$(stub_count tunnel 'drops approve')" "1"
check_contains "$(cat "$NOTIFY_LOG" 2>/dev/null)" "stalled-occupier 豁免：#99999" "N1 豁免 note 落 notify 日志（可 grep）"

make_item probe-salvage probe
N2_ID="$ID"
occ_view_json "$SB/occ-view.json" "$(date -v-3d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
notify_occ "$N2_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "N2 notify 活跃占坑 3 天 → 置 rejected" "$(rq_state "$N2_ID")" "rejected"
check_eq "N2 零审批卡零审批页" "$(stub_count tunnel 'drops approve')" "0"
check_eq "N2 零审批卡推送" "$(stub_count hermes 'contrib L2 审批')" "0"
check_contains "$(cat "$NOTIFY_LOG" 2>/dev/null)" "已被 PR 99999 占坑" "N2 原判死文案一字不改（占坑）"
check_contains "$(cat "$SB/contrib-data/events.jsonl" 2>/dev/null)" "premise-dead" "N2 premise-dead 事件入账"

make_item probe-salvage probe
N3_ID="$ID"
occ_view_json "$SB/occ-view.json" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
notify_occ "$N3_ID" "OCC_VIEW_JSON=$SB/occ-view.json" "OCC_VIEW_RC=1"
check_eq "N3 notify gh 取证失败 → fail-closed 置 rejected" "$(rq_state "$N3_ID")" "rejected"
check_eq "N3 零审批页（不发卡不误判）" "$(stub_count tunnel 'drops approve')" "0"
check_contains "$(cat "$NOTIFY_LOG" 2>/dev/null)" "取证失败（rc=1），占坑判定 fail-closed" "N3 fail-closed reason 落日志可诊断"
check_contains "$(cat "$SB/contrib-data/events.jsonl" 2>/dev/null)" "fail-closed" "N3 事件注明 fail-closed（不误报 premise 死亡）"

make_item probe-salvage probe
N4_ID="$ID"
occ_view_json "$SB/occ-view.json" "$(date -v-50d '+%Y-%m-%dT%H:%M:%SZ')" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')" \
  "occupier-nanami" "$(date -v-40d '+%Y-%m-%dT%H:%M:%SZ')" "reviewer-x" "$(date -v-1d '+%Y-%m-%dT%H:%M:%SZ')"
occ_reset_logs
notify_occ "$N4_ID" "OCC_VIEW_JSON=$SB/occ-view.json"
check_eq "N4 notify 第三方评论顶新 updatedAt + 作者锚 40 天 → 仍发卡" "$(rq_state "$N4_ID")" "awaiting-approval"
check_eq "N4 审批卡推送 1 次" "$(stub_count hermes 'contrib L2 审批')" "1"
check_contains "$(cat "$NOTIFY_LOG" 2>/dev/null)" "stalled-occupier 豁免" "N4 豁免 note 落 notify 日志"
sb_done

# ================= C 组：静态门 + 生产零触碰 =================
echo "===== C 组：静态门 + 生产零触碰 ====="

FULLWIDTH_HITS="$( {
  perl -ne 'print "'"$0"'" . ":$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[（）：；，「」｜。？！【】、]/' "$0"
  perl -ne 'print "'"$COLLECT"'" . ":$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[（）：；，「」｜。？！【】、]/' "$COLLECT"
  perl -ne 'print "'"$EXECUTE"'" . ":$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[（）：；，「」｜。？！【】、]/' "$EXECUTE"
  perl -ne 'print "'"$NOTIFY"'" . ":$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[（）：；，「」｜。？！【】、]/' "$NOTIFY"
  perl -ne 'print "'"$RQ"'" . ":$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[（）：；，「」｜。？！【】、]/' "$RQ"
} )"
check_eq "knowledge 盲区门: \$var 紧跟全角标点零命中" "$(printf '%s' "$FULLWIDTH_HITS" | grep -c . || true)" "0"

SYNTAX_BAD=0
for f in "$RQ" "$NOTIFY" "$COLLECT" "$EXECUTE" "$0"; do
  bash -n "$f" 2>/dev/null || { say_fail "bash -n $f" "语法错误"; SYNTAX_BAD=1; }
done
(( SYNTAX_BAD == 0 )) && say_pass "bash -n 全部新/改脚本通过"

# refresh-branch（卡 t_2b06fd69）静态门：卡面 falsify 锚 = execute.sh 含 force 字样的行恒 =1
# （force 能力不得从 refresh 分支扩散到 push-only/build-and-push 路）；闸默认 false 亦锁死。
check_eq "refresh 门: execute.sh 含 force 字样的行恒 1（falsify 锚）" \
  "$(grep -c -- '--force' "$EXECUTE" 2>/dev/null | tr -d ' ')" "1"
# 默认值锁死判据 =「带 'false' 缺省的调用点数 == 调用点总数」（空集不算在位）。
# 原判据写死 ==1，而卡 t_fc3f1e9f 的 refresh 豁免修复合法地新增了第二个调用点
# （execute.sh 的 MODE 判定 + 占坑豁免谓词）⇒ 断言失真为红；且写死计数对新增调用点
# 恒脆（每加一处就误报）。逐调用点对齐才既保「缺省 false 在位」语义又不误伤。
# 红队 F3（2026-09-14）：总数侧原用单引号字面量匹配（`cfg '\.allow_own_pr_refresh'`），
# 双引号写法 `cfg ".allow_own_pr_refresh"` 恒不计入 ⇒ 该形态的新增调用点逃逸。
# 改用引号字符类 ["'] 同时覆盖两种写法（本班实证：加一条双引号调用点，旧式恒 2、新式 3）。
check_eq "refresh 门: allow_own_pr_refresh 缺省 false（全部调用点默认值在位）" \
  "$(grep -c "cfg '.allow_own_pr_refresh' 'false'" "$EXECUTE" 2>/dev/null | tr -d ' ')" \
  "$(grep -cE "cfg [\"']\.allow_own_pr_refresh[\"']" "$EXECUTE" 2>/dev/null | tr -d ' ')"

check_eq "plist StartInterval=90" "$(defaults read "$PLIST" StartInterval 2>/dev/null)" "90"
check_eq "plist RunAtLoad=false" "$(defaults read "$PLIST" RunAtLoad 2>/dev/null)" "0"
check_eq "plist AbandonProcessGroup=true（launchd 进程组收割教训）" "$(defaults read "$PLIST" AbandonProcessGroup 2>/dev/null)" "1"
check_eq "plist StandardErrorPath 指向 contrib-data/logs" "$(defaults read "$PLIST" StandardErrorPath 2>/dev/null | grep -c '/contrib-data/logs/' )" "1"

assert_production_untouched
echo "===== 汇总 ====="
echo "PASS=${PASS} FAIL=${FAIL}${FAILED_NAMES:+ FAILED:${FAILED_NAMES}}"
sb_done
rm -rf "$BASELINE"
if (( FAIL == 0 )); then
  echo "##SUMMARY {\"suite\":\"approval\",\"total\":$((PASS + FAIL)),\"passed\":${PASS},\"failed\":0}"
  exit 0
fi
echo "##SUMMARY {\"suite\":\"approval\",\"total\":$((PASS + FAIL)),\"passed\":${PASS},\"failed\":${FAIL}}"
exit 1
