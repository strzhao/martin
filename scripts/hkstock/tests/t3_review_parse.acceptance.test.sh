#!/bin/bash
# t3_review_parse.acceptance.test.sh — signal_review._mktd_daily_close() 解析契约自测（红队，模块级黑盒）
# 依据：state.md ## 契约规约「解析函数契约」+ example 三例 + ## 验收场景 P1（det-machine）
# 覆盖：
#   - example 正例：{"timestamp":"2026-09-28","price":312.0} → ("2026-09-28", 312.0)
#   - example 边界：旧键 date/close 优先于新键 timestamp/price + str(...)[:10] 截断 + int close → float
#   - example 反例：约定键全缺（ts/px）→ 丢行
#   - fallback 链 invariant：date→timestamp→日期 / close→price→收盘→close_price；close 值非 int/float → 丢行
#   - 错误场景（契约：全部返回 []，不抛异常）：mktd exit≠0 / stdout 无 [...] 包裹 / JSON 损坏 / mktd 不存在 / records 空
#   - P1 谓词：exit==0 ∧ 解析行数 ≥ 1 ∧ 每行 date 匹配 ^\d{4}-\d{2}-\d{2}$ ∧ close 为 float ∧ 升序
# 注入：契约声明模块级常量 signal_review.MKTD → fake 脚本回放 canned JSON（零网络零真实数据，不读生产 signals.jsonl）；
#       marker 文件自证 fake 确被调用——若实现绕开 MKTD 常量直打真 mktd/网络，本测试硬红。
# 用法：MARTIN_ROOT="$PWD" bash scripts/hkstock/tests/t3_review_parse.acceptance.test.sh
# 退出码：0 = 全绿；1 = 有 FAIL
set -u

MARTIN_ROOT="${MARTIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"; export MARTIN_ROOT  # 跟随测试文件所在仓定位（<root>/scripts/hkstock/tests 上爬三层；主 checkout 行为不变），并 export 供 runner.py 继承；硬编码绝对路径会在 worktree 裸跑时静默测错树

TMP="$(mktemp -d /tmp/t3-review-parse-accept.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAIL_COUNT=0
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { printf 'PASS %s\n' "$1"; }

export FAKE_MKTD="$TMP/fake-mktd"
MARKER="$TMP/fake-mktd-called"

# ---------- fake mktd：默认回放 ${FAKE_MKTD_PAYLOAD}；可注入 exit≠0（FAKE_MKTD_EXIT）或原始非数组 stdout（FAKE_MKTD_RAW_STDOUT）----------
{
  printf '#!/bin/bash\n'
  cat <<'FAKEBODY'
[ -n "${FAKE_MKTD_CALLED:-}" ] && : > "$FAKE_MKTD_CALLED"
if [ -n "${FAKE_MKTD_EXIT:-}" ]; then
  echo "fake-mktd: simulated nonzero exit" >&2
  exit "$FAKE_MKTD_EXIT"
fi
if [ -n "${FAKE_MKTD_RAW_STDOUT:-}" ]; then
  printf '%s\n' "$FAKE_MKTD_RAW_STDOUT"
  exit 0
fi
cat "${FAKE_MKTD_PAYLOAD:?FAKE_MKTD_PAYLOAD not set}"
FAKEBODY
} > "$FAKE_MKTD"
chmod +x "$FAKE_MKTD"

# ---------- runner：无副作用 import signal_review（契约 __main__ 守卫）→ 替换 MKTD 属性 → 调 _mktd_daily_close → 打印 rows JSON ----------
cat > "$TMP/runner.py" <<'RUNNERBODY'
import importlib.util
import json
import os
import sys

martin_root = os.environ["MARTIN_ROOT"]
mod_path = os.path.join(martin_root, "scripts", "hkstock", "signal_review.py")
sys.path.insert(0, os.path.dirname(mod_path))  # 兼容模块合法的同目录 sibling import（不弱化断言）
spec = importlib.util.spec_from_file_location("signal_review", mod_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod.MKTD = os.environ["FAKE_MKTD"]  # 契约注入缝：模块级常量 signal_review.MKTD

rows = mod._mktd_daily_close(sys.argv[1], int(sys.argv[2]))
print(json.dumps([[d, c] for d, c in rows]))
RUNNERBODY

# call_parse <payload-path> <symbol> <days> <label> —— 结果进 OUT/RC；附带两个硬断言：
#   <label>-call       : _mktd_daily_close 不抛异常（契约：错误也返回 [] 不 raise）且 runner 正常产出行
#   <label>-injection  : fake 确被调用（MKTD 注入缝存活，杜绝真网络假绿）
call_parse() {
  local payload="$1" symbol="$2" days="$3" label="$4"
  rm -f "$MARKER"
  OUT="$(FAKE_MKTD_PAYLOAD="$payload" FAKE_MKTD_CALLED="$MARKER" \
    python3 "$TMP/runner.py" "$symbol" "$days" 2>"$TMP/lasterr")"
  RC=$?
  [ "$RC" -eq 0 ] || fail "$label-call" "exit=$RC stderr=$(cat "$TMP/lasterr")"
  [ -f "$MARKER" ] || fail "$label-injection" "fake mktd 未被调用——signal_review.MKTD 注入缝失效"
}

# ---------- 用例 1（example 正例 + P1 + 升序 invariant + 行数不足照常返回）----------
# mktd daily 真实记录形态（timestamp/price 键）；records 故意倒序（09-28→09-26），输出必须升序（kills 不排序 mutation）；
# days=60 但仅 3 行 → 行数不足空缺段照常返回，不报错。
cat > "$TMP/p-ok.json" <<'EOF'
{"cache": true, "count": 3, "cmd": "daily 301308", "days": 60, "records": [
  {"symbol": "sz301308", "price": 312.0, "timestamp": "2026-09-28", "open": 311.0, "high": 313.0, "low": 310.5, "volume": 1200},
  {"symbol": "sz301308", "price": 311.5, "timestamp": "2026-09-27", "open": 310.0, "high": 312.0, "low": 309.5, "volume": 1100},
  {"symbol": "sz301308", "price": 310.0, "timestamp": "2026-09-26", "open": 309.0, "high": 311.0, "low": 308.5, "volume": 1000}
]}
EOF
call_parse "$TMP/p-ok.json" 301308 60 "1-real-shape"
printf '%s' "$OUT" | python3 -c '
import json, re, sys
rows = json.load(sys.stdin)
assert isinstance(rows, list) and len(rows) >= 1, rows   # P1: 解析行数 ≥ 1
# 升序 invariant：输入倒序，输出必须按 date 字符串升序
assert rows == [["2026-09-26", 310.0], ["2026-09-27", 311.5], ["2026-09-28", 312.0]], rows
for d, c in rows:
    assert re.match(r"^\d{4}-\d{2}-\d{2}$", d), d        # P1: date 字面格式
    assert isinstance(c, float), (d, c, type(c))         # P1: close 为 float
' && pass "1-real-shape-ascending" || fail "1-real-shape-ascending" "$OUT"

# ---------- 用例 2（example 边界）：旧键 date/close 优先于新键 + [:10] 截断 + int→float ----------
# 新键故意给不同值（2020-01-01/1.5）：若实现错选新键，得到的是 ["2020-01-01",1.5] → 硬红（kills 条件翻转 mutation）。
cat > "$TMP/p-boundary.json" <<'EOF'
{"cache": false, "count": 1, "cmd": "daily 301308", "days": 60, "records": [
  {"symbol": "sz301308", "date": "2026-09-28T15:00:00", "close": 312, "timestamp": "2020-01-01T00:00:00", "price": 1.5}
]}
EOF
call_parse "$TMP/p-boundary.json" 301308 60 "2-boundary"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
# 旧键优先 + [:10] 截断（不得残留 T15:00:00）+ int 312 → 312.0
assert rows == [["2026-09-28", 312.0]], rows
assert rows[0][0] == "2026-09-28", rows
assert isinstance(rows[0][1], float), rows
' && pass "2-boundary-old-keys-truncate-int2float" || fail "2-boundary-old-keys-truncate-int2float" "$OUT"

# ---------- 用例 3（example 反例）：约定键全缺（ts/px）→ 丢行，合法行保留 ----------
# 期望恰 1 行：kills「全丢成 []」与「全留成 2 行」两个 mutation。
cat > "$TMP/p-negative.json" <<'EOF'
{"cache": false, "count": 2, "cmd": "daily 301308", "days": 60, "records": [
  {"ts": "2026-09-28", "px": 312.0},
  {"symbol": "sz301308", "price": 311.0, "timestamp": "2026-09-27"}
]}
EOF
call_parse "$TMP/p-negative.json" 301308 60 "3-negative"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [["2026-09-27", 311.0]], rows
' && pass "3-negative-drop-row" || fail "3-negative-drop-row" "$OUT"

# ---------- 用例 4：fallback 链尾部键（日期 / 收盘 / close_price）仍被支持（契约 invariant 逐字）----------
cat > "$TMP/p-alias.json" <<'EOF'
{"cache": false, "count": 2, "cmd": "daily 301308", "days": 60, "records": [
  {"日期": "2026-09-25", "收盘": 300},
  {"timestamp": "2026-09-26", "close_price": 305}
]}
EOF
call_parse "$TMP/p-alias.json" 301308 60 "4-alias"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [["2026-09-25", 300.0], ["2026-09-26", 305.0]], rows
assert all(isinstance(c, float) for _, c in rows), rows
' && pass "4-alias-chain" || fail "4-alias-chain" "$OUT"

# ---------- 用例 5：close 值非 int/float（字符串）→ 丢行；日期键全缺 → 丢行；合法行保留 ----------
cat > "$TMP/p-typeguard.json" <<'EOF'
{"cache": false, "count": 3, "cmd": "daily 301308", "days": 60, "records": [
  {"symbol": "sz301308", "price": "312.0", "timestamp": "2026-09-28"},
  {"symbol": "sz301308", "price": 310.0},
  {"symbol": "sz301308", "price": 311.0, "timestamp": "2026-09-27"}
]}
EOF
call_parse "$TMP/p-typeguard.json" 301308 60 "5-typeguard"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [["2026-09-27", 311.0]], rows
' && pass "5-typeguard-drop-invalid" || fail "5-typeguard-drop-invalid" "$OUT"

# ---------- 用例 6（错误场景 1）：mktd exit≠0 → 返回 [] 且不抛异常 ----------
rm -f "$MARKER"
OUT="$(FAKE_MKTD_EXIT=3 FAKE_MKTD_CALLED="$MARKER" python3 "$TMP/runner.py" 301308 60 2>"$TMP/err6")"
RC=$?
[ "$RC" -eq 0 ] || fail "6-exit-nonzero-call" "exit=${RC}（契约：returncode≠0 须返回 [] 不抛异常）stderr=$(cat "$TMP/err6")"
[ -f "$MARKER" ] || fail "6-exit-nonzero-injection" "fake mktd 未被调用"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [], rows
' && pass "6-exit-nonzero-empty" || fail "6-exit-nonzero-empty" "$OUT"

# ---------- 用例 7（错误场景 2）：stdout 无 [...] 包裹（JSON 对象形态）→ [] ----------
rm -f "$MARKER"
OUT="$(FAKE_MKTD_RAW_STDOUT='{"cache":false,"count":0,"cmd":"daily 301308","days":60,"records":[]}' \
  FAKE_MKTD_CALLED="$MARKER" python3 "$TMP/runner.py" 301308 60 2>"$TMP/err7")"
RC=$?
[ "$RC" -eq 0 ] || fail "7-no-bracket-call" "exit=$RC stderr=$(cat "$TMP/err7")"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [], rows
' && pass "7-no-bracket-empty" || fail "7-no-bracket-empty" "$OUT"

# ---------- 用例 8（错误场景 3）：stdout 括号包裹但 JSON 损坏 → [] ----------
rm -f "$MARKER"
OUT="$(FAKE_MKTD_RAW_STDOUT='[{"timestamp":"2026-09-28","price":312.0, broken' \
  FAKE_MKTD_CALLED="$MARKER" python3 "$TMP/runner.py" 301308 60 2>"$TMP/err8")"
RC=$?
[ "$RC" -eq 0 ] || fail "8-broken-json-call" "exit=$RC stderr=$(cat "$TMP/err8")"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [], rows
' && pass "8-broken-json-empty" || fail "8-broken-json-empty" "$OUT"

# ---------- 用例 9（错误场景 4）：mktd 二进制不存在 → [] 且不抛异常；fake 不应被调用 ----------
rm -f "$MARKER"
OUT="$(FAKE_MKTD="$TMP/no-such-mktd-bin" python3 "$TMP/runner.py" 301308 60 2>"$TMP/err9")"
RC=$?
[ "$RC" -eq 0 ] || fail "9-mktd-missing-call" "exit=${RC}（契约：二进制不存在须返回 [] 不抛异常）stderr=$(cat "$TMP/err9")"
[ ! -f "$MARKER" ] || fail "9-mktd-missing-marker" "二进制不存在场景 marker 不应存在"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [], rows
' && pass "9-mktd-missing-empty" || fail "9-mktd-missing-empty" "$OUT"

# ---------- 用例 10：records 空（行数不足极限态）→ [] ----------
cat > "$TMP/p-empty.json" <<'EOF'
{"cache": false, "count": 0, "cmd": "daily 301308", "days": 60, "records": []}
EOF
call_parse "$TMP/p-empty.json" 301308 60 "10-empty-records"
printf '%s' "$OUT" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert rows == [], rows
' && pass "10-empty-records-empty" || fail "10-empty-records-empty" "$OUT"

printf '\n%s\n' "FAIL_COUNT=$FAIL_COUNT"
exit "$([ "$FAIL_COUNT" -eq 0 ] && echo 0 || echo 1)"
