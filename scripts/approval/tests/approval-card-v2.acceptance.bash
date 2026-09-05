#!/bin/bash
# 红队验收测试：T4 审批卡 v2 + 人读页生成（契约 C4/C5/C6；场景 5.P1 / 5.P2 / 5.P3；2.P2 源序半边）
# 仅依据 state.md「## 设计文档 T4」「## 契约规约 C4/C5/C6」「## 验收场景 5」编写。
# 不读蓝队本次新写的实现代码；黑盒驱动 notify.sh/rq.sh 既有 env seam（CONTRIB_DATA_DIR /
# NOTIFY_DRY_RUN / HERMES_BIN / TUNNEL_BIN / NOTIFY_LOCK / RQ_LOCKDIR / NOTIFY_SEND_LAST）。
#
# target: scripts/approval/tests/approval-card-v2.acceptance.bash
# 运行：bash scripts/approval/tests/approval-card-v2.acceptance.bash
#
# 硬约束自证：零真实微信（HERMES_BIN=stub，dry-run 只打印）、零真实部署（dry-run 登记合成 URL /
# 非 dry 走 TUNNEL_BIN=stub）、零 gh 调用（本文件不发 gh）。
# 断言全部硬断言：失败计 FAIL 并打印期望/实际差异；末尾输出 PASS <n> checks；有 FAIL 则 exit 1。
#
# 跨系统共享种子（与 tunnel-cli 侧 *.acceptance.test.ts 同源字面量）：
#   slug=a3k7tq9m2z / code=K3MT9Q / comment=红队种子意见：TTL 复验通过，占坑无新冲突

set -uo pipefail
# stdin 守卫：本脚本自身不读 stdin；避免子进程（stub cat / gh 管线）继承未关闭的
# 交互 stdin 而阻塞（run2 实证：TTL 通过后 gh 调用变深即挂）。
exec 0</dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 定位 martin 根（兼容最终落位 scripts/approval/tests/ 与暂存区两种深度）──
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
APPROVAL_IMPL_DIR="${APPROVAL_IMPL_DIR:-$SCRIPT_DIR/..}"   # 最终落位 = scripts/approval
# 暂存区运行时回退到仓内标准位置（静态门作用对象=仓内 scripts/approval/ 新 bash 面）
if [[ ! -f "$APPROVAL_IMPL_DIR/collect.sh" && -f "$MARTIN_ROOT/scripts/approval/collect.sh" ]]; then
  APPROVAL_IMPL_DIR="$MARTIN_ROOT/scripts/approval"
fi
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
check_eq() { # <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1" "expected=[$2] actual=[$3]"; fi
}
check_contains() { # <desc> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else fail "$1" "expected to contain [$2]"; fi
}
check_not_contains() { # <desc> <needle> <haystack>
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else fail "$1" "must NOT contain [$2]"; fi
}
check_match() { # <desc> <ere> <value>
  if [[ "$3" =~ $2 ]]; then ok "$1"; else fail "$1" "value does not match /$2/: [$3]"; fi
}

# pinned diff（knowledge patterns.md:321：第三方 diff 遮蔽导致假绿）
DIFF_BIN="/usr/bin/diff"
[[ -x "$DIFF_BIN" ]] || DIFF_BIN="$(command -v diff)"

# ── 沙箱 ──
SB="$(mktemp -d "${TMPDIR:-/tmp}/approval-card-redteam.XXXXXX")"
CONTRIB="$SB/data"
STUBS="$SB/stubs"
mkdir -p "$CONTRIB/pending" "$CONTRIB/logs" "$STUBS"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

# ── stub：hermes send（计数，零真实微信）──
cat > "$STUBS/hermes" <<'STUB'
#!/bin/bash
LOG="${HERMES_CALL_LOG:?}"
{ printf '=== hermes'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) [[ -f "$2" ]] && { printf '--- sent body ---\n'; cat "$2"; printf '\n'; } >> "$LOG"; shift 2 ;;
    *) shift ;;
  esac
done
printf '{"success":true}' > "${NOTIFY_SEND_LAST:?}"
exit 0
STUB

# ── stub：tunnel（记录 argv；drops approve 打印部署行；rm 记录）──
cat > "$STUBS/tunnel" <<'STUB'
#!/bin/bash
LOG="${TUNNEL_CALL_LOG:?}"
{ printf '=== tunnel'; printf ' %s' "$@"; printf '\n'; } >> "$LOG"
cmd="${1:-}"; sub="${2:-}"
if [[ "$cmd" == "drops" && "$sub" == "approve" ]]; then
  slug=""
  prev=""
  for a in "$@"; do
    [[ "$prev" == "--name" || "$prev" == "-n" ]] && slug="$a"
    prev="$a"
  done
  echo "✓ 已部署 → https://d.stringzhao.life/${slug}"
  exit 0
fi
if [[ "$cmd" == "rm" ]]; then exit 0; fi
echo "tunnel-stub: unsupported args: $*" >&2
exit 64
STUB

cat > "$STUBS/osascript" <<'STUB'
#!/bin/bash
printf '=== osascript %s\n' "$*" >> "${OSASCRIPT_CALL_LOG:?}"
exit 0
STUB

cat > "$STUBS/pgrep-miss" <<'STUB'
#!/bin/bash
exit 1
STUB

chmod +x "$STUBS/hermes" "$STUBS/tunnel" "$STUBS/osascript" "$STUBS/pgrep-miss"

# ── 环境 seam 全指向沙箱 ──
export MARTIN_DIR="$MARTIN_ROOT"
export CONTRIB_DATA_DIR="$CONTRIB"
export NOTIFY_LOCK="$SB/notify.lock"
export RQ_LOCKDIR="$SB/rq.lock"
export NOTIFY_SEND_LAST="$SB/send-last.json"
export HERMES_BIN="$STUBS/hermes"
export TUNNEL_BIN="$STUBS/tunnel"
export OSASCRIPT_BIN="$STUBS/osascript"
export GATEWAY_PROBE_BIN="$STUBS/pgrep-miss"
export HERMES_CALL_LOG="$SB/hermes-calls.log"
export TUNNEL_CALL_LOG="$SB/tunnel-calls.log"
export OSASCRIPT_CALL_LOG="$SB/osascript-calls.log"
export NOTIFY_DRY_RUN="true"
: > "$HERMES_CALL_LOG"
: > "$TUNNEL_CALL_LOG"

write_config() { # approval_interactive <bool>
  jq -n --argjson interactive "$1" '{notify_dry_run: true, notify_target: "wechat:redteam",
    approval_interactive: $interactive, approval_ttl_hours: 48, max_approval_pushes_per_day: 10,
    max_alert_pushes_per_day: 3, notify_min_interval_min: 20}' > "$CONTRIB/config.json"
}
write_config true

bash "$RQ" init >/dev/null

# ── 种子：两条待决项（A=deep lane，B=probe lane）──
DRAFT_A="$CONTRIB/pending/rq-20260905-103901.md"
cat > "$DRAFT_A" <<'DRAFT'
<!-- PR-DRAFT id=rq-20260905-103901 lane=deep generator=run-deepcheck -->
## Verdict request (evidence authority)

Premise 1: delivery_outcome 仅遥测不落库。
Evidence: state.db schema 直查无 delivery_outcome 列（红队种子意见：TTL 复验通过，占坑无新冲突）。
DRAFT

DRAFT_B="$CONTRIB/pending/rq-20260905-103902.md"
cat > "$DRAFT_B" <<'DRAFT'
<!-- PR-DRAFT id=rq-20260905-103902 lane=probe generator=probe -->
## Probe salvage note

stale_session 计数 8/8 与 poll 全绿并存（34h 龄边界样本）。
DRAFT

ID_A="$(bash "$RQ" add --issue 103901 --disposition review-evidence --score 13 \
  --title "delivery_outcome 遥测断裂修复" --lane deep \
  --premises-json '[{"claim":"delivery_outcome 仅遥测不落库","evidence":"state.db schema 直查无该列"}]')"
ID_B="$(bash "$RQ" add --issue 103902 --disposition probe-salvage --score 9 \
  --title "cron 投递 stale_session 边界取证" --lane probe \
  --premises-json '[{"claim":"无入站 34h 后 cron 必败而 poll 全绿","evidence":"send_result 8/8 stale_session 零误判"}]')"
bash "$RQ" set-draft "$ID_A" "$DRAFT_A" >/dev/null
bash "$RQ" set-draft "$ID_B" "$DRAFT_B" >/dev/null
bash "$RQ" set "$ID_A" awaiting-approval >/dev/null
bash "$RQ" set "$ID_B" awaiting-approval >/dev/null

# ── 卡片提取（从 dry-run stdout 抽卡片文本块，落盘供 fs-grep）──
extract_card() { # $1=raw → stdout 卡片
  awk '/^🟡【L2 审批 #/{found=1} found { if ($0 ~ /^─+$/) exit; print }' <<<"$1"
}

printf '=== 场景5：审批卡 v2 dry-run 生成（项 A，deep lane）===\n'
OUT_A="$(bash "$NOTIFY" approve "$ID_A" 2>"$SB/approve-a.err")"
RC_A=$?
CARD_FILE_A="$SB/card-a.txt"
extract_card "$OUT_A" > "$CARD_FILE_A"
CARD_A="$(cat "$CARD_FILE_A")"

L1_A="$(sed -n '1p' <<<"$CARD_A")"
L2_A="$(sed -n '2p' <<<"$CARD_A")"
L3_A="$(sed -n '3p' <<<"$CARD_A")"
L4_A="$(sed -n '4p' <<<"$CARD_A")"
L5_A="$(sed -n '5p' <<<"$CARD_A")"
L6_A="$(sed -n '6p' <<<"$CARD_A")"
NLINES_A="$(grep -c . <<<"$CARD_A" | tr -d ' ')"

# 场景5.P1（driver: fs-grep 审批卡 dry-run 输出）
check_eq "5.P1: notify.sh approve dry-run 退出码 0" "0" "$RC_A"
if [[ -s "$CARD_FILE_A" ]]; then
  ok "5.P1: dry-run 输出可提取审批卡文本（fs-grep 载体 ${CARD_FILE_A}）"
else
  fail "5.P1: dry-run 输出可提取审批卡文本" "card 为空；approve stderr=[$(cat "$SB/approve-a.err" 2>/dev/null)] raw=[$OUT_A]"
fi
check_match "C6 行1: 🟡【L2 审批 #<id>】前缀" "^🟡【L2 审批 #${ID_A}】." "$L1_A"
# <disposition 表述>：按 disposition 渲染的人读表述（不锚英文字面量），但绝不允许旧硬编码「<disp> 评论」形态
EXPR_A="${L1_A#*】}"
check_match "C6 行1: disposition 表述非空" ".+" "$EXPR_A"
check_not_contains "5.P3(硬编码修正①): 行1 不是旧硬编码「<disp> 评论」形态" "review-evidence 评论" "$L1_A"
check_match "C6 行2: 目标行完整形状" "^目标: NousResearch/hermes-agent#103901 · 13/15 · strategist\+红队双审$" "$L2_A"
check_eq "C6 行3: 概要 = title 原文（title 未超 80）" "概要: delivery_outcome 遥测断裂修复" "$L3_A"
check_match "C6 行4: 点开即批行形状（page-url?key=<code>）" \
  "^✅ 点开即批（短码已自动填入）: https://d\.stringzhao\.life/[a-z0-9]{10}\?key=[a-km-np-z2-9]{6}$" "$L4_A"
check_match "C6 行5: 截止行形状（MM-DD HH:MM 前有效（48h））" \
  "^⏱ [0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} 前有效（48h），超时自动搁置$" "$L5_A"
check_eq "C6 行6: 微信备用降级指令逐字" "💬 微信备用: 批/否 #${ID_A}；改 #${ID_A}: 意见" "$L6_A"
check_eq "C6 行序固定: 卡片恰 6 行" "6" "$NLINES_A"

# 场景5.P2：截止时间字段值 + 降级指令均非空非占位符
DL="$(sed -E 's/^⏱ ([0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}) 前有效.*/\1/' <<<"$L5_A")"
DL_EPOCH="$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y)-$DL" "+%s" 2>/dev/null || true)"
NOW_EPOCH="$(date +%s)"
if [[ "$DL_EPOCH" =~ ^[0-9]+$ && "$NOW_EPOCH" =~ ^[0-9]+$ ]]; then
  DIFF48=$(( DL_EPOCH - NOW_EPOCH - 172800 ))
  if (( DIFF48 < -600 || DIFF48 > 600 )); then
    fail "5.P2: 截止时间 = 发卡时刻 + 48h（±10min）" "deadline=$DL delta=${DIFF48}s"
  else
    ok "5.P2: 截止时间 = 发卡时刻 + 48h（±10min），delta=${DIFF48}s"
  fi
else
  fail "5.P2: 截止时间字段值可解析且换算 epoch" "无法从行5提取/解析 MM-DD HH:MM: [$(sed -n '5p' <<<"$CARD_A")] raw_dl=[$DL]"
fi
check_contains "5.P2: 降级微信文本指令存在" "批/否 #${ID_A}" "$CARD_A"
check_contains "5.P2: 降级改意见指令存在" "改 #${ID_A}: 意见" "$CARD_A"
check_not_contains "5.P2: 截止时间非占位符" "MM-DD" "$CARD_A"

# 场景5.P1：卡片 slug/key == 登记值
CARD_SLUG_A="$(sed -E 's#.*life/([a-z0-9]{10})\?key=.*#\1#' <<<"$L4_A")"
CARD_CODE_A="$(sed -E 's#.*\?key=([a-km-np-z2-9]{6})$#\1#' <<<"$L4_A")"
REG_SLUG_A="$(jq -r --arg id "$ID_A" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$CONTRIB/ready-queue.json")"
REG_CODE_A="$(jq -r --arg id "$ID_A" '.items[] | select(.id == $id) | .tunnel.code // ""' "$CONTRIB/ready-queue.json")"
check_eq "5.P1: 卡片 slug == rq 登记 .tunnel.slug" "$REG_SLUG_A" "$CARD_SLUG_A"
check_eq "5.P1: 卡片 key == rq 登记 .tunnel.code" "$REG_CODE_A" "$CARD_CODE_A"

# C5 schema：.tunnel 六键齐 + code 非空 + url 合成值
T_KEYS="$(jq -r --arg id "$ID_A" '.items[] | select(.id == $id) | .tunnel | keys | sort | join(",")' "$CONTRIB/ready-queue.json")"
check_eq "C5: .tunnel schema 六键齐（sorted）" "code,deployed_at,deployed_epoch,removed_at,slug,url" "$T_KEYS"
REG_URL_A="$(jq -r --arg id "$ID_A" '.items[] | select(.id == $id) | .tunnel.url // ""' "$CONTRIB/ready-queue.json")"
check_eq "C5/T4 dry-run 登记语义: url = 合成值 https://d.stringzhao.life/<slug>" \
  "https://d.stringzhao.life/${REG_SLUG_A}" "$REG_URL_A"
DEPLOYED_AT_A="$(jq -r --arg id "$ID_A" '.items[] | select(.id == $id) | .tunnel.deployed_at // ""' "$CONTRIB/ready-queue.json")"
DEPLOYED_EP_A="$(jq -r --arg id "$ID_A" '.items[] | select(.id == $id) | .tunnel.deployed_epoch // 0' "$CONTRIB/ready-queue.json")"
check_match "C5: deployed_at 非空" ".+" "$DEPLOYED_AT_A"
if [[ "$DEPLOYED_EP_A" =~ ^[0-9]+$ && "$DEPLOYED_EP_A" -gt 0 ]]; then
  ok "C5: deployed_epoch 为正整数"
else
  fail "C5: deployed_epoch 为正整数" "actual=[$DEPLOYED_EP_A]"
fi

# C4 字符集：slug [a-z0-9]{10}；code [a-km-np-z2-9]{6}
check_match "C4: slug 匹配 [a-z0-9]{10}" "^[a-z0-9]{10}$" "$REG_SLUG_A"
check_match "C4: code 匹配 [a-km-np-z2-9]{6}（去 0/o/1/l）" "^[a-km-np-z2-9]{6}$" "$REG_CODE_A"

# dry-run 零副作用：零真实发送 + 零真实部署调用
HERMES_N="$(grep -c '=== hermes' "$HERMES_CALL_LOG" 2>/dev/null || true)"; HERMES_N="${HERMES_N:-0}"
TUNNEL_N="$(grep -c '=== tunnel' "$TUNNEL_CALL_LOG" 2>/dev/null || true)"; TUNNEL_N="${TUNNEL_N:-0}"
check_eq "T4 dry-run 登记语义: hermes send 调用 0 次" "0" "$HERMES_N"
check_eq "T4 dry-run 登记语义: tunnel deploy 调用 0 次（合成 URL 登记）" "0" "$TUNNEL_N"

# ── B1 人读页生成 ──
printf '=== B1 人读页生成（pending/*page.md）===\n'
# CONTRACT_AMBIGUOUS：T4 行文为「pending/<id>.page.md」，机制规则为「draft 路径 + .page.md 后缀」
# （= <id>.md.page.md）。两者取一未冻结——此处断言 pending 下恰新增一个 *page.md 产物，
# 内容断言不受文件名分歧影响。
PAGE_COUNT="$(find "$CONTRIB/pending" -maxdepth 1 -name '*page.md' -type f | wc -l | tr -d ' ')"
check_eq "B1: pending 下恰生成 1 个人读页 *page.md" "1" "$PAGE_COUNT"
PAGE_A="$(find "$CONTRIB/pending" -maxdepth 1 -name '*page.md' -type f | head -1)"
if [[ -n "$PAGE_A" && -s "$PAGE_A" ]]; then
  ok "B1: 人读页非空（${PAGE_A}）"
else
  fail "B1: 人读页非空" "page file=[$PAGE_A]"
fi
PAGE_TEXT="$(cat "$PAGE_A" 2>/dev/null)"
IDX_FENCE="$(grep -n '```interactive' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_VERDICT="$(grep -n 'id: verdict' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_OPT_OK="$(grep -n '^  - 批准$' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_OPT_NO="$(grep -n '^  - 否决$' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_OPT_RV="$(grep -n '^  - 需修改$' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_COMMENT="$(grep -n 'id: comment' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_BLUF="$(grep -n 'delivery_outcome 遥测断裂修复' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_EVID="$(grep -n 'delivery_outcome 仅遥测不落库' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
IDX_APPENDIX="$(grep -n 'Verdict request (evidence authority)' <<<"$PAGE_TEXT" | head -1 | cut -d: -f1)"
for pair in "interactive fence|$IDX_FENCE" "id: verdict|$IDX_VERDICT" "选项 批准|$IDX_OPT_OK" "选项 否决|$IDX_OPT_NO" "选项 需修改|$IDX_OPT_RV" "id: comment|$IDX_COMMENT" "BLUF(标题)|$IDX_BLUF" "证据表(premise)|$IDX_EVID" "原文附录|$IDX_APPENDIX"; do
  label="${pair%%|*}"; val="${pair#*|}"
  if [[ "$val" =~ ^[0-9]+$ && "$val" -gt 0 ]]; then ok "B1: 人读页含 ${label}（行 ${val}）"; else fail "B1: 人读页含 ${label}" "未找到（${PAGE_A}）"; fi
done
check_contains "C2/B1: comment 组件为 text 类型" "type: text" "$PAGE_TEXT"
# 三选项顺序（C2 固定顺序，markdown 源行序严格递增）
if [[ "$IDX_OPT_OK" =~ ^[0-9]+$ && "$IDX_OPT_NO" =~ ^[0-9]+$ && "$IDX_OPT_RV" =~ ^[0-9]+$ \
  && "$IDX_OPT_OK" -gt 0 && "$IDX_OPT_NO" -gt "$IDX_OPT_OK" && "$IDX_OPT_RV" -gt "$IDX_OPT_NO" ]]; then
  ok "C2/B1: 三选项顺序 批准→否决→需修改（行序严格递增）"
else
  fail "C2/B1: 三选项顺序 批准→否决→需修改" "ok=$IDX_OPT_OK no=$IDX_OPT_NO revise=$IDX_OPT_RV"
fi
# 场景2.P2 源序半边：决策区 < BLUF < 证据表 < 英文附录（HTML 序由 tunnel-cli 侧覆盖）
if [[ "$IDX_VERDICT" =~ ^[0-9]+$ && "$IDX_BLUF" =~ ^[0-9]+$ && "$IDX_EVID" =~ ^[0-9]+$ && "$IDX_APPENDIX" =~ ^[0-9]+$ \
  && "$IDX_VERDICT" -gt 0 && "$IDX_VERDICT" -lt "$IDX_BLUF" && "$IDX_BLUF" -lt "$IDX_EVID" && "$IDX_EVID" -lt "$IDX_APPENDIX" ]]; then
  ok "场景2.P2(源序): 决策区 < BLUF < 证据表 < 英文附录（v=${IDX_VERDICT}/${IDX_BLUF}/${IDX_EVID}/${IDX_APPENDIX}）"
else
  fail "场景2.P2(源序): 决策区 < BLUF < 证据表 < 英文附录" \
    "verdict=$IDX_VERDICT bluf=$IDX_BLUF evid=$IDX_EVID appendix=$IDX_APPENDIX"
fi
check_contains "B1: 人读页含审核轮次（deep→strategist+红队双审）" "strategist+红队双审" "$PAGE_TEXT"
# 机器稿本体绝不加 fence
if grep -q '```interactive' "$DRAFT_A"; then
  fail "T4: 机器稿本体不加 fence" "draft 被污染"
else
  ok "T4: 机器稿本体不加 fence"
fi
# 机器稿全文逐字保留（逐行 grep -F）
DRAFT_LOST=""
while IFS= read -r dline; do
  [[ -z "$dline" ]] && continue
  [[ "$dline" == "<!--"* ]] && continue   # 头部注释块不要求逐字（附录可保留亦可剥，见 C8 断言在 execute 侧）
  if ! grep -qF -- "$dline" "$PAGE_A"; then DRAFT_LOST+=$'\n'"      lost: $dline"; fi
done < "$DRAFT_A"
if [[ -z "$DRAFT_LOST" ]]; then ok "B1: 机器稿正文逐字进入人读页附录"; else fail "B1: 机器稿正文逐字进入人读页附录" "$DRAFT_LOST"; fi

printf '=== 场景5.P3：两条待决项字段各自取值 + slug/code 相异 ===\n'
OUT_B="$(bash "$NOTIFY" approve "$ID_B" 2>/dev/null)"
CARD_B="$(extract_card "$OUT_B")"
L1_B="$(sed -n '1p' <<<"$CARD_B")"
L2_B="$(sed -n '2p' <<<"$CARD_B")"
L3_B="$(sed -n '3p' <<<"$CARD_B")"
L4_B="$(sed -n '4p' <<<"$CARD_B")"
check_match "5.P3: B 卡行1 前缀 = B 项 id" "^🟡【L2 审批 #${ID_B}】." "$L1_B"
EXPR_B="${L1_B#*】}"
check_match "5.P3: B 卡行1 disposition 表述非空（取自 B 项而非 A 项）" ".+" "$EXPR_B"
check_not_contains "5.P3(硬编码修正①): B 卡行1 不再是硬编码「 评论」后缀" "probe-salvage 评论" "$L1_B"
check_eq "5.P3: B 卡行2 = B 项 issue/score + probe 单轮" \
  "目标: NousResearch/hermes-agent#103902 · 9/15 · strategist 单轮" "$L2_B"
check_eq "5.P3: B 卡行3 = B 项 title" "概要: cron 投递 stale_session 边界取证" "$L3_B"
check_match "5.P3: B 卡行4 形状（URL?key=code）" \
  "^✅ 点开即批（短码已自动填入）: https://d\.stringzhao\.life/[a-z0-9]{10}\?key=[a-km-np-z2-9]{6}$" "$L4_B"
CARD_SLUG_B="$(sed -E 's#.*life/([a-z0-9]{10})\?key=.*#\1#' <<<"$L4_B")"
CARD_CODE_B="$(sed -E 's#.*\?key=([a-km-np-z2-9]{6})$#\1#' <<<"$L4_B")"
REG_SLUG_B="$(jq -r --arg id "$ID_B" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$CONTRIB/ready-queue.json")"
REG_CODE_B="$(jq -r --arg id "$ID_B" '.items[] | select(.id == $id) | .tunnel.code // ""' "$CONTRIB/ready-queue.json")"
check_eq "5.P3: B 卡 slug == B 项登记值" "$REG_SLUG_B" "$CARD_SLUG_B"
check_eq "5.P3: B 卡 code == B 项登记值" "$REG_CODE_B" "$CARD_CODE_B"
if [[ -n "$CARD_SLUG_A" && "$CARD_SLUG_A" != "$CARD_SLUG_B" ]]; then
  ok "5.P3: 两次发卡 slug 互不相同（${CARD_SLUG_A} vs ${CARD_SLUG_B}）"
else
  fail "5.P3: 两次发卡 slug 互不相同" "A=$CARD_SLUG_A B=$CARD_SLUG_B"
fi
if [[ -n "$CARD_CODE_A" && "$CARD_CODE_A" != "$CARD_CODE_B" ]]; then
  ok "5.P3: 两次发卡短码互不相同（${CARD_CODE_A} vs ${CARD_CODE_B}）"
else
  fail "5.P3: 两次发卡短码互不相同" "A=$CARD_CODE_A B=$CARD_CODE_B"
fi
# lane 渲染硬编码修正②：probe 卡不得出现「双审」
check_not_contains "5.P3(硬编码修正②): probe 卡行2 不含双审表述" "红队双审" "$L2_B"
# B 的原文附录逐字（文件名约定 CONTRACT_AMBIGUOUS，按 103902 前缀定位）
PAGE_B="$(find "$CONTRIB/pending" -maxdepth 1 -name '*103902*page.md' -type f | head -1)"
if [[ -n "$PAGE_B" && -s "$PAGE_B" ]]; then
  ok "B1: B 项人读页存在（${PAGE_B}）"
  check_contains "5.P3/B1: B 人读页含 B 原文附录" "stale_session 计数 8/8 与 poll 全绿并存（34h 龄边界样本）。" "$(cat "$PAGE_B")"
else
  fail "B1: B 项人读页存在" "find '*103902*page.md' 为空"
fi

printf '=== 旧模板回退路（approval_interactive=false）===\n'
ID_C="$(bash "$RQ" add --issue 103903 --disposition review-evidence --score 11 \
  --title "granularity per-delivery 去重取证" --lane deep \
  --premises-json '[{"claim":"granularity 去重零回应","evidence":"#77836 锚 08-29 核查"}]' )"
DRAFT_C="$CONTRIB/pending/rq-20260905-103903.md"
printf '<!-- PR-DRAFT id=%s -->\n旧文本卡路回归稿。\n' "$ID_C" > "$DRAFT_C"
bash "$RQ" set-draft "$ID_C" "$DRAFT_C" >/dev/null
bash "$RQ" set "$ID_C" awaiting-approval >/dev/null
write_config false
OUT_C="$(bash "$NOTIFY" approve "$ID_C" 2>/dev/null)"
CARD_C="$(extract_card "$OUT_C")"
check_contains "回退路: 旧卡含微信文本回复指令" "批 #${ID_C}" "$CARD_C"
check_not_contains "回退路: 旧卡不含 ?key= 短码链接" "?key=" "$CARD_C"
T_SLUG_C="$(jq -r --arg id "$ID_C" '.items[] | select(.id == $id) | .tunnel.slug // "null"' "$CONTRIB/ready-queue.json")"
check_eq "回退路: 不做短码部署登记（.tunnel.slug 仍空）" "null" "$T_SLUG_C"
PAGE_C="$(find "$CONTRIB/pending" -name 'rq-20260905-103903*page.md' 2>/dev/null | wc -l | tr -d ' ')"
check_eq "回退路: 不生成人读页" "0" "$PAGE_C"
write_config true

printf '=== 非 dry 路径（TUNNEL_BIN/HERMES_BIN stub，仍零真实外发）===\n'
ID_D="$(bash "$RQ" add --issue 103904 --disposition review-evidence --score 12 \
  --title "非 dry 短码发卡路径" --lane deep \
  --premises-json '[{"claim":"p1","evidence":"e1"}]')"
DRAFT_D="$CONTRIB/pending/rq-20260905-103904.md"
printf '非 dry 路径回归稿正文。\n' > "$DRAFT_D"
bash "$RQ" set-draft "$ID_D" "$DRAFT_D" >/dev/null
bash "$RQ" set "$ID_D" awaiting-approval >/dev/null
NOTIFY_DRY_RUN="false" bash "$NOTIFY" approve "$ID_D" >/dev/null 2>&1
APPROVE_CALLS="$(grep -c 'drops approve' "$TUNNEL_CALL_LOG" 2>/dev/null || true)"; APPROVE_CALLS="${APPROVE_CALLS:-0}"
check_eq "非 dry: tunnel drops approve 恰调用 1 次" "1" "$APPROVE_CALLS"
APPROVE_LINE="$(grep 'drops approve' "$TUNNEL_CALL_LOG" 2>/dev/null | tail -1)"
check_contains "T4: approve 调用带 --name <slug> 参数" "--name" "$APPROVE_LINE"
REG_SLUG_D="$(jq -r --arg id "$ID_D" '.items[] | select(.id == $id) | .tunnel.slug // ""' "$CONTRIB/ready-queue.json")"
check_match "非 dry: 登记 slug 仍为 [a-z0-9]{10} 随机短码型（非 rq id）" "^[a-z0-9]{10}$" "$REG_SLUG_D"
HERMES_D="$(grep -c '=== hermes' "$HERMES_CALL_LOG" 2>/dev/null || true)"; HERMES_D="${HERMES_D:-0}"
check_eq "非 dry: hermes send 走 stub 恰 1 次（零真实微信）" "1" "$HERMES_D"
check_contains "非 dry: 发出的卡带 ?key= 短码链接" "?key=" "$(cat "$HERMES_CALL_LOG" 2>/dev/null)"

printf '=== 静态门：新增 bash 面 $var+全角标点盲区（knowledge patterns.md:317）===\n'
# 作用域 = 设计 T5 新增 bash 面（collect.sh / execute.sh）；notify.sh 卡渲染面由蓝队 P8 静态门自证
GATE_FILES=()
for gf in "$APPROVAL_IMPL_DIR/collect.sh" "$APPROVAL_IMPL_DIR/execute.sh"; do
  [[ -f "$gf" ]] && GATE_FILES+=("$gf")
done
if [[ "${#GATE_FILES[@]}" -lt 2 ]]; then
  fail "静态门: collect.sh/execute.sh 应存在于 scripts/approval/" \
    "found=[${GATE_FILES[*]:-无}]（impl dir=${APPROVAL_IMPL_DIR}）"
else
  GATE_HITS=""
  for gf in "${GATE_FILES[@]}"; do
    GATE_HITS+="$(perl -ne 'BEGIN { $f = shift @ARGV; } print "$f:$.: $_" if /\$(\w+)(?=[（）：；，「」｜·】）])/;' "$gf" "$gf" 2>/dev/null)"
  done
  if [[ -n "$GATE_HITS" ]]; then
    fail "静态门: collect/execute 无 \$var 紧跟全角标点盲区" "$GATE_HITS"
  else
    ok "静态门: collect/execute 无 \$var 紧跟全角标点盲区"
  fi
fi

printf '\n==== 汇总 ====\n'
printf 'PASS %d checks\n' "$PASS"
if [[ "$FAIL" -gt 0 ]]; then
  printf 'FAIL %d checks:%s\n' "$FAIL" "$FAILED_NOTES"
  exit 1
fi
exit 0
