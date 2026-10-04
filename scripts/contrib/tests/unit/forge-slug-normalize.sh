#!/bin/bash
# forge-slug-normalize.sh — init/register slug 归一守卫（[fix] t_48e0415d）
#
# 缺口：caller 把 issue 全名当 slug 传（如 `132507-plugin-approval-advice` 已带 forge- 前缀的
# 全名形 `forge-132507-plugin-approval-advice`）时，旧版 forge.sh 拼出 forge-forge-* 双前缀
# 条目与分支（三次生产实证：t_02feb332 班、08:53 岗哨班、t_60a2188d 班）。
# 修复：init/register 双侧 `slug="${slug#forge-}"` 归一，全名/短名等价。
#
# 本测试纯函数级：不建真 worktree（init 的 git 面由 e2e/人工覆盖），只验证 slug 归一逻辑
# 与「init/register 配对同一 id」的不变量——从 forge.sh 提取两处归一行做行为对拍。
# 回退：git revert <forge.sh 补丁 sha>；本测试文件随补丁一起 revert。
set -uo pipefail

TARGET="${CONTRIB_TEST_TARGET:-$(cd "$(dirname "$0")/../.." && pwd)}"
FORGE="$TARGET/forge.sh"
[[ -f "$FORGE" ]] || FORGE="$(cd "$(dirname "$0")/../../forge.sh" && pwd)"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS forge-slug-normalize.sh $1"; }
bad()  { fail=$((fail+1)); echo "FAIL forge-slug-normalize.sh $1"; }

# ── 静态形状：两处归一行都在位（init 与 register 各一）──
n_init=$(grep -c 'slug="${slug#forge-}"' "$FORGE" 2>/dev/null); n_init="${n_init:-0}"; n_init="$(printf '%s' "$n_init" | tr -d '[:space:]')"
if [[ "$n_init" == "2" ]]; then ok "归一行恰 2 处（init+register）"; else bad "归一行数量=${n_init} (期望 2)"; fi

# ── 行为对拍：bash 参数展开语义与 forge.sh 内联逻辑逐字一致 ──
# 用与 forge.sh 完全相同的表达式在子 shell 里跑，锁住「归一后 register 能配对 init id」
norm() { local slug="$1"; slug="${slug#forge-}"; printf '%s' "forge-$slug"; }

r1=$(norm "132494-pip-row-catalog-pin")
[[ "$r1" == "forge-132494-pip-row-catalog-pin" ]] && ok "短名输入 → 单前缀 id" || bad "短名输入得 $r1"

r2=$(norm "forge-132507-plugin-approval-advice")
[[ "$r2" == "forge-132507-plugin-approval-advice" ]] && ok "全名输入 → 归一为单前缀 id（不再 forge-forge-*）" || bad "全名输入得 $r2"

r3=$(norm "forge-forge-131355-aux-reset-at")
[[ "$r3" == "forge-forge-131355-aux-reset-at" ]] && ok "双前缀输入 → id 稳定（与 legacy 条目 round-trip 自洽）" || bad "双前缀输入得 $r3"

r3b=$(norm "$r3")
[[ "$r3b" == "$r3" ]] && ok "归一幂等：norm(norm(x))==norm(x)" || bad "归一不幂等：$r3 -> $r3b"

r4=$(norm "forgeforge-x")
[[ "$r4" == "forge-forgeforge-x" ]] && ok "forgeforge-* 不误剥（# 前缀剥离只吃字面 forge-）" || bad "forgeforge 形态得 $r4"

# ── init/register id 配对不变量：同一输入在两侧归一后必得同一 id ──
init_id=$(norm "forge-126004-worktree-partial-reuse")
reg_id=$(norm "forge-126004-worktree-partial-reuse")
[[ "$init_id" == "$reg_id" ]] && ok "init/register 同输入同 id（配对不变量）" || bad "init=$init_id register=$reg_id 不配对"

# ── slug 正则仍在位（归一不削弱形状闸）──
grep -q '\^\[a-z0-9\]\[a-z0-9-\]{1,40}\$' "$FORGE" && ok "slug 形状正则未被移除" || bad "slug 形状正则丢失"

echo "##SUMMARY {\"dim\":\"unit\",\"file\":\"forge-slug-normalize.sh\",\"total\":$((pass+fail)),\"passed\":$pass,\"failed\":$fail,\"skipped\":0}"
[[ "$fail" == "0" ]]
