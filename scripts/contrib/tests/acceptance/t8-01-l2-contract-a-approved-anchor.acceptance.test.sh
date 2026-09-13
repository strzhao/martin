#!/usr/bin/env bash
# =============================================================================
# t8-01-l2-contract-a-approved-anchor.acceptance.test.sh — T8 红队验收①：契约 A（写侧）
#   DIM=acceptance；黑盒（未读 l2_ledger.sh / own_pr_watch.sh / notify.sh / rq.sh 实现，
#   仅依赖设计「公共接口面」逐字 + 沙箱 seam + stub 旋钮）
#   覆盖契约 A：任何 own-PR 类 push / 开 PR 动作发生后，approved.log 必有对应记录，
#   且含可机械检索的分支锚 branch=<分支>。
#   谓词覆盖（SSOT「验收场景」）：
#     A.P1 publish 全链路 → exit 0 ∧ 台账行数 +1 ∧ grep -F "branch=<B>" 命中 ∧
#                          check --branch exit 0 ∧ 恰 1 push + 1 pr create ∧ PUBLISHED 行含锚
#     A.P2 record 补记双锚 → branch=<B> 与 URL 同行 ∧ check --branch / --pr 双 exit 0
#     A.P3 第三方裸 grep → 命中分支 exit 0 ∧ 无关分支 exit 1
#     A.P4 重复动作不重复记账 → 二次 publish：push=0 ∧ pr create=0 ∧ 台账行数不变
#     A.P5 多分支各自有锚 → 恰 2 行 ∧ 每分支各自命中（互不串锚）
#   Mental Mutation 靶点（A 组）：append_ledger 丢 OUT_BRANCH → A.P1/A.P5 红；
#     already_ledgered 恒真/恒假 → A.P4 红（恒真连首跑前置、A.P1 全链路也红）；
#     URL 列丢 → A.P2 红
#   黑盒依赖（契约冻结）：l2_ledger.sh record/publish/check CLI 面逐字、台账行分支锚
#     字面量 branch=<分支> grep -F 可命中、seam APPROVED_LOG / L2_LEDGER_LOCKDIR / RQ_SH
#     （sb_run 白名单外 -e 显式注入）、stub 旋钮 STUB_GH_PR_CREATE_URL / STUB_GH_PRS_FILE
#   场景实证（黑盒探针结论，非实现源码）：publish 的 fork 面 remote 名默认 fork、owner 从
#     remote URL 解析——工作仓以 https://github.com/strzhao/hermes-agent 为 fork URL，
#     git pushInsteadOf 重写到沙箱内裸仓（push 真、URL 可解析）；「已有 PR」以
#     STUB_GH_PRS_FILE 提供 pr list 影子数据表达
# CONTRACT_AMBIGUOUS：
#   - A.P4 二次 publish 退出码：设计只钉「零新 push/零新 create/行数不变」，未钉 rc 闭集取值——
#     本用例取「幂等重跑=良性成功 rc 0」读法（实测 0）；若后续实现改取 2，本断言红=交人审裁决
# 红队纪律：每断言硬失败、无 skip；全部轮次在 sb_new 沙箱 + 影子 stub 内运行，绝不触真实
#   contrib-data / 仓根 approved.log，绝不真调 gh/hermes/claude；git 经沙箱 shim 记账包装器
#   透传真身（计数面，黑盒可观测），repo 搭建全部落在沙箱 mktemp 路径。
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

D="2027-06-01"   # 冻结同日（确定性；非 +%F/+%H 的 date 形态全量透传，不影响本文件断言面）
LEDGER=""
WORK=""
PRS=""

install_git_logger() { # 沙箱 shim/git 换成记账包装器（argv 记 calls.log 后透传真身）→ git 调用黑盒可计数
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

make_work_repo() { # <dir> — 工作仓 + upstream(origin)/fork 双裸仓；fork remote 用 GitHub 形 URL
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

mk_branch() { # <repo> <branch> — 从 main 拉新分支并落一个提交（有可推内容）
  git -C "$1" checkout -q main 2>/dev/null
  git -C "$1" checkout -q -b "$2"
  printf '%s\n' "$2" >"$1/rt.txt"
  git -C "$1" add rt.txt
  git -C "$1" commit -q -m "rt $2"
}

sb_new_a() { # 沙箱 + 记账 shim + 工作仓 + 空 pr list 影子（每用例独立沙箱）
  sb_new >/dev/null 2>&1 || { _fail "sb_new" "沙箱创建失败"; t_finish; }
  LEDGER="$SB_ROOT/contrib-data/approved.log"
  WORK="$SB_ROOT/work"
  PRS="$SB_ROOT/tmp/prs.json"
  mkdir -p "$SB_ROOT/tmp"
  printf '[]\n' >"$PRS"
  install_git_logger
  make_work_repo "$WORK"
}

sb_l2() { # <l2 参数...> — 沙箱副本 l2_ledger.sh；公共 seam -e 显式注入（白名单外一律显式传）
  local a snippet=""
  for a in "$@"; do snippet="$snippet$(printf '%q ' "$a")"; done
  sb_run \
    -e "APPROVED_LOG=$LEDGER" \
    -e "L2_LEDGER_LOCKDIR=$SB_ROOT/locks/l2" \
    -e "RQ_SH=$SB_ROOT/scripts/contrib/rq.sh" \
    -e "STUB_GH_PRS_FILE=$PRS" \
    -e "STUB_DATE_TODAY=$D" \
    "bash \"\$MARTIN_DIR/scripts/contrib/l2_ledger.sh\" $snippet"
}

l2_check_rc() { # <check 参数...> — 只读 check 的退出码
  sb_l2 check "$@" >/dev/null 2>&1
  return $?
}

l2_rows() { # 台账行数（缺失=0；grep -c '' 连末行无换行也计）
  local n=0
  if [[ -f "$LEDGER" ]]; then n="$(grep -c '' "$LEDGER" 2>/dev/null)"; fi
  printf '%s' "${n:-0}"
}

stub_argc() { # <stub 名> <argv 子串> → calls.log 中该 stub 且 argv 含子串的行数
  local n
  n="$(awk -F'|' -v s="$1" '$1 == s' "$SB_STUBLOG/calls.log" 2>/dev/null | grep -cF -- "$2")"
  printf '%s' "${n:-0}"
}

push_count() { # git 记账行中 argv 带独立 push 词的调用数
  local n
  n="$(awk -F'|' '$1 == "git"' "$SB_STUBLOG/calls.log" 2>/dev/null | grep -cE '(^|[| ])push( |$)')"
  printf '%s' "${n:-0}"
}

# =============================================================================
t_case "A.P1 publish 全链路：恰 1 push+1 create+台账恰+1 行含分支锚+check 命中+PUBLISHED 行含锚"
sb_new_a
mk_branch "$WORK" fix-a
OUT="$(sb_l2 publish --worktree "$WORK" --branch fix-a --title "rt a1 publish" \
  --approval "APPROVE rt-a1 push fix-a" --repo NousResearch/hermes-agent --base main)"
RC=$?
assert_exit 0 "$RC" "A.P1 publish 全链路 exit 0"
assert_eq "$(push_count)" "1" "A.P1 恰 1 次 git push"
assert_eq "$(stub_argc gh 'pr create')" "1" "A.P1 恰 1 次 gh pr create"
assert_eq "$(l2_rows)" "1" "A.P1 台账恰 +1 行（发布前 0 行）"
assert_file_contains "$LEDGER" "branch=fix-a" "A.P1 台账行含分支锚 branch=fix-a（grep -F 口径）"
l2_check_rc --branch fix-a --ledger "$LEDGER"; CROC=$?
assert_exit 0 "$CROC" "A.P1 check --branch fix-a 命中（exit 0 有台账）"
PUB_LINE="$(printf '%s\n' "$OUT" | grep -F 'PUBLISHED' | head -n 1)"
assert_contains "$PUB_LINE" "branch=fix-a" "A.P1 stdout PUBLISHED 行含分支锚"
sb_cleanup

# =============================================================================
t_case "A.P2 record 补记双锚：branch token 与 URL 同行、check --branch/--pr 双命中"
sb_new_a
PURL="https://github.com/NousResearch/hermes-agent/pull/108006"
sb_l2 record --kind own-PR --pr 108006 --channel "rt-a2" \
  --approval "APPROVE rt-a2 backfill 108006" --branch fix-b --url "$PURL" \
  --summary "backfill 108006" >/dev/null
RC=$?
assert_exit 0 "$RC" "A.P2 record 补记路径 exit 0"
assert_eq "$(l2_rows)" "1" "A.P2 台账恰 1 行"
LINE="$(sed -n '1p' "$LEDGER" 2>/dev/null)"
assert_contains "$LINE" "branch=fix-b" "A.P2 行内分支锚 branch=fix-b"
assert_contains "$LINE" "$PURL" "A.P2 同一行含 URL 锚（URL 列不被丢）"
l2_check_rc --branch fix-b --ledger "$LEDGER"; R1=$?
assert_exit 0 "$R1" "A.P2 check --branch fix-b exit 0"
l2_check_rc --pr 108006 --ledger "$LEDGER"; R2=$?
assert_exit 0 "$R2" "A.P2 check --pr 108006 exit 0"
sb_cleanup

# =============================================================================
t_case "A.P3 第三方机械检索原语：仓外裸 grep -F 命中分支 exit 0 + 无关分支负对照 exit 1"
sb_new_a
sb_l2 record --kind own-PR --pr 108007 --channel "rt-a3" \
  --approval "APPROVE rt-a3" --branch fix-c \
  --url "https://github.com/NousResearch/hermes-agent/pull/108007" >/dev/null
RC=$?
assert_exit 0 "$RC" "A.P3 record 前置 exit 0"
grep -F "branch=fix-c" "$LEDGER" >/dev/null 2>&1; G1=$?
assert_exit 0 "$G1" "A.P3 仓外裸 grep -F 命中 branch=fix-c（exit 0）"
grep -F "branch=rt-not-mine" "$LEDGER" >/dev/null 2>&1; G2=$?
assert_exit 1 "$G2" "A.P3 无关分支负对照不命中（grep exit 1）"
sb_cleanup

# =============================================================================
t_case "A.P4 幂等去重：同分支二次 publish（已有 PR）→ 零新 push/零新 create/台账行数不变"
sb_new_a
mk_branch "$WORK" fix-d
sb_l2 publish --worktree "$WORK" --branch fix-d --title "rt a4 first" \
  --approval "APPROVE rt-a4" --repo NousResearch/hermes-agent --base main >/dev/null
RC1=$?
assert_exit 0 "$RC1" "A.P4 首次 publish exit 0（前置）"
assert_eq "$(l2_rows)" "1" "A.P4 首次后台账 1 行（前置）"
P0="$(push_count)"
C0="$(stub_argc gh 'pr create')"
# 「已有 PR」：pr list 影子现在返回该分支的既有 PR（publish 先探 pr list 再动作）
printf '[{"number":501,"url":"https://github.com/NousResearch/hermes-agent/pull/501"}]\n' >"$PRS"
sb_l2 publish --worktree "$WORK" --branch fix-d --title "rt a4 second" \
  --approval "APPROVE rt-a4 again" --repo NousResearch/hermes-agent --base main >/dev/null
RC2=$?
assert_exit 0 "$RC2" "A.P4 二次 publish exit 0（幂等=良性成功；CONTRACT_AMBIGUOUS：实现改取 2 则红=交人审）"
assert_eq "$(push_count)" "$P0" "A.P4 零新 push（branch 锚判重先于 push）"
assert_eq "$(stub_argc gh 'pr create')" "$C0" "A.P4 零新 pr create"
assert_eq "$(l2_rows)" "1" "A.P4 台账行数不变（不重复记账）"
sb_cleanup

# =============================================================================
t_case "A.P5 多分支不串锚：两分支各发布 → 恰 2 行、各自锚各自命中"
sb_new_a
mk_branch "$WORK" fix-e1
sb_l2 publish --worktree "$WORK" --branch fix-e1 --title "rt a5 one" \
  --approval "APPROVE rt-a5 one" --repo NousResearch/hermes-agent --base main >/dev/null
RC1=$?
mk_branch "$WORK" fix-e2
sb_l2 publish --worktree "$WORK" --branch fix-e2 --title "rt a5 two" \
  --approval "APPROVE rt-a5 two" --repo NousResearch/hermes-agent --base main >/dev/null
RC2=$?
assert_exit 0 "$RC1" "A.P5 第一分支 publish exit 0"
assert_exit 0 "$RC2" "A.P5 第二分支 publish exit 0"
assert_eq "$(l2_rows)" "2" "A.P5 台账恰 2 行"
L1="$(sed -n '1p' "$LEDGER" 2>/dev/null)"
L2="$(sed -n '2p' "$LEDGER" 2>/dev/null)"
assert_contains "$L1" "branch=fix-e1" "A.P5 行 1 含自己分支锚 fix-e1"
assert_not_contains "$L1" "branch=fix-e2" "A.P5 行 1 不串第二分支锚"
assert_contains "$L2" "branch=fix-e2" "A.P5 行 2 含自己分支锚 fix-e2"
assert_not_contains "$L2" "branch=fix-e1" "A.P5 行 2 不串第一分支锚"
l2_check_rc --branch fix-e1 --ledger "$LEDGER"; E1=$?
assert_exit 0 "$E1" "A.P5 check --branch fix-e1 命中"
l2_check_rc --branch fix-e2 --ledger "$LEDGER"; E2=$?
assert_exit 0 "$E2" "A.P5 check --branch fix-e2 命中"
sb_cleanup

t_finish
