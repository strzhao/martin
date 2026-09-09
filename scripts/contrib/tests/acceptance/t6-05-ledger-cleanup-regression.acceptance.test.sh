#!/usr/bin/env bash
# =============================================================================
# t6-05-ledger-cleanup-regression.acceptance.test.sh — T6 验收⑤：挂账清理回归
#   H1  healthcheck「rc=0 输出非数组」分支 stub 用例（T6 挂账清单）：resp=JSON object 或
#       空白 → FAIL + down 计数；连续第 2 次 → exit 3；恢复 → 清零
#   H2  B-2 陈旧佐证：NOTIFY_SEND_LAST 非本轮写入（mtime < 调用起点）→ send 失败回写
#       不带佐证（send_result 不出现 success:true）；新鲜佐证保留面由 H2b 钉死防 No-op 删证
#   H3  B-3 digest 消费分支补删 body.md/card.json：done+sent:true 消费 / done+未sent fallback
#       接管 / blocked 失败终态 fallback 三分支，digest-<ts>.{json,digest.md,body.md,card.json}
#       四族文件全清
#   H4  SKILL.md 模式一回落段删除回归锚：模式一段零 pending-hits + 批次数据源词仍在
#   H5  t1-03 旋钮名修正：死旋钮 token 零残留（静态）+ 旋钮行为有效性（黑盒双态）
#   H6  既有套件改锚后仍全绿：t1-01（board seam 打破 create argv 邻接断言）/ t1-02（兼容写
#       撤销打破双写断言）/ t1-03（旋钮名）子进程实跑 summary failed==0
# 依据：state.md 输出契约 6「挂账清理：B-2 陈旧佐证（notify.sh send 失败回写校验新鲜度
#   mtime > 调用起点才算佐证，否则不带）/ B-3 digest body.md+card.json 消费清理 / healthcheck
#   非数组分支用例 / QC_OPEN 死变量（t6-04）/ t1-03 旋钮名漂移修」+ §2「SKILL.md 模式一删
#   『空则回落 pending-hits.json（兼容）』句」+ 验收标准 1「run.sh 全量绿」
# CONTRACT_AMBIGUOUS：
#   - B-2 的失败注入用「NOTIFY_SEND_LAST 指向只读目录内陈旧文件 + STUB_HERMES_FAIL」双保险，
#     使 _send 无论经重定向失败还是 stub 失败都走失败路；佐证断言收在语义面「send_result 不带
#     success:true」（实现若先写临时文件再落位，本轮写入的失败载荷属新鲜佐证，允许带上）
#   - H6 的 t1-01/t1-02 改锚是 T6 的隐含必做（board seam/兼容写撤销打破其既有断言；验收标准 1
#     要求 run.sh 全绿）；子进程实跑是对改锚质量的直接验收
# 红队纪律：黑盒；每断言硬失败；无 skip。
# Mental Mutation：非数组分支缺用例属挂账本身（H1 即新增覆盖）；B-2 未修→H2 红；B-2 过修成
#   永不带证→H2b 红；B-3 只删部分族文件/只改一个分支→H3 三分支必红；SKILL 回落句残留→H4 红；
#   旋钮名没修→H5 静态+行为双红；既有套件没改锚→H6 红。
# =============================================================================
set -u
REPO_ROOT="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" rev-parse --show-toplevel 2>/dev/null || echo /Users/stringzhao/workspace/martin)"
TESTS_ROOT="$REPO_ROOT/scripts/contrib/tests"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$REPO_ROOT/scripts/contrib}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=acceptance
T_FILE="$(basename "${BASH_SOURCE[0]}")"
source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"

t_init "$T_FILE"

SKILL_MD="$REPO_ROOT/.claude/skills/contrib-watch/SKILL.md"

# ---- 本文件专用工具 ----

DIGEST_TOKEN='ACC-T6-DIGEST-BODY-5d17'

file_md5() { python3 -c 'import sys,hashlib;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null || echo "unreadable"; }

make_digest_file() { printf '%s\n%s: 测试摘要正文 %s\n%s: 无需动作\n' \
  "🟠【contrib 告警】$(date +%m-%d)" "发生了什么" "$DIGEST_TOKEN" "建议动作" > "$1"; }

make_real_batch() { # <key...> → flush 建卡产出的真实快照路径（黑盒 round-trip）
  local k
  for k in "$@"; do
    sb_seed_event "pipeline-failure" "$k" "叙事事件 $k"
  done
  sb_run 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null
  jq -r '.batch_file // empty' "$SB_ROOT/contrib-data/kanban-flight-digest.json" 2>/dev/null
}

run_send_digest() { # [-e K=V]... <batch> <digest>
  local -a pass=()
  while [ $# -gt 0 ] && [ "$1" = "-e" ]; do
    pass[${#pass[@]}]="-e"; pass[${#pass[@]}]="$2"; shift 2
  done
  local batch="$1" digest="$2"
  sb_run ${pass[@]+"${pass[@]}"} \
    "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$digest' --batch '$batch'"
}

run_healthcheck() { sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck'; }

write_hermes_raw() { # <text>：覆写沙箱 hermes 为「exit 0 原样输出」裸 stub。
  # 共享 stub 的 STUB_HERMES_OUT 旋钮在 kanban 分支之后才生效，打不到 `kanban list`
  # （healthcheck 探测面）——非数组输出注入必须走 bin/ 覆写
  cat > "$SB_ROOT/bin/hermes" <<EOF
#!/bin/bash
printf '%s\n' '$1'
exit 0
EOF
  chmod +x "$SB_ROOT/bin/hermes"
}
write_hermes_default() { # 恢复共享影子 stub
  cp "$CONTRIB_TEST_STUBS/hermes" "$SB_ROOT/bin/hermes" && chmod +x "$SB_ROOT/bin/hermes"
}
down_count() { cat "$SB_ROOT/contrib-data/.hermes-down" 2>/dev/null || printf '0'; }
hermes_down_events() {
  jq -s '[.[] | select(((.key // "") | endswith("-hermes-down")))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}
hermes_lines()  { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
create_calls()  { hermes_lines | grep -c 'kanban create' || true; }
scan_create_calls() { hermes_lines | grep -c 'kanban create.*idempotency-key scan-' || true; }
claude_scan_calls() { grep '^claude|' "$SB_ROOT/stublog/calls.log" 2>/dev/null | grep -c 'contrib-watch scan' || true; }

events_total() { wc -l < "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null | tr -d ' '; }
events_pushed_true() { jq -s '[.[] | select(.pushed == true)] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
first_line() { printf '%s' "$1" | head -n 1; }
control_row() { jq -s '.[-1]' "$1" 2>/dev/null; }

mk_issues() {
  local out="$1" s="$2" e="$3" i
  {
    printf '['
    for ((i = s; i <= e; i++)); do
      [ "$i" -gt "$s" ] && printf ','
      printf '{"number":%d,"title":"gateway regression %d","labels":[{"name":"bug"}],"user":{"login":"alice"},"created_at":"2026-09-09T00:00:00Z","comments":0,"pull_request":null}' "$i" "$i"
    done
    printf ']\n'
  } > "$out"
}
seed_cursor() { jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' > "$SB_ROOT/contrib-data/scan-cursor.json"; }
seed_flight() {
  jq -n --arg id "$1" --arg bf "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" --argjson ep "$2" \
    '{kind:"scan",card_id:$id,batch_file:$bf,created_epoch:$ep}' > "$SB_ROOT/contrib-data/kanban-flight-scan.json"
}
seed_card_store() { printf '{"id":"t_old","status":"%s","assignee":"contrib","priority":0}\n' "$1" > "$SB_ROOT/stublog/kanban-cards.jsonl"; }
flight_card_id() { jq -r '.card_id // ""' "$SB_ROOT/contrib-data/kanban-flight-scan.json" 2>/dev/null || echo ""; }

GHF=""
rw_common_setup() {
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  mkdir -p "$SB_ROOT/tmp"
  mk_issues "$SB_ROOT/tmp/issues.json" 101 101
  seed_cursor 100
  GHF="STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json"
}
run_watch() { sb_run -e "$GHF" "$@"; }

# =============================================================================
t_case "H1a healthcheck rc=0 + JSON object 输出 → FAIL + down=1 + exit 1 + -hermes-down 告警恰 1 条"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
write_hermes_raw '{"success":true,"id":"not-an-array"}'
OUT="$(run_healthcheck)"; RC=$?
case "$(first_line "$OUT")" in
  FAIL*) _pass "5.1 stdout FAIL <原因>" ;;
  *) _fail "5.1 stdout FAIL <原因>" "实=[$(first_line "$OUT")]（rc=0 但非数组输出必须判 FAIL）" ;;
esac
assert_exit 1 $RC "5.1 首败 exit 1"
assert_eq "$(down_count)" "1" "5.1 down 计数=1"
assert_eq "$(hermes_down_events)" "1" "5.1 -hermes-down 告警恰 1 条"
sb_cleanup

# =============================================================================
t_case "H1b healthcheck rc=0 + 空白输出 → FAIL + 计数（空响应同属非数组闭集外）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
write_hermes_raw '   '
OUT="$(run_healthcheck)"; RC=$?
case "$(first_line "$OUT")" in
  FAIL*) _pass "5.2 stdout FAIL <原因>" ;;
  *) _fail "5.2 stdout FAIL <原因>" "实=[$(first_line "$OUT")]" ;;
esac
assert_exit 1 $RC "5.2 exit 1"
assert_eq "$(down_count)" "1" "5.2 down 计数=1"
sb_cleanup

# =============================================================================
t_case "H1c 连续第 2 次非数组 → exit 3 + down=2（不重复告警）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
write_hermes_raw '{"a":1}'
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck' >/dev/null
OUT="$(run_healthcheck)"; RC=$?
assert_exit 3 $RC "5.3 连续第 2 次 exit 3（调用方跳过建卡走 fallback）"
assert_eq "$(down_count)" "2" "5.3 down 计数=2"
assert_eq "$(hermes_down_events)" "1" "5.3 告警不重复（仍 1 条）"
sb_cleanup

# =============================================================================
t_case "H1d 非数组失败后恢复 → exit 0 + OK + down 清零（唯一清零点=探测成功）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
write_hermes_raw '{"a":1}'
sb_run 'bash "$MARTIN_DIR/scripts/contrib/kanban_card.sh" healthcheck' >/dev/null
assert_eq "$(down_count)" "1" "5.4 前置：down=1"
write_hermes_default
OUT="$(run_healthcheck)"; RC=$?
assert_exit 0 $RC "5.4 恢复 exit 0"
assert_eq "$OUT" "OK" "5.4 stdout OK"
assert_eq "$(down_count)" "0" "5.4 down 清零"
sb_cleanup

# =============================================================================
t_case "H2 B-2 陈旧佐证：NOTIFY_SEND_LAST 非本轮写入 + send 失败 → 回写不带 success:true 佐证"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
BATCH="$(make_real_batch "k-t6-b2-stale")"
if [ -z "$BATCH" ] || [ ! -f "$BATCH" ]; then _fail "5.5 前置自证" "round-trip 快照未产出"; t_finish; fi
DIG="$SB_ROOT/tmp/digest-b2.md"
make_digest_file "$DIG"
RO="$SB_ROOT/tmp/ro"
mkdir -p "$RO"
printf '{"success":true,"id":"STALE-9f2c","note":"stale-corroboration-fixture"}\n' > "$RO/last.json"
chmod 444 "$RO/last.json"
chmod 555 "$RO"
touch -t 202001010000 "$RO/last.json"   # mtime 远早于调用起点
# 双保险失败注入：NOTIFY_SEND_LAST 落只读目录（重定向失败→文件不被本轮触碰）+ stub hermes 必败
OUT="$(sb_run -e "NOTIFY_SEND_LAST=$RO/last.json" -e STUB_HERMES_FAIL=1 \
  "bash \"\$MARTIN_DIR/scripts/contrib/notify.sh\" send-digest --digest '$DIG' --batch '$BATCH'")"; RC=$?
assert_exit 1 $RC "5.5 send 失败 exit 1"
case "$(first_line "$OUT")" in
  FAIL*) _pass "5.5 stdout FAIL <原因>" ;;
  *) _fail "5.5 stdout FAIL <原因>" "实=[$(first_line "$OUT")]" ;;
esac
ROW="$(control_row "$BATCH")"
assert_eq "$(printf '%s' "$ROW" | jq -r '.sent == false')" "true" "5.5 控制行 sent=false（失败回写已发生；不用 // 判布尔防 false 塌缩）"
assert_eq "$(printf '%s' "$ROW" | jq -r '.reason // ""')" "send" "5.5 控制行 reason=send"
SR_SUCC="$(printf '%s' "$ROW" | jq -r '.send_result.success // "absent"')"
case "$SR_SUCC" in
  true) _fail "5.5 回写不带陈旧佐证" "send_result.success=true（陈旧文件被当本轮佐证，B-2 未修）" ;;
  absent|false) _pass "5.5 回写不带陈旧佐证（send_result=$SR_SUCC/null 或本轮新鲜失败载荷）" ;;
  *) _fail "5.5 回写不带陈旧佐证" "send_result.success 解析异常 [$SR_SUCC]" ;;
esac
chmod -R u+rwx "$RO" 2>/dev/null   # 解除只读，放行 sb_cleanup
sb_cleanup

# =============================================================================
t_case "H2b B-2 新鲜佐证保留：本轮真实成功 → sent:true + send_result.success==true（防过修删证）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
BATCH="$(make_real_batch "k-t6-b2-fresh")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "5.6 前置自证" "快照未产出"; t_finish; }
DIG="$SB_ROOT/tmp/digest-b2b.md"
make_digest_file "$DIG"
OUT="$(run_send_digest "$BATCH" "$DIG")"; RC=$?
assert_exit 0 $RC "5.6 成功 exit 0"
assert_eq "$(first_line "$OUT")" "OK" "5.6 stdout OK"
ROW="$(control_row "$BATCH")"
assert_eq "$(printf '%s' "$ROW" | jq -r '.sent == true')" "true" "5.6 sent=true"
assert_eq "$(printf '%s' "$ROW" | jq -r '.send_result.success == true')" "true" "5.6 新鲜佐证仍在（send_result.success=true；永不高危删证）"
sb_cleanup

# =============================================================================
t_case "H3a B-3 消费分支 done+sent:true：四族文件（json/digest.md/body.md/card.json）全清 + 零新卡 + 账本收敛"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
BATCH="$(make_real_batch "k-t6-b3a" "k-t6-b3b")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "5.7 前置自证" "快照未产出"; t_finish; }
BODYF="${BATCH%.json}.body.md"
CARDF="${BATCH%.json}.card.json"
DIGF="${BATCH%.json}.digest.md"
[ -f "$BODYF" ] && [ -f "$CARDF" ] && _pass "5.7 前置自证：body.md/card.json 建卡产物在盘" \
  || { _fail "5.7 前置自证" "body/card.json 缺失（${BODYF}/${CARDF})"; t_finish; }
make_digest_file "$DIGF"    # worker 角色写摘要文件
OUT="$(run_send_digest "$BATCH" "$DIGF")"; RC=$?
assert_exit 0 $RC "5.7 worker send-digest OK（构造 sent:true）"
assert_eq "$(events_pushed_true)" "2" "5.7 两事件已 pushed"
sb_seed_event "pipeline-failure" "k-t6-b3c" "叙事事件 k-t6-b3c"
sb_state_set '.last_flush_epoch = 0'
sb_run -e STUB_KANBAN_CARD_STATUS=done 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null; RC=$?
assert_exit 0 $RC "5.7 消费轮 flush exit"
assert_eq "$(create_calls)" "1" "5.7 零新卡（消费轮不建卡防卡风暴）"
for f in "$BATCH" "$DIGF" "$BODYF" "$CARDF" "$SB_ROOT/contrib-data/kanban-flight-digest.json"; do
  if [ -e "$f" ]; then
    _fail "5.7 消费清理 $(basename "$f")" "残留：${f}（B-3 未清 body.md/card.json 或消费分支漏删）"
  else
    _pass "5.7 消费清理 $(basename "$f")"
  fi
done
assert_eq "$(events_total)" "3" "5.7 账本不重（3 行）"
assert_eq "$(events_pushed_true)" "2" "5.7 消费轮零账本动作：前两事件 pushed，新事件 k-t6-b3c 留待下轮（双写禁止）"
sb_cleanup

# =============================================================================
t_case "H3b B-3 done+未 sent → fallback 接管：snapshot/body.md/card.json 全清 + 账本收敛"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
BATCH="$(make_real_batch "k-t6-b3d")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "5.8 前置自证" "快照未产出"; t_finish; }
BODYF="${BATCH%.json}.body.md"
CARDF="${BATCH%.json}.card.json"
[ -f "$BODYF" ] && [ -f "$CARDF" ] && _pass "5.8 前置自证：body.md/card.json 在盘" \
  || { _fail "5.8 前置自证" "$BODYF / $CARDF 缺失"; t_finish; }
sb_state_set '.last_flush_epoch = 0'
sb_run -e STUB_KANBAN_CARD_STATUS=done 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null; RC=$?
assert_exit 0 $RC "5.8 flush exit（fallback 接管）"
for f in "$BATCH" "$BODYF" "$CARDF" "$SB_ROOT/contrib-data/kanban-flight-digest.json"; do
  [ -e "$f" ] && _fail "5.8 消费清理 $(basename "$f")" "残留：$f" || _pass "5.8 消费清理 $(basename "$f")"
done
assert_eq "$(events_total)" "1" "5.8 账本恰 1 行"
assert_eq "$(events_pushed_true)" "1" "5.8 fallback 接管完成收敛（pushed=1）"
sb_cleanup

# =============================================================================
t_case "H3c B-3 blocked 失败终态 → fallback：snapshot/body.md/card.json 全清"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
BATCH="$(make_real_batch "k-t6-b3e")"
[ -n "$BATCH" ] && [ -f "$BATCH" ] || { _fail "5.9 前置自证" "快照未产出"; t_finish; }
BODYF="${BATCH%.json}.body.md"
CARDF="${BATCH%.json}.card.json"
[ -f "$BODYF" ] && [ -f "$CARDF" ] && _pass "5.9 前置自证：body.md/card.json 在盘" \
  || { _fail "5.9 前置自证" "$BODYF / $CARDF 缺失"; t_finish; }
sb_state_set '.last_flush_epoch = 0'
sb_run -e STUB_KANBAN_CARD_STATUS=blocked 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" flush' >/dev/null; RC=$?
assert_exit 0 $RC "5.9 flush exit（失败终态清登记走 fallback）"
for f in "$BATCH" "$BODYF" "$CARDF" "$SB_ROOT/contrib-data/kanban-flight-digest.json"; do
  [ -e "$f" ] && _fail "5.9 消费清理 $(basename "$f")" "残留：$f" || _pass "5.9 消费清理 $(basename "$f")"
done
assert_eq "$(events_pushed_true)" "1" "5.9 fallback 接管收敛（pushed=1）"
sb_cleanup

# =============================================================================
t_case "H4 SKILL.md 模式一回落段删除回归锚：模式一段零 pending-hits + 批次数据源词仍在"
if [ ! -f "$SKILL_MD" ]; then
  _fail "5.10 SKILL.md 存在" "$SKILL_MD 缺失"
else
  M1="$(awk '/^## 模式一/{f=1;next} /^## 模式二/{f=0} f' "$SKILL_MD")"
  if [ -z "$M1" ]; then
    _fail "5.10 模式一段存在" "awk 提取为空（标题结构变了？回归锚需人工复核）"
  else
    PH_N="$(printf '%s\n' "$M1" | grep -c 'pending-hits' || true)"
    assert_eq "$PH_N" "0" "5.10 模式一段零 pending-hits（『空则回落 pending-hits.json（兼容）』句已删）"
    if printf '%s\n' "$M1" | grep -q 'pending-batches\|scan-latest-batch'; then
      _pass "5.10 模式一批次数据源词仍在（唯一数据源=批次文件的指引锚）"
    else
      _fail "5.10 模式一批次数据源词仍在" "模式一段无 pending-batches/scan-latest-batch（数据源指引缺失）"
    fi
  fi
fi

# =============================================================================
t_case "H5a t1-03 旋钮行为有效性：RUN_OUTCOME 非闭集（agent_error）→ 非终态，零 fallback 登记保留"
rw_common_setup
seed_flight "t_old" "$(date +%s)"
seed_card_store "blocked"
run_watch -e STUB_KANBAN_RUN_OUTCOME=agent_error 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(claude_scan_calls)" "0" "5.11 非闭集 outcome 不 fallback（旋钮生效才会读到 agent_error）"
assert_eq "$(scan_create_calls)" "0" "5.11 非终态不建新卡"
assert_eq "$(flight_card_id)" "t_old" "5.11 登记保留（可自愈）"
sb_cleanup

# =============================================================================
t_case "H5b t1-03 旋钮行为有效性：CARD_STATUS=done 覆盖卡库 → 清旧登记建新卡"
rw_common_setup
seed_flight "t_old" "$(date +%s)"
seed_card_store "ready"
run_watch -e STUB_KANBAN_CARD_STATUS=done 'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null
assert_eq "$(scan_create_calls)" "1" "5.12 done → 本轮建新卡（旋钮生效才把 ready 覆盖成 done）"
assert_eq "$(claude_scan_calls)" "0" "5.12 done 路零 fallback"
CID="$(flight_card_id)"
case "$CID" in t_old|"") _fail "5.12 旧登记已清换新卡" "card_id=[$CID]" ;; *) _pass "5.12 新卡登记（${CID})" ;; esac
sb_cleanup

# =============================================================================
t_case "H5c t1-03 死旋钮 token 零残留（静态；全行注释剥离后）"
T103="$TESTS_ROOT/acceptance/t1-03-run-watch-flight.acceptance.test.sh"
if [ ! -f "$T103" ]; then
  _fail "5.13 t1-03 存在" "$T103 缺失"
else
  D1="$(grep -v '^[[:space:]]*#' "$T103" | grep -cE 'STUB_KANBAN_STATUS([^_]|$)' || true)"
  D2="$(grep -v '^[[:space:]]*#' "$T103" | grep -cE 'STUB_KANBAN_OUTCOME([^_]|$)' || true)"
  assert_eq "$D1" "0" "5.13 零 STUB_KANBAN_STATUS 死旋钮（应为 STUB_KANBAN_CARD_STATUS）"
  assert_eq "$D2" "0" "5.13 零 STUB_KANBAN_OUTCOME 死旋钮（应为 STUB_KANBAN_RUN_OUTCOME）"
fi

# =============================================================================
t_case "H6 既有套件改锚后仍全绿：t1-01/t1-02/t1-03 子进程实跑 summary failed==0"
run_suite() { # <file>
  local file="$1" out rc sum total failed
  [ -f "$file" ] && { _pass "$(basename "$file") 存在"; } || { _fail "$(basename "$file") 存在" "$file 缺失"; return 0; }
  out="$(bash "$file" 2>&1)"; rc=$?
  sum="$(printf '%s\n' "$out" | grep '^##SUMMARY ' | tail -1)"
  sum="${sum#\#\#SUMMARY }"   # 剥前缀再喂 jq（run.sh 同款；整行直喂=parse error exit 5）
  total="$(printf '%s' "$sum" | jq -r '.total // -1' 2>/dev/null)"
  failed="$(printf '%s' "$sum" | jq -r '.failed // -1' 2>/dev/null)"
  assert_exit 0 "$rc" "$(basename "$file") exit 0"
  assert_eq "$failed" "0" "$(basename "$file") summary failed==0（board seam/兼容写撤销/旋钮修正改锚后）"
  case "$total" in ''|*[!0-9]*|0) _fail "$(basename "$file") total>0" "total=[$total]（空跑=No-op）" ;; *) _pass "$(basename "$file") total>0（${total})" ;; esac
}
run_suite "$TESTS_ROOT/acceptance/t1-01-kanban-card-create.acceptance.test.sh"
run_suite "$TESTS_ROOT/acceptance/t1-02-scan-gate-batch.acceptance.test.sh"
run_suite "$TESTS_ROOT/acceptance/t1-03-run-watch-flight.acceptance.test.sh"

t_finish
