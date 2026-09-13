#!/usr/bin/env bash
# =============================================================================
# t5-02-notify-send-digest.acceptance.test.sh — T5 验收②：send-digest 子命令四态+幂等快路+守卫+dry-run 全链
#   S1  正常态：OK 一行 + exit 0 + _send 被调（body=摘要文件内容，subject=contrib-watch 告警）
#       + 账本按批次 keys 标记 pushed + state_bump alerts + 批次文件回写 sent:true
#   S2  限额满：state alerts>=max → FAIL 一行 + exit 1 + 零发送 + 回写 sent:false（reason 含
#       limit 字面）+ 零账本标记（拒发即挂账语义）
#   S3  dry-run：NOTIFY_DRY_RUN=true → exit 0 + 打印完整消息体与目标 + 零真实发送 + 零账本标记
#       + 回写 sent:false（reason 含 dry-run 字面）
#   S4  锁超时：NOTIFY_LOCK 被占 → FAIL lock-timeout + exit 1 + 零发送 + 批次文件字节级零回写
#       （acquire_lock 静默 exit 0 的现状语义不得漏进 send-digest——重审 BLOCKER）
#   S5  幂等快路：批次文件 sent:true 已存在（首轮已发送）→ 二次调用 OK + exit 0 + 零新增发送
#       零新增账本动作
#   S6  空卡守卫：摘要仅报头 → FAIL + exit 1 + 零发送 + 批次文件不得标 sent:true
#   S7  dry-run 全链（验收标准 5）：dry_run=true 下 flush 建卡 → worker send-digest exit 0+
#       sent:false → 卡 done 后下轮 flush 走 fallback 接管 → 账本最终收敛（不丢不重）
# 依据：state.md「## 设计文档」§2 + 契约规约：
#   「send-digest --digest <摘要文件> --batch <批次json>；stdout 一行 OK/FAIL <原因>；exit 0/1；
#     空卡守卫照抄 flush 同款；限额拒发 reason=limit；dry-run reason=dry-run 且 exit 0；
#     锁超时输出 FAIL lock-timeout + exit 1（acquire_lock 本身不改）；成功=账本标记 pushed
#     （按批次 keys）+ state_bump alerts + 回写 sent:true；attempts 留给 flush fallback 路」
# 批次文件形态（黑盒 round-trip，零 schema 假设）：S1-S6 的批次文件一律取「flush 建卡产出的
#   真实快照」（flight.batch_file），S7 全链同理——被测实现自己的格式自己读写，测试只断言
#   契约语义面（OK/FAIL 行、exit 码、账本 pushed/attempts/alerts、sent 布尔可观测态）。
#   sent 布尔判读容忍紧凑/带空格 JSON 形态（batch_sent_state）。
# CONTRACT_AMBIGUOUS（红→回设计对齐，不是测试 bug）：
#   - S2/S3 的 reason 字面按契约钉 limit/dry-run（设计字面），以「回写载体中含该词」判读；
#     若实现把 reason 写往快照外载体（sidecar）则红 → 回设计对齐
# 红队纪律：黑盒（未读 notify.sh 本次改动）；每断言硬失败；无 skip。Mental Mutation：锁保护
#   缺失退回 acquire_lock 静默语义→S4 红；dry-run 误 exit 1/误标 sent:true→S3/S7 红；限额
#   检查删→S2 红；幂等快路删→S5 重复发送红；空卡守卫删→S6 红；账本标记与发送删→S1 红。
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

DIGEST_TOKEN='AAA-DIGEST-BODY-7c31'   # 摘要正文哨兵（外发载荷断言锚）

# ---- 本文件专用装具 ----

file_md5() { # <file> → md5（字节级零回写断言用）
  python3 -c 'import sys,hashlib;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

batch_sent_state() { # <file> → true|false|unknown（契约语义级判读，容忍 JSON 空格形态）
  local f="$1"
  if grep -qE '"sent"[[:space:]]*:[[:space:]]*true' "$f" 2>/dev/null; then printf true
  elif grep -qE '"sent"[[:space:]]*:[[:space:]]*false' "$f" 2>/dev/null; then printf false
  else printf unknown; fi
}

make_digest_file() { # <path> — 可过空卡守卫的摘要 fixture（报头+实质内容）
  printf '%s\n%s: 测试摘要正文 %s\n%s: 无需动作\n' \
    "🟠【contrib 告警】$(date +%m-%d)" "发生了什么" "$DIGEST_TOKEN" "建议动作" > "$1"
}

make_empty_digest_file() { # <path> — 仅报头（空卡守卫应拦）
  printf '%s\n' "🟠【contrib 告警】$(date +%m-%d)" > "$1"
}

make_real_batch() { # <key...> → stdout 快照路径（经 flush 建卡黑盒产出：seed 事件→flush→取 flight.batch_file）
  local k
  for k in "$@"; do
    sb_seed_event "pipeline-failure" "$k" "叙事事件 $k"
  done
  sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
  jq -r '.batch_file // empty' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null
}

run_send_digest() { # [-e K=V]... <batch_path> <digest_path> → stdout；rc 经 $?
  local -a pass=()
  while [ $# -gt 0 ] && [ "$1" = "-e" ]; do
    pass[${#pass[@]}]="-e"
    pass[${#pass[@]}]="$2"
    shift 2
  done
  local batch="$1" digest="$2"
  sb_run ${pass[@]+"${pass[@]}"} \
    "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$digest' --batch '$batch'"
}

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
send_calls()   { hermes_lines | grep -c '|send ' || true; }
first_line()   { printf '%s' "$1" | head -n 1; }

events_total() { wc -l < "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null | tr -d ' '; }
events_pushed_true() { jq -s '[.[] | select(.pushed == true)] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
events_attempts_sum() { jq -s '[.[] | (.attempts // 0)] | add' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
alerts_today() { jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

# =============================================================================
t_case "S1 正常态 → OK+exit 0+_send+账本标记 pushed+state_bump+回写 sent:true"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k1" "k2")"
if [ -z "$BATCH" ] || [ ! -f "$BATCH" ]; then
  _fail "S1 前置自证" "round-trip 快照未产出（BATCH=[$BATCH]）"; t_finish
fi
_pass "S1 前置自证：真实快照已产出"
DIG="$SB_ROOT/tmp/digest-s1.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
OUT="$(run_send_digest "$BATCH" "$DIG")"; RC=$?
assert_exit 0 $RC "S1 exit 0"
assert_eq "$(first_line "$OUT")" "OK" "S1 stdout 一行 OK（worker 收尾判据闭集）"
assert_eq "$(send_calls)" "1" "S1 _send 恰 1 次"
BODYF="$(stub_last_body hermes)"
if [ -n "$BODYF" ] && [ -f "$BODYF" ]; then
  assert_file_contains "$BODYF" "$DIGEST_TOKEN" "S1 外发载荷=摘要文件内容"
else
  _fail "S1 外发载荷副本" "bodies/hermes-*.txt 缺失"
fi
assert_contains "$(hermes_lines)" "contrib-watch 告警" "S1 subject=contrib-watch 告警（复用 _send 契约）"
assert_eq "$(batch_sent_state "$BATCH")" "true" "S1 批次文件回写 sent:true（可观测态）"
assert_eq "$(events_pushed_true)" "2" "S1 账本按批次 keys 标记 pushed（两事件）"
assert_eq "$(events_total)" "2" "S1 账本零重复行（整文件重写不丢行）"
assert_eq "$(events_attempts_sum)" "0" "S1 worker 卡不计数（attempts 留给 flush fallback 路）"
assert_eq "$(alerts_today)" "1" "S1 state_bump alerts"
sb_cleanup

# =============================================================================
t_case "S2 限额满 → FAIL+exit 1+零发送+回写 sent:false（reason 含 limit）+零账本标记"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k3")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "S2 前置自证" "快照未产出"; t_finish; }
DIG="$SB_ROOT/tmp/digest-s2.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
# 限额前置归用例自持（同 e10 口径：种子 max_alert_pushes_per_day 09-10 起镜像生产 30——
# 本用例只测「限额满拒发」分支，须显式 pin 上限=3 才有可判满的窗口）
sb_config_set '.max_alert_pushes_per_day = 3'
jq --arg d "$(date +%F)" '.alerts[$d] = 3' "$SB_ROOT/contrib-data/notify-state.json" \
  > "$SB_ROOT/contrib-data/notify-state.json.tmp" \
  && mv "$SB_ROOT/contrib-data/notify-state.json.tmp" "$SB_ROOT/contrib-data/notify-state.json"
OUT="$(run_send_digest "$BATCH" "$DIG")"; RC=$?
assert_exit 1 $RC "S2 exit 1"
case "$(first_line "$OUT")" in
  FAIL*) _pass "S2 stdout 一行 FAIL <原因>" ;;
  *) _fail "S2 stdout 一行 FAIL <原因>" "实=[$(first_line "$OUT")]" ;;
esac
assert_eq "$(send_calls)" "0" "S2 限额满拒发（零 hermes send）"
assert_eq "$(batch_sent_state "$BATCH")" "false" "S2 回写 sent:false"
if grep -q 'limit' "$BATCH" 2>/dev/null; then
  _pass "S2 reason 含 limit 字面（契约字面，CONTRACT_AMBIGUOUS：sidecar 载体则红）"
else
  _fail "S2 reason 含 limit 字面" "回写载体未含 limit"
fi
assert_eq "$(events_pushed_true)" "0" "S2 零账本标记（拒发即挂账，事件保留下轮）"
assert_eq "$(alerts_today)" "3" "S2 计数不再增长"
sb_cleanup

# =============================================================================
t_case "S3 dry-run → exit 0+打印完整消息体与目标+零真实发送+sent:false reason=dry-run"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k4")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "S3 前置自证" "快照未产出"; t_finish; }
DIG="$SB_ROOT/tmp/digest-s3.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
OUT="$(run_send_digest -e NOTIFY_DRY_RUN=true "$BATCH" "$DIG")"; RC=$?
assert_exit 0 $RC "S3 dry-run exit 0（worker 据此 normal-complete）"
assert_contains "$OUT" "dry-run" "S3 打印 dry-run 语义（同 _send 印记）"
assert_contains "$OUT" "$DIGEST_TOKEN" "S3 打印完整消息体"
assert_contains "$OUT" "weixin:test-target@sandbox" "S3 打印目标"
assert_eq "$(send_calls)" "0" "S3 零真实发送"
assert_eq "$(batch_sent_state "$BATCH")" "false" "S3 回写 sent:false"
if grep -q 'dry-run' "$BATCH" 2>/dev/null; then
  _pass "S3 reason 含 dry-run 字面（契约字面，CONTRACT_AMBIGUOUS：sidecar 载体则红）"
else
  _fail "S3 reason 含 dry-run 字面" "回写载体未含 dry-run"
fi
assert_eq "$(events_pushed_true)" "0" "S3 零账本标记（发送未发生，标记归 flush fallback 路）"
assert_eq "$(alerts_today)" "0" "S3 零 state_bump"
sb_cleanup

# =============================================================================
t_case "S4 锁超时 → FAIL lock-timeout+exit 1+零发送+批次文件字节级零回写"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k5")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "S4 前置自证" "快照未产出"; t_finish; }
DIG="$SB_ROOT/tmp/digest-s4.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
MD5_BEFORE="$(file_md5 "$BATCH")"
mkdir -p "$SB_ROOT/locks/notify.lock"   # 预占锁：send-digest 必须超时 FAIL 而非静默继续
OUT="$(run_send_digest "$BATCH" "$DIG")"; RC=$?
assert_exit 1 $RC "S4 exit 1（worker 按失败收尾，下轮 flush 兜底重试）"
case "$(first_line "$OUT")" in
  FAIL*lock-timeout*) _pass "S4 FAIL lock-timeout 输出闭集" ;;
  *) _fail "S4 FAIL lock-timeout 输出闭集" "实=[$(first_line "$OUT")]" ;;
esac
assert_eq "$(send_calls)" "0" "S4 锁超时零发送（无锁不得碰共享态）"
assert_eq "$(file_md5 "$BATCH")" "$MD5_BEFORE" "S4 批次文件字节级零回写"
assert_eq "$(events_pushed_true)" "0" "S4 账本零动作"
assert_eq "$(alerts_today)" "0" "S4 计数零动作"
sb_cleanup

# =============================================================================
t_case "S5 幂等快路：批次 sent:true 已存在（首轮已发）→ 二次调用 OK+exit 0+零新增发送零账本动作"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k6")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "S5 前置自证" "快照未产出"; t_finish; }
DIG="$SB_ROOT/tmp/digest-s5.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
run_send_digest "$BATCH" "$DIG" >/dev/null; RC1=$?
assert_exit 0 $RC1 "S5 首轮正常发送（构造 sent:true 前置）"
assert_eq "$(batch_sent_state "$BATCH")" "true" "S5 首轮回写 sent:true"
SEND_AFTER_1="$(send_calls)"
ALERTS_AFTER_1="$(alerts_today)"
OUT2="$(run_send_digest "$BATCH" "$DIG")"; RC2=$?
assert_exit 0 $RC2 "S5 二次调用 exit 0"
assert_eq "$(first_line "$OUT2")" "OK" "S5 二次 stdout OK"
assert_eq "$(send_calls)" "$SEND_AFTER_1" "S5 二次零新增发送（已发送批次不得二次外发）"
assert_eq "$(events_pushed_true)" "1" "S5 零新增账本动作（不重复标记）"
assert_eq "$(events_attempts_sum)" "0" "S5 attempts 零动作"
assert_eq "$(alerts_today)" "$ALERTS_AFTER_1" "S5 零新增 state_bump"
assert_eq "$(batch_sent_state "$BATCH")" "true" "S5 批次文件保持 sent:true"
sb_cleanup

# =============================================================================
t_case "S6 空卡守卫 → FAIL+exit 1+零发送+批次文件不得标 sent:true"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k7")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "S6 前置自证" "快照未产出"; t_finish; }
DIG="$SB_ROOT/tmp/digest-s6.md"
mkdir -p "$SB_ROOT/tmp"
make_empty_digest_file "$DIG"
OUT="$(run_send_digest "$BATCH" "$DIG")"; RC=$?
assert_exit 1 $RC "S6 exit 1"
case "$(first_line "$OUT")" in
  FAIL*) _pass "S6 stdout FAIL <原因>" ;;
  *) _fail "S6 stdout FAIL <原因>" "实=[$(first_line "$OUT")]" ;;
esac
assert_eq "$(send_calls)" "0" "S6 空卡守卫拦截 → 零发送（绝不发空壳卡）"
assert_ne "$(batch_sent_state "$BATCH")" "true" "S6 批次文件不得标 sent:true"
assert_eq "$(events_pushed_true)" "0" "S6 零账本标记"
sb_cleanup

# =============================================================================
t_case "S7 dry-run 全链：建卡 → send-digest dry-run → 卡 done 下轮 flush fallback 接管 → 账本收敛不丢不重"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
sb_seed_event "pipeline-failure" "k-dry" "dry-run 全链叙事事件 rq-8"
# 第一轮：dry-run 下 flush → 建 digest 卡（建卡为本地动作不受 dry-run 管）
sb_run -e NOTIFY_DRY_RUN=true 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
assert_eq "$(hermes_lines | grep -c 'kanban create' || true)" "1" "S7 第一轮建卡"
FLIGHT="$SB_ROOT/contrib-data/kanban-flight-digest.json"
[ -s "$FLIGHT" ] && _pass "S7 flight 登记" || { _fail "S7 flight 登记" "建卡后无 kanban-flight-digest.json"; t_finish; }
SNAP="$(jq -r '.batch_file' "$FLIGHT")"
[ -f "$SNAP" ] && _pass "S7 快照落盘" || _fail "S7 快照落盘" "快照缺失: $SNAP"
DIG="$SB_ROOT/tmp/digest-s7.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
# worker 步：send-digest 受 dry-run 管 → exit 0 + sent:false（不真发）
OUT="$(run_send_digest -e NOTIFY_DRY_RUN=true "$SNAP" "$DIG")"; RC=$?
assert_exit 0 $RC "S7 worker send-digest exit 0"
assert_ne "$(batch_sent_state "$SNAP")" "true" "S7 dry-run 不回写 sent:true（下轮不得误走零动作消费分支）"
# 第三轮：卡 done + 批次 sent 非 true → flush 必须走 fallback 接管（dry-run 只盖发送不盖账本）
# 卡库保持 flush 建卡的真实 id（勿覆写 store——flight.card_id 须可查），终态经旋钮注入
sb_run -e NOTIFY_DRY_RUN=true -e STUB_KANBAN_CARD_STATUS=done \
  'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
if [ -e "$FLIGHT" ]; then
  _fail "S7 登记已清" "fallback 接管后 flight 仍在"
else
  _pass "S7 登记已清"
fi
if [ -e "$SNAP" ]; then
  _fail "S7 快照已清" "fallback 消费后快照残留: $SNAP"
else
  _pass "S7 快照已清"
fi
assert_eq "$(events_total)" "1" "S7 账本不重：事件恰 1 行"
assert_eq "$(events_pushed_true)" "1" "S7 账本不丢：pushed 恰 1 次（fallback 接管完成收敛）"
assert_eq "$(events_attempts_sum)" "0" "S7 attempts 零（dry-run 下 fallback 成功链不计数）"
assert_eq "$(alerts_today)" "1" "S7 dry-run 只盖发送不盖账本（state_bump 照记，知识库坑口径）"
sb_cleanup

t_finish
