#!/bin/bash
# e1-flush-real.sh — E1：flush 真发全链（事件→聚合→stub 送达→账本/配额三同现）
# 契约锚点：真发成功判据（hermes rc==0 且 success:true 才标 pushed 并 bump 配额）
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=e2e
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "e1-flush-real.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"

t_case "E1: 叙事事件→digest 卡（T5 卡化：flight 四键+快照+零 send 零 claude+挂账 attempts 不增）"
sb_notify event pipeline-failure --key e1-narrative --summary "scan 研判 claude -p 失败 exit=1" >/dev/null
assert_exit 0 $?
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$out" "" "真发轮无 stdout 噪音（结果落账本/日志）"
# flight 四键 + 快照落盘（异步化主路：建卡而非内联发送）
DFLIGHT="$SB_ROOT/contrib-data/kanban-flight-digest.json"
assert_eq "$(jq -r '.kind // empty' "$DFLIGHT" 2>/dev/null)" "digest" "flight kind=digest"
SNAP="$(jq -r '.batch_file // empty' "$DFLIGHT" 2>/dev/null)"
[[ -n "$SNAP" && -f "$SNAP" ]] && _pass "batch_file=快照路径且落盘" || _fail "batch_file=快照路径" "actual=$SNAP"
assert_eq "$(jq -r '.created_epoch > 0' "$DFLIGHT" 2>/dev/null)" "true" "created_epoch 落值"
# 主路零发送零 LLM（发送移至 worker 卡内 send-digest）
send_calls="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
assert_eq "$send_calls" "0" "hermes send 零调用（异步化：发送在 worker 卡内）"
assert_stub_called claude 0 "主路零 claude"
# 事件保留未推、attempts 不增（在飞挂账）
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .pushed' "$EVENTS_FILE")" "false" "事件保留未推（等卡闭环）"
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .attempts' "$EVENTS_FILE")" "0" "attempts 不增（在飞非失败）"
# 卡 body 断言：含快照路径与三段式规范，无 raw 事件正文直推
body_file="$(stub_last_body hermes)"
[[ -n "$body_file" ]] && assert_file_contains "$body_file" "$SNAP" "卡 body 含快照路径"
[[ -n "$body_file" ]] && assert_file_contains "$body_file" "三段式" "卡 body 含三段式规范"
[[ -n "$body_file" ]] && assert_not_contains "$(cat "$body_file")" '"summary":"scan 研判' "无 raw JSON dump"

t_case "E1w: worker 收尾模拟——send-digest 发送 → 账本 pushed/配额 bump/批次 sent:true 三同现"
DIGEST="${SNAP%.json}.digest.md"
printf '🟠【contrib 告警】09-09\n\nscan 失败已挂账；无需动作。\n' >"$DIGEST"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIGEST' --batch '$SNAP'")"
assert_exit 0 $?
assert_eq "$out" "OK" "send-digest stdout 闭集 OK"
assert_file_contains "$SB_ROOT/stublog/hermes-send-last.json" '"success":true' "发送结果 success:true"
# ① 账本标 pushed=true + pushed_at 非空
assert_eq "$(jq -r 'select(.key == "e1-narrative") | .pushed' "$EVENTS_FILE")" "true" "events 标 pushed"
assert_not_contains "$(jq -r 'select(.key == "e1-narrative") | .pushed_at' "$EVENTS_FILE")" "null" "pushed_at 落值"
# ② 配额 bump ③ 批次文件 sent:true（send_result 佐证）
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "1" "当日告警配额 bump 1"
assert_eq "$(jq -rs '[.[] | select(.sent == true)] | length' "$SNAP" 2>/dev/null)" "1" "批次回写 sent:true"
send_body="$(stub_last_body hermes)"
assert_contains "$(cat "$send_body")" "🟠【contrib 告警】" "外发内容为摘要（报头）"
assert_not_contains "$(cat "$send_body")" '"summary":"scan 研判' "外发无 raw JSON dump（永不 raw dump）"

t_case "E1c: 卡 done + 批次 sent:true 消费轮 → 零账本动作（双写禁止）+ 清登记清快照"
printf '{"id":"%s","status":"done","assignee":"contrib","priority":0}\n' "$(jq -r '.card_id' "$DFLIGHT")" \
  >"$SB_ROOT/stublog/kanban-cards.jsonl"
sb_state_set '.last_flush_epoch = 0'
sb_notify event pipeline-failure --key e1-next --summary "消费轮新攒叙事" >/dev/null
before_pushed="$(jq -s '[.[] | select(.pushed == true)] | length' "$EVENTS_FILE")"
before_alerts="$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null 2>&1
assert_exit 0 $?
assert_eq "$(jq -s '[.[] | select(.pushed == true)] | length' "$EVENTS_FILE")" "$before_pushed" "零新增 pushed（账本双写禁止）"
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "$before_alerts" "配额不被重复消耗"
[[ ! -f "$DFLIGHT" ]] && _pass "登记已清" || _fail "登记已清" "残留"
[[ ! -f "$SNAP" ]] && _pass "快照消费即删" || _fail "快照消费即删" "残留"
send_calls="$(awk -F'|' '$1 == "hermes" && $3 ~ /^send / { c++ } END { printf "%d", c + 0 }' \
  "$SB_ROOT/stublog/calls.log" 2>/dev/null)"
assert_eq "$send_calls" "1" "消费轮零发送（唯一 send 来自 worker 环节）"
assert_eq "$(jq -r 'select(.key == "e1-next") | .pushed' "$EVENTS_FILE")" "false" "新攒事件留待下小时轮（不丢）"

t_case "E1b: 纯机械批次→模板卡（零 LLM）+ ▪ 实质行"
# 前置态收口：消费轮新攒的 e1-next 留待下小时轮（卡路），此处拨账模拟其已被消费，
# 使本批为纯机械批（E1b 回归锚点）
jq 'if .key == "e1-next" then .pushed = true else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
rm -f "$SB_ROOT/contrib-data/kanban-flight-digest.json"   # E1b 建的卡在本用例语境外，清登记
sb_notify event probe-premise-dead --key e1-mech --summary "radar 2026-09-05 premise 复验：#102413 已被占坑出局" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
before_claude="$(stub_count claude)"
before_hermes="$(stub_count hermes)"
out="$(sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush')"
assert_exit 0 $?
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "纯机械批次零 claude 调用"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "1" "hermes 再发一次"
body_file="$(stub_last_body hermes)"
assert_contains "$(cat "$body_file")" "▪ 候选折损" "模板卡实质行（▪ 开头）"
assert_contains "$(cat "$body_file")" "↳ " "模板卡动作行"
assert_eq "$(jq -r 'select(.key == "e1-mech") | .pushed' "$EVENTS_FILE")" "true" "机械事件标 pushed"

t_case "E1f: 失败链（建卡失败 → fallback claude+send 也败）→ 事件保留 + attempts 递增"
sb_notify event pipeline-failure --key e1-fail --summary "会失败的事件" >/dev/null
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" -e "STUB_HERMES_FAIL=1" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 1 $? "flush 上报失败"
assert_eq "$(jq -r 'select(.key == "e1-fail") | .pushed' "$EVENTS_FILE")" "false" "不得标 pushed"
assert_eq "$(jq -r 'select(.key == "e1-fail") | .attempts' "$EVENTS_FILE")" "1" "attempts 递增"
[[ ! -f "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]] && _pass "建卡失败不写登记" \
  || _fail "建卡失败不写登记" "残留"

t_case "E1g: 简报级事件（own-pr-info）不进微信批——账本 route=brief 标记且不占限额/不推进闸门"
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
sb_notify event own-pr-info --key e1-brief --summary "mergeable 翻转（无决策点）" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
before_claude="$(stub_count claude)"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "降级轮零外发（即时推送不出）"
assert_eq "$(( $(stub_count claude) - before_claude ))" "0" "降级轮零 LLM（摘要路同样不出）"
assert_eq "$(jq -r 'select(.key == "e1-brief") | .route' "$EVENTS_FILE")" "brief" "账本 route=brief（当日简报消费队列）"
assert_eq "$(jq -r 'select(.key == "e1-brief") | .pushed' "$EVENTS_FILE")" "true" "降级即标记已派发（不积压 unpushed）"
assert_eq "$(jq -r 'select(.key == "e1-brief") | .attempts' "$EVENTS_FILE")" "0" "降级不占 attempts"
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "0" "降级不占当日告警限额"
assert_eq "$(jq -r '.last_flush_epoch' "$STATE_FILE")" "0" "标记动作不推进 last_flush_epoch"
# 09-14 修：降级不止是账本标记——同一条行必须落进当日简报文件（此前的黑洞：账本标 route=brief，
# briefs/<date>.md 里 grep 该 key = 0，全机无消费者）
BRIEF_FILE="$SB_ROOT/contrib-data/briefs/$(date +%F).md"
[[ -f "$BRIEF_FILE" ]] && _pass "当日简报文件已建（route=brief 真落文件）" || _fail "当日简报文件已建" "缺失 $BRIEF_FILE"
assert_file_contains "$BRIEF_FILE" "# contrib 简报 $(date +%F)" "简报文件头（惰性创建）"
assert_file_contains "$BRIEF_FILE" "## 简报队列（机械落账）" "固定小节头"
assert_file_contains "$BRIEF_FILE" '`e1-brief`' "记录行含 key（反引号形态，查重锚）"
assert_file_contains "$BRIEF_FILE" "own-pr-info" "记录行含 class"
assert_file_contains "$BRIEF_FILE" ' ｜ ' "记录行字段分隔（ts ｜ class ｜ key ｜ summary ｜ channel）"
assert_eq "$(grep -cF -- 'e1-brief' "$BRIEF_FILE")" "1" "该 key 恰一行（不重复）"
assert_eq "$(grep -c '^- ' "$BRIEF_FILE")" "1" "记录形态=单行列表项（恒单行）"
assert_not_contains "$(cat "$BRIEF_FILE")" '"summary"' "简报不落 raw JSON（人读面）"

t_case "E1i: 幂等——同 key 二次入批（簇重推把 pushed 拨回 false 的同形前置态）不得重复成行"
# 生产 repush 路径会把已推行的 pushed 拨回 false 重新入批；简报落账必须按 key 查重。
# ⚠ 账本是逐行 JSONL（`_event_line_of` 按行 grep + line-splice）⇒ 改行必须 `jq -c`：
#   默认 jq 会 pretty-print 成多行，把账本行结构打碎（本用例首跑即栽在此，红队可复现）。
jq -c 'if .key == "e1-brief" then .pushed = false else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
assert_eq "$(jq -r 'select(.key == "e1-brief") | .pushed' "$EVENTS_FILE")" "false" "前置态：该行确已拨回未推"
BRIEF_SHA_BEFORE="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_state_set '.last_flush_epoch = 0'
before_hermes="$(stub_count hermes)"
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1-brief") | .pushed' "$EVENTS_FILE")" "true" "重推轮账本重新标已派发（证明该 key 真被再处理）"
assert_eq "$(jq -r 'select(.key == "e1-brief") | .route' "$EVENTS_FILE")" "brief" "重推轮账本仍标 route=brief"
assert_eq "$(grep -cF -- 'e1-brief' "$BRIEF_FILE")" "1" "简报文件仍恰一行（幂等，不重复追加）"
assert_eq "$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')" "$BRIEF_SHA_BEFORE" "简报文件逐字节未变（查重命中即零写入）"
assert_eq "$(jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$STATE_FILE")" "0" "幂等轮仍不占当日限额"
assert_eq "$(( $(stub_count hermes) - before_hermes ))" "0" "幂等轮零外发"

t_case "E1h: brief_only_classes 覆盖 = replace 语义（表内类降级、缺省表类不再降级）"
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
# 沙箱 config 注入 brief_only_classes=[own-pr-unledgered] —— 整体替代缺省表（非并集）
sb_config_set '.brief_only_classes = ["own-pr-unledgered"]'
sb_notify event own-pr-info --key e1-cfg-info --summary "缺省表内的类" >/dev/null
sb_notify event own-pr-unledgered --key e1-cfg-unl --summary "覆盖表内的类" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1-cfg-unl") | .route' "$EVENTS_FILE")" "brief" "覆盖表内的类降级 route=brief"
assert_eq "$(jq -r 'select(.key == "e1-cfg-unl") | .pushed' "$EVENTS_FILE")" "true" "覆盖表内的类降级即标记派发"
assert_eq "$(jq -r 'select(.key == "e1-cfg-info") | .route' "$EVENTS_FILE")" "push" "缺省表内的类不再降级（replace 语义）"

t_case "E1j: 散文以反引号引用同 key ≠ 查重命中——机械落账仍成行（红队 F1）"
# 09-14 红队 F1：_brief_append_record 的查重曾是「全文件 grep -qF `key`」。当日简报上半是班次
# 手写散文，而散文引用账本 key 取证是惯例（falsify 纠偏明文要求）⇒ 散文里的同 key 把机械落账
# 静默吞掉：账本照标 pushed=true/route=brief，机械小节零落账 = 「事件进账本却无人读」复现形态。
# 本用例锁边界：散文行 + 记录行 = 同 key 计 2，且重推轮零重复追加。
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
BRIEF_FILE="$SB_ROOT/contrib-data/briefs/$(date +%F).md"
TICK='`'
mkdir -p "$SB_ROOT/contrib-data/briefs"
{
  printf '# contrib 简报 %s\n\n' "$(date +%F)"
  printf '## shift-手写\n'
  printf -- '- 散文提到 %se1j-key%s 一次（shift 手写取证惯例）。\n' "$TICK" "$TICK"
} >"$BRIEF_FILE"
PROSE_SHA="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_notify event own-pr-info --key e1j-key --summary "散文同 key 边界" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1j-key") | .pushed' "$EVENTS_FILE")" "true" "账本仍正常降级标记（pushed=true）"
assert_eq "$(jq -r 'select(.key == "e1j-key") | .route' "$EVENTS_FILE")" "brief" "账本仍标 route=brief"
assert_eq "$(grep -cF -- 'e1j-key' "$BRIEF_FILE")" "2" "散文行 + 记录行 = 2（未被散文假查重吞掉）"
assert_eq "$(grep -cF -- " ｜ ${TICK}e1j-key${TICK} ｜ " "$BRIEF_FILE")" "1" "记录行恰 1 行（字段缝判据）"
assert_eq "$(grep -c -- '^## 简报队列（机械落账）$' "$BRIEF_FILE")" "1" "机械小节头恰 1 行"
assert_eq "$(head -n 4 "$BRIEF_FILE" | shasum -a 256 | awk '{print $1}')" "$PROSE_SHA" "散文段逐字节未改写（append-only）"
# 重推轮（簇重推把 pushed 拨回 false 的同形前置态）：查重命中 ⇒ 零追加
jq -c 'if .key == "e1j-key" then .pushed = false else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
SHA_AFTER_FIRST="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1j-key") | .pushed' "$EVENTS_FILE")" "true" "重推轮账本重新标已派发"
assert_eq "$(grep -cF -- 'e1j-key' "$BRIEF_FILE")" "2" "重推轮仍恰 2 行（散文 1 + 记录 1，不重复追加）"
assert_eq "$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')" "$SHA_AFTER_FIRST" "重推轮简报逐字节未变（查重命中即零写入）"

t_case "E1k: 散文内联提及小节头 ≠ 小节存在——仍补真小节头（否则记录落小节外、查重失锚）"
# 同族边界：小节头判据若用「全文 grep -F 头部字符串」，散文内联提及即误判小节已存在 ⇒ 记录被追加
# 到文件尾却无小节头 ⇒ 查重锚（小节作用域）落空 ⇒ 重推轮重复追加。判据取整行精确。
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
BRIEF_FILE="$SB_ROOT/contrib-data/briefs/$(date +%F).md"
mkdir -p "$SB_ROOT/contrib-data/briefs"
{
  printf '# contrib 简报 %s\n\n' "$(date +%F)"
  printf '## shift-手写\n'
  printf -- '- 散文内联提到 ## 简报队列（机械落账） 与 %se1k-key%s 这个词，但不是小节头行。\n' "$TICK" "$TICK"
} >"$BRIEF_FILE"
sb_notify event own-pr-info --key e1k-key --summary "内联小节头边界" >/dev/null
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(grep -c -- '^## 简报队列（机械落账）$' "$BRIEF_FILE")" "1" "真小节头仍被补写（整行精确判据）"
assert_eq "$(grep -cF -- 'e1k-key' "$BRIEF_FILE")" "2" "散文行 + 记录行 = 2"
assert_eq "$(grep -cF -- " ｜ ${TICK}e1k-key${TICK} ｜ " "$BRIEF_FILE")" "1" "记录行恰 1 行（字段缝判据，散文内联提及不算）"
# 重推轮：记录已在小节内 ⇒ 查重命中，零追加（散文内联提及不得让查重失锚）
jq -c 'if .key == "e1k-key" then .pushed = false else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
SHA_AFTER_FIRST="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(grep -cF -- 'e1k-key' "$BRIEF_FILE")" "2" "重推轮仍恰 2 行（不重复追加）"
assert_eq "$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')" "$SHA_AFTER_FIRST" "重推轮简报逐字节未变"

# rec_lines <brief_file> <key> → 记录行数（独立度量：行首 `- <ISO 时间戳>` 且 key 紧跟 class 字段）
rec_lines() {
  grep -cE "^- [0-9]{4}-[0-9]{2}-[0-9]{2}T.*｜ own-pr-info ｜ \`$2\` ｜" "$1" 2>/dev/null
}

t_case "E1l: 机械小节内散文复述记录格式（含完整字段缝「 ｜ \`key\` ｜ 」）≠ 查重命中——记录仍成行（红队 F2）"
# 09-14 红队 F2：查重作用域收窄到机械小节后，判据仍是「纯字段缝」而非「行形」。作用域 = 小节头到
# EOF，而班次在小节之下继续手写散文属于常态（append-s27b 范式向 EOF 追加）——散文逐字复述记录
# 格式（`- 班次复述格式：- ts ｜ own-pr-info ｜ \`<key>\` ｜ 手工引用 ｜ contrib`）即命中纯字段缝判据
# ⇒ 真实事件零落账而账本照标 pushed=true/route=brief（「事件进账本却无人读」残余形态）。散文只
# 复述**格式**时事件内容并不在简报里，损失是实的。本用例锁边界：记录仍成行恰 1 行 + 重推轮零追加。
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
BRIEF_FILE="$SB_ROOT/contrib-data/briefs/$(date +%F).md"
TICK='`'
mkdir -p "$SB_ROOT/contrib-data/briefs"
{
  printf '# contrib 简报 %s\n\n' "$(date +%F)"
  printf '## shift-手写\n- 开头散文\n\n'
  printf '%s\n\n' '## 简报队列（机械落账）'
  printf -- '- 2026-09-14T10:00:00+0800 ｜ own-pr-info ｜ %se1l-other%s ｜ 既有记录 ｜ contrib\n' "$TICK" "$TICK"
  printf -- '- 班次复述格式：- ts ｜ own-pr-info ｜ %se1l-key%s ｜ 手工引用 ｜ contrib（散文，不是记录）\n' "$TICK" "$TICK"
} >"$BRIEF_FILE"
PRE_LINES="$(wc -l <"$BRIEF_FILE" | tr -d ' ')"
PRE_SHA="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_notify event own-pr-info --key e1l-key --summary "小节内散文复述记录格式" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1l-key") | .pushed' "$EVENTS_FILE")" "true" "账本仍正常降级标记（pushed=true）"
assert_eq "$(jq -r 'select(.key == "e1l-key") | .route' "$EVENTS_FILE")" "brief" "账本仍标 route=brief"
assert_eq "$(grep -cF -- " ｜ ${TICK}e1l-key${TICK} ｜ " "$BRIEF_FILE")" "2" "字段缝计数 = 2（散文假命中面确凿存在 ⇒ 纯字段缝判据必吞落账）"
assert_eq "$(rec_lines "$BRIEF_FILE" e1l-key)" "1" "记录行恰 1 行（行形锚定：ISO 行首 + key 恰第 3 字段）"
assert_eq "$(grep -cF -- 'e1l-key' "$BRIEF_FILE")" "2" "散文行 + 记录行 = 2（未被散文假命中吞掉）"
assert_eq "$(head -n "$PRE_LINES" "$BRIEF_FILE" | shasum -a 256 | awk '{print $1}')" "$PRE_SHA" "前态逐字节未改写（append-only）"
# 重推轮（簇重推把 pushed 拨回 false 的同形前置态）：查重命中 ⇒ 零追加
jq -c 'if .key == "e1l-key" then .pushed = false else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
SHA_AFTER_FIRST="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1l-key") | .pushed' "$EVENTS_FILE")" "true" "重推轮账本重新标已派发"
assert_eq "$(rec_lines "$BRIEF_FILE" e1l-key)" "1" "重推轮记录行仍恰 1 行（不重复追加）"
assert_eq "$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')" "$SHA_AFTER_FIRST" "重推轮简报逐字节未变（查重命中即零写入）"

t_case "E1m: 小节内 ISO 行首的手写行引用同 key（key 不在第 3 字段）≠ 查重命中——记录仍成行"
# 同族边界（字段位守卫的可杀性）：手写行以 ISO 时间戳开头、含完整字段缝，但 key 出现在引用尾部
# （第 5 字段）——「ISO 行首 + 含字段缝」若不再校验字段位仍会假命中吞落账。行形判据要求 key 恰
# 为记录行的第 3 字段，故此处必须落账。
sb_cleanup
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
EVENTS_FILE="$SB_ROOT/contrib-data/events.jsonl"
STATE_FILE="$SB_ROOT/contrib-data/notify-state.json"
BRIEF_FILE="$SB_ROOT/contrib-data/briefs/$(date +%F).md"
TICK='`'
mkdir -p "$SB_ROOT/contrib-data/briefs"
{
  printf '# contrib 简报 %s\n\n' "$(date +%F)"
  printf '## shift-手写\n- 开头散文\n\n'
  printf '%s\n\n' '## 简报队列（机械落账）'
  printf -- '- 2026-09-14T10:00:00+0800 ｜ own-pr-info ｜ %se1m-other%s ｜ 手工引用 ｜ %se1m-key%s ｜ contrib（散文，不是记录）\n' \
    "$TICK" "$TICK" "$TICK" "$TICK"
} >"$BRIEF_FILE"
PRE_LINES="$(wc -l <"$BRIEF_FILE" | tr -d ' ')"
PRE_SHA="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_notify event own-pr-info --key e1m-key --summary "ISO 行首手写行引用同 key" >/dev/null
assert_exit 0 $?
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(jq -r 'select(.key == "e1m-key") | .pushed' "$EVENTS_FILE")" "true" "账本仍正常降级标记（pushed=true）"
assert_eq "$(grep -cF -- " ｜ ${TICK}e1m-key${TICK} ｜ " "$BRIEF_FILE")" "2" "字段缝计数 = 2（行首 ISO + 字段缝俱在 ⇒ 字段位守卫承重）"
assert_eq "$(rec_lines "$BRIEF_FILE" e1m-key)" "1" "记录行恰 1 行（key 恰第 3 字段才算记录行）"
assert_eq "$(head -n "$PRE_LINES" "$BRIEF_FILE" | shasum -a 256 | awk '{print $1}')" "$PRE_SHA" "前态逐字节未改写（append-only）"
jq -c 'if .key == "e1m-key" then .pushed = false else . end' "$EVENTS_FILE" >"$EVENTS_FILE.tmp" \
  && mv "$EVENTS_FILE.tmp" "$EVENTS_FILE"
SHA_AFTER_FIRST="$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')"
sb_state_set '.last_flush_epoch = 0'
sb_run -e "NOTIFY_DRY_RUN=false" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_exit 0 $?
assert_eq "$(rec_lines "$BRIEF_FILE" e1m-key)" "1" "重推轮记录行仍恰 1 行（不重复追加）"
assert_eq "$(shasum -a 256 <"$BRIEF_FILE" | awk '{print $1}')" "$SHA_AFTER_FIRST" "重推轮简报逐字节未变"

sb_cleanup
t_finish
