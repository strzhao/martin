#!/bin/bash
# duty-cardify.sh — Tier U：值班卡环（duty，2026-09-13）
# 覆盖（对应验收场景 7.P2 七类口径）：
#   ① create 成功建卡且 body 内嵌 brief（五段结构 / flight-duty 三键 / duty-<ts> 幂等键 /
#     --board 父级 flag 位 / --assignee contrib --max-retries 2 --json / 节流戳落盘 / 零 duty 事件）
#   ② 节流：窗口内第二次 create → 10 零新卡；--force 绕过节流
#   ③ 在飞：flight-duty 登记在途 → 10（零新卡，登记保留）；登记卡终态 / 坏 JSON → 自愈清后建卡
#   ④ harvest 幂等恒 0（终态清登记 / 在途保留 / 坏 JSON 保留不炸 / 查无清登记）
#   ⑤ apply 复核五条不合格目标只跳过（龄 ≤24h / running / rq awaiting-approval 三变体）——
#     零 archive 调用 + skipped 台账行落账（判据含状态与卡龄）+ 合格目标代行归档（executed 行）
#   ⑥ apply 幂等（已有 executed 行零重复归档调用，幂等跳过同落 skipped 行）
#     + --dry-run 与 DUTY_APPLY_DRY_RUN=1 零写入
#   ⑦ create 失败路径（stub state_brief rc≠0 / 空输出 / 缺「伤情判定」→ exit 1 且
#     events.jsonl 有 -duty-brief-fail 行，零卡零戳零登记）
#   ⑧ run-watch 值班段接线冒烟：板库守卫（无板惰性跳过 / 预置假板库恢复 create 触发面）
#     + 三连被调整轮 exit 0 + 同窗第二轮 create 节流零新增值班卡
# 全部经 CONTRIB_DATA_DIR/HERMES_BIN stub 沙箱隔离，绝不读写真实 contrib-data，绝不调用真实
# hermes/gh/claude——沙箱 stub 在无 STUB_LOG_DIR 的环境自拒（exit 97）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "duty-cardify.sh"

# ---- 通用工具 ----
count_create() { # stub hermes kanban create 调用次数（calls.log 缺失按 0）
  local f="$CONTRIB_TEST_STUB_LOG/calls.log"
  [[ -f "$f" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "hermes" && index($0, "kanban create") { c++ } END { printf "%d", c + 0 }' "$f" 2>/dev/null
}
count_duty_create() { # 值班卡 create 调用次数（容 --board pin：kanban 与 create 之间可插 --board <slug>）
  local f="$CONTRIB_TEST_STUB_LOG/calls.log"
  [[ -f "$f" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "hermes" && index($0, "kanban") && index($0, "create") && index($0, "值班卡") { c++ } END { printf "%d", c + 0 }' "$f" 2>/dev/null
}
count_archive() { # stub hermes kanban archive 调用次数
  local f="$CONTRIB_TEST_STUB_LOG/calls.log"
  [[ -f "$f" ]] || { printf '0'; return 0; }
  awk -F'|' '$1 == "hermes" && index($0, "kanban archive") { c++ } END { printf "%d", c + 0 }' "$f" 2>/dev/null
}
ev_key_count() { # <key 后缀>（endswith 口径，日期段不钉死）
  jq -s --arg s "$1" '[.[] | select(((.key // "") | endswith($s)))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}
duty_flight() { printf '%s/contrib-data/kanban-flight-duty.json' "$SB_ROOT"; }
duty_stamp() { printf '%s/contrib-data/.duty-last-create' "$SB_ROOT"; }
duty_ledger() { printf '%s/contrib-data/duty-ledger.md' "$SB_ROOT"; }
seed_flight_duty() { # <card_id> [epoch]
  jq -n --arg id "$1" --argjson e "${2:-$(date +%s)}" '{kind:"duty",card_id:$id,created_epoch:$e}' \
    >"$(duty_flight)"
}
seed_card_store() { # <card_id> <status>（标准 stub 有状态卡库）
  printf '{"id":"%s","status":"%s","assignee":"contrib","priority":0}\n' "$1" "$2" \
    >"$SB_ROOT/stublog/kanban-cards.jsonl"
}
ledger_rows() { # 台账数据行计数（^| 开头）
  local n
  n="$(grep -c '^|' "$(duty_ledger)" 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}
seed_ledger() { # <行...> — 每参数一行追加到 fixture 台账（含表头与行格式说明）
  {
    printf '# contrib 值班台账（fixture）\n\n行格式：| 时间 | 动作 | 对象 | 状态 | 判据：… | decisionReason：… |\n\n'
    local r
    for r in "$@"; do
      printf '%s\n' "$r"
    done
  } >"$(duty_ledger)"
}
quiet_sb() { # 新沙箱（scan/mail/radar 段静默底座 + 清 board seam 残留）
  unset SB_KANBAN_BOARD 2>/dev/null || true
  sb_new >/dev/null 2>&1
  mkdir -p "$SB_ROOT/mailstub"
  printf '[]\n' >"$SB_ROOT/mailstub/envelopes.json"
  printf '[]\n' >"$SB_ROOT/gh-issues.json"
  printf '{"last_issue":9000}\n' >"$SB_ROOT/contrib-data/scan-cursor.json"
  printf '[]\n' >"$SB_ROOT/contrib-data/pending-hits.json"
}
run_duty() { # <sub [args]> [K=V ...] — 沙箱内跑被测 duty_card.sh 子命令
  local sub="${1:-}"; shift
  local kv extra=()
  for kv in "$@"; do
    extra[${#extra[@]}]="-e"; extra[${#extra[@]}]="$kv"
  done
  sb_run ${extra[@]+"${extra[@]}"} \
    "bash \"\$MARTIN_DIR/scripts/contrib/duty_card.sh\" $sub" >/dev/null 2>&1
}
run_watch() { # 沙箱内真跑 run-watch.sh 副本（全套 stub，值班段接线冒烟用）
  sb_run -e "MAIL_STUB_ENVELOPES=$SB_ROOT/mailstub/envelopes.json" \
    -e "MAIL_STUB_DIR=$SB_ROOT/mailstub" \
    'zsh "$MARTIN_DIR/scripts/contrib/run-watch.sh"' >/dev/null 2>&1
}
install_brief_stub() { # 覆写沙箱内 state_brief.sh（DUTY_STUB_BRIEF 旋钮：ok/fail/empty/noanchor）
  cat >"$SB_ROOT/scripts/contrib/state_brief.sh" <<'EOF'
#!/bin/bash
# 测试内联 stub：state_brief（DUTY_STUB_BRIEF=ok|fail|empty|noanchor）
case "${DUTY_STUB_BRIEF:-ok}" in
  fail)
    echo "stub state_brief: forced fail" >&2
    exit 3
    ;;
  empty)
    exit 0
    ;;
  noanchor)
    printf '# contrib state brief（fixture，无判定锚）\n\n正文一行\n'
    ;;
  *)
    printf '# contrib state brief（fixture）\n\n## 1) contrib board 非终态全景\n- 伤情判定：正常 —— 沙箱 fixture\n'
    ;;
esac
exit 0
EOF
  chmod +x "$SB_ROOT/scripts/contrib/state_brief.sh"
}
install_duty_stub() { # 覆写沙箱内 hermes stub（apply 用：show 带 created_at/title/body）
  # DUTY_STUB_TASKS=<json 文件>：{"<卡id>": {"status","created_at","title","body"}}
  cat >"$SB_ROOT/bin/hermes" <<'EOF'
#!/bin/bash
# 测试内联 stub：duty apply 用 hermes（list/show/archive/create）
LOG_DIR="${STUB_LOG_DIR:-}"
if [[ -z "$LOG_DIR" ]]; then
  echo "duty-stub: STUB_LOG_DIR 未设置（拒绝在沙箱外运行）" >&2
  exit 97
fi
line="hermes|$PWD|"
first=1
for a in "$@"; do
  if [[ $first -eq 0 ]]; then line="$line "; fi
  line="$line${a//$'\n'/ }"
  first=0
done
printf '%s\n' "$line" >>"$LOG_DIR/calls.log"
if [[ "${1:-}" == "kanban" ]]; then
  _sub="${2:-}"
  _id="${3:-}"
  if [[ "$_sub" == "--board" ]]; then
    _sub="${4:-}"
    _id="${6:-}"
  fi
  case "$_sub" in
    list)
      if [[ -n "${DUTY_STUB_TASKS:-}" && -f "${DUTY_STUB_TASKS}" ]]; then
        jq -r 'to_entries | map({id: .key, status: (.value.status // "unknown")})' "$DUTY_STUB_TASKS" 2>/dev/null || printf '[]\n'
      else
        printf '[]\n'
      fi
      exit 0
      ;;
    show)
      if [[ -n "${DUTY_STUB_TASKS:-}" && -f "${DUTY_STUB_TASKS}" ]]; then
        jq -c --arg id "$_id" '.[$id] as $t | {task: ({id: $id} + ($t // {})), runs: [], children: []}' "$DUTY_STUB_TASKS" 2>/dev/null
      fi
      exit 0
      ;;
    archive)
      printf '{"success":true,"id":"%s"}\n' "$_id"
      exit 0
      ;;
    create)
      printf '{"id":"t_duty_stub","status":"ready"}\n'
      exit 0
      ;;
  esac
fi
printf '{"success":true}\n'
exit 0
EOF
  chmod +x "$SB_ROOT/bin/hermes"
}

# ================= ① create 成功建卡且 body 内嵌 brief =================

t_case "create 成功: 建卡 + body 五段内嵌 brief + flight 三键 + duty-<ts> 幂等键 + 节流戳 + board pin + 零 duty 事件"
quiet_sb
export SB_KANBAN_BOARD=contrib   # board seam：--board 插在 kanban 与子命令之间（父级 flag 位）
install_brief_stub
run_duty create
assert_exit 0 $?
assert_eq "$(ev_key_count '-duty-brief-fail')" "0" "成功路零 -duty-brief-fail 事件"
assert_eq "$(ev_key_count '-duty-card-fail')" "0" "成功路零 -duty-card-fail 事件"
create_line="$(awk -F'|' '$1 == "hermes" && index($0, "kanban") && index($0, "create") && index($0, "值班卡") { l = $0 } END { print l }' "$CONTRIB_TEST_STUB_LOG/calls.log" 2>/dev/null)"
assert_contains "$create_line" "kanban --board contrib create" "--board 插在 kanban 与 create 之间（父级 flag 位）"
assert_contains "$create_line" "contrib 值班卡 " "标题 contrib 值班卡 <YYYYMMDD-HHMM>"
assert_contains "$create_line" "--assignee contrib" "--assignee contrib"
assert_contains "$create_line" "--idempotency-key duty-" "幂等键 duty-<YYYYMMDD-HHMMSS>"
assert_contains "$create_line" "--max-retries 2" "--max-retries 2"
assert_contains "$create_line" "--json" "--json"
F="$(duty_flight)"
assert_eq "$(jq -r '.kind // empty' "$F" 2>/dev/null)" "duty" "flight kind=duty"
case "$(jq -r '.card_id // empty' "$F" 2>/dev/null)" in
  t_stub_*) _pass "flight card_id 登记" ;;
  *) _fail "flight card_id 登记" "actual=$(jq -r '.card_id' "$F" 2>/dev/null)" ;;
esac
assert_eq "$(jq -r '.created_epoch > 0' "$F" 2>/dev/null)" "true" "flight created_epoch"
body_copy="$(stub_last_body hermes)"
[[ -n "$body_copy" ]] || _fail "卡 body 可捕获" "stub bodies 缺副本"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "贡献域值班卡" "首段含 贡献域值班卡 字样"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "生成时间" "首段含生成时间"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "节流双闸" "首段含节流与在飞语义"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "## state brief 全文" "第二段标题"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "伤情判定" "brief 原样内嵌（锚字样）"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "## 行动手册（worker 契约，白名单与红线原文）" "第三段标题"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban-flight-" "手册白名单①清 flight 陈旧登记"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "rq.sh set" "手册白名单②rq.sh set expired"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "budget refund" "手册白名单③budget refund"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "archive-request" "手册 archive 只声明不执行"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "HERMES_DELEGATED_CHILD_CONTEXT" "手册含 fence 分工理由"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "rq-20260912-812574" "红线锚 rq-20260912-812574"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "t_f8c0d470" "红线锚 t_f8c0d470"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "pipeline-failure" "手册升级通道"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "duty-ledger.md" "手册台账路径"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "## 深入阅读指针" "第四段标题"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "SKILL.md" "指针含 SKILL.md 模式七"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "## 收尾要求" "第五段标题"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "kanban_complete" "收尾双传"
[[ -n "$body_copy" ]] && assert_file_contains "$body_copy" "三段式" "summary 三段式"
[[ -s "$(duty_stamp)" ]] && _pass "节流戳已落盘" || _fail "节流戳已落盘" "缺失"

# ================= ② 节流（第二次 create → 10；--force 绕过） =================

t_case "节流: 窗口内第二次 create → 10 零新卡（戳为 epoch 整数）；--force 绕过节流（先清在飞登记使 force 落到建卡步）"
quiet_sb
install_brief_stub
run_duty create
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "首轮建 1 张值班卡"
stamp="$(cat "$(duty_stamp)" 2>/dev/null || true)"
case "$stamp" in
  ''|*[!0-9]*) _fail "节流戳为 epoch 整数" "actual=[$stamp]" ;;
  *) _pass "节流戳为 epoch 整数" ;;
esac
run_duty create
assert_exit 10 $?
assert_eq "$(count_duty_create)" "1" "节流窗内零新卡"
# --force 只绕节流不绕在飞守卫：把首轮卡置终态清登记，让 force 落到建卡步
seed_card_store "$(jq -r '.card_id // empty' "$(duty_flight)" 2>/dev/null)" "done"
run_duty "create --force"
assert_exit 0 $?
assert_eq "$(count_duty_create)" "2" "--force 绕过节流建卡"

# ================= ③ 在飞（flight-duty 登记在途 → 10；终态/坏 JSON 自愈） =================

t_case "在飞: 登记在途 → create 10 零新卡且登记保留；登记卡终态/坏 JSON → 清登记自愈建新卡（DUTY_INTERVAL_SECS=0 隔离节流面）"
quiet_sb
install_brief_stub
seed_flight_duty "t_old"
seed_card_store "t_old" "running"
run_duty create "DUTY_INTERVAL_SECS=0"
assert_exit 10 $?
assert_eq "$(count_duty_create)" "0" "在飞零新卡（同时刻仅一张值班卡）"
assert_eq "$(jq -r '.card_id // empty' "$(duty_flight)" 2>/dev/null)" "t_old" "登记保留"
seed_card_store "t_old" "done"
run_duty create "DUTY_INTERVAL_SECS=0"
assert_exit 0 $?
assert_eq "$(count_duty_create)" "1" "登记卡终态 → 自愈后建新卡"
assert_ne "$(jq -r '.card_id // empty' "$(duty_flight)" 2>/dev/null)" "t_old" "登记换成新卡 id"
printf 'not-json{{{\n' >"$(duty_flight)"
run_duty create "DUTY_INTERVAL_SECS=0"
assert_exit 0 $?
assert_eq "$(count_duty_create)" "2" "坏 JSON → 清登记自愈建卡"

# ================= ④ harvest 幂等恒 0（终态清 / 在途保留 / 坏 JSON 不炸 / 查无清） =================

t_case "harvest: 终态清登记；连续第二次恒 0（幂等）"
quiet_sb
seed_flight_duty "t_old"
seed_card_store "t_old" "done"
run_duty harvest
assert_exit 0 $?
[[ -f "$(duty_flight)" ]] && _fail "终态登记已清" "残留" || _pass "终态登记已清"
run_duty harvest
assert_exit 0 $?
_pass "第二次 harvest 恒 0（幂等，无登记空转）"

t_case "harvest: 在途保留 / 坏 JSON 保留不炸 / 查无清登记（三态恒 0）"
quiet_sb
seed_flight_duty "t_old"
seed_card_store "t_old" "running"
run_duty harvest
assert_exit 0 $?
assert_eq "$(jq -r '.card_id // empty' "$(duty_flight)" 2>/dev/null)" "t_old" "在途登记保留"
printf 'not-json{{{\n' >"$(duty_flight)"
run_duty harvest
assert_exit 0 $?
assert_eq "$(cat "$(duty_flight)" 2>/dev/null)" "not-json{{{" "坏 JSON 保留（create 自愈面）"
seed_flight_duty "t_gone"
run_duty harvest "STUB_KANBAN_LIST_EMPTY=1"
assert_exit 0 $?
[[ -f "$(duty_flight)" ]] && _fail "查无登记已清" "残留" || _pass "查无登记已清"

# ================= ⑤ apply 复核五条：不合格只跳过 + 合格代行归档 =================

t_case "apply: 不合格目标只跳过（龄≤24h / running / rq awaiting-approval 三变体）——零 archive 调用 + skipped 台账行落账"
quiet_sb
install_duty_stub
install_brief_stub
NOW="$(date +%s)"
cat >"$SB_TMP/tasks.json" <<EOF
{
  "t_young": {"status": "blocked", "created_at": $((NOW - 3600)), "title": "孤儿卡 young", "body": ""},
  "t_run": {"status": "running", "created_at": $((NOW - 200000)), "title": "孤儿卡 run", "body": ""},
  "t_rq": {"status": "blocked", "created_at": $((NOW - 200000)), "title": "深检遗留卡", "body": "关联 rq-20260901-22222"}
}
EOF
sb_seed_queue_item "rq-20260901-22222" 22222 deep awaiting-approval 40
seed_ledger \
  "| 2026-09-13 10:00 | archive-request | t_young | pending | 判据：blocked 但龄不足 | decisionReason：worker 声明（模式七点三） |" \
  "| 2026-09-13 10:01 | archive-request | t_run | pending | 判据：worker 观察态 | decisionReason：worker 声明（模式七点三） |" \
  "| 2026-09-13 10:02 | archive-request | t_rq | pending | 判据：rq 处 awaiting-approval | decisionReason：worker 声明（模式七点三） |"
rows_before="$(ledger_rows)"
run_duty apply "DUTY_STUB_TASKS=$SB_TMP/tasks.json"
assert_exit 0 $?
assert_eq "$(count_archive)" "0" "不合格目标零 archive 调用（零 executed 行）"
assert_eq "$(ledger_rows)" "$((rows_before + 3))" "三变体恰 3 行 skipped 台账行"
assert_file_contains "$(duty_ledger)" "| archive | t_young | skipped |" "龄≤24h 变体 skipped 行"
assert_file_contains "$(duty_ledger)" "复核4 不过：卡龄=" "skipped 判据含不过项与卡龄"
assert_file_contains "$(duty_ledger)" "| archive | t_run | skipped |" "running 变体 skipped 行"
assert_file_contains "$(duty_ledger)" "复核2 不过：status=running 不在 {blocked,gave_up}" "running 变体 skipped 判据"
assert_file_contains "$(duty_ledger)" "| archive | t_rq | skipped |" "rq awaiting 变体 skipped 行"
assert_file_contains "$(duty_ledger)" "复核5 不过：rq-20260901-22222 态=awaiting-approval（审批链所有）" "rq 变体 skipped 判据（红线：审批链零触碰）"
assert_file_contains "$(duty_ledger)" "decisionReason：编排层代行（worker 进程被框架 fence，kanban 写 fail-closed）" "skipped 行 decisionReason 固定措辞"

t_case "apply: 合格目标代行归档——archive 调用 + executed 六列台账行（含判据与编排层 decisionReason）"
quiet_sb
install_duty_stub
install_brief_stub
NOW="$(date +%s)"
cat >"$SB_TMP/tasks.json" <<EOF
{
  "t_ok": {"status": "blocked", "created_at": $((NOW - 90000)), "title": "深检遗留卡", "body": "关联 rq-20260901-33333"}
}
EOF
sb_seed_queue_item "rq-20260901-33333" 33333 deep queued 40
seed_ledger "| 2026-09-13 10:00 | archive-request | t_ok | pending | 判据：blocked 25h，rq 无审批态项 | decisionReason：worker 声明（模式七点三） |"
run_duty apply "DUTY_STUB_TASKS=$SB_TMP/tasks.json"
assert_exit 0 $?
assert_eq "$(count_archive)" "1" "合格目标恰 1 次 archive 调用"
assert_file_contains "$(duty_ledger)" "| archive | t_ok | executed |" "executed 台账行"
assert_file_contains "$(duty_ledger)" "卡龄=" "判据含状态与龄"
assert_file_contains "$(duty_ledger)" "decisionReason：编排层代行（worker 进程被框架 fence，kanban 写 fail-closed）" "decisionReason 固定措辞"

# ================= ⑥ apply 幂等 + --dry-run 零写入 =================

t_case "apply 幂等: 已有 executed 行的目标不再执行（同批其他待处理目标照常）"
quiet_sb
install_duty_stub
install_brief_stub
NOW="$(date +%s)"
cat >"$SB_TMP/tasks.json" <<EOF
{
  "t_done": {"status": "blocked", "created_at": $((NOW - 90000)), "title": "已归档过", "body": ""},
  "t_next": {"status": "blocked", "created_at": $((NOW - 90000)), "title": "待归档", "body": ""}
}
EOF
seed_ledger \
  "| 2026-09-13 09:00 | archive-request | t_done | pending | 判据：blocked 25h | decisionReason：worker 声明（模式七点三） |" \
  "| 2026-09-13 09:30 | archive | t_done | executed | 判据：复核通过 status=blocked 卡龄=90000s | decisionReason：编排层代行（worker 进程被框架 fence，kanban 写 fail-closed） |" \
  "| 2026-09-13 10:00 | archive-request | t_next | pending | 判据：blocked 25h | decisionReason：worker 声明（模式七点三） |"
run_duty apply "DUTY_STUB_TASKS=$SB_TMP/tasks.json"
assert_exit 0 $?
assert_eq "$(count_archive)" "1" "仅 t_next 被归档（t_done 已 executed 幂等剔除，零重复归档调用）"
t_done_exec="$(grep -cF '| archive | t_done | executed |' "$(duty_ledger)" 2>/dev/null || true)"
assert_eq "${t_done_exec:-0}" "1" "t_done executed 行不重复（幂等不双写）"
assert_file_contains "$(duty_ledger)" "| archive | t_done | skipped |" "幂等跳过落 skipped 台账行"
assert_file_contains "$(duty_ledger)" "已有 executed 行幂等跳过" "幂等 skipped 判据"

t_case "apply --dry-run 与 DUTY_APPLY_DRY_RUN=1: 只打印清单零写入（零 archive 零台账行）"
quiet_sb
install_duty_stub
install_brief_stub
NOW="$(date +%s)"
cat >"$SB_TMP/tasks.json" <<EOF
{
  "t_dry": {"status": "blocked", "created_at": $((NOW - 90000)), "title": "深检遗留卡", "body": ""}
}
EOF
seed_ledger "| 2026-09-13 10:00 | archive-request | t_dry | pending | 判据：blocked 25h | decisionReason：worker 声明（模式七点三） |"
rows_before="$(ledger_rows)"
run_duty "apply --dry-run" "DUTY_STUB_TASKS=$SB_TMP/tasks.json"
assert_exit 0 $?
assert_eq "$(count_archive)" "0" "--dry-run 零 archive 调用"
assert_eq "$(ledger_rows)" "$rows_before" "--dry-run 零台账写入"
run_duty apply "DUTY_APPLY_DRY_RUN=1" "DUTY_STUB_TASKS=$SB_TMP/tasks.json"
assert_exit 0 $?
assert_eq "$(count_archive)" "0" "DUTY_APPLY_DRY_RUN=1 零 archive 调用"
assert_eq "$(ledger_rows)" "$rows_before" "DUTY_APPLY_DRY_RUN=1 零台账写入"

# ================= ⑦ create 失败路径（brief 取不到 → exit 1 + 事件） =================

t_case "create 失败: stub state_brief rc≠0 → exit 1 + -duty-brief-fail 事件 + 零卡零戳零登记"
quiet_sb
install_brief_stub
run_duty create "DUTY_STUB_BRIEF=fail"
assert_exit 1 $?
assert_eq "$(ev_key_count '-duty-brief-fail')" "1" "-duty-brief-fail 入账"
assert_eq "$(count_create)" "0" "零建卡调用"
[[ -f "$(duty_flight)" ]] && _fail "零 flight 登记" "残留" || _pass "零 flight 登记"
[[ -f "$(duty_stamp)" ]] && _fail "零节流戳" "残留" || _pass "零节流戳"

t_case "create 失败: stub state_brief 空输出 → exit 1 + 事件（防空 brief 成卡）"
quiet_sb
install_brief_stub
run_duty create "DUTY_STUB_BRIEF=empty"
assert_exit 1 $?
assert_eq "$(ev_key_count '-duty-brief-fail')" "1" "-duty-brief-fail 入账"
assert_eq "$(count_create)" "0" "零建卡调用"

t_case "create 失败: stub state_brief 缺「伤情判定」锚 → exit 1 + 事件"
quiet_sb
install_brief_stub
run_duty create "DUTY_STUB_BRIEF=noanchor"
assert_exit 1 $?
assert_eq "$(ev_key_count '-duty-brief-fail')" "1" "-duty-brief-fail 入账"
assert_eq "$(count_create)" "0" "零建卡调用"

# ================= ⑧ run-watch 值班段接线冒烟（三连被调 + 板库守卫 + 节流零新增） =================

t_case "run-watch 值班段冒烟: 无板环境 create 惰性跳过；预置板库后三连被调整轮 exit 0；同窗再轮 create 节流零新增值班卡"
quiet_sb
install_brief_stub
run_watch
assert_exit 0 $?
WLOG="$SB_ROOT/contrib-data/logs/launchd.log"
assert_file_contains "$WLOG" "duty 值班环 harvest exit=0" "值班段 harvest 无条件被调且恒 0"
assert_file_contains "$WLOG" "duty 值班环 apply exit=0" "值班段 apply 无条件被调且恒 0（无台账空转）"
assert_file_contains "$WLOG" "duty 值班环 create 跳过（contrib 板库不存在，无板环境惰性面）" "板库守卫生效：无板环境零建卡"
assert_eq "$(count_duty_create)" "0" "无板环境零值班卡调用"
# 预置假板库（沙箱 HOME），恢复 create 的 run-watch 触发面覆盖
mkdir -p "$SB_ROOT/home/.hermes/kanban/boards/contrib"
touch "$SB_ROOT/home/.hermes/kanban/boards/contrib/kanban.db"
run_watch
assert_exit 0 $?
assert_file_contains "$WLOG" "duty 值班环 create exit=0" "板库在 → 值班段 create 被调"
assert_eq "$(count_duty_create)" "1" "首轮值班段建 1 张值班卡"
run_watch
assert_exit 0 $?
assert_file_contains "$WLOG" "duty 值班环 create exit=10" "第二轮 create 节流 10（fail-soft 不打断主链）"
assert_eq "$(count_duty_create)" "1" "同窗第二轮零新增值班卡"
assert_file_contains "$WLOG" "duty 值班环 apply exit=0" "第二轮 apply 恒 0"

t_finish
