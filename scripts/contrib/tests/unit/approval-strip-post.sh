#!/bin/bash
# approval-strip-post.sh — 评论投递剥离通道：单一真源 + L2-auto 薄包装（卡 t_ee058c57，2026-10-24）
#
# 背景：2026-10-24 issue #140178 首评（comment 6369855435）手工 `gh api -X POST …/comments`
# 绕过 execute.sh strip 层，内部 HTML 块外泄 3389 字节（投递后回读抓到、PATCH 同 id 净化）。
# 修复 = 剥离逻辑提为 scripts/approval/strip-comment.sh 单一真源（execute.sh source 共用）
# + post-comment.sh 薄包装（strip 后才见 gh）。本测试守四件事：
#   G 组 黄金向量：剥离语义逐字节锁定（多块/多行块/文中块/无注释/单行块/内部备注截断/全剥空）
#   S 组 单源守卫：仓内禁第二份剥离实现（inblock 形态仅 strip-comment.sh）；execute.sh
#        不得回植内嵌定义；两个调用方必须 source 共享库
#   P 组 薄包装黑盒：stub gh 收到的载荷 = 剥离后正文（逐字节、经 body=@ 通道）；stdout=
#        html_url；剥后空正文拒发；gh 失败 rc=1；用法错误 rc=2；dry-run 零 gh 调用
#   M 组 mutation RED 电池：M1 摘 awk inblock 置位（多行内部块外泄）/ M2 摘「## 内部备注」
#        exit（尾段外泄）/ M3 摘空正文拒发行（空评论上线）——各自必须 RED；
#        M-CTRL 对照组真实件跑同一电池必须零命中（防探针自身失真，家规）
#
# 布局注意：被测对象在 scripts/approval/（不在 CONTRIB_TEST_TARGET=scripts/contrib 覆盖内），
# 本文件按仓内布局直接锚定 ../../approval；被测件只读，沙箱写全在独立 mktemp 沙箱，零真实外发。
#
# falsify：`bash scripts/contrib/tests/unit/approval-strip-post.sh | grep -c '^FAIL'` = 0 为绿；
#   对 pre-fix 布局（execute.sh 内嵌函数、无共享库）对拍：S3/S4 须 FAIL。
# 回退：本测试文件单独 revert；机制回退 = git revert 修复 commit（execute.sh 恢复内嵌函数、
#   strip-comment.sh/post-comment.sh 删除）——L2-A 隧道路行为逐字节不变（现状钳夹在
#   scripts/approval/tests/run.sh B 组 6.P1/6.P3 的 C8 断言）。
# 红线：绝不真实 gh 写；stub gh 只落本地日志。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
MARTIN_ROOT="$(cd "$TESTS_ROOT/../../.." && pwd)"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
t_init "approval-strip-post.sh"

APPROVAL_DIR="$MARTIN_ROOT/scripts/approval"
STRIP_LIB="$APPROVAL_DIR/strip-comment.sh"
POST_COMMENT="$APPROVAL_DIR/post-comment.sh"
EXECUTE="$APPROVAL_DIR/execute.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/approval-strip-post.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

JQ_DIR="$(dirname "$(command -v jq)")"
GH_LOG="$SANDBOX/gh.log"

# stub gh：调用行 + body=@ 载荷倾倒（落 GH_LOG 日志）；POST_BODY_FAIL=1 强制失败
cat > "$SANDBOX/gh" <<'STUB'
#!/bin/bash
LOG="${GH_STUB_LOG:?}"
{
  printf '=== gh %s\n' "$*"
  for a in "$@"; do
    case "$a" in
      body=@*)
        f="${a#body=@}"
        if [[ -f "$f" ]]; then printf -- '--- body-file ---\n'; cat "$f"; printf -- '--- end ---\n'; fi
        ;;
    esac
  done
} >> "$LOG"
if [[ "${POST_BODY_FAIL:-0}" == "1" ]]; then exit 1; fi
echo '{"html_url":"https://github.com/r/o/issues/42#issuecomment-6369855435"}'
exit 0
STUB
chmod +x "$SANDBOX/gh"

PRC=0
PDRAFT_OUT=""
post_run() { # <post-script> <repo> <num> <draft> [KEY=VAL...] → PRC/PDRAFT_OUT（stderr 落 post.err）
  local script="$1" repo="$2" num="$3" draft="$4"
  shift 4
  : > "$GH_LOG"
  PDRAFT_OUT="$(env PATH="$JQ_DIR:/usr/bin:/bin" GH_BIN="$SANDBOX/gh" GH_STUB_LOG="$GH_LOG" \
    "$@" bash "$script" "$repo" "$num" "$draft" 2>"$SANDBOX/post.err")"
  PRC=$?
}

golden() { # <name> — fixture 在 $SANDBOX/<name>.md，期望字节在 $SANDBOX/<name>.expected
  local name="$1"
  t_case "G $name"
  bash "$STRIP_LIB" "$SANDBOX/$name.md" > "$SANDBOX/$name.out" 2>"$SANDBOX/$name.err"
  assert_exit 0 "$?" "直呼剥离 rc=0"
  if cmp -s "$SANDBOX/$name.out" "$SANDBOX/$name.expected"; then
    _pass "输出逐字节=期望"
  else
    _fail "输出逐字节=期望" "diff: $(diff "$SANDBOX/$name.expected" "$SANDBOX/$name.out" 2>&1 | head -4 | tr '\n' ' ')"
  fi
  # shellcheck disable=SC1090  # STRIP_LIB 路径经沙箱变量注入，无法静态 follow
  ( source "$STRIP_LIB"; strip_leading_comments "$SANDBOX/$name.md" ) > "$SANDBOX/$name.out2" 2>/dev/null
  if cmp -s "$SANDBOX/$name.out" "$SANDBOX/$name.out2"; then
    _pass "函数形式与直呼同源同字节"
  else
    _fail "函数形式与直呼同源同字节" "两路口径不一"
  fi
}

payload_extract() { # → $SANDBOX/payload（body=@ 载荷字节）
  awk '/^--- body-file ---$/{f=1;next} /^--- end ---$/{f=0} f' "$GH_LOG" > "$SANDBOX/payload"
}

gh_calls() { grep -c '^=== gh ' "$GH_LOG" 2>/dev/null || true; }

# ================= G 组：黄金向量 =================
t_case "G1 多块+多行内部块+内部备注截断"
cat > "$SANDBOX/g1.md" <<'EOF'
<!-- twq:internal
rq-20261024-140178 判据与姿态措辞（3389 字节外泄事故形态） -->

<!-- 审批页中文摘要（L1，不随评论发出）：
L0 一句话
3-5 要点
-->

# 判定：#140178 复检收官

正文第一段，投递时须逐字保留。

- evidence: jobs.py:2347

## 内部备注：窗口期复盘，绝不随评论上线
这行更不能上线
EOF
cat > "$SANDBOX/g1.expected" <<'EOF'
# 判定：#140178 复检收官

正文第一段，投递时须逐字保留。

- evidence: jobs.py:2347

EOF
golden g1

t_case "G2 多行注释块含 --> 形态"
cat > "$SANDBOX/g2.md" <<'EOF'
<!-- 审批页 payload 表格：
| 列 | 值 | -->
|---|---|-->
# 标题行
正文 A
EOF
cat > "$SANDBOX/g2.expected" <<'EOF'
|---|---|-->
# 标题行
正文 A
EOF
golden g2

t_case "G3 文中注释块保留（只剥头部）"
cat > "$SANDBOX/g3.md" <<'EOF'
# 标题
正文开头
<!-- 文中说明：保留 -->
正文结尾
EOF
cp "$SANDBOX/g3.md" "$SANDBOX/g3.expected"
golden g3

t_case "G4 无注释直通"
printf '# 标题\n正文一\n正文二\n' > "$SANDBOX/g4.md"
cp "$SANDBOX/g4.md" "$SANDBOX/g4.expected"
golden g4

t_case "G5 单行注释块剥离"
printf '<!-- 摘要：x -->\n正文行\n' > "$SANDBOX/g5.md"
printf '正文行\n' > "$SANDBOX/g5.expected"
golden g5

t_case "G6 全剥空（注释+内部备注即全文）"
printf '<!-- c -->\n\n## 内部备注：x\n尾巴\n' > "$SANDBOX/g6.md"
: > "$SANDBOX/g6.expected"
golden g6

# ================= S 组：单源守卫 =================
t_case "S 单源守卫"
assert_eq "$(grep -c 'inblock = 1' "$STRIP_LIB")" "1" "S1 awk inblock 置位恰 1 处（单源锚）"
assert_eq "$(grep -rln --include='*.sh' 'inblock = 1' "$MARTIN_ROOT/scripts" 2>/dev/null \
  | grep -v 'strip-comment\.sh$' | grep -v '/tests/' | wc -l | tr -d ' ')" "0" \
  "S2 仓内无第二份剥离实现（inblock 形态仅 strip-comment.sh）"
assert_eq "$(grep -c '^strip_leading_comments()' "$EXECUTE")" "0" "S3 execute.sh 无内嵌定义（禁回植）"
assert_eq "$(grep -c 'source .*strip-comment\.sh' "$EXECUTE")" "1" "S4 execute.sh source 共享库"
assert_eq "$(grep -c 'source .*strip-comment\.sh' "$POST_COMMENT")" "1" "S5 post-comment.sh source 共享库"

# ================= P 组：薄包装黑盒 =================
D="$SANDBOX/p-draft.md"
cat > "$D" <<'EOF'
<!-- twq:internal
rq-20261024-140178：内部判据与姿态措辞 -->

# 判定：复检收官

正文第一段，投递时须逐字保留。

- evidence: scheduler.py:2967

## 内部备注：只进 approved.log，绝不外发
备注正文行
EOF
bash "$STRIP_LIB" "$D" > "$SANDBOX/p-expected"   # 期望载荷 = 单源剥离结果

t_case "P1 dry-run 只打印零投递"
post_run "$POST_COMMENT" "r/o" 42 "$D" POST_COMMENT_DRY_RUN=true
assert_exit 0 "$PRC" "dry-run rc=0"
if [[ "$PDRAFT_OUT" == *'-X POST repos/r/o/issues/42/comments'* ]]; then
  _pass "dry-run 打印投递命令形态"
else
  _fail "dry-run 打印投递命令形态" "out=[$PDRAFT_OUT]"
fi
assert_eq "$(gh_calls)" "0" "dry-run 零 gh 调用"

t_case "P2 真投递：命令形态与 rc"
post_run "$POST_COMMENT" "r/o" 42 "$D"
assert_exit 0 "$PRC" "投递 rc=0"
assert_contains "$(cat "$GH_LOG")" "gh api -X POST repos/r/o/issues/42/comments" "投递端点与 -X POST 在位"
assert_contains "$(cat "$GH_LOG")" "-F body=@" "载荷走 body=@ 通道（-f stdin 陷阱不复发）"

t_case "P3 载荷逐字节=剥离后正文"
payload_extract
if cmp -s "$SANDBOX/payload" "$SANDBOX/p-expected"; then
  _pass "载荷字节=单源剥离结果"
else
  _fail "载荷字节=单源剥离结果" "diff: $(diff "$SANDBOX/p-expected" "$SANDBOX/payload" 2>&1 | head -4 | tr '\n' ' ')"
fi
assert_not_contains "$(cat "$SANDBOX/payload")" "rq-20261024" "内部块标记零外泄（回读探针同源）"
assert_not_contains "$(cat "$SANDBOX/payload")" "内部备注" "内部备注段零外泄"

t_case "P4 stdout=评论 html_url"
assert_eq "$PDRAFT_OUT" "https://github.com/r/o/issues/42#issuecomment-6369855435" "stdout=html_url（回执照可用）"

t_case "P5 空文件拒发"
: > "$SANDBOX/empty.md"
post_run "$POST_COMMENT" "r/o" 42 "$SANDBOX/empty.md"
assert_exit 1 "$PRC" "空正文 rc=1"
assert_eq "$(gh_calls)" "0" "空正文零投递"
assert_contains "$(cat "$SANDBOX/post.err")" "拒发" "拒发原因落 stderr 可诊断"

t_case "P6 全剥空拒发"
cat > "$SANDBOX/only-internal.md" <<'EOF'
<!-- 只有一段内部块 -->

## 内部备注：x
EOF
post_run "$POST_COMMENT" "r/o" 42 "$SANDBOX/only-internal.md"
assert_exit 1 "$PRC" "全剥空 rc=1"
assert_eq "$(gh_calls)" "0" "全剥空零投递"

t_case "P7 gh 失败透传 rc=1"
post_run "$POST_COMMENT" "r/o" 42 "$D" POST_BODY_FAIL=1
assert_exit 1 "$PRC" "gh 失败 rc=1"
assert_contains "$(cat "$SANDBOX/post.err")" "投递失败" "失败原因落 stderr"

t_case "P8 用法错误 rc=2"
env PATH="$JQ_DIR:/usr/bin:/bin" bash "$POST_COMMENT" onlyonearg >/dev/null 2>&1; assert_exit 2 "$?" "参数不足 rc=2"
env PATH="$JQ_DIR:/usr/bin:/bin" bash "$POST_COMMENT" noslash 42 "$D" >/dev/null 2>&1; assert_exit 2 "$?" "repo 无 / rc=2"
env PATH="$JQ_DIR:/usr/bin:/bin" bash "$POST_COMMENT" "r/o" 42abc "$D" >/dev/null 2>&1; assert_exit 2 "$?" "num 非数字 rc=2"
env PATH="$JQ_DIR:/usr/bin:/bin" bash "$POST_COMMENT" "r/o" 42 "$SANDBOX/不存在.md" >/dev/null 2>&1; assert_exit 2 "$?" "稿件不存在 rc=2"

# ================= M 组：mutation RED 电池 =================
MUT="$SANDBOX/mut"
mkdir -p "$MUT/m1" "$MUT/m2" "$MUT/m3"
cp "$POST_COMMENT" "$MUT/m1/post-comment.sh"; cp "$POST_COMMENT" "$MUT/m2/post-comment.sh"; cp "$POST_COMMENT" "$MUT/m3/post-comment.sh"
# M1: 摘 awk inblock 置位 → 多行内部块外泄
sed '/inblock = 1; next/d' "$STRIP_LIB" > "$MUT/m1/strip-comment.sh"
# M2: 摘「## 内部备注」exit 行 → 尾段外泄（awk 行有缩进，锚取含 ^ 锚的完整字面）
grep -vF '/^## 内部备注/ { exit }' "$STRIP_LIB" > "$MUT/m2/strip-comment.sh"
# M3: 摘空正文拒发的 exit 1（块内替换为空命令，保语法）→ 空评论上线
sed '/剥离后正文为空/,/^fi/s/^  exit 1$/  :/' "$POST_COMMENT" > "$MUT/m3/post-comment.sh"
cp "$STRIP_LIB" "$MUT/m3/strip-comment.sh"

t_case "M1 摘 inblock 置位 → 多行内部块外泄（须 RED）"
post_run "$MUT/m1/post-comment.sh" "r/o" 42 "$D"
payload_extract
if grep -q 'rq-20261024-140178' "$SANDBOX/payload"; then
  _pass "M1 变异体内部块外泄被抓（RED 自证）"
else
  _fail "M1 变异体内部块外泄被抓（RED 自证）" "变异未产生可分输出，探针失真"
fi

t_case "M2 摘内部备注 exit → 尾段外泄（须 RED）"
post_run "$MUT/m2/post-comment.sh" "r/o" 42 "$D"
payload_extract
if grep -q '内部备注' "$SANDBOX/payload"; then
  _pass "M2 变异体尾段外泄被抓（RED 自证）"
else
  _fail "M2 变异体尾段外泄被抓（RED 自证）" "变异未产生可分输出，探针失真"
fi

t_case "M3 摘空正文拒发 → 空评论上线（须 RED）"
post_run "$MUT/m3/post-comment.sh" "r/o" 42 "$SANDBOX/only-internal.md"
assert_eq "$(gh_calls)" "1" "M3 变异体空正文仍投递（RED 自证）"

t_case "M-CTRL 对照组真实件同电池零命中"
post_run "$POST_COMMENT" "r/o" 42 "$D"
payload_extract
if grep -q 'rq-20261024-140178\|内部备注' "$SANDBOX/payload"; then
  _fail "对照组 P 稿零外泄" "真实件漏内部内容——机制或探针失真"
else
  _pass "对照组 P 稿零外泄"
fi
post_run "$POST_COMMENT" "r/o" 42 "$SANDBOX/only-internal.md"
assert_exit 1 "$PRC" "对照组全剥空仍拒发"
assert_eq "$(gh_calls)" "0" "对照组全剥空零投递"

t_finish
