#!/usr/bin/env bash
# =============================================================================
# t5-03-notify-send-env-isolation.acceptance.test.sh — T5 验收③：send-digest 成功链路
#   hermes 子进程 env 剥离（HERMES_HOME / HERMES_PROFILE → env -u 语义，黑盒）
#   E1  注入态成功跑（P1）：worker env 注入 HERMES_HOME+HERMES_PROFILE → send-digest 后
#       $CONTRIB_TEST_STUB_LOG/hermes-env.log 恰 1 行且逐字等于
#       "hermes_home=absent hermes_profile=absent"（子进程 env 视角双 absent）
#       + 送达链路不变（exit 0 / stdout 一行 OK / hermes send 恰 1 次）
#   E2  注入态回写收敛（P2，同一成功跑内闭环）：批次文件末控制行 "sent": true
#       + send_result.success == true + sent_at 在场 + 账本按批次 keys pushed:true（不丢不重）
#       + notify-state alerts[今日]==1；并同跑复证 env log 逐字行（P1+P2 绑定同一次跑）
#   E3  非注入态回归（P3）：不注入两变量（sb_run env -i 本就不透传=真实缺省）→ 行为同 P2
#       且 env log 两变量 absent（未设时剥离必须 no-op，不得反向注入/不得置空串）
#   E4  注入态幂等快路组合：首轮成功后二次调用 → 零新增 send（快路不重发）；
#       若快路产生新 hermes 调用，其 env 视角仍须双 absent（剥离层不可绕过）
# 依据（设计契约，字面钉死）：
#   - _send 调 hermes 前剥离 HERMES_HOME/HERMES_PROFILE（env -u 语义；未设时 no-op），
#     其余 env 与调用方一致
#   - 命令契约不变：send-digest --digest <摘要文件> --batch <批次json> → stdout 一行
#     OK / FAIL <原因>；exit 0/1
#   - 副作用契约不变：成功 → 批次文件尾行 {sent:true, sent_at, send_result}
#     （send_result.success==true）+ events.jsonl 批次 keys pushed:true + alerts[今日]+1
#   - stub 装具契约（新）：影子 hermes stub 每次被调向 $CONTRIB_TEST_STUB_LOG/hermes-env.log
#     追加一行 hermes_home=(present|absent) hermes_profile=(present|absent)
#   - 沙箱：sb_run=env -i 白名单 → 两变量默认不透传；复现 worker env 须 -e 显式注入
# 历史坑显式规避（context.md「相关历史知识」）：
#   - 账本写入方多形态（jq 紧凑 / json.dumps 带空格）→ "sent" 判读一律 tolerant-spaced
#     grep（batch_tail_has_sent_true / batch_sent_flag 双格式），send_result 走 jq 结构化判读
#   - dry-run 只盖发送不盖账本 → 本文件全部走非 dry-run，发送与账本两口径不混
# CONTRACT_AMBIGUOUS（红 → 回设计对齐，不是测试 bug）：
#   - 批次尾控制行物理形态（JSONL 尾行 / 整对象合入）未知 → batch_control_obj 三形态
#     判读（尾行 jq 对象 → 整文件 jq 对象 → 含 "sent" 末行 jq 对象），全判不出=硬红
#   - P1「恰 1 行」以 send-digest 单次成功跑为窗口：前置 flush 建卡产生的 hermes 调用
#     不计入（跑前 rm -f 重置 hermes-env.log）；若实现在成功链路内另有 hermes 调用点 → 红
# 红队纪律：黑盒（未读 notify.sh 本次改动 / 未读影子 stub / 未读 unit/）；每断言硬失败；
#   无 skip。Mental Mutation：剥离整体删除 → E1/E2/E3 env log 行含 present 红；只剥
#   HERMES_HOME 不剥 HERMES_PROFILE（或反向半剥）→ 逐字断言红；剥离误写成反向注入或
#   置空串 → E3 红；剥离挂在非 hermes 路径装样子 → E1 env log 仍 present 红；幂等快路
#   删除二次重发 → E4 红；回写/账本标记/计数删 → E2 红。
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

DIGEST_TOKEN='BBB-DIGEST-BODY-t503'   # 摘要正文哨兵
ENV_STRIP_LINE='hermes_home=absent hermes_profile=absent'   # 契约逐字行（P1/P3）

# ---- 本文件专用装具 ----

make_digest_file() { # <path> — 可过空卡守卫的摘要 fixture（报头+实质内容）
  printf '%s\n%s: 测试摘要正文 %s\n%s: 无需动作\n' \
    "🟠【contrib 告警】$(date +%m-%d)" "发生了什么" "$DIGEST_TOKEN" "建议动作" > "$1"
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

run_send_digest_worker() { # <batch_path> <digest_path> → stdout（注入态：复现 kanban worker env，两变量显式注入子进程）
  local -a we=()
  we[${#we[@]}]="-e"
  we[${#we[@]}]="HERMES_HOME=$SB_ROOT/home/.hermes/profiles/contrib"
  we[${#we[@]}]="-e"
  we[${#we[@]}]="HERMES_PROFILE=contrib"
  run_send_digest ${we[@]+"${we[@]}"} "$1" "$2"
}

hermes_lines() { grep '^hermes|' "$SB_ROOT/stublog/calls.log" 2>/dev/null || true; }
send_calls()   { hermes_lines | grep -c '|send ' || true; }
first_line()   { printf '%s' "$1" | head -n 1; }
line_count()   { printf '%s' "$1" | grep -c ''; }

# ---- hermes-env.log 装具（stub 契约：每次被调追加一行 env 视角） ----

env_log_path() { printf '%s/hermes-env.log' "${CONTRIB_TEST_STUB_LOG:-/nonexistent}"; }

reset_env_log() { # 前置 flush 建卡的 hermes 调用不计入本跑窗口（见头注 CONTRACT_AMBIGUOUS）
  rm -f "$(env_log_path)"
  return 0
}

env_log_count() { # 行数（缺文件=0；容忍末行无换行：grep -c '' 计行）
  local f n
  f="$(env_log_path)"
  if [ ! -f "$f" ]; then
    printf '0'
    return 0
  fi
  n="$(grep -c '' "$f" 2>/dev/null)" || n=0
  printf '%s' "$n"
}

env_log_all() { cat "$(env_log_path)" 2>/dev/null || true; }

assert_env_log_exact() { # <label-prefix> — 恰 1 行且逐字等于剥离行（P1/P3 det-machine 谓词）
  local prefix="$1" n line
  n="$(env_log_count)"
  assert_eq "$n" "1" "$prefix hermes-env.log 恰 1 行（单次成功跑恰一次 hermes 子进程）"
  line="$(env_log_all | head -n 1)"
  assert_eq "$line" "$ENV_STRIP_LINE" "$prefix 子进程 env 视角逐字等于剥离行（两变量均 unset）"
}

# ---- 批次文件控制行判读（双格式容忍：jq 紧凑 / json.dumps 带空格） ----

batch_sent_flag() { # <file> → true|false|unknown（tolerant-spaced grep，同 t5-02 口径）
  local f="$1"
  if grep -qE '"sent"[[:space:]]*:[[:space:]]*true' "$f" 2>/dev/null; then printf true
  elif grep -qE '"sent"[[:space:]]*:[[:space:]]*false' "$f" 2>/dev/null; then printf false
  else printf unknown; fi
}

batch_tail_has_sent_true() { # <file> → rc 0 当末控制行含 "sent": true（整对象形态则看顶层 .sent）
  local f="$1" last
  last="$(tail -n 1 "$f" 2>/dev/null || true)"
  if printf '%s' "$last" | grep -qE '"sent"[[:space:]]*:[[:space:]]*true'; then
    return 0
  fi
  jq -e '.sent == true' "$f" >/dev/null 2>&1
}

batch_control_obj() { # <file> → 尾部控制记录 JSON（三形态判读；判不出输出空 → 断言层硬红）
  local f="$1" last
  last="$(tail -n 1 "$f" 2>/dev/null || true)"
  if [ -n "$last" ] && printf '%s' "$last" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$last"
    return 0
  fi
  if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    cat "$f"
    return 0
  fi
  last="$(grep '"sent"' "$f" 2>/dev/null | tail -n 1 || true)"
  if [ -n "$last" ] && printf '%s' "$last" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s' "$last"
    return 0
  fi
  return 0
}

assert_writeback_ok() { # <label-prefix> <batch_path> <expected_pushed> — P2 副作用契约全套
  local prefix="$1" batch="$2" want_pushed="$3" ctrl
  if batch_tail_has_sent_true "$batch"; then
    _pass "$prefix 批次文件末控制行 sent:true"
  else
    _fail "$prefix 批次文件末控制行 sent:true" "尾行与整对象两形态均未判出（见头注 CONTRACT_AMBIGUOUS）"
  fi
  ctrl="$(batch_control_obj "$batch")"
  if [ -n "$ctrl" ]; then
    assert_eq "$(printf '%s' "$ctrl" | jq -r '.sent // "MISSING"')" "true" "$prefix 控制记录 .sent==true（结构化）"
    assert_eq "$(printf '%s' "$ctrl" | jq -r '.send_result.success // "MISSING"')" "true" "$prefix send_result.success==true"
    assert_ne "$(printf '%s' "$ctrl" | jq -r '.sent_at // empty')" "" "$prefix 控制记录含 sent_at（契约尾行三键之一）"
  else
    _fail "$prefix 批次控制记录可解析" "尾行/整文件/含 sent 末行三形态均非 jq 对象"
  fi
  assert_eq "$(events_pushed_true)" "$want_pushed" "$prefix 账本按批次 keys 标记 pushed"
  assert_eq "$(events_total)" "$want_pushed" "$prefix 账本零重复行（整文件重写不丢行）"
  assert_eq "$(events_attempts_sum)" "0" "$prefix attempts 零（留给 flush fallback 路）"
  assert_eq "$(alerts_today)" "1" "$prefix notify-state alerts[今日]==1"
}

events_total() { wc -l < "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null | tr -d ' '; }
events_pushed_true() { jq -s '[.[] | select(.pushed == true)] | length' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
events_attempts_sum() { jq -s '[.[] | (.attempts // 0)] | add' "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo "?"; }
alerts_today() { jq -r --arg d "$(date +%F)" '.alerts[$d] // 0' "$SB_ROOT/contrib-data/notify-state.json" 2>/dev/null || echo "?"; }

# =============================================================================
t_case "E1 注入态成功跑 → env log 恰 1 行逐字双 absent（P1）+ 送达链路 OK+exit 0+send 恰 1 次"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k-env-1" "k-env-2")"
if [ -z "$BATCH" ] || [ ! -f "$BATCH" ]; then
  _fail "E1 前置自证" "round-trip 快照未产出（BATCH=[$BATCH]）"; t_finish
fi
_pass "E1 前置自证：真实快照已产出"
DIG="$SB_ROOT/tmp/digest-e1.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
reset_env_log
OUT="$(run_send_digest_worker "$BATCH" "$DIG")"; RC=$?
assert_exit 0 $RC "E1 exit 0"
assert_eq "$(first_line "$OUT")" "OK" "E1 stdout 一行 OK（命令契约不变）"
assert_eq "$(line_count "$OUT")" "1" "E1 stdout 恰一行（闭集）"
assert_eq "$(send_calls)" "1" "E1 hermes send 恰 1 次"
assert_env_log_exact "E1"
sb_cleanup

# =============================================================================
t_case "E2 注入态回写收敛（P2，同一成功跑） → 批次尾控制行 sent:true+send_result.success+账本 pushed+alerts==1"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k-env-3" "k-env-4")"
if [ -z "$BATCH" ] || [ ! -f "$BATCH" ]; then
  _fail "E2 前置自证" "round-trip 快照未产出（BATCH=[$BATCH]）"; t_finish
fi
DIG="$SB_ROOT/tmp/digest-e2.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
reset_env_log
OUT="$(run_send_digest_worker "$BATCH" "$DIG")"; RC=$?
assert_exit 0 $RC "E2 exit 0"
assert_eq "$(first_line "$OUT")" "OK" "E2 stdout 一行 OK"
assert_eq "$(send_calls)" "1" "E2 hermes send 恰 1 次"
assert_writeback_ok "E2" "$BATCH" "2"
assert_env_log_exact "E2 同跑复证"
sb_cleanup

# =============================================================================
t_case "E3 非注入态回归（P3） → 行为同 P2 且 env log 双 absent（no-op 剥离零 env 泄露）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k-env-5")"
if [ -z "$BATCH" ] || [ ! -f "$BATCH" ]; then
  _fail "E3 前置自证" "round-trip 快照未产出（BATCH=[$BATCH]）"; t_finish
fi
DIG="$SB_ROOT/tmp/digest-e3.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
reset_env_log
# 无 -e 注入：sb_run env -i 两变量本就不透传 = 真实未设态（剥离必须 no-op）
OUT="$(run_send_digest "$BATCH" "$DIG")"; RC=$?
assert_exit 0 $RC "E3 exit 0"
assert_eq "$(first_line "$OUT")" "OK" "E3 stdout 一行 OK"
assert_eq "$(send_calls)" "1" "E3 hermes send 恰 1 次"
assert_writeback_ok "E3" "$BATCH" "1"
assert_env_log_exact "E3"
sb_cleanup

# =============================================================================
t_case "E4 注入态幂等快路组合 → 二次调用零新增 send；新增 hermes 调用（若有）env 视角仍双 absent"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
BATCH="$(make_real_batch "k-env-6")"
if [ -z "$BATCH" ] || [ ! -f "$BATCH" ]; then
  _fail "E4 前置自证" "round-trip 快照未产出（BATCH=[$BATCH]）"; t_finish
fi
DIG="$SB_ROOT/tmp/digest-e4.md"
mkdir -p "$SB_ROOT/tmp"
make_digest_file "$DIG"
run_send_digest_worker "$BATCH" "$DIG" >/dev/null; RC1=$?
assert_exit 0 $RC1 "E4 首轮正常发送（构造 sent:true 前置）"
assert_eq "$(batch_sent_flag "$BATCH")" "true" "E4 首轮回写 sent:true"
SEND_AFTER_1="$(send_calls)"
ENV_N_1="$(env_log_count)"
ALERTS_1="$(alerts_today)"
OUT2="$(run_send_digest_worker "$BATCH" "$DIG")"; RC2=$?
assert_exit 0 $RC2 "E4 二次调用 exit 0"
assert_eq "$(first_line "$OUT2")" "OK" "E4 二次 stdout OK"
assert_eq "$(send_calls)" "$SEND_AFTER_1" "E4 二次零新增发送（幂等快路不重发）"
ENV_N_2="$(env_log_count)"
if [ "$ENV_N_2" -gt "$ENV_N_1" ]; then
  NEWLINES="$(env_log_all | tail -n "+$((ENV_N_1 + 1))")"
  assert_not_contains "$NEWLINES" "hermes_home=present" "E4 快路新增 hermes 调用 env 视角 hermes_home absent"
  assert_not_contains "$NEWLINES" "hermes_profile=present" "E4 快路新增 hermes 调用 env 视角 hermes_profile absent"
else
  _pass "E4 快路零新增 hermes 调用（env log 零增长）"
fi
assert_eq "$(alerts_today)" "$ALERTS_1" "E4 二次零新增计数"
assert_eq "$(batch_sent_flag "$BATCH")" "true" "E4 批次文件保持 sent:true"
sb_cleanup

t_finish
