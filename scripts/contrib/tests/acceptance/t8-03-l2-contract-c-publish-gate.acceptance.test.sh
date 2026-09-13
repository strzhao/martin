#!/usr/bin/env bash
# =============================================================================
# t8-03-l2-contract-c-publish-gate.acceptance.test.sh — T8 红队验收③：契约 C（发布闸）
#   DIM=acceptance；黑盒（未读 l2_ledger.sh / own_pr_watch.sh / notify.sh / rq.sh 实现，
#   仅依赖设计「公共接口面」逐字 + 沙箱 seam + stub 旋钮）
#   覆盖契约 C：l2_ledger.sh publish 缺批准证据时 fail-closed——exit 2 且零 git/gh 调用；
#   push 成功但台账写入失败必须 rc=9 显式暴露。
#   谓词覆盖（SSOT「验收场景」）：
#     C.P1 缺批准 fail-closed → exit 2 ∧ git=0 ∧ gh=0 ∧ approved.log 不变
#     C.P2 空白批准视同缺失 → exit 2 ∧ 零调用
#     C.P3 rq 闸 fail-closed → 不存在/非 approved 均 exit 2 ∧ 零调用
#     C.P4 dry-run 不绕闸 → exit 2
#     C.P5 台账写失败 rc=9 → exit 恰 9 ∧ push=1 ∧ pr create=1 ∧ 输出含暴露文案
#          ∧ check --branch exit 1（MISSING，不一致可机械发现）
#     （C6 全拒绝面 approved.log 零副作用 → C.P1 不变式在全部拒绝面扩展，见末用例）
#   Mental Mutation 靶点（C 组）：批准闸移到 remote/worktree 校验之后 → C.P1 红（沙箱内
#     worktree/remote 全部就绪，任何先于闸的探测都会留下 git/gh 调用痕迹）；空白校验退化
#     `-n "$approval"` → C.P2 红；dry-run 短路闸 → C.P4 红；rc 9→1（或吞成 0）→ C.P5 红；
#     fail-closed 写侧有动作 → C.P1/C6 的 approved.log 不变式红
#   场景实证（黑盒探针结论，非实现源码）：publish 的 fork 面 remote 名默认 fork、owner 从
#     remote URL 解析——工作仓以 https://github.com/strzhao/hermes-agent 为 fork URL，
#     git pushInsteadOf 重写到沙箱内裸仓（push 真、URL 可解析）
#   黑盒依赖（契约冻结）：publish CLI 面逐字（exit 0/2/9 闭集）、check exit 0/1/2 闭集、
#     seam APPROVED_LOG / L2_LEDGER_LOCKDIR / RQ_SH（-e 显式注入；锁目录由被测脚本自建，
#     沙箱绝不预建）、sb_seed_queue_item（ready-queue 前置态）
# CONTRACT_AMBIGUOUS：
#   - 「非 approved」的 rq 状态字面量未冻结——本用例取队列自然待审态 "queued"；红=交人审裁决
#   - C.P5「输出含显式暴露文案」具体措辞未冻结——本用例硬断言输出流非空（stdout∪stderr），
#     机械暴露锚定在 exit 恰 9 + push/create 各 1 + check MISSING 等已冻结判据上
#   - C.P5「台账路径不可写」实现口径未冻结——本用例以只读父目录（chmod 555）承载 APPROVED_LOG
# 红队纪律：每断言硬失败、无 skip；全部轮次在 sb_new 沙箱 + 影子 stub 内运行，绝不触真实
#   contrib-data / 仓根 approved.log，绝不真调 gh/hermes/claude；git 经沙箱 shim 记账包装器
#   透传真身（计数面），repo 搭建全部落在沙箱 mktemp 路径。
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

D="2027-06-01"
LEDGER=""
WORK=""

install_git_logger() { # 沙箱 shim/git 记账包装器（argv 记 calls.log 后透传真身）→ 零 git 断言可黑盒计数
  local real_git
  real_git="$(command -v git)"
  rm -f "$SB_ROOT/shim/git"   # shim/git 原是真 git 符号链接，必须先摘链再落包装器
  cat >"$SB_ROOT/shim/git" <<EOF
#!/bin/bash
printf '%s\n' "git|\$PWD|\$*" >> "$SB_STUBLOG/calls.log"
exec "$real_git" "\$@"
EOF
  chmod +x "$SB_ROOT/shim/git"
}

make_work_repo() { # <dir> — worktree/remote 全部就绪（闸若移到上下文探测之后必留调用痕迹）
  local w="$1" upstream="$1-upstream.git" fk="$1-fork"
  git init -q --bare "$upstream" 2>/dev/null
  git init -q --bare "$fk.git" 2>/dev/null
  git init -q "$w" 2>/dev/null
  git -C "$w" config user.email rt@redteam.local
  git -C "$w" config user.name rt
  printf 'base\n' >"$w/base.txt"
  git -C "$w" add base.txt
  git -C "$w" commit -q -m init
  git -C "$w" branch -M main 2>/dev/null
  git -C "$w" remote add origin "$upstream"
  git -C "$w" remote add fork "https://github.com/strzhao/hermes-agent.git"
  git -C "$w" config url."$fk".pushInsteadOf "https://github.com/strzhao/hermes-agent"
}

mk_branch() { # <repo> <branch>
  git -C "$1" checkout -q main 2>/dev/null
  git -C "$1" checkout -q -b "$2"
  printf '%s\n' "$2" >"$1/rt.txt"
  git -C "$1" add rt.txt
  git -C "$1" commit -q -m "rt $2"
}

sb_new_c() { # 沙箱 + 记账 shim + 就绪工作仓（每用例独立沙箱；锁目录由被测脚本自建）
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  LEDGER="$SB_ROOT/contrib-data/approved.log"
  WORK="$SB_ROOT/work"
  install_git_logger
  make_work_repo "$WORK"
  mk_branch "$WORK" fix-g
}

sb_l2c() { # <publish/check 参数...> — 沙箱副本 l2_ledger.sh；公共 seam -e 显式注入
  local a snippet=""
  for a in "$@"; do snippet="$snippet$(printf '%q ' "$a")"; done
  sb_run \
    -e "APPROVED_LOG=$LEDGER" \
    -e "L2_LEDGER_LOCKDIR=$SB_ROOT/locks/l2" \
    -e "RQ_SH=$SB_ROOT/scripts/contrib/rq.sh" \
    -e "STUB_DATE_TODAY=$D" \
    "bash \"\$MARTIN_DIR/scripts/contrib/l2_ledger.sh\" $snippet"
}

ledger_state() { # approved.log 副作用观测：absent 或内容 md5
  if [[ -f "$LEDGER" ]]; then md5 -q "$LEDGER" 2>/dev/null || printf present; else printf absent; fi
}

stub_total() { # <stub 名> → calls.log 总行数（含 git 记账包装器）
  local n
  n="$(awk -F'|' -v s="$1" '$1 == s' "$SB_STUBLOG/calls.log" 2>/dev/null | wc -l | tr -d ' ')"
  printf '%s' "${n:-0}"
}

stub_argc() { # <stub 名> <argv 子串> → 行数
  local n
  n="$(awk -F'|' -v s="$1" '$1 == s' "$SB_STUBLOG/calls.log" 2>/dev/null | grep -cF -- "$2")"
  printf '%s' "${n:-0}"
}

push_count() {
  local n
  n="$(awk -F'|' '$1 == "git"' "$SB_STUBLOG/calls.log" 2>/dev/null | grep -cE '(^|[| ])push( |$)')"
  printf '%s' "${n:-0}"
}

# =============================================================================
t_case "C.P1 缺批准 fail-closed：exit 2 ∧ 零 git ∧ 零 gh（含只读 pr list）∧ approved.log 不变"
sb_new_c
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c1 no-approval" \
  --repo NousResearch/hermes-agent --base main >/dev/null
RC=$?
assert_exit 2 "$RC" "C.P1 缺批准证据 exit 2（fail-closed）"
assert_eq "$(stub_total git)" "0" "C.P1 零 git 调用（闸先于一切上下文探测；worktree/remote 已就绪）"
assert_eq "$(stub_total gh)" "0" "C.P1 零 gh 调用（含只读 pr list）"
assert_eq "$(ledger_state)" "absent" "C.P1 approved.log 零副作用（未被创建）"
sb_cleanup

# =============================================================================
t_case "C.P2 空白批准视同缺失：--approval sanitize 后为空 → exit 2 ∧ 零调用"
sb_new_c
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c2 blank" \
  --approval $' \t ' --repo NousResearch/hermes-agent --base main >/dev/null
RC=$?
assert_exit 2 "$RC" "C.P2 空白 --approval exit 2（防『非空字符串』伪检查突变）"
assert_eq "$(stub_total git)" "0" "C.P2 零 git 调用"
assert_eq "$(stub_total gh)" "0" "C.P2 零 gh 调用"
assert_eq "$(ledger_state)" "absent" "C.P2 approved.log 零副作用"
sb_cleanup

# =============================================================================
t_case "C.P3 rq 闸 fail-closed：--rq 不存在 → exit 2 ∧ 零调用"
sb_new_c
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c3a" \
  --rq rt-nonexistent-id --repo NousResearch/hermes-agent --base main >/dev/null
RCA=$?
assert_exit 2 "$RCA" "C.P3a --rq 不存在 → exit 2"
assert_eq "$(stub_total git)" "0" "C.P3a 零 git 调用"
assert_eq "$(stub_total gh)" "0" "C.P3a 零 gh 调用"
assert_eq "$(ledger_state)" "absent" "C.P3a approved.log 零副作用"
sb_cleanup

t_case "C.P3 rq 闸 fail-closed（非 approved 态）：exit 2 ∧ 零调用"
sb_new_c
sb_seed_queue_item "rq-rt-c3" 108010 "gate" "queued" 30   # 存在但非 approved 态（CONTRACT_AMBIGUOUS，见头注）
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c3b" \
  --rq rq-rt-c3 --repo NousResearch/hermes-agent --base main >/dev/null
RCB=$?
assert_exit 2 "$RCB" "C.P3b --rq 非 approved（queued）→ exit 2"
assert_eq "$(stub_total git)" "0" "C.P3b 零 git 调用"
assert_eq "$(stub_total gh)" "0" "C.P3b 零 gh 调用"
assert_eq "$(ledger_state)" "absent" "C.P3b approved.log 零副作用"
sb_cleanup

# =============================================================================
t_case "C.P4 dry-run 不绕闸：无批准 + --dry-run → exit 2 ∧ 零调用"
sb_new_c
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c4 dryrun" \
  --dry-run --repo NousResearch/hermes-agent --base main >/dev/null
RC=$?
assert_exit 2 "$RC" "C.P4 无批准 + dry-run 仍 exit 2（dry-run 短路闸突变红）"
assert_eq "$(stub_total git)" "0" "C.P4 零 git 调用"
assert_eq "$(stub_total gh)" "0" "C.P4 零 gh 调用"
assert_eq "$(ledger_state)" "absent" "C.P4 approved.log 零副作用"
sb_cleanup

# =============================================================================
t_case "C.P5 rc=9 精确暴露：push 成功+create 成功+台账路径不可写 → 恰 exit 9、push=1、暴露文案、check MISSING"
sb_new_c
mkdir -p "$SB_ROOT/tmp/ro-ledger"
chmod 555 "$SB_ROOT/tmp/ro-ledger"   # 台账路径不可写（CONTRACT_AMBIGUOUS 实现口径，见头注）
LEDGER="$SB_ROOT/tmp/ro-ledger/approved.log"
OUT="$(sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c5 rc9" \
  --approval "APPROVE rt-c5" --repo NousResearch/hermes-agent --base main)"
RC=$?
assert_exit 9 "$RC" "C.P5 exit 恰 9（非 0/1/2；rc 9→1 突变红）"
assert_eq "$(push_count)" "1" "C.P5 push 恰 1 次（副作用已发生）"
assert_eq "$(stub_argc gh 'pr create')" "1" "C.P5 pr create 恰 1 次"
COMBINED="$OUT
$(sb_out 100)"
assert_ne "$(printf '%s' "$COMBINED" | tr -d '[:space:]')" "" "C.P5 输出含显式暴露文案（stdout∪stderr 非空；措辞契约未冻结=交人审）"
sb_l2c check --branch fix-g --ledger "$LEDGER" >/dev/null 2>&1; CRC=$?
assert_exit 1 "$CRC" "C.P5 事后 check --branch = MISSING（exit 1，push/台账不一致可机械发现）"
if [[ -f "$LEDGER" ]]; then
  _fail "C.P5 台账文件未落盘" "只读目录下 approved.log 竟被写入: $LEDGER"
else
  _pass "C.P5 台账文件未落盘（写失败真实发生）"
fi
sb_cleanup

# =============================================================================
t_case "C6 全部拒绝面 approved.log 零副作用（C.P1 不变式扩展：fail-closed 写侧零动作）"
sb_new_c
S0="$(ledger_state)"
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c6-1" \
  --repo NousResearch/hermes-agent --base main >/dev/null
RC1=$?
assert_exit 2 "$RC1" "C6 拒绝面①缺批准 exit 2"
assert_eq "$(ledger_state)" "$S0" "C6 拒绝面①后 approved.log 不变"
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c6-2" \
  --approval "   " --repo NousResearch/hermes-agent --base main >/dev/null
RC2=$?
assert_exit 2 "$RC2" "C6 拒绝面②空白批准 exit 2"
assert_eq "$(ledger_state)" "$S0" "C6 拒绝面②后 approved.log 不变"
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c6-3" \
  --rq rt-nonexistent-id --repo NousResearch/hermes-agent --base main >/dev/null
RC3=$?
assert_exit 2 "$RC3" "C6 拒绝面③rq 不存在 exit 2"
assert_eq "$(ledger_state)" "$S0" "C6 拒绝面③后 approved.log 不变"
sb_seed_queue_item "rq-rt-c6" 108011 "gate" "queued" 30
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c6-4" \
  --rq rq-rt-c6 --repo NousResearch/hermes-agent --base main >/dev/null
RC4=$?
assert_exit 2 "$RC4" "C6 拒绝面④rq 非 approved exit 2"
assert_eq "$(ledger_state)" "$S0" "C6 拒绝面④后 approved.log 不变"
sb_l2c publish --worktree "$WORK" --branch fix-g --title "rt c6-5" \
  --dry-run --repo NousResearch/hermes-agent --base main >/dev/null
RC5=$?
assert_exit 2 "$RC5" "C6 拒绝面⑤dry-run 无批准 exit 2"
assert_eq "$(ledger_state)" "$S0" "C6 拒绝面⑤后 approved.log 不变"
assert_eq "$(stub_total git)" "0" "C6 五次拒绝全程零 git 调用"
assert_eq "$(stub_total gh)" "0" "C6 五次拒绝全程零 gh 调用"
sb_cleanup

t_finish
