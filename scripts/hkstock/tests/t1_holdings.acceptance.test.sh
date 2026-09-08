#!/bin/bash
# t1_holdings.acceptance.test.sh — hkstock 持仓文件与校验器契约验收（红队，黑盒）
# 覆盖谓词：3.P1 / 3.P2 / 3.P3 / 3.P4
# 依据：设计文档「C1 holdings 契约」+「隐私契约」+「validate_holdings.py CLI 契约」
#   - git check-ignore -v hkstock-data/holdings.yaml exit 0（martin 仓内）
#   - holdings.yaml 合法 YAML ∧ accounts 键存在
#   - martin git 追踪文件中 hkstock-data 引用零命中（negate 不入库）
#   - validator：合法 exit 0 + stdout 含 valid；非法 exit != 0 + stderr 非空；缺文件 exit 2
#   ⚠️ 3.P4 非法 fixture 全部在 /tmp 自建，绝不触碰真实 holdings.yaml
# 用法：bash t1_holdings.acceptance.test.sh
# 退出码：0 = 全绿；非 0 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-/Users/stringzhao/workspace/martin}"
HOLDINGS="$MARTIN_ROOT/hkstock-data/holdings.yaml"
VALIDATOR="$MARTIN_ROOT/scripts/hkstock/validate_holdings.py"
TMPDIR_T1="$(mktemp -d /tmp/t1-hkstock-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T1"' EXIT

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t1_holdings: holdings 契约 + 校验器契约 + 隐私契约验收 =="

# --- 3.P1: git check-ignore -v hkstock-data/holdings.yaml exit == 0 ---
ci_out="$(git -C "$MARTIN_ROOT" check-ignore -v hkstock-data/holdings.yaml 2>&1)"
ci_rc=$?
if [[ $ci_rc -eq 0 ]]; then
  pass "3.P1"
else
  fail "3.P1" "git check-ignore -v 退出码 $ci_rc（要求 0），输出: ${ci_out:0:300}"
fi

# --- 3.P2: holdings 合法 YAML ∧ accounts 键存在 ---
if [[ ! -f "$HOLDINGS" ]]; then
  fail "3.P2" "holdings.yaml 不存在: $HOLDINGS"
else
  p2_out="$(python3 - "$HOLDINGS" <<'PYEOF'
import sys, yaml
try:
    data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("PARSE_ERROR:", e)
    sys.exit(3)
if not isinstance(data, dict) or "accounts" not in data:
    sys.exit(1)
sys.exit(0)
PYEOF
)"
  p2_rc=$?
  case $p2_rc in
    0) pass "3.P2" ;;
    1) fail "3.P2" "holdings.yaml 解析成功但缺 accounts 键" ;;
    3) fail "3.P2" "holdings.yaml 不是合法 YAML: ${p2_out:0:300}" ;;
    *) fail "3.P2" "YAML 检查异常 rc=$p2_rc" ;;
  esac
fi

# --- 3.P3: git 追踪文件检索 hkstock-data 命中数 == 0 ---
tracked="$(git -C "$MARTIN_ROOT" ls-files)"
hits="$(printf '%s\n' "$tracked" | grep -c 'hkstock-data' || true)"
if [[ "$hits" -eq 0 ]]; then
  pass "3.P3"
else
  fail "3.P3" "git 追踪文件中 hkstock-data 命中 $hits 条（要求 0）: $(printf '%s\n' "$tracked" | grep 'hkstock-data' | head -5 | tr '\n' ' ')"
fi

# --- 3.P4: validate_holdings.py CLI 契约（fixture 全部 /tmp 自建） ---
if [[ ! -f "$VALIDATOR" ]]; then
  fail "3.P4" "校验器不存在: $VALIDATOR"
else
  # 合法样例（逐字依 C1 契约构造：accounts[].type ∈ {stock,fund,hk,futures}，currency ∈ {CNY,HKD}，qty>0，cost≥0）
  cat > "$TMPDIR_T1/valid.yaml" <<'YEOF'
accounts:
  - name: t1-accept-fixture
    type: stock
    positions:
      - symbol: "00700"
        name: tencent-fixture
        qty: 100
        cost: 300.0
        currency: HKD
    note: t1 acceptance fixture
watchlist: []
updated_at: "2026-09-08T00:00:00"
YEOF

  # 非法 fixture ×4：type: bond / qty: -1 / currency: USD / 缺 symbol
  cat > "$TMPDIR_T1/bad_type.yaml" <<'YEOF'
accounts:
  - name: bad-type
    type: bond
    positions:
      - symbol: "00700"
        name: x
        qty: 100
        cost: 1
        currency: HKD
watchlist: []
updated_at: "2026-09-08T00:00:00"
YEOF
  cat > "$TMPDIR_T1/bad_qty.yaml" <<'YEOF'
accounts:
  - name: bad-qty
    type: stock
    positions:
      - symbol: "00700"
        name: x
        qty: -1
        cost: 1
        currency: HKD
watchlist: []
updated_at: "2026-09-08T00:00:00"
YEOF
  cat > "$TMPDIR_T1/bad_currency.yaml" <<'YEOF'
accounts:
  - name: bad-currency
    type: stock
    positions:
      - symbol: "00700"
        name: x
        qty: 100
        cost: 1
        currency: USD
watchlist: []
updated_at: "2026-09-08T00:00:00"
YEOF
  cat > "$TMPDIR_T1/missing_symbol.yaml" <<'YEOF'
accounts:
  - name: missing-symbol
    type: stock
    positions:
      - name: x
        qty: 100
        cost: 1
        currency: HKD
watchlist: []
updated_at: "2026-09-08T00:00:00"
YEOF

  # 合法样例：exit 0 ∧ stdout 含 valid
  v_out="$(python3 "$VALIDATOR" --file "$TMPDIR_T1/valid.yaml" 2>/dev/null)"
  v_rc=$?
  if [[ $v_rc -eq 0 && "$v_out" == *valid* ]]; then
    pass "3.P4 valid-exit0"
  else
    fail "3.P4" "合法样例 rc=$v_rc（要求 0），stdout=[$v_out]（要求含 valid）"
  fi

  # 非法样例 ×4：exit != 0 ∧ stderr 非空（stderr 需指明违规字段——契约字面：stderr 非空为硬断言底线）
  for fx in bad_type bad_qty bad_currency missing_symbol; do
    python3 "$VALIDATOR" --file "$TMPDIR_T1/$fx.yaml" >/dev/null 2>"$TMPDIR_T1/$fx.err"
    e_rc=$?
    e_err="$(cat "$TMPDIR_T1/$fx.err")"
    if [[ $e_rc -ne 0 && -n "$e_err" ]]; then
      pass "3.P4 $fx"
    else
      fail "3.P4" "非法 fixture $fx: rc=$e_rc（要求非 0），stderr 长度=${#e_err}（要求非空）"
    fi
  done

  # 不存在路径：exit == 2
  m_rc=0
  python3 "$VALIDATOR" --file "$TMPDIR_T1/__no_such_file__.yaml" >/dev/null 2>&1 || m_rc=$?
  if [[ $m_rc -eq 2 ]]; then
    pass "3.P4 missing-file-exit2"
  else
    fail "3.P4" "不存在路径 rc=$m_rc（要求 2）"
  fi
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
