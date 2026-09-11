#!/bin/bash
# approval-page-summary.sh — Tier U：审批页「中文摘要（L1）」段渲染容错（t_404ff5c1 回归锚点）
# 缺陷：notify.sh:898 的摘要切分用**字面量** split，写死「）＋全角冒号」；稿件里半角冒号与
#   「）【注记】：」写法并存 → 不命中 → $summary 为空 → L0 回退成 $it.title、要点层整段丢失
#   （静默降级为「标题+premises」）。用户 30 秒决策依赖的 L0+要点层失明。
# 本用例覆盖：
#   ① 三种段头写法（全角冒号 / 半角冒号 / 带【注记】全角冒号）都必须渲染出 L0 与要点层
#   ② 降级判别：页内 L0 行不得是 $it.title（哨兵 title 断言）
#   ③ L0 标签前缀（「L0:」/「一句话：」）剥除容错
#   ④ 载荷不受影响：正文 verbatim 在页内、内部备注被截尾、摘要段本体不随载荷外发
#   ⑤ 真实调用点（cmd_approve 交互路，dry-run）落盘 <draft>.page.md 且内容正确
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "approval-page-summary.sh"

sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
PEND="$SB_ROOT/contrib-data/pending"

# render <id> <draft> → 页 markdown（source guard 载入纯函数，零外发/零 gh/零 tunnel）
render() {
  sb_run -e "NOTIFY_SOURCE_ONLY=1" "source \"\$MARTIN_DIR/scripts/contrib/notify.sh\" >/dev/null 2>&1
_build_approval_page \"$1\" \"$2\" \"01-01 00:00\" 48"
}

# mk_draft <id> <分隔符> <L0 标签前缀> <标签后分隔符>
mk_draft() {
  local id="$1" sep="$2" lbl="$3" lsep="$4"
  cat >"$PEND/$id.md" <<EOF
<!--
  版次: unit-test | 依据: 合成稿（t_404ff5c1）
    审批页中文摘要（L1，不随评论发出）${sep}
      ${lbl}${lsep}L0-哨兵-${id}
      要点:
        1. 要点一-${id}
        2. 要点二-${id}
-->
正文第一行-${id}

## 内部备注
内部备注不该出现在页里-${id}
EOF
}

seed_item() { # <id> <issue>
  sb_seed_queue_item "$1" "$2" deep awaiting-approval
  jq --arg id "$1" --arg d "$PEND/$1.md" \
    '(.items[] | select(.id == $id)) |= (.draft = $d)' \
    "$SB_ROOT/contrib-data/ready-queue.json" >"$SB_ROOT/contrib-data/ready-queue.json.tmp" \
    && mv "$SB_ROOT/contrib-data/ready-queue.json.tmp" "$SB_ROOT/contrib-data/ready-queue.json"
}

# ── ① 三种段头写法（含 ② 降级判别 ③ 标签剥除）──────────────────────────────
# 变体：id / 段头分隔符 / L0 标签 / 标签分隔符（空串 = 该部分缺省）
CASES="rq-u-fullwidth|：|L0|:
rq-u-ascii|:|一句话|：
rq-u-annot|【redteam 定稿；v6 只补一条】：|L0|：
rq-u-nolabel|:||
"
n=0
while IFS='|' read -r id sep lbl lsep; do
  [[ -n "$id" ]] || continue
  n=$((n + 1))
  issue=$((991000 + n))
  seed_item "$id" "$issue"
  mk_draft "$id" "$sep" "$lbl" "$lsep"
  page="$(render "$id" "$PEND/$id.md")"

  t_case "$id 段头「${sep}」：L0 = 摘要首行（非 title）"
  assert_contains "$page" "> L0-哨兵-$id" "L0 行 = 摘要段首行"
  assert_not_contains "$page" "> issue #$issue" "L0 未回退为 \$it.title"

  t_case "$id 段头「${sep}」：要点层非空"
  assert_contains "$page" "1. 要点一-$id" "要点 1 在页内"
  assert_contains "$page" "2. 要点二-$id" "要点 2 在页内"
  assert_not_contains "$page" "（详见附录原文）" "未走「- title（详见附录原文）」降级路"

  t_case "$id 段头「${sep}」：L0 标签前缀已剥"
  assert_not_contains "$page" "> L0:" "页内 L0 行无「L0:」标签残留"
  assert_not_contains "$page" "> 一句话：" "页内 L0 行无「一句话：」标签残留"

  t_case "$id 段头「${sep}」：载荷与内备注边界不回归"
  assert_contains "$page" "正文第一行-$id" "真实载荷 verbatim 在页内"
  assert_not_contains "$page" "内部备注不该出现在页里-$id" "「## 内部备注」尾部已截掉"
  assert_not_contains "$page" "审批页中文摘要（L1，不随评论发出）" "摘要段本体不外发（详情见载荷层）"
done <<<"$CASES"

# ── ⑤ 真实调用点：cmd_approve 交互路 dry-run 落盘 <draft>.page.md ──────────────
t_case "cmd_approve 交互路（dry-run）：落盘 page.md 且 L0/要点层正确"
sb_config_set '.approval_interactive = true'
sid="rq-u-approve"
seed_item "$sid" 991100
mk_draft "$sid" ":" "L0" ":"
pagemd="$PEND/$sid.md.page.md"
out="$(sb_run -e "NOTIFY_DRY_RUN=true" 'bash "$MARTIN_DIR/scripts/contrib/notify.sh" approve '"$sid"'')"
rc=$?
assert_exit 0 $rc "approve rc=0"
assert_contains "$out" "[dry-run]" "审批卡走 dry-run 打印（未真实外发）"
if [[ -f "$pagemd" ]]; then
  _pass "page.md 已落盘"
  page_body="$(cat "$pagemd")"
  assert_contains "$page_body" "> L0-哨兵-$sid" "落盘页 L0 = 摘要首行"
  assert_not_contains "$page_body" "> issue #991100" "落盘页 L0 未回退 title"
  assert_contains "$page_body" "1. 要点一-$sid" "落盘页要点层非空"
else
  _fail "page.md 已落盘" "缺失: ${pagemd}（stderr: $(sb_out 6)）"
fi
assert_stub_not_called hermes "dry-run 零 hermes 调用（审批卡只打印）"
assert_stub_not_called tunnel "dry-run 零 tunnel 调用"

sb_cleanup
t_finish
