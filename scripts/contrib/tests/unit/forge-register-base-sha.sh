#!/bin/bash
# forge-register-base-sha.sh — register --base 补记成品基座（radar 新鲜度巡检的数据前提）
#
# 版意（2026-10-17，双 issue+PR 发布日补台账实证）：standalone register（未走 init）
# 产出的条目 base_sha=null，而 forge.sh check 的说明明文「ready 项 base_sha 落后量由
# radar 对上游仓实查：rev-list --count <base_sha>..origin/main」——空值 = 该件永久逃过
# 漂移巡检。本卡给 register 加 --base <sha>（可选；给则覆盖，不给保持原值/null），并把
# 「standalone 登记必须给 --base」写进 usage。
#
# 黑盒行为版（同 forge-slug-normalize.sh 家规）：沙箱内直呼真 forge.sh，断言铁律 =
# 退出码 + 沙箱台账 jq 读回双证，stdout 契约行只作第三证。
#
# mutation 自证电池（每次运行都跑，两例 + 对照组）：
#   MUT-1 删 ready_fields 的条件 base_sha 赋值 → init→register --base Y 的覆盖路径失守
#        （AC3 探针处决：base 停留 init 值 ≠ Y）
#   MUT-2 base_sha 赋值双路全删（standalone 字面量 + ready_fields 管道——单删一路
#         必有另一路兜底假活）→ AC1 探针处决：base_sha 空
#   MUT-CTRL 未变异副本过同一双探针必须零命中——防探针自身失真。
#
# falsify：`bash scripts/contrib/tests/unit/forge-register-base-sha.sh | grep -c '^FAIL'` = 0 为绿；
#   对本卡之前的 forge.sh（无 --base 形参）对拍：register --base 走 usage exit 2，AC1 探针处决。
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
t_init "forge-register-base-sha.sh"

TARGET="$(tests_scripts_dir "$TARGET_DEFAULT")"
FORGE="$TARGET/forge.sh"
LEDGER=""

MUTROOT="$(mktemp -d "${TMPDIR:-/tmp}/forge-base-sha.XXXXXX")"
trap 'rm -rf "$MUTROOT"' EXIT

BOOT="boot-0000-ledger-seed"          # 台账自举用（standalone 前必须存在 inventory.json）
SLUG="140418-downgrade-exit75"        # standalone+--base 探针
SLUG_NOBASE="140419-no-base-legacy"   # 无 --base 惯例探针（null 契约留档）
SLUG_PAIR="140420-init-pair"          # init→register 覆盖路径探针
BASE_Y="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

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

run_forge() { # <args...> → 黑盒直呼沙箱内 forge.sh
  local a snippet=""
  for a in "$@"; do snippet="$snippet$(printf '%q ' "$a")"; done
  sb_run "\"\${MARTIN_DIR}/scripts/contrib/forge.sh\" $snippet"
}

inv_field() { # <id> <field> → 沙箱台账 jq 读回（缺件/缺账=空）
  jq -r --arg id "$1" --arg f "$2" '(.items[] | select(.id == $id) | .[$f]) // ""' "$LEDGER" 2>/dev/null
}
inv_total() { jq -r '(.items | length)' "$LEDGER" 2>/dev/null; }

make_mutant() { # <tag> <mode> → 变异副本目录；模式未命中/副本未变化 → 非零（输出空）
  local d
  d="$MUTROOT/$1"
  mkdir -p "$d"
  cp "$FORGE" "$d/forge.sh" || return 1
  python3 "$MUTROOT/mutate.py" "$d/forge.sh" "$2" >/dev/null 2>&1 || return 1
  cmp -s "$FORGE" "$d/forge.sh" && return 2
  printf '%s' "$d"
}

cat > "$MUTROOT/mutate.py" <<'PYEOF'
import io
import sys


def main() -> int:
    path, mode = sys.argv[1], sys.argv[2]
    with io.open(path, "r", encoding="utf-8") as f:
        src = f.read()
    ready_tok = '| (if $base != "" then .base_sha = $base else . end)'
    lit_tok = 'base_sha: (if $base != "" then $base else null end)'
    if mode == "del_ready_field":
        if src.count(ready_tok) != 1:
            return 3
        src = src.replace(ready_tok, "")
    elif mode == "null_both":
        # base_sha 赋值是双保险（standalone 字面量 + ready_fields 管道），单删一路
        # 必有另一路兜底——有效变异必须双路全删（否则变异体靠冗余路径假活）。
        if src.count(ready_tok) != 1 or src.count(lit_tok) != 1:
            return 3
        src = src.replace(ready_tok, "")
        src = src.replace(lit_tok, "base_sha: null")
    else:
        return 2
    with io.open(path, "w", encoding="utf-8") as f:
        f.write(src)
    return 0


sys.exit(main())
PYEOF

probe_standalone() { # <tag> — AC1 探针：standalone register --base → base_sha 落账
  local fa rc
  fa="$(build_fake_upstream "$1")"
  run_forge init "$BOOT" --repo NousResearch/hermes-agent --dir "$fa" >/dev/null
  run_forge register "$SLUG" --branch "forge/$SLUG" --sha "$BASE_Y" --domain gateway \
    --base "0ab43d4f67112233445566778899aabbccddeeff" >/dev/null
  rc=$?
  if [[ "$rc" == "0" && "$(inv_field "forge-$SLUG" status)" == "ready" \
        && "$(inv_field "forge-$SLUG" base_sha)" == "0ab43d4f67112233445566778899aabbccddeeff" ]]; then
    return 0
  fi
  return 1
}

probe_pair_overwrite() { # <tag> — AC3 探针：init 记 base=X → register --base Y 覆盖
  local fb rc_x rc_y
  fb="$(build_fake_upstream "$1")"
  run_forge init "$SLUG_PAIR" --repo NousResearch/hermes-agent --dir "$fb" >/dev/null
  rc_x=$?
  run_forge register "$SLUG_PAIR" --branch "forge/$SLUG_PAIR" --sha "$BASE_Y" --domain gateway \
    --base "$BASE_Y" >/dev/null
  rc_y=$?
  if [[ "$rc_x" == "0" && "$rc_y" == "0" && "$(inv_field "forge-$SLUG_PAIR" base_sha)" == "$BASE_Y" ]]; then
    return 0
  fi
  return 1
}

# ================= 第一沙箱：行为面（正 / 惯例 / 配对覆盖 / 拒） =================
sb_new >/dev/null 2>&1 || { echo "sandbox-fail"; exit 1; }
LEDGER="${CONTRIB_DATA_DIR}/inventory.json"

t_case "前置自检：被测副本在位 + --base 形参在位（形状快照，非主断言）"
if [[ -f "$FORGE" ]]; then
  _pass "被测 forge.sh 在位"
else
  _fail "被测 forge.sh 在位" "缺失: $FORGE"
fi
n_base="$(grep -cF -- '--base) base="$2"; shift 2 ;;' "$FORGE" 2>/dev/null || true)"
assert_eq "$n_base" "1" "--base 形参恰 1 处（形状快照，非主断言）"

t_case "AC1: standalone register --base → exit 0 + base_sha 落账（radar 巡检前提）"
FAKE_A="$(build_fake_upstream a)"
run_forge init "$BOOT" --repo NousResearch/hermes-agent --dir "$FAKE_A" >/dev/null
assert_exit 0 $?
ac1_out="$(run_forge register "$SLUG" --branch "forge/$SLUG" --sha "$BASE_Y" --domain gateway \
  --base "0ab43d4f67112233445566778899aabbccddeeff" --notes "proof-drill")"
assert_exit 0 $?
assert_eq "$(inv_field "forge-$SLUG" status)" "ready" "台账读回 status=ready"
assert_eq "$(inv_field "forge-$SLUG" base_sha)" "0ab43d4f67112233445566778899aabbccddeeff" "base_sha 落账（radar rev-list 前提）"
assert_contains "$ac1_out" "base=0ab43d4f67" "stdout 契约行（第三证）"

t_case "AC2: standalone register 无 --base → base_sha 保持 null（旧惯例留档：init 路径不受影响）"
ac2_rc=0
run_forge register "$SLUG_NOBASE" --branch "forge/$SLUG_NOBASE" --sha "$BASE_Y" --domain gateway >/dev/null || ac2_rc=$?
assert_exit 0 $ac2_rc
assert_eq "$(inv_field "forge-$SLUG_NOBASE" base_sha)" "" "无 --base → base_sha 空（null）"

t_case "AC3: init 记 base=X → register --base Y 覆盖（成品实际基座可后填）"
FAKE_C="$(build_fake_upstream c)"
run_forge init "$SLUG_PAIR" --repo NousResearch/hermes-agent --dir "$FAKE_C" >/dev/null
assert_exit 0 $?
X_SHA="$(inv_field "forge-$SLUG_PAIR" base_sha)"
run_forge register "$SLUG_PAIR" --branch "forge/$SLUG_PAIR" --sha "$BASE_Y" --domain gateway --base "$BASE_Y" >/dev/null
assert_exit 0 $?
assert_eq "$(inv_field "forge-$SLUG_PAIR" base_sha)" "$BASE_Y" "register --base 覆盖 init 基座（X=${X_SHA:0:7} → Y）"
assert_eq "$(inv_field "forge-$SLUG_PAIR" status)" "ready" "配对链完好（in-flight → ready）"

t_case "AC4: --base 形态非法 → exit 2 且台账零写入"
before_total="$(inv_total)"
ac4_rc=0
run_forge register "140421-bad-base" --branch "forge/140421-bad-base" --sha "$BASE_Y" --domain gateway --base "ZZZ" >/dev/null || ac4_rc=$?
assert_exit 2 $ac4_rc
assert_eq "$(inv_total)" "$before_total" "拒收不落账"

# ================= mutation 电池（两例 + 对照组；每例独立沙箱） =================
t_case "MUT-CTRL: 未变异副本过双探针零命中（防探针自身失真）"
CONTRIB_TEST_TARGET="$TARGET"
if sb_new >/dev/null 2>&1; then
  LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
  if probe_standalone ctrl-a && probe_pair_overwrite ctrl-b; then
    _pass "对照组双探针零命中"
  else
    _fail "对照组双探针零命中" "未变异即不满足契约——探针失真"
  fi
  sb_cleanup
else
  _fail "MUT-CTRL 沙箱" "sb_new 失败"
fi

t_case "MUT-1: 删 ready_fields 条件 base_sha 赋值 → AC3 覆盖路径必须处决"
mut1="$(make_mutant mut1 del_ready_field)"
if [[ -n "$mut1" ]]; then
  CONTRIB_TEST_TARGET="$mut1"
  if sb_new >/dev/null 2>&1; then
    LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
    if probe_pair_overwrite mut1; then
      _fail "MUT-1 被电池处决" "init→register --base 覆盖照常——变异体存活"
    else
      _pass "MUT-1 被电池处决（覆盖路径失守：base 停留 init 值）"
    fi
    sb_cleanup
  else
    _fail "MUT-1 沙箱" "sb_new 失败"
  fi
else
  _fail "MUT-1 变异副本" "make_mutant del_ready_field 失败（模式未命中或副本未变化）"
fi

t_case "MUT-2: base_sha 赋值双路全删 → AC1 必须处决"
mut2="$(make_mutant mut2 null_both)"
if [[ -n "$mut2" ]]; then
  CONTRIB_TEST_TARGET="$mut2"
  if sb_new >/dev/null 2>&1; then
    LEDGER="${CONTRIB_DATA_DIR}/inventory.json"
    if probe_standalone mut2; then
      _fail "MUT-2 被电池处决" "standalone --base 照常落账——变异体存活"
    else
      _pass "MUT-2 被电池处决（standalone 路径失守：base_sha 空）"
    fi
    sb_cleanup
  else
    _fail "MUT-2 沙箱" "sb_new 失败"
  fi
else
  _fail "MUT-2 变异副本" "make_mutant null_both 失败（模式未命中或副本未变化）"
fi

t_finish
