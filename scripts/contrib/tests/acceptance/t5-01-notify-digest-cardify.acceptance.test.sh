#!/usr/bin/env bash
# =============================================================================
# t5-01-notify-digest-cardify.acceptance.test.sh — T5 验收①：flush 叙事批 digest 卡化全矩阵
#   D1  叙事批无登记 → 建 digest 卡：建卡参数（--idempotency-key digest-<YYYYMMDD>-<md5 前 8>）
#       + body 五要素（快照路径/三段式规范/摘要输出路径 .digest.md/唯一外发通道 send-digest 红线/
#       收尾双传）+ 快照落盘 pending/digest-<ts>.json + flight 四键精确键集
#       + 本批挂账 attempts 不增 + 零 send 零 claude（异步化：建卡≠发送≠内联 LLM）
#   D1b 另一事件键建卡 → 幂等键后缀与 D1 不同（key 派生突变靶；序列化形态 CONTRACT_AMBIGUOUS）
#   D2  flight 在飞（running 未超时）→ 本批挂账 attempts 不增 + 零建卡零 claude 零 send + 登记保留
#   D3  done+批次文件 sent:true → 清 flight + 删快照/摘要文件 + events.jsonl 零新增标记动作
#       （零 pushed 翻转/零 attempts/零 state_bump——账本双写禁止，禁止正向断言的反面=零动作断言）
#   D3b done+sent:true 消费后本轮新攒叙事批 → 本轮 return 不再建新卡（I2 防每小时卡风暴，保守单调）
#   D4  done+sent:false → 清 flight + fallback _ai_digest 被调 + 旧语义成功链（send/pushed/alerts）
#       + 快照与摘要文件清理（I4）
#   D5  done+sent 缺失 → 同 D4（缺省按 false，突变靶：缺失误判 true 则跳过 fallback）
#   D6  blocked+outcome 闭集（gave_up）→ 清 flight + fallback 成功链 + 清理
#   D7  blocked+outcome 非闭集（agent_error）→ 非失败终态 → 登记保留零 fallback（闭集锚定）
#   D8  stale（DIGEST_STALE_SECS=60，epoch-120s）→ 清 flight + fallback + event（事件族 key 未钉，
#       断言事件总数增长）+ 清理
#   D9  stale 守卫窗（SECS=3600，epoch-30s）→ 未超时 → 登记保留零动作
#   D10 建卡失败（hermes down）→ fallback _ai_digest 被调 + 发送链走旧语义（attempts+1，rc≠0）
#   D11 建卡失败+claude 也败 → attempts+1 + 零 send + 零 flight（摘要失败=搁置重试）
#   D12 fallback 空卡守卫：摘要产物仅报头 → 守卫触发 → 零 send + attempts+1（守卫删除突变靶）
#   D13 连续 3 败 → osascript 本地机械提示 + fallback_notice 当日置 1（3 败兜底回归）
#   D14 纯机械批回归：模板卡零 LLM 零建卡（send 恰 1、body 含速报与原始摘要、pushed/alerts 正常链）
#   D15 notify_digest=false 回归：叙事批不建卡直接挂账（零建卡零 LLM，attempts+1，exit 1 现行为）
#   D16 混合批次（机械+叙事）→ 整批 digest 卡（零模板 send 零 claude）
# 依据：state.md「## 设计文档」§1/§2 + 契约规约：
#   「flight=$CONTRIB/kanban-flight-digest.json 四键 kind/card_id/batch_file/created_epoch；
#     快照=$CONTRIB/pending/digest-<ts>.json；幂等键=digest-<YYYYMMDD>-<md5(keys) 前 8>；
#     DIGEST_STALE_SECS 缺省 21600；done+sent:true 消费=零账本动作；快照/摘要清理（I4）；
#     在飞挂账不加 attempts；fallback_ai()=原 _ai_digest→空卡守卫→_send→attempts+1/3 败 osascript」
# CONTRACT_AMBIGUOUS（红→回设计对齐，不是测试 bug）：
#   - 批次/快照文件 fixture 采用「JSONL 事件行 + 尾部 sent 控制行」形态（与 flush 建卡产物
#     黑盒同构；契约只钉「回写 sent:true|false + send_result 佐证 + 按批次 keys 标记 pushed」）。
#     实现若改用他形态需回设计对齐并同步 fixture
#   - 幂等键 md5 的 keys 序列化形态黑盒不可命中（实现哈希不在任意合理候选集内）：D1 降为
#     「digest-<YYYYMMDD>-<8hex> 形态」断言，D1b 钉批次唯一性（不同 keys→不同键）、D1c 钉
#     确定性（同 keys→同键）；md5 字面合规性留待设计对齐（CONTRACT_AMBIGUOUS）
#   - 摘要文件命名钉为 <快照去 .json>.digest.md（契约「digest-<ts>.digest.md」最自然派生）
#   - 建卡成功/在飞/非终态分支的 flush exit code 未钉 → 不断言（D10/D11/D15 失败链 rc 契约有钉）
#   - stale 分支事件族 key 未钉 → 只断言事件总数增长，不断言 key 字面
#   - D9 守卫窗为附加用例（矩阵外，kill「>= 判成 >」off-by-one 突变）
# 红队纪律：黑盒（未读 notify.sh 本次改动 / SKILL.md 新段；notify.sh 现状仅经 git show HEAD）；
#   每断言硬失败；无 skip。Mental Mutation：异步化退化回内联 LLM→D1 claude 断言红；建卡后仍
#   直推→D1 零 send 红；attempts 误增→D1/D2 红；done 消费重复标记账本→D3 红；消费后继续建卡→
#   D3b 红；sent 缺失判 true→D5 红；outcome 闭集删→D7 红；stale 守卫删→D9 红；fallback 删→
#   D4/D5/D6/D8/D10 红；空卡守卫删→D12 红；3 败 osascript 删→D13 红；机械路径被误改→D14 红；
#   notify_digest=false 语义丢→D15 红；混合批退化按类拆批→D16 红。
# =============================================================================
set -u
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT" ]]; then
  echo "ACCEPTANCE-FAIL[env]: REPO_ROOT 不可解析——git rev-parse --show-toplevel 在 ${SELF_DIR} 无输出（非 git 仓库 / git 不可用）；本套件禁静默兜底到生产主 checkout" >&2
  exit 1
fi
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

RAW='RAWTOKEN-9f2'   # raw dump 哨兵：任何外发载荷（卡 body/微信消息/通知文案）出现即红
KEY1_HASH=""         # D1 幂等键后缀（D1b 差异断言用，跨沙箱存活）

# ---- 本文件专用装具 ----

seed_narrative_event() { # <key> <summary> — 叙事类事件（非机械三类）
  sb_seed_event "pipeline-failure" "$1" "$2"
}

seed_flight_digest() { # <card_id> <batch_file> <created_epoch> — 四键登记（契约字面 schema）
  jq -n --arg id "$1" --arg bf "$2" --argjson ep "$3" \
    '{kind:"digest",card_id:$id,batch_file:$bf,created_epoch:$ep}' \
    > "$SB_ROOT/contrib-data/kanban-flight-digest.json"
}

seed_card_store() { # <status>：在飞查询前置态（list/show 两种读法同真，同 t4 chain_setup 口径）
  printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" \
    > "$SB_ROOT/stublog/kanban-cards.jsonl"
}

mk_batch_file() { # <path> <true|false|omit> <key...> — 快照 fixture：JSONL 事件行+尾部 sent 控制行
  local path="$1" sent="$2" k   # （与 flush 建卡产物同构的黑盒约定；omit=无控制行）
  shift 2
  : > "$path"
  for k in "$@"; do
    printf '{"ts":"2026-01-01T00:00:00+08:00","class":"pipeline-failure","key":"%s","channel":"contrib","summary":"s-%s","pushed":false,"attempts":0,"pushed_at":null}\n' "$k" "$k" >> "$path"
  done
  case "$sent" in
    true|false) printf '{"sent":%s,"reason":null,"sent_at":"2026-09-09T12:00:00+08:00","send_result":null}\n' "$sent" >> "$path" ;;
  esac
}

digest_file_of() { # <batch_file> → 契约派生的摘要输出路径（CONTRACT_AMBIGUOUS 命名钉法）
  printf '%s.digest.md' "${1%.json}"
}

flight_exists()  { [ -s "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]; }
flight_field()   { jq -r "$1" "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null || echo ""; }
flight_keyset()  { jq -r 'keys | join(",")' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null || echo "?"; }

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls()       { hermes_lines | grep -c 'kanban create' || true; }
create_digest_calls() { hermes_lines | grep 'kanban create' | grep -c -- '--idempotency-key digest-' || true; }
send_calls()         { hermes_lines | grep -c '|send ' || true; }
claude_calls()       { stub_count claude; }   # awk 计数：calls.log 缺失时回 0（grep -c 会回空串）

events_total()  { wc -l < "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null | tr -d ' '; }
events_pushed_true() { jq -s '[.[] | select(.pushed == true)] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
events_attempts_sum() { jq -s '[.[] | (.attempts // 0)] | add' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
ge1() { # <n> <label>：>=1 硬断言（行为断言不受调用次数细节影响）
  case "${1:-}" in
    ''|*[!0-9]*) _fail "$2" "非数值 [$1]" ;;
    *) [ "$1" -ge 1 ] && _pass "$2" || _fail "$2" "实得 $1 < 1" ;;
  esac
}
alerts_today()  { jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }
approvals_len() { jq -r '.approvals // {} | length' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }
fallback_notice_today() { jq -r --arg d "$(date +%F)" '.fallback_notice[$d] // "0"' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

run_flush() { sb_run "$@" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush'; }

# ---- D1 断言组件 ----

digest_idem_key_line() { # → 最近一次 digest 建卡 argv 行（无则空）
  hermes_lines | grep 'kanban create' | grep -- '--idempotency-key digest-' | tail -1
}

KEY_HASH_OUT=""   # assert_digest_key_form 的回传通道（函数内含 stdout 断言输出，禁再回显）

assert_digest_key_form() { # <label> → 断言键形态 digest-<YYYYMMDD>-<8 位 hex>，哈希段写入 KEY_HASH_OUT
  local label="$1" line parsed dpart hpart
  KEY_HASH_OUT=""
  line="$(digest_idem_key_line)"
  if [ -z "$line" ]; then
    _fail "$label" "建卡 argv 无 --idempotency-key digest- 前缀"
    return 0
  fi
  parsed="$(printf '%s' "$line" | sed -E 's/.*--idempotency-key digest-([0-9]{8})-([0-9a-f]{8}).*/\1 \2/')"
  case "$parsed" in
    "$line") _fail "$label" "幂等键形态非 digest-<8 位日期>-<8 位 hex>：$line"; return 0 ;;
  esac
  dpart="${parsed%% *}"; hpart="${parsed#* }"
  assert_eq "$dpart" "$(date +%Y%m%d)" "$label 键日期段=YYYYMMDD"
  _pass "$label 键哈希段=8 位 hex（派生自批次 keys 的确定性摘要；md5 具体序列化形态 CONTRACT_AMBIGUOUS，由 D1b/D1c 唯一性与确定性钉死）"
  KEY_HASH_OUT="$hpart"
}

card_store_last_id() { tail -1 "$SB_ROOT/stublog/kanban-cards.jsonl" 2>/dev/null | jq -r '.id // ""'; }

# =============================================================================
t_case "D1 叙事批无登记 → 建 digest 卡：参数+body 五要素+快照落盘+flight 四键+挂账不增+零发送零 LLM"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-a" "$RAW narrative pipeline 炸了 rq-1"
run_flush >/dev/null; RC=$?
assert_eq "$(create_digest_calls)" "1" "D1 恰 1 次 digest 建卡（--idempotency-key digest- 前缀）"
assert_eq "$(claude_calls)" "0" "D1 建卡路零 claude（异步化：LLM 进 worker 不在 flush）"
assert_eq "$(send_calls)" "0" "D1 建卡路零 hermes send（发送归 worker 卡内 send-digest）"
assert_digest_key_form "D1"; KEY1_HASH="$KEY_HASH_OUT"
SNAP="$(flight_field '.batch_file')"
case "$SNAP" in
  */pending/digest-*.json) _pass "D1 快照路径形态 pending/digest-<ts>.json" ;;
  *) _fail "D1 快照路径形态" "flight.batch_file=[$SNAP] 非 pending/digest-*.json" ;;
esac
if [ -f "$SNAP" ]; then
  _pass "D1 快照文件落盘"
  assert_file_contains "$SNAP" "k-a" "D1 快照含本批事件 key（=batch_file 拷贝）"
else
  _fail "D1 快照文件落盘" "快照缺失: $SNAP"
fi
BODYF="$(stub_last_body hermes)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  _pass "D1 卡 body 副本已捕获"
  assert_file_contains "$BODYF" "$SNAP" "D1 body 含快照绝对路径"
  assert_file_contains "$BODYF" ".digest.md" "D1 body 含摘要输出路径约定（digest-<ts>.digest.md）"
  assert_file_contains "$BODYF" "发生了什么" "D1 body 含三段式规范（发生了什么）"
  assert_file_contains "$BODYF" "建议" "D1 body 含三段式规范（建议动作）"
  assert_file_contains "$BODYF" "300" "D1 body 含长度规范（<=300 字）"
  assert_file_contains "$BODYF" "send-digest" "D1 body 红线：唯一外发通道=notify.sh send-digest"
  assert_file_contains "$BODYF" "hermes send" "D1 body 红线：禁 hermes send 直调"
  assert_file_contains "$BODYF" "raw" "D1 body 红线：禁 raw dump"
  assert_file_contains "$BODYF" "kanban_complete" "D1 body 收尾双传要求"
  if grep -qF "$RAW" "$BODYF"; then
    _fail "D1 卡路无 raw dump" "卡 body 含原始事件哨兵 $RAW"
  else
    _pass "D1 卡路无 raw dump"
  fi
else
  _fail "D1 卡 body 副本已捕获" "bodies/hermes-*.txt 无建卡载荷（body 未进 --body argv？）"
fi
flight_exists && _pass "D1 flight-digest 登记存在" || _fail "D1 flight-digest 登记存在" "建卡成功应写 kanban-flight-digest.json"
assert_eq "$(flight_keyset)" "batch_file,card_id,created_epoch,kind" "D1 登记四键精确键集（勿多 batch_file 外键，重审 I3）"
assert_eq "$(flight_field '.kind')" "digest" "D1 登记 kind=digest"
assert_eq "$(flight_field '.card_id')" "$(card_store_last_id)" "D1 登记 card_id=本次建卡产出 id"
assert_eq "$(flight_field '.created_epoch | type')" "number" "D1 created_epoch 数值"
assert_eq "$(events_pushed_true)" "0" "D1 本批挂账：零 pushed 翻转"
assert_eq "$(events_attempts_sum)" "0" "D1 本批挂账 attempts 不增（在飞/建卡非失败）"
assert_eq "$(events_total)" "1" "D1 零新增事件行"
assert_eq "$(alerts_today)" "0" "D1 零 state_bump（未发生发送）"
assert_eq "$(approvals_len)" "0" "D1 notify-state approvals 零新增（隔离）"
sb_cleanup

# =============================================================================
t_case "D1b 另一事件键建卡 → 幂等键后缀与 D1 不同（key 派生突变靶）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-b" "另一批叙事事件 rq-2"
run_flush >/dev/null
assert_eq "$(create_digest_calls)" "1" "D1b 恰 1 次 digest 建卡"
assert_digest_key_form "D1b"; KEY2_HASH="$KEY_HASH_OUT"
if [ -n "$KEY1_HASH" ] && [ -n "$KEY2_HASH" ]; then
  assert_ne "$KEY2_HASH" "$KEY1_HASH" "D1b 不同批次 keys → 幂等键哈希段不同（D1=[$KEY1_HASH] D1b=[$KEY2_HASH]）"
else
  _fail "D1b 幂等键差异" "前后两轮建卡哈希段未取齐（KEY1=[$KEY1_HASH] KEY2=[$KEY2_HASH]）"
fi
sb_cleanup

# =============================================================================
t_case "D1c 同批次 keys 重复建卡 → 幂等键完全一致（同 key 幂等：重试不产生第二张卡）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-a" "与 D1 同 keys 的重试批 rq-2b"
run_flush >/dev/null
assert_eq "$(create_digest_calls)" "1" "D1c 恰 1 次 digest 建卡"
assert_digest_key_form "D1c"; KEY3_HASH="$KEY_HASH_OUT"
if [ -n "$KEY1_HASH" ] && [ -n "$KEY3_HASH" ]; then
  assert_eq "$KEY3_HASH" "$KEY1_HASH" "D1c 同 keys → 幂等键哈希段确定（D1=[$KEY1_HASH] D1c=[$KEY3_HASH]）"
else
  _fail "D1c 幂等键确定性" "哈希段未取齐（KEY1=[$KEY1_HASH] KEY3=[$KEY3_HASH]）"
fi
sb_cleanup

# =============================================================================
t_case "D2 flight 在飞（running 未超时）→ 本批挂账 attempts 不增 + 零建卡零 claude 零 send"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-c" "在飞期间新叙事事件 rq-3"
seed_flight_digest "t_old" "/tmp/batch-digest-fixture.json" "$(date +%s)"
seed_card_store "running"
run_flush -e STUB_KANBAN_CARD_STATUS=running >/dev/null
assert_eq "$(create_digest_calls)" "0" "D2 同 kind 单飞 → 不建第二张卡"
assert_eq "$(claude_calls)" "0" "D2 在飞零 fallback claude"
assert_eq "$(send_calls)" "0" "D2 在飞零发送"
assert_eq "$(flight_field '.card_id')" "t_old" "D2 登记保留"
assert_eq "$(events_attempts_sum)" "0" "D2 本批挂账 attempts 不增（在飞非失败）"
assert_eq "$(events_pushed_true)" "0" "D2 零 pushed 翻转"
assert_eq "$(alerts_today)" "0" "D2 零 state_bump"
sb_cleanup

# =============================================================================
t_case "D3 done+sent:true → 清 flight+删快照/摘要+events.jsonl 零新增标记动作（账本双写禁止）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-d" "worker 已发送批的残留事件 rq-4"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-d3.json"
DIGF="$(digest_file_of "$BATCHF")"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" true "k-d"
printf 'worker 摘要（fixture）\n' > "$DIGF"
seed_flight_digest "t_old" "$BATCHF" "$(date +%s)"
seed_card_store "done"
run_flush -e STUB_KANBAN_CARD_STATUS=done >/dev/null
if flight_exists; then
  _fail "D3 登记已清" "done+sent:true 消费后 kanban-flight-digest.json 仍在（下轮锁死在飞态）"
else
  _pass "D3 登记已清"
fi
if [ -e "$BATCHF" ]; then _fail "D3 快照已删（I4）" "快照残留: $BATCHF"; else _pass "D3 快照已删（I4）"; fi
if [ -e "$DIGF" ]; then _fail "D3 摘要文件已删（I4）" "摘要残留: $DIGF"; else _pass "D3 摘要文件已删（I4）"; fi
assert_eq "$(events_pushed_true)" "0" "D3 零新增标记动作：零 pushed 翻转（worker 已标记，flush 不得重复）"
assert_eq "$(events_attempts_sum)" "0" "D3 零 attempts 动作"
assert_eq "$(alerts_today)" "0" "D3 零 state_bump（pushed 计数不变）"
assert_eq "$(create_digest_calls)" "0" "D3 消费轮零建卡"
assert_eq "$(claude_calls)" "0" "D3 消费轮零 fallback"
assert_eq "$(send_calls)" "0" "D3 消费轮零发送"
sb_cleanup

# =============================================================================
t_case "D3b done+sent:true 消费后本轮新攒叙事批 → 本轮 return 不再建新卡（I2 保守单调）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-done" "上一批已由 worker 发送" contrib 0 true
seed_narrative_event "k-new" "消费后新攒叙事事件 rq-5"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-d3b.json"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" true "k-done"
seed_flight_digest "t_old" "$BATCHF" "$(date +%s)"
seed_card_store "done"
run_flush -e STUB_KANBAN_CARD_STATUS=done >/dev/null
assert_eq "$(create_digest_calls)" "0" "D3b 消费轮不为新批建卡（防每小时 digest 卡风暴）"
assert_eq "$(claude_calls)" "0" "D3b 零 fallback"
assert_eq "$(send_calls)" "0" "D3b 零发送（新批下小时轮自然建卡）"
if flight_exists; then
  _fail "D3b 登记已清" "消费后登记未清"
else
  _pass "D3b 登记已清"
fi
assert_eq "$(events_pushed_true)" "1" "D3b 仅上一批保持已推（worker 标记），新批仍挂账"
assert_eq "$(events_attempts_sum)" "0" "D3b 新批 attempts 不增（保守单调）"
sb_cleanup

# =============================================================================
t_case "D4 done+sent:false → 清 flight+fallback 成功链+快照/摘要清理（I4）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-e" "worker 完成但未发送的异常收口 rq-6"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-d4.json"
DIGF="$(digest_file_of "$BATCHF")"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" false "k-e"
printf 'worker 未发送的摘要（fixture）\n' > "$DIGF"
seed_flight_digest "t_old" "$BATCHF" "$(date +%s)"
seed_card_store "done"
run_flush -e STUB_KANBAN_CARD_STATUS=done >/dev/null
ge1 "$(claude_calls)" "D4 fallback _ai_digest 被调（claude -p）"
assert_eq "$(send_calls)" "1" "D4 兜底摘要经 _send 发送"
assert_eq "$(events_pushed_true)" "1" "D4 兜底成功 → 事件标记已推（旧语义）"
assert_eq "$(events_attempts_sum)" "0" "D4 成功链零 attempts 计数"
assert_eq "$(alerts_today)" "1" "D4 state_bump alerts 正常链"
if flight_exists; then
  _fail "D4 登记已清" "fallback 消费后登记仍在"
else
  _pass "D4 登记已清"
fi
if [ -e "$BATCHF" ]; then _fail "D4 快照已删（I4）" "快照残留: $BATCHF"; else _pass "D4 快照已删（I4）"; fi
if [ -e "$DIGF" ]; then _fail "D4 摘要文件已删（I4）" "摘要残留: $DIGF"; else _pass "D4 摘要文件已删（I4）"; fi
assert_eq "$(create_digest_calls)" "0" "D4 fallback 路不建卡"
sb_cleanup

# =============================================================================
t_case "D5 done+sent 缺失 → 同 D4 fallback（缺失不得误判 true 跳过兜底）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-f" "批次文件无 sent 字段 rq-7"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-d5.json"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" omit "k-f"
seed_flight_digest "t_old" "$BATCHF" "$(date +%s)"
seed_card_store "done"
run_flush -e STUB_KANBAN_CARD_STATUS=done >/dev/null
ge1 "$(claude_calls)" "D5 sent 缺失按 false → fallback 被调"
assert_eq "$(send_calls)" "1" "D5 兜底发送"
assert_eq "$(events_pushed_true)" "1" "D5 兜底成功标记已推"
if flight_exists; then
  _fail "D5 登记已清" "fallback 消费后登记仍在"
else
  _pass "D5 登记已清"
fi
sb_cleanup

# =============================================================================
t_case "D6 blocked+outcome 闭集（gave_up）→ 清 flight+fallback+清理"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-g" "卡失败收口 rq-8"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-d6.json"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" false "k-g"
seed_flight_digest "t_old" "$BATCHF" "$(date +%s)"
seed_card_store "blocked"
run_flush -e STUB_KANBAN_CARD_STATUS=blocked -e STUB_KANBAN_RUN_OUTCOME=gave_up >/dev/null
ge1 "$(claude_calls)" "D6 失败终态 → fallback _ai_digest 被调"
assert_eq "$(send_calls)" "1" "D6 兜底发送"
assert_eq "$(events_pushed_true)" "1" "D6 兜底成功标记已推"
assert_eq "$(create_digest_calls)" "0" "D6 失败终态不建新卡"
if flight_exists; then
  _fail "D6 登记已清" "失败终态后登记仍在"
else
  _pass "D6 登记已清"
fi
if [ -e "$BATCHF" ]; then _fail "D6 快照已删（I4 fallback 同样清理）" "快照残留: $BATCHF"; else _pass "D6 快照已删（I4 fallback 同样清理）"; fi
sb_cleanup

# =============================================================================
t_case "D7 blocked+outcome 非闭集（agent_error）→ 非失败终态 → 登记保留零 fallback"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-h" "非闭集 outcome 事件 rq-9"
seed_flight_digest "t_old" "/tmp/batch-digest-fixture-d7.json" "$(date +%s)"
seed_card_store "blocked"
run_flush -e STUB_KANBAN_CARD_STATUS=blocked -e STUB_KANBAN_RUN_OUTCOME=agent_error >/dev/null
assert_eq "$(create_digest_calls)" "0" "D7 非终态不建卡"
assert_eq "$(claude_calls)" "0" "D7 非闭集 outcome → 不 fallback"
assert_eq "$(send_calls)" "0" "D7 零发送"
assert_eq "$(flight_field '.card_id')" "t_old" "D7 登记保留"
assert_eq "$(events_attempts_sum)" "0" "D7 attempts 不增"
sb_cleanup

# =============================================================================
t_case "D8 stale（DIGEST_STALE_SECS=60，epoch-120s）→ 清 flight+fallback+event+清理"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-i" "stale 在飞批 rq-10"
BATCHF="$SB_ROOT/contrib-data/pending/digest-test-d8.json"
mkdir -p "$SB_ROOT/contrib-data/pending"
mk_batch_file "$BATCHF" false "k-i"
seed_flight_digest "t_old" "$BATCHF" "$(( $(date +%s) - 120 ))"
seed_card_store "running"
EV_BEFORE="$(events_total)"
run_flush -e STUB_KANBAN_CARD_STATUS=running -e DIGEST_STALE_SECS=60 >/dev/null
ge1 "$(claude_calls)" "D8 stale → fallback 被调"
assert_eq "$(send_calls)" "1" "D8 兜底发送"
assert_eq "$(events_pushed_true)" "1" "D8 兜底成功标记已推"
if flight_exists; then
  _fail "D8 登记已清" "陈旧 flight 未清（停摆放大）"
else
  _pass "D8 登记已清"
fi
if [ -e "$BATCHF" ]; then _fail "D8 快照已删" "快照残留: $BATCHF"; else _pass "D8 快照已删"; fi
assert_eq "$(create_digest_calls)" "0" "D8 陈旧在飞不建新卡"
if [ "$(events_total)" -ge "$(( EV_BEFORE + 1 ))" ]; then
  _pass "D8 stale 分支 event 入账（事件族 key 未钉，CONTRACT_AMBIGUOUS 只断言增长）"
else
  _fail "D8 stale 分支 event 入账" "事件总数 $EV_BEFORE → $(events_total)，未增长"
fi
sb_cleanup

# =============================================================================
t_case "D9 stale 守卫窗（SECS=3600，epoch-30s）→ 未超时 → 登记保留零动作"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-j" "守卫窗内事件 rq-11"
seed_flight_digest "t_old" "/tmp/batch-digest-fixture-d9.json" "$(( $(date +%s) - 30 ))"
seed_card_store "running"
run_flush -e STUB_KANBAN_CARD_STATUS=running -e DIGEST_STALE_SECS=3600 >/dev/null
assert_eq "$(flight_field '.card_id')" "t_old" "D9 守卫窗内 → 登记保留"
assert_eq "$(create_digest_calls)" "0" "D9 零建卡"
assert_eq "$(claude_calls)" "0" "D9 零 fallback（未超时）"
assert_eq "$(send_calls)" "0" "D9 零发送"
assert_eq "$(events_attempts_sum)" "0" "D9 attempts 不增"
sb_cleanup

# =============================================================================
t_case "D10 建卡失败（hermes down）→ fallback 被调 + 旧语义失败链（attempts+1，rc≠0）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-k" "建卡失败收口 rq-12"
run_flush -e STUB_HERMES_FAIL=1 >/dev/null; RC=$?
case "$(create_calls)" in
  0) _fail "D10 前置自证" "kanban create 零调用——注毒未生效，本用例空转" ;;
  *) _pass "D10 前置自证：建卡确实被尝试后失败" ;;
esac
ge1 "$(claude_calls)" "D10 建卡失败 → fallback _ai_digest 被调"
ge1 "$(send_calls)" "D10 兜底摘要发送被尝试（旧语义链）"
assert_eq "$(events_attempts_sum)" "1" "D10 发送失败 → attempts+1（挂账重试）"
assert_eq "$(events_pushed_true)" "0" "D10 零 pushed 翻转"
if [ -e "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]; then
  _fail "D10 失败不写登记" "建卡失败仍留 flight（下轮锁死在飞态）"
else
  _pass "D10 失败不写登记"
fi
assert_ne "0" "$RC" "D10 失败链 rc≠0（契约：摘要/发送失败向上传播）"
sb_cleanup

# =============================================================================
t_case "D11 建卡失败+claude 也败 → attempts+1+零 send+零 flight（摘要失败=搁置重试）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-l" "双重失败收口 rq-13"
run_flush -e STUB_HERMES_FAIL=1 -e STUB_CLAUDE_FAIL=1 >/dev/null; RC=$?
ge1 "$(claude_calls)" "D11 fallback claude 被调（后失败）"
assert_eq "$(send_calls)" "0" "D11 摘要失败 → 零发送（绝不 raw dump 兜底）"
assert_eq "$(events_attempts_sum)" "1" "D11 attempts+1"
assert_eq "$(events_pushed_true)" "0" "D11 事件保留"
if [ -e "$SB_ROOT/contrib-data/kanban-flight-digest.json" ]; then
  _fail "D11 零登记" "双重失败仍写 flight"
else
  _pass "D11 零登记"
fi
assert_ne "0" "$RC" "D11 失败链 rc≠0"
sb_cleanup

# =============================================================================
t_case "D12 fallback 空卡守卫：摘要产物仅报头 → 守卫触发 → 零 send+attempts+1"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
seed_narrative_event "k-m" "空卡守卫用例 rq-14"
# claude 产出仅报头（过 _ai_digest 尺寸校验但无实质内容）→ 空卡守卫必须拦在 send 之前
run_flush -e STUB_HERMES_FAIL=1 -e 'STUB_CLAUDE_OUT=🟠【contrib 告警】09-09' >/dev/null; RC=$?
ge1 "$(claude_calls)" "D12 fallback claude 被调（输出仅报头）"
assert_eq "$(send_calls)" "0" "D12 空卡守卫触发 → 零发送（守卫删除突变靶：直发空卡则红）"
assert_eq "$(events_attempts_sum)" "1" "D12 按失败挂账 attempts+1"
assert_ne "0" "$RC" "D12 守卫触发按失败处理 rc≠0"
sb_cleanup

# =============================================================================
t_case "D13 连续 3 败 → osascript 本地机械提示 + fallback_notice 当日置 1"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-n" "三败兜底用例 rq-15" contrib 2   # 预置 attempts=2，本轮 +1=3
run_flush -e STUB_HERMES_FAIL=1 -e STUB_CLAUDE_FAIL=1 >/dev/null
assert_eq "$(events_attempts_sum)" "3" "D13 attempts 2→3"
assert_stub_called "osascript" 1 "D13 3 败 → osascript 本地机械提示"
assert_eq "$(fallback_notice_today)" "1" "D13 fallback_notice 当日置 1（每至多一次/日）"
assert_eq "$(send_calls)" "0" "D13 摘要失败零发送"
sb_cleanup

# =============================================================================
t_case "D14 纯机械批回归：模板卡零 LLM 零建卡（send 正常链）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "probe-premise-dead" "mech-1" "radar 2026-09-09 premise 复验：rq-1 占坑出局"
run_flush >/dev/null; RC=$?
assert_exit 0 $RC "D14 flush exit"
assert_eq "$(create_digest_calls)" "0" "D14 纯机械批零 digest 建卡"
assert_eq "$(claude_calls)" "0" "D14 纯机械批零 LLM"
assert_eq "$(send_calls)" "1" "D14 模板卡经 _send 发送"
assert_eq "$(events_pushed_true)" "1" "D14 事件标记已推"
assert_eq "$(alerts_today)" "1" "D14 state_bump alerts"
assert_eq "$(events_attempts_sum)" "0" "D14 零 attempts"
BODYF="$(stub_last_body hermes)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  assert_file_contains "$BODYF" "速报" "D14 模板卡形态（速报报头）"
  assert_file_contains "$BODYF" "rq-1 占坑出局" "D14 模板卡含机械摘要"
else
  _fail "D14 模板卡 body 副本" "bodies/hermes-*.txt 缺失"
fi
sb_cleanup

# =============================================================================
t_case "D15 notify_digest=false 回归：叙事批不建卡直接挂账（现行为）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_config_set '.notify_digest = false'
seed_narrative_event "k-o" "digest 关闭态叙事事件 rq-16"
run_flush >/dev/null; RC=$?
assert_eq "$(create_digest_calls)" "0" "D15 零建卡"
assert_eq "$(claude_calls)" "0" "D15 零 LLM"
assert_eq "$(send_calls)" "0" "D15 零发送（挂账待 AI 会话转述）"
assert_eq "$(events_attempts_sum)" "1" "D15 挂账 attempts+1"
assert_exit 1 $RC "D15 exit 1（现行为保留）"
sb_cleanup

# =============================================================================
t_case "D16 混合批次（机械+叙事）→ 整批 digest 卡"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "own-pr-activity" "mech-mix" "自有 PR 有新动静"
seed_narrative_event "k-p" "混合批叙事事件 rq-17"
run_flush >/dev/null
assert_eq "$(create_digest_calls)" "1" "D16 混有任何叙事 → 整批 digest 卡"
assert_eq "$(claude_calls)" "0" "D16 建卡路零 LLM"
assert_eq "$(send_calls)" "0" "D16 混合批零直推（模板卡路不得接管）"
assert_eq "$(events_attempts_sum)" "0" "D16 挂账 attempts 不增"
sb_cleanup

t_finish
