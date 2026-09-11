#!/usr/bin/env bash
# =============================================================================
# t6-01-scan-gate-pendinghits-revoke.acceptance.test.sh — T6 验收①：scan_gate.sh
#   pending-hits.json 兼容写撤销（契约 1b 过渡期结束）
#   R1  零写入：正常扫描路 pending-hits.json 不创建不更新（fresh 不创建 / legacy 不改写）
#   R2  积压聚合只算批次文件源：pending-hits 源残留必零告警（反向锚，兼容读未删必红）；
#       批次源 >80 仍告警（正向锚）+ 同日幂等
#   R3  双 shell guard 保留：zsh 调用镜像生产（run-watch.sh:105 原样 `zsh scan_gate.sh`）——
#       零批次文件时无 nomatch 崩溃（null_glob）+ 批次计数在 zsh 下活着；bash 直调同语义
#   R4  --init/--drain 语义收窄：只操作批次文件，pending-hits.json 永不被写
#   R5  exit 语义不变（0/10）；批次文件+指针主路照常产出
#   R6  静态锚：scan_gate.sh 全文零 pending-hits token（唯一数据源=批次文件）
# 依据：state.md「## 设计文档」契约规约 2「兼容写撤销不变量：scan_gate.sh 撤销后唯一数据源=
#   批次文件；--init/--drain 语义收窄为仅操作批次文件（--drain 保留作 fallback 手动兜底）；
#   exit 0/10 不变」+「改写区必须保留 ZSH_VERSION/null_glob 双 shell guard（重审 I6）」
# CONTRACT_AMBIGUOUS：
#   - --drain 对批次文件的确切动作未钉（原地标记非 pending / 删除文件皆合法）→ 断言收在
#     「drain 后批次内 state==pending 条目数为 0」（两种实现形态都满足，漏改必红）
#   - 积压聚合是否仅在 hit_count>0 路径评估未细述（T1 同款含糊）→ 各用例均带 ≥1 条新命中
# 红队纪律：黑盒（未读任何 T6 实现代码）；每断言硬失败；无 skip。
# Mental Mutation：兼容写残留→R1 双向红；聚合仍读 pending-hits→1.4 红；null_glob guard 丢→
#   1.1 红（zsh nomatch 崩溃）；guard 退化为恒假→1.2 红（zsh 批次静默零计数）；批次主路误删→
#   1.6 红；exit 语义漂移→1.2/1.3/1.10 红。
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

SCRIPTS_DIR="$(tests_scripts_dir "$REPO_ROOT/scripts/contrib")"

# ---- 本文件专用工具 ----

mk_issues() { # <out> <start> <end>：gh issue JSON 数组（可过黑名单粗滤）
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

mk_hit_items() { # <out> <start> <end> [state]：hit 元素数组
  local out="$1" s="$2" e="$3" st="${4:-}" i
  {
    printf '['
    for ((i = s; i <= e; i++)); do
      [ "$i" -gt "$s" ] && printf ','
      printf '{"number":%d,"title":"backlog item %d","labels":[],"author":"bob","created":"2026-09-08T00:00:00Z","comments":0' "$i" "$i"
      [ -n "$st" ] && printf ',"state":"%s"' "$st"
      printf '}'
    done
    printf ']\n'
  } > "$out"
}

seed_cursor() { jq -n --argjson n "$1" --arg d "2026-09-09T00:00:00Z" '{last_issue:$n,initialized:$d}' > "$SB_ROOT/contrib-data/scan-cursor.json"; }

run_gate_zsh()  { sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json" 'zsh "$MARTIN_DIR/scripts/contrib/scan_gate.sh"'; }
run_gate_bash() { sb_run -e "STUB_GH_ISSUES_FILE=$SB_ROOT/tmp/issues.json" 'bash "$MARTIN_DIR/scripts/contrib/scan_gate.sh"'; }

backlog_event_count() { # events.jsonl 中 class=pipeline-failure 且 key 以 -backlog 结尾的条数
  jq -s '[.[] | select(.class == "pipeline-failure" and ((.key // "") | endswith("-backlog")))] | length' \
    "$SB_ROOT/contrib-data/events.jsonl" 2>/dev/null || echo 0
}

file_md5() { python3 -c 'import sys,hashlib;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null || echo "unreadable"; }

pending_md5() { file_md5 "$SB_ROOT/contrib-data/pending-hits.json"; }

batch_pending_total() { # pending-batches/ 内 state==pending 条目总数（目录缺失/无文件=0）
  local total=0 f n
  [ -d "$SB_ROOT/contrib-data/pending-batches" ] || { printf '0'; return 0; }
  for f in "$SB_ROOT/contrib-data/pending-batches"/batch-*.json; do
    [ -e "$f" ] || continue
    n="$(jq '[.[]? | select(.state? == "pending")] | length' "$f" 2>/dev/null || echo 0)"
    total=$((total + n))
  done
  printf '%s' "$total"
}

# =============================================================================
t_case "1.1 zsh 镜像生产 + 零批次文件 + 无命中 → exit 0 且零 nomatch 崩溃（null_glob guard 保留）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf '[]\n' > "$SB_ROOT/tmp/issues.json"     # 无新 issue
seed_cursor 100
# pending-batches 目录存在但为空（gate 启动 mkdir -p 产物）——zsh 无 null_glob 时 glob 报 no matches found
run_gate_zsh; RC=$?
assert_exit 0 $RC "1.1 zsh 无命中 exit 0（guard 丢失时 nomatch 会使脚本带错崩出）"
ERR="$(sb_out 40)"
assert_not_contains "$ERR" "no matches found" "1.1 零 zsh nomatch 报错（ZSH_VERSION/null_glob guard 活着）"
assert_eq "$(backlog_event_count)" "0" "1.1 零积压告警"
sb_cleanup

# =============================================================================
t_case "1.2 zsh + 批次 90 条 + 1 新命中 → exit 10 + 恰 1 条 -backlog 告警（zsh 下批次计数活着）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp" "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 1 90 pending
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_gate_zsh; RC=$?
assert_exit 10 $RC "1.2 zsh 有命中 exit 10"
assert_eq "$(backlog_event_count)" "1" "1.2 zsh 并集 91>80 → 恰 1 条告警（guard 恒假=批次静默零计数必红）"
sb_cleanup

# =============================================================================
t_case "1.3 bash 直调同场景 → exit 10 + 恰 1 条告警（双 shell 同一循环语义）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp" "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 1 90 pending
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_gate_bash; RC=$?
assert_exit 10 $RC "1.3 bash 有命中 exit 10"
assert_eq "$(backlog_event_count)" "1" "1.3 bash 并集 91>80 → 恰 1 条告警"
sb_cleanup

# =============================================================================
t_case "1.4 反向锚：积压只躺 pending-hits（90 条，无批次文件）→ 零告警（兼容读残留必红）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 1 90
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_gate_bash; RC=$?
assert_exit 10 $RC "1.4 exit 10（1 条新命中）"
assert_eq "$(backlog_event_count)" "0" "1.4 pending-hits 源不参与聚合（撤销前并集 91 会误报，本断言必红）"
assert_eq "$(pending_md5)" "$(file_md5 "$SB_ROOT/contrib-data/pending-hits.json")" "1.4 pending-hits 零写入（自反基线）"
sb_cleanup

# =============================================================================
t_case "1.5 批次源正向 + 同日幂等：两轮触发同 key 仍恰 1 条告警"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp" "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 1 90 pending
mk_issues "$SB_ROOT/tmp/issues.json" 101 101
seed_cursor 100
run_gate_zsh >/dev/null
assert_eq "$(backlog_event_count)" "1" "1.5 首轮恰 1 条"
mk_issues "$SB_ROOT/tmp/issues.json" 101 102
run_gate_zsh >/dev/null
assert_eq "$(backlog_event_count)" "1" "1.5 次轮同 key（<date>-backlog）幂等仍 1 条"
sb_cleanup

# =============================================================================
t_case "1.6 零写入·fresh（zsh 生产镜像）：命中路 pending-hits.json 不创建；批次文件+指针照常产出"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
mk_issues "$SB_ROOT/tmp/issues.json" 101 102
seed_cursor 100
run_gate_zsh; RC=$?
assert_exit 10 $RC "1.6 exit 10"
if [ -e "$SB_ROOT/contrib-data/pending-hits.json" ]; then
  _fail "1.6 pending-hits 零创建" "撤销后命中路仍产出 pending-hits.json（兼容写未删）"
else
  _pass "1.6 pending-hits 零创建"
fi
PTR="$SB_ROOT/contrib-data/scan-latest-batch.json"
BF="$(jq -r '.batch_file // ""' "$PTR" 2>/dev/null)"
if [ -f "$BF" ]; then
  _pass "1.6 批次文件主路照常"
  assert_eq "$(jq -r 'length' "$BF")" "2" "1.6 批次条数=命中数"
  assert_eq "$(jq -r 'all(.[]; .state == "pending")' "$BF")" "true" "1.6 每元素 state=pending"
  assert_eq "$(jq -r '.count' "$PTR")" "2" "1.6 指针 count 一致"
else
  _fail "1.6 批次文件主路照常" "批次文件未产出（${BF})——唯一数据源不能被撤销动作误伤"
fi
sb_cleanup

# =============================================================================
t_case "1.7 零写入·legacy 不更新：预置旧 pending-hits + 命中不同 issue 号 → 文件字节级不变"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 999900 999999
MD5_BEFORE="$(pending_md5)"
mk_issues "$SB_ROOT/tmp/issues.json" 101 102     # 与 legacy 无重叠 → 兼容写残留必改写文件
seed_cursor 100
run_gate_bash >/dev/null
assert_eq "$(pending_md5)" "$MD5_BEFORE" "1.7 legacy pending-hits 字节级零改写（合并写残留必红）"
sb_cleanup

# =============================================================================
t_case "1.8 --init 收窄：游标拨号生效 + pending-hits 不被写（撤销前会清空为 []，必红锚）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 999900 999999
MD5_BEFORE="$(pending_md5)"
sb_run -e STUB_GH_LATEST=555 'bash "$MARTIN_DIR/scripts/contrib/scan_gate.sh" --init' >/dev/null; RC=$?
assert_exit 0 $RC "1.8 --init exit 0"
assert_eq "$(jq -r '.last_issue // 0' "$SB_ROOT/contrib-data/scan-cursor.json")" "555" "1.8 游标拨到 STUB_GH_LATEST"
assert_eq "$(pending_md5)" "$MD5_BEFORE" "1.8 --init 零写 pending-hits（收窄前 printf '[]' 必红）"
sb_cleanup

# =============================================================================
t_case "1.9 --drain 收窄（fallback 手动兜底）：批次 pending 清零 + pending-hits 不被写"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp" "$SB_ROOT/contrib-data/pending-batches"
mk_hit_items "$SB_ROOT/contrib-data/pending-batches/batch-20260909-010101.json" 1 3 pending
mk_hit_items "$SB_ROOT/contrib-data/pending-hits.json" 999900 999999
MD5_BEFORE="$(pending_md5)"
sb_run 'bash "$MARTIN_DIR/scripts/contrib/scan_gate.sh" --drain' >/dev/null; RC=$?
assert_exit 0 $RC "1.9 --drain exit 0"
assert_eq "$(batch_pending_total)" "0" "1.9 drain 后批次内 state==pending 条目为 0（标记/删文件两形态皆过；未收窄必红）"
assert_eq "$(pending_md5)" "$MD5_BEFORE" "1.9 --drain 零写 pending-hits（收窄前 printf '[]' 必红）"
sb_cleanup

# =============================================================================
t_case "1.10 bash 无命中 exit 0（exit 语义闭集补全：0/10 双 shell 已全覆盖）"
sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
mkdir -p "$SB_ROOT/tmp"
printf '[]\n' > "$SB_ROOT/tmp/issues.json"
seed_cursor 100
run_gate_bash; RC=$?
assert_exit 0 $RC "1.10 bash 无命中 exit 0"
sb_cleanup

# =============================================================================
t_case "1.11 静态锚：scan_gate.sh 全文零 pending-hits token（唯一数据源=批次文件的源级回归锚）"
if [ ! -f "$SCRIPTS_DIR/scan_gate.sh" ]; then
  _fail "1.11 scan_gate.sh 存在" "$SCRIPTS_DIR/scan_gate.sh 缺失"
else
  N="$(grep -c 'pending-hits' "$SCRIPTS_DIR/scan_gate.sh" 2>/dev/null || true)"
  assert_eq "$N" "0" "1.11 scan_gate.sh 零 pending-hits 引用（路径常量/双写注释残留都算未撤销）"
fi

t_finish
