#!/bin/bash
# l2-ledger.sh — Tier U：l2_ledger.sh（L2 台账写入器 + own-PR 发布闸）stub 测试矩阵
# 覆盖（#108006 台账缺口闭环的写法面）：
#   record：5 列格式与 execute.sh 同形 / 分支 token / 渠道标签 / 批准原文入账 /
#           幂等（同分支重复 ALREADY 零第二行）/ 缺 --approval fail-closed / 缺 --channel /
#           未知 --kind / secret 拒写 / 竖线转义（列数恒 5）/ --dry-run 零写入
#   check：branch token 命中 / PR 号锚（pull/N）/ 裸分支历史手工行 / 无台账 → 0|1 态；
#          只读（台账哈希不变）
#   publish：批准证据闸（--approval 空 → 零 git/gh 调用）/ --rq 状态闸（非 approved 拒）/
#            拒 main|master / 拒指向上游的 remote / 已有 PR 幂等（零 push，仅补台账）/
#            --dry-run 零写调用 / push 失败零台账 / gh pr create 失败零台账 /
#            台账写失败 rc=9（push 已发生的显式暴露）
#   自决路可见性（宪法 §12 契约 2）：record/publish --self-decided → 恰 emit 一条 self-decided
#           事件（channel=contrib / route=brief）；幂等、--dry-run、常规批准路零 emit；
#           emit 失败不回滚台账（台账是权威，简报是投影）
# 全程沙箱影子 stub（gh/git）+ 沙箱 MARTIN_DIR：零真实 gh、零真实 git push、
# 零生产 approved.log 写入（断言只读 $SB_ROOT/approved.log）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "l2-ledger.sh"

sb_new >/dev/null 2>&1 || { echo "FATAL: 沙箱创建失败"; exit 1; }

L2_REL="scripts/contrib/l2_ledger.sh"
LEDGER="$SB_ROOT/approved.log"
WORKTREE="$SB_ROOT/wt"
CALLS="$SB_STUBLOG/calls.log"

sb_l2() { # 沙箱内调 l2_ledger.sh（参数安全引用）
  local a snippet=""
  for a in "$@"; do
    snippet="$snippet$(printf '%q ' "$a")"
  done
  sb_run "bash \"\$MARTIN_DIR/$L2_REL\" $snippet"
}

ledger_lines() { if [[ -f "$LEDGER" ]]; then wc -l <"$LEDGER" | tr -d ' '; else echo 0; fi; }
ledger_cols() { awk -F'[|]' 'NR == 1 { print NF; exit }' "$LEDGER" 2>/dev/null || true; }
git_calls() { stub_count git; }
last_log() { [[ -f "$LEDGER" ]] && tail -1 "$LEDGER" || true; }

# git 影子 stub（沙箱 bin/ 先于 shim —— l2_ledger.sh 的 GIT_BIN 缺省走 PATH 命中它）
mk_git_stub() {
  cat >"$SB_ROOT/bin/git" <<'EOF'
#!/bin/bash
LOG_DIR="${STUB_LOG_DIR:-/nonexistent}"
printf 'git|%s|%s\n' "$PWD" "$*" >>"$LOG_DIR/calls.log" 2>/dev/null || true
case "$*" in
  *"rev-parse --git-dir"*) echo ".git"; exit 0 ;;
  *"remote get-url"*) printf '%s\n' "${STUB_GIT_REMOTE_URL:-https://github.com/strzhao/hermes-agent.git}"; exit 0 ;;
  *" push "*) [[ "${STUB_GIT_PUSH_FAIL:-}" == "1" ]] && { echo "push denied" >&2; exit 128; }; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$SB_ROOT/bin/git"
}
mk_git_stub
mkdir -p "$WORKTREE"

# ---------------- ① record：格式与批准依据 ----------------
t_case "record 基础：5 列 + 锚点 + 分支 token + 渠道 + 批准原文"
out="$(sb_l2 record --kind own-PR --issue 108006 --channel "L2-B 会话内批准" \
  --approval "用户会话明示：资源闸做成 own-PR" --branch contrib/kanban-resource-gate \
  --url "https://github.com/NousResearch/hermes-agent/pull/108006")"
assert_exit 0 $? "record 成功 exit 0"
assert_eq "$(ledger_lines)" "1" "台账恰 1 行"
assert_eq "$(ledger_cols)" "5" "行分 5 列（与 execute.sh 同形）"
assert_file_contains "$LEDGER" "issue #108006 own-PR 处置" "第 3 列含锚点与处置中文"
assert_file_contains "$LEDGER" "branch=contrib/kanban-resource-gate" "分支 token（check 判据）"
assert_file_contains "$LEDGER" "L2-B 会话内批准" "渠道标签入账"
assert_file_contains "$LEDGER" "用户会话明示：资源闸做成 own-PR" "批准原文入账（可审计）"

t_case "record 幂等：同分支重复 → ALREADY 且不写第二行"
out="$(sb_l2 record --kind own-PR --issue 108006 --channel "L2-B 会话内批准" \
  --approval "重复批" --branch contrib/kanban-resource-gate)"
assert_exit 0 $? "重复 record exit 0（幂等）"
assert_contains "$out" "ALREADY-LEDGERED" "输出 ALREADY-LEDGERED"
assert_eq "$(ledger_lines)" "1" "台账仍 1 行"

t_case "record 竖线转义：批准原文含 | 不破列（竖线数恒 4）"
sb_l2 record --kind evidence --issue 108007 --channel "L2-auto" \
  --approval "a | b | c 三段" --branch feat/pipe-test >/dev/null
assert_eq "$(ledger_lines)" "2" "第二行已写"
assert_eq "$(awk -F'[|]' 'NR == 2 { print NF }' "$LEDGER")" "5" "含竖线行仍 5 列（4 个分隔竖线）"

t_case "record fail-closed：缺 --approval / 缺 --channel / 未知 kind"
before="$(ledger_lines)"
sb_l2 record --kind own-PR --issue 1 --channel "L2-B" --approval "" >/dev/null
assert_exit 2 $? "缺 --approval → exit 2"
sb_l2 record --kind own-PR --issue 1 --channel "" --approval "批" >/dev/null
assert_exit 2 $? "缺 --channel → exit 2"
sb_l2 record --kind nonsense --issue 1 --channel "L2-B" --approval "批" >/dev/null
assert_exit 2 $? "未知 --kind → exit 2"
assert_eq "$(ledger_lines)" "$before" "三次拒绝均零写入"

t_case "record secret 拒写（ghp_ 模式命中）"
before="$(ledger_lines)"
sb_l2 record --kind own-PR --issue 1 --channel "L2-B" \
  --approval "token ghp_0123456789012345678901" >/dev/null
assert_exit 2 $? "secret 命中 → exit 2"
assert_eq "$(ledger_lines)" "$before" "零写入"

t_case "record --dry-run：零写入 + stdout 打印待写行"
before="$(ledger_lines)"
out="$(sb_l2 record --kind own-PR --issue 111 --channel "L2-B" --approval "批" \
  --branch dry/x --dry-run)"
assert_exit 0 $? "dry-run exit 0"
assert_contains "$out" "[dry-run] approved.log +=" "打印待写行"
assert_eq "$(ledger_lines)" "$before" "台账零增长"

# ---------------- ② check：只读判定 ----------------
t_case "check：分支 token / PR 号锚 / 裸分支历史行 / 无命中"
out="$(sb_l2 check --branch contrib/kanban-resource-gate)"
assert_exit 0 $? "branch token 命中 → 0"
out="$(sb_l2 check --pr 108006)"
assert_exit 0 $? "PR 号锚（pull/N）命中 → 0"
printf '%s\n' "2026-09-05T19:45+08:00 | hermes-contrib | own-PR #103271 落地（手工历史行）：分支 fix/verify-evidence-cross-session @ 309caa1ff8 | L2-B 会话内明示 | push fork fix/verify-evidence-cross-session" >>"$LEDGER"
out="$(sb_l2 check --branch fix/verify-evidence-cross-session)"
assert_exit 0 $? "裸分支历史手工行命中 → 0"
out="$(sb_l2 check --branch feat/never-recorded)"
assert_exit 1 $? "无台账 → 1"
assert_contains "$out" "MISSING" "MISSING 输出"

t_case "check 零副作用：台账字节不变"
sha_before="$(shasum -a 256 "$LEDGER" | awk '{print $1}')"
sb_l2 check --branch contrib/kanban-resource-gate >/dev/null
assert_eq "$(shasum -a 256 "$LEDGER" | awk '{print $1}')" "$sha_before" "check 后台账哈希不变"

# ---------------- ③ publish：批准闸与幂等 ----------------
t_case "publish 批准闸：无 --approval 无 --rq → 零 git/gh 调用"
: >"$CALLS"
sb_l2 publish --worktree "$WORKTREE" --branch feat/ungated --title "T" >/dev/null
assert_exit 2 $? "无批准证据 → exit 2"
assert_eq "$(git_calls)" "0" "零 git 调用"
assert_eq "$(stub_count gh)" "0" "零 gh 调用"

t_case "publish --rq 状态闸：awaiting-approval 拒 / approved 放行（push+PR+台账）"
sb_seed_queue_item rq-20260912-1 108006 deep awaiting-approval >/dev/null
sb_l2 publish --worktree "$WORKTREE" --branch feat/rq1 --title "T" --rq rq-20260912-1 >/dev/null
assert_exit 2 $? "非 approved → exit 2"
assert_eq "$(git_calls)" "0" "拒后零 git 调用"
sb_seed_queue_item rq-20260912-2 108006 deep approved >/dev/null
before="$(ledger_lines)"
out="$(sb_run -e "STUB_GH_PR_CREATE_URL=https://github.com/NousResearch/hermes-agent/pull/108006" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/rq2 --title T --rq rq-20260912-2")"
assert_exit 0 $? "approved → exit 0"
assert_eq "$(( $(ledger_lines) - before ))" "1" "台账 +1"
assert_file_contains "$LEDGER" "branch=feat/rq2" "分支 token 入账"
assert_file_contains "$LEDGER" "pull/108006" "PR URL 入账"
assert_file_contains "$LEDGER" "L2-A tunnel 短码批准" "rq 路渠道标签自动切 L2-A"

t_case "publish push argv 形态：push fork <branch>，全程零 --force"
assert_contains "$(grep '^git|' "$CALLS" 2>/dev/null | grep ' push ' || true)" \
  "push fork feat/rq2" "push 形态为 push fork <branch>"
assert_eq "$(grep -c -- '--force' "$CALLS" 2>/dev/null || true)" "0" "calls.log 零 --force"

t_case "publish 拒绝 main|master 与指向上游的 remote"
sb_l2 publish --worktree "$WORKTREE" --branch main --title "T" --approval "批" >/dev/null
assert_exit 2 $? "main 拒"
sb_run -e "STUB_GIT_REMOTE_URL=https://github.com/NousResearch/hermes-agent.git" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/up --title T --approval 批" >/dev/null
assert_exit 2 $? "上游 remote 拒"

t_case "publish 已有 PR：跳过 push，仅补台账"
: >"$CALLS"
printf '[{"number":777,"url":"https://github.com/NousResearch/hermes-agent/pull/777"}]' >"$SB_ROOT/pr-exists.json"
before="$(ledger_lines)"
sb_run -e "STUB_GH_PRS_FILE=$SB_ROOT/pr-exists.json" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/exists --title T --approval 批" >/dev/null
assert_exit 0 $? "已有 PR exit 0"
assert_eq "$(grep -c ' push ' "$CALLS" 2>/dev/null || true)" "0" "零 push 调用"
assert_eq "$(( $(ledger_lines) - before ))" "1" "补台账 +1"
assert_file_contains "$LEDGER" "branch=feat/exists" "已有 PR 分支入账"

t_case "publish --dry-run：零 push 零 pr create 零台账"
: >"$CALLS"
before="$(ledger_lines)"
out="$(sb_l2 publish --worktree "$WORKTREE" --branch feat/dry --title "T" --approval "批" --dry-run)"
assert_exit 0 $? "dry-run exit 0"
assert_contains "$out" "[dry-run]" "打印计划"
assert_eq "$(grep -cE ' push |pr create' "$CALLS" 2>/dev/null || true)" "0" "零写调用"
assert_eq "$(ledger_lines)" "$before" "台账零增长"

t_case "publish push 失败：非零退出且零台账"
before="$(ledger_lines)"
sb_run -e "STUB_GIT_PUSH_FAIL=1" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/pushfail --title T --approval 批" >/dev/null
rc=$?
assert_ne "$rc" "0" "push 失败非零退出"
assert_eq "$(ledger_lines)" "$before" "失败零台账"

t_case "publish gh pr create 失败：非零退出且零台账"
before="$(ledger_lines)"
sb_run -e "STUB_GH_PR_CREATE_FAIL=1" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/prfail --title T --approval 批" >/dev/null
rc=$?
assert_ne "$rc" "0" "PR 创建失败非零退出"
assert_eq "$(ledger_lines)" "$before" "零台账"

t_case "publish 台账写失败：rc=9（push 已发生的显式暴露）"
: >"$CALLS"
sb_run -e "APPROVED_LOG=$SB_ROOT/nodir/approved.log" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/lbfail --title T --approval 批" >/dev/null
assert_exit 9 $? "台账写失败 exit 9"
assert_eq "$(grep -c ' push ' "$CALLS" 2>/dev/null || true)" "1" "push 确实已发生（暴露面成立）"

# ---------------- ④ 自决路可见性（宪法 §12 契约 2）：落账即 emit 简报级事件 ----------------
# 自决动作只写 approved.log / l2-ledger.log，而 flush 只读 events.jsonl ⇒ 落账处必须自己 emit，
# 否则自决路在结构上永远进不了当日简报（09-15 首单实证）。本组断言锁三件事：
#   ① 自决 record/publish 各 emit 恰一条 class=self-decided（channel=contrib、route=brief）；
#   ② 幂等跳过 / --dry-run / 常规批准路零 emit（既有分支语义逐字不变）；
#   ③ emit 是投影：失败不影响台账写入结果。
EVENTS="$SB_ROOT/contrib-data/events.jsonl"

t_case "record --self-decided：落账 + emit self-decided 事件（class/channel/route/锚）"
sb_config_set '.brief_only_classes = ["own-pr-info", "visual-run-done", "self-decided"]'
: >"$EVENTS"
before="$(ledger_lines)"
sb_l2 record --kind evidence --issue 91653 --channel "operator 自决路（§12）" \
  --self-decided "已批动作类（常规可逆），草稿双审已过" --branch contrib/selfdecided-a >/dev/null
assert_exit 0 $? "自决 record exit 0"
assert_eq "$(( $(ledger_lines) - before ))" "1" "台账 +1（落账不受影响）"
assert_eq "$(jq -s 'length' "$EVENTS")" "1" "恰 emit 1 条事件"
assert_eq "$(jq -sr '.[0].class' "$EVENTS")" "self-decided" "class=self-decided"
assert_eq "$(jq -sr '.[0].channel' "$EVENTS")" "contrib" "channel=contrib（flush 合法闭集）"
assert_eq "$(jq -sr '.[0].route' "$EVENTS")" "brief" "route=brief（简报级，不进微信批）"
assert_eq "$(jq -sr '.[0].pushed' "$EVENTS")" "false" "pushed=false（待下轮 flush 入简报）"
assert_contains "$(jq -sr '.[0].summary' "$EVENTS")" "自决: 已批动作类" "summary 带自决理由"
assert_contains "$(jq -sr '.[0].key' "$EVENTS")" "selfdecided-contrib/selfdecided-a-" "key = 前缀 + 落账锚 + 时刻"

t_case "自决 emit 与幂等/dry-run/常规批准路正交（既有分支语义不变）"
n="$(jq -s 'length' "$EVENTS")"
sb_l2 record --kind evidence --issue 91653 --channel "operator 自决路（§12）" \
  --self-decided "重复" --branch contrib/selfdecided-a >/dev/null
assert_eq "$(jq -s 'length' "$EVENTS")" "$n" "同锚幂等跳过 → 零 emit"
sb_l2 record --kind other --issue 555 --channel "L2-B" --self-decided "干跑" \
  --branch contrib/selfdecided-dry --dry-run >/dev/null
assert_eq "$(jq -s 'length' "$EVENTS")" "$n" "--dry-run → 零 emit"
sb_l2 record --kind evidence --issue 556 --channel "L2-B 会话内批准" \
  --approval "用户明示" --branch contrib/approved-path >/dev/null
assert_eq "$(jq -s 'length' "$EVENTS")" "$n" "常规批准路 → 零 emit（非自决不 emit）"

t_case "publish --self-decided：发布路同样 emit（第二条调用点）"
n="$(jq -s 'length' "$EVENTS")"
before="$(ledger_lines)"
sb_run -e "STUB_GH_PR_CREATE_URL=https://github.com/NousResearch/hermes-agent/pull/91653" \
  "bash \"\$MARTIN_DIR/$L2_REL\" publish --worktree \"$WORKTREE\" --branch feat/selfdecided --title T --self-decided \"评论类可逆动作\" " >/dev/null
assert_exit 0 $? "自决 publish exit 0"
assert_eq "$(( $(ledger_lines) - before ))" "1" "台账 +1"
assert_eq "$(( $(jq -s 'length' "$EVENTS") - n ))" "1" "emit +1"
assert_eq "$(jq -sr '.[-1].class' "$EVENTS")" "self-decided" "末条 class=self-decided"
assert_contains "$(jq -sr '.[-1].key' "$EVENTS")" "selfdecided-feat/selfdecided-" "key 锚 = 分支"

t_case "emit 失败不改台账结果：notify.sh 不可达时仍 rc=0 且台账已落"
mv "$SB_ROOT/scripts/contrib/notify.sh" "$SB_ROOT/scripts/contrib/notify.sh.hidden"
before="$(ledger_lines)"
sb_l2 record --kind evidence --issue 557 --channel "operator 自决路（§12）" --self-decided "无通知器" \
  --branch contrib/selfdecided-b >/dev/null
assert_exit 0 $? "notify.sh 不可达 → 仍 exit 0（投影失败不回滚权威）"
assert_eq "$(( $(ledger_lines) - before ))" "1" "台账照旧落账"
mv "$SB_ROOT/scripts/contrib/notify.sh.hidden" "$SB_ROOT/scripts/contrib/notify.sh"

sb_cleanup
t_finish
