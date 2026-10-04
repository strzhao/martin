#!/bin/bash
# forge-slug-normalize.sh — init/register slug 归一守卫（黑盒行为版；t_5adc9d1a 行为化加固）
#
# 版意：t_48e0415d 落地 forge.sh 双侧 `slug="${slug#forge-}"` 归一（commit 534beb2）后，
# 红队实证首版纯函数级测试的两个盲区：(a) `grep -c` 数归一行数量、不辨位置——把 init 侧
# 归一行错位到 slug 正则之后，8/8 仍全绿；(b) 行为断言跑测试内自拷贝表达式（norm()），
# 不经 forge.sh 真路径。本版升级为黑盒 CLI 行为测试（同 forge-status-enum.sh 家规）：
# 沙箱内直呼真 forge.sh，断言铁律 = 退出码 + 沙箱台账 jq 读回双证，stdout/契约日志只作第三证。
#
# 假上游配方：git init + 空 seed commit + update-ref refs/remotes/origin/main HEAD——
# 无 origin remote → forge.sh fetch 失败走警告回退路径（base=本地 ref），沙箱内确定性成立。
#
# mutation 自证电池（每次运行都跑，三例 + 对照组）：
#   MUT-1 删除 init 侧归一行（RED 已证，t_48e0415d）
#   MUT-2 init 侧归一行错位到 slug 正则之后（本卡核心：全名探针不可分——正则恰吃全名形态，
#         剥空探针 forge- 可分：契约 exit 2，错位版漏过正则在 git worktree 层炸 rc=1）
#   MUT-3 删除 register 侧归一行（配对链断裂：原条目不翻 ready + forge-forge-* 新条目）
#   MUT-CTRL 未变异本过同一电池必须零命中——防探针自身失真。
#
# CONTRIB_TEST_TARGET 语义 = scripts/contrib 目录本身（非其父目录）；变异副本按平面布局
# （目录内直接放 forge.sh）注入独立沙箱，台账与主沙箱互不串扰。
#
# falsify：`bash scripts/contrib/tests/unit/forge-slug-normalize.sh | grep -c '^FAIL'` = 0 为绿；
#   对 534beb2^ 旧版对拍（CONTRIB_TEST_TARGET 指向仅含旧 forge.sh 的目录）须 fails>0。
# 回退：本测试文件单独 revert，不触 forge.sh。
# 红线：绝不 push；台账只在沙箱内写。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET_DEFAULT="$(cd "$TESTS_ROOT/.." && pwd)"
export CONTRIB_TEST_TARGET="${CONTRIB_TEST_TARGET:-$TARGET_DEFAULT}"
export CONTRIB_TEST_STUBS="${CONTRIB_TEST_STUBS:-$TESTS_ROOT/stubs}"
export DIM=unit

source "$TESTS_ROOT/lib/assert.sh"
source "$TESTS_ROOT/lib/sandbox.sh"
t_init "forge-slug-normalize.sh"

TARGET="$(tests_scripts_dir "$TARGET_DEFAULT")"
FORGE="$TARGET/forge.sh"
LEDGER=""

# ── fixtures 根：假上游 + 变异副本（EXIT 统一清理；台账仍只在沙箱内）──
MUTROOT="$(mktemp -d "${TMPDIR:-/tmp}/forge-slug-bb.XXXXXX")"
trap 'rm -rf "$MUTROOT"' EXIT

UP_FULL="forge-132507-plugin-approval-advice"   # 全名输入（生产事故形态，35 位恰在正则域内）
UP_SLUG="132507-plugin-approval-advice"         # 期望归一结果
UP_SHORT="132494-pip-row-catalog-pin"           # 短名输入

build_fake_upstream() { # <tag> → 假上游仓路径（fetch 必败；origin/main=本地 ref 可解析）
  local d
  d="$MUTROOT/up-$1"
  mkdir -p "$d"
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" -c user.name=forge-bb -c user.email=forge-bb@test \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q --allow-empty -m seed >/dev/null 2>&1
  git -C "$d" update-ref refs/remotes/origin/main HEAD >/dev/null 2>&1
  printf '%s' "$d"
}

run_forge() { # <args...> → 黑盒直呼沙箱内 forge.sh；rc=$?（stdout 捕获或丢弃由调用方定）
  local a snippet=""
  for a in "$@"; do snippet="$snippet$(printf '%q ' "$a")"; done
  sb_run "\"\${MARTIN_DIR}/scripts/contrib/forge.sh\" $snippet"
}

inv_field() { # <id> <field> → 沙箱台账 jq 读回（缺件/缺账=空）——读回证据唯一通道
  jq -r --arg id "$1" --arg f "$2" '(.items[] | select(.id == $id) | .[$f]) // ""' "$LEDGER" 2>/dev/null
}
inv_total() { jq -r '(.items | length)' "$LEDGER" 2>/dev/null; }
inv_forgeforge() { jq -r '[.items[] | select(.id | startswith("forge-forge-"))] | length' "$LEDGER" 2>/dev/null; }

wt_count() { git -C "$1" worktree list --porcelain 2>/dev/null | awk '$1 == "worktree" { c++ } END { print c + 0 }'; }
forgeforge_branch_count() { git -C "$1" for-each-ref 'refs/heads/forge/forge-*' --format='%(refname)' 2>/dev/null | awk 'END { print NR + 0 }'; }
branch_exists() { git -C "$1" rev-parse --verify --quiet "refs/heads/$2" >/dev/null 2>&1; }

make_mutant() { # <tag> <mode> → 变异副本目录路径；模式未命中/副本未变化 → 非零返回（输出为空）
  local d
  d="$MUTROOT/$1"
  mkdir -p "$d"
  cp "$FORGE" "$d/forge.sh" || return 1
  python3 "$MUTROOT/mutate.py" "$d/forge.sh" "$2" >/dev/null 2>&1 || return 1
  cmp -s "$FORGE" "$d/forge.sh" && return 2
  printf '%s' "$d"
}

# mutation 行级手术（模式未命中即非零退出——对旧版目标显式 FAIL 而非假绿）
cat > "$MUTROOT/mutate.py" <<'PYEOF'
import io
import sys


def main() -> int:
    path, mode = sys.argv[1], sys.argv[2]
    with io.open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    tok = 'slug="${slug#forge-}"'

    def hits(pred):
        return [i for i, ln in enumerate(lines) if pred(ln)]

    if mode == "del_init":
        idx = hits(lambda ln: tok in ln and "caller" in ln)
        if len(idx) != 1:
            return 3
        del lines[idx[0]]
    elif mode == "del_register":
        idx = hits(lambda ln: tok in ln and "同一归一" in ln)
        if len(idx) != 1:
            return 3
        del lines[idx[0]]
    elif mode == "move_init_after_regex":
        idx = hits(lambda ln: tok in ln and "caller" in ln)
        rx = hits(lambda ln: "只许小写字母数字连字符" in ln)
        if len(idx) != 1 or len(rx) != 1:
            return 3
        i, r = idx[0], rx[0]
        moved = lines.pop(i)
        if i < r:
            r -= 1
        lines.insert(r + 1, moved)
    else:
        return 2
    with io.open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    return 0


sys.exit(main())
PYEOF

PROBE_A_HIT=1
PROBE_B_HIT=1
PROBE_DETAIL=""
probe_battery() { # <tagA> <tagB> — 双探针打当前沙箱被测本；行为≠契约 → 对应 *_HIT=1
  PROBE_A_HIT=1
  PROBE_B_HIT=1
  PROBE_DETAIL=""
  local fa fb rca rcb st ff
  fa="$(build_fake_upstream "$1")"
  run_forge init "$UP_FULL" --repo NousResearch/hermes-agent --issue 132507 --dir "$fa" >/dev/null
  rca=$?
  st="$(inv_field "$UP_FULL" status)"
  ff="$(inv_forgeforge)"
  if [[ "$rca" == "0" && "$st" == "in-flight" && "$ff" == "0" \
        && "$(forgeforge_branch_count "$fa")" == "0" \
        && -d "$fa/.claude/worktrees/forge-$UP_SLUG" ]]; then
    PROBE_A_HIT=0
  else
    PROBE_DETAIL="探针A(全名init) rc=$rca 台账status=[$st] forgeforge=$ff;"
  fi
  fb="$(build_fake_upstream "$2")"
  run_forge init forge- --repo NousResearch/hermes-agent --dir "$fb" >/dev/null
  rcb=$?
  if [[ "$rcb" == "2" ]]; then
    PROBE_B_HIT=0
  else
    PROBE_DETAIL="${PROBE_DETAIL} 探针B(剥空init) rc=$rcb(契约=2)"
  fi
}

# ================= 第一沙箱：行为面（正 / 配对 / 补样 / 拒） =================
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
LEDGER="${CONTRIB_DATA_DIR}/inventory.json"

t_case "前置自检：被测副本在位 + 形状快照（仅 precheck 信号——grep 不辨位置，错位由 MUT-2 电池堵）"
if [[ -f "$FORGE" ]]; then
  _pass "被测 forge.sh 在位"
else
  _fail "被测 forge.sh 在位" "缺失: $FORGE"
fi
n_norm="$(grep -cF 'slug="${slug#forge-}"' "$FORGE" 2>/dev/null || true)"
[[ -z "$n_norm" ]] && n_norm=0
assert_eq "$n_norm" "2" "归一行恰 2 处（形状快照，非主断言）"
if grep -q '只许小写字母数字连字符' "$FORGE" 2>/dev/null; then
  _pass "slug 形状正则在位"
else
  _fail "slug 形状正则在位" "正则行丢失"
fi

t_case "AC1: init 短名 → exit 0 + 台账 jq 读回 id=forge-<slug> + 分支/worktree 落地"
FAKE_A="$(build_fake_upstream a)"
ac1_out="$(run_forge init "$UP_SHORT" --repo NousResearch/hermes-agent --issue 132494 --dir "$FAKE_A")"
assert_exit 0 $?
assert_eq "$(inv_field "forge-$UP_SHORT" status)" "in-flight" "台账读回 id=forge-$UP_SHORT (status=in-flight)"
if branch_exists "$FAKE_A" "forge/$UP_SHORT"; then
  _pass "分支 refs/heads/forge/$UP_SHORT 落地"
else
  _fail "分支 refs/heads/forge/$UP_SHORT 落地" "rev-parse --verify 失败"
fi
if [[ -d "$FAKE_A/.claude/worktrees/forge-$UP_SHORT" ]]; then
  _pass "worktree 目录存在"
else
  _fail "worktree 目录存在" "forge-$UP_SHORT 缺失"
fi
assert_contains "$ac1_out" "[forge] worktree 就绪" "stdout 契约行（第三证）"

t_case "AC2: init 全名（生产事故形态）→ exit 0 + 归一 id + 三面零 forge-forge-* 残留"
FAKE_B="$(build_fake_upstream b)"
ac2_out="$(run_forge init "$UP_FULL" --repo NousResearch/hermes-agent --issue 132507 --dir "$FAKE_B")"
assert_exit 0 $?
assert_eq "$(inv_field "$UP_FULL" status)" "in-flight" "台账读回 id=${UP_FULL}（归一，非 forge-forge-*）"
if branch_exists "$FAKE_B" "forge/$UP_SLUG"; then
  _pass "分支 refs/heads/forge/$UP_SLUG 落地"
else
  _fail "分支 refs/heads/forge/$UP_SLUG 落地" "rev-parse --verify 失败"
fi
if [[ -d "$FAKE_B/.claude/worktrees/forge-${UP_SLUG}" ]]; then
  _pass "worktree 目录（forge-${UP_SLUG}）"
else
  _fail "worktree 目录（forge-${UP_SLUG}）" "目录缺失"
fi
assert_eq "$(inv_forgeforge)" "0" "台账零 forge-forge-* 残留"
assert_eq "$(forgeforge_branch_count "$FAKE_B")" "0" "分支零 forge/forge-* 残留"
assert_eq "$(inv_total)" "2" "台账恰 2 条（短名+全名各一）"
assert_contains "$ac2_out" "[forge] worktree 就绪" "stdout 契约行（第三证）"

t_case "AC3: register 全名与 init 全名条目配对 → 翻 ready、总数不变、零 forge-forge-*"
base_b="$(git -C "$FAKE_B" rev-parse HEAD)"
ac3_out="$(run_forge register "$UP_FULL" --branch "forge/$UP_SLUG" --sha "$base_b" --domain repo:NousResearch/hermes-agent --notes 黑盒配对验收)"
assert_exit 0 $?
assert_eq "$(inv_field "$UP_FULL" status)" "ready" "init 条目翻 ready（配对命中）"
assert_eq "$(inv_field "$UP_FULL" fork_sha)" "$base_b" "fork_sha 写入读回"
assert_eq "$(inv_total)" "2" "条目总数不变（配对非新增）"
assert_eq "$(inv_forgeforge)" "0" "零 forge-forge-* 新条目"
assert_contains "$ac3_out" "已入库: $UP_FULL →" "stdout 契约行（第三证，归一 slug 回显）"

t_case "AC4: register 短名与 init 短名条目配对（双向归一闭合）"
base_a="$(git -C "$FAKE_A" rev-parse HEAD)"
ac4_out="$(run_forge register "$UP_SHORT" --branch "forge/$UP_SHORT" --sha "$base_a" --domain repo:NousResearch/hermes-agent)"
assert_exit 0 $?
assert_eq "$(inv_field "forge-$UP_SHORT" status)" "ready" "init 短名条目翻 ready"
assert_eq "$(inv_total)" "2" "条目总数不变"
assert_contains "$ac4_out" "已入库: forge-$UP_SHORT →" "stdout 契约行（第三证）"

t_case "补样: forgeforge-* 不误剥（# 前缀剥离只吃字面 forge-，与 legacy 形态 round-trip 自洽）"
FAKE_C="$(build_fake_upstream c)"
run_forge init forgeforge-x --repo NousResearch/hermes-agent --dir "$FAKE_C" >/dev/null
assert_exit 0 $?
assert_eq "$(inv_field forge-forgeforge-x status)" "in-flight" "id=forge-forgeforge-x（非 forge-forge-x 双剥）"
if branch_exists "$FAKE_C" "forge/forgeforge-x"; then
  _pass "分支 forge/forgeforge-x 落地"
else
  _fail "分支 forge/forgeforge-x 落地" "rev-parse --verify 失败"
fi
assert_eq "$(inv_total)" "3" "台账恰 3 条"

t_case "AC5: 拒绝面（大写/剥空/缺参）→ exit 2 + 台账字节 cmp 不变 + 零新增 worktree"
cp "$LEDGER" "${SB_TMP}/ac5-before.json"
wt_before="$(wt_count "$FAKE_B")"
run_forge init FORGE-132507-X --repo NousResearch/hermes-agent --dir "$FAKE_B" >/dev/null
assert_exit 2 $? "大写 slug → exit 2"
assert_contains "$(sb_out 5)" "只许小写" "stderr 拒绝文案（第三证）"
run_forge init forge- --repo NousResearch/hermes-agent --dir "$FAKE_B" >/dev/null
assert_exit 2 $? "剥空 slug（forge-）→ exit 2"
run_forge init >/dev/null
assert_exit 2 $? "缺 slug 实参 → exit 2（usage）"
run_forge init 132999-missing-repo --issue 132999 >/dev/null
assert_exit 2 $? "缺 --repo → exit 2"
if cmp -s "${SB_TMP}/ac5-before.json" "$LEDGER"; then
  _pass "台账字节不变（cmp -s 四连拒绝零写盘）"
else
  _fail "台账字节不变（cmp -s 四连拒绝零写盘）" "拒绝路径发生写盘"
fi
assert_eq "$(wt_count "$FAKE_B")" "$wt_before" "worktree 零新增"
assert_eq "$(forgeforge_branch_count "$FAKE_B")" "0" "拒绝零分支残留"
assert_eq "$(inv_total)" "3" "台账条数不变"

sb_cleanup

# ================= mutation 自证电池（对照组 + 三变异体） =================
t_case "MUT-CTRL: 对照组（未变异本）过双探针必须零命中——探针自身失真防御"
if sb_new >/dev/null 2>&1; then
  LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
  probe_battery c1 c2
  assert_eq "$PROBE_A_HIT" "0" "对照组探针A零命中（rc0+归一id+零残留）"
  assert_eq "$PROBE_B_HIT" "0" "对照组探针B零命中（剥空→exit 2）"
  sb_cleanup
else
  _fail "对照组沙箱" "sb_new 失败——mutation 电池未执行"
fi

t_case "MUT-1: 删除 init 侧归一行 → 电池必须处决（RED 已证 t_48e0415d）"
mut1="$(make_mutant mut1 del_init)"
if [[ -n "$mut1" ]]; then
  CONTRIB_TEST_TARGET="$mut1"
  if sb_new >/dev/null 2>&1; then
    LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
    probe_battery m1a m1b
    if [[ "$PROBE_A_HIT" == "1" || "$PROBE_B_HIT" == "1" ]]; then
      _pass "MUT-1 被电池处决（${PROBE_DETAIL}）"
    else
      _fail "MUT-1 被电池处决" "双探针均未命中——变异体存活"
    fi
    sb_cleanup
  else
    _fail "MUT-1 沙箱" "sb_new 失败"
  fi
else
  _fail "MUT-1 变异副本" "make_mutant del_init 失败（模式未命中或副本未变化——被测本形态异常）"
fi

t_case "MUT-2: init 侧归一行错位到 slug 正则之后 → 电池必须处决（本卡核心：错位盲区）"
mut2="$(make_mutant mut2 move_init_after_regex)"
if [[ -n "$mut2" ]]; then
  CONTRIB_TEST_TARGET="$mut2"
  if sb_new >/dev/null 2>&1; then
    LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
    probe_battery m2a m2b
    if [[ "$PROBE_A_HIT" == "1" || "$PROBE_B_HIT" == "1" ]]; then
      _pass "MUT-2 被电池处决（${PROBE_DETAIL}）"
    else
      _fail "MUT-2 被电池处决" "双探针均未命中——变异体存活（错位盲区未堵）"
    fi
    sb_cleanup
  else
    _fail "MUT-2 沙箱" "sb_new 失败"
  fi
else
  _fail "MUT-2 变异副本" "make_mutant move_init_after_regex 失败（模式未命中或副本未变化）"
fi

t_case "MUT-3: 删除 register 侧归一行 → 配对链断裂必须处决（原条目不翻 ready / forge-forge-* 新条目）"
mut3="$(make_mutant mut3 del_register)"
if [[ -n "$mut3" ]]; then
  CONTRIB_TEST_TARGET="$mut3"
  if sb_new >/dev/null 2>&1; then
    LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
    fm3="$(build_fake_upstream m3)"
    bm3="$(git -C "$fm3" rev-parse HEAD)"
    run_forge init "$UP_FULL" --repo NousResearch/hermes-agent --issue 132507 --dir "$fm3" >/dev/null
    rci=$?
    run_forge register "$UP_FULL" --branch "forge/$UP_SLUG" --sha "$bm3" --domain repo:NousResearch/hermes-agent >/dev/null
    rcr=$?
    if [[ "$rci" == "0" && "$rcr" == "0" && "$(inv_field "$UP_FULL" status)" == "ready" \
          && "$(inv_total)" == "1" && "$(inv_forgeforge)" == "0" ]]; then
      _fail "MUT-3 被电池处决" "init+register 全链照常——变异体存活"
    else
      _pass "MUT-3 被电池处决（rc=$rci/$rcr status=$(inv_field "$UP_FULL" status) total=$(inv_total) ff=$(inv_forgeforge)）"
    fi
    sb_cleanup
  else
    _fail "MUT-3 沙箱" "sb_new 失败"
  fi
else
  _fail "MUT-3 变异副本" "make_mutant del_register 失败（模式未命中或副本未变化）"
fi

t_finish
