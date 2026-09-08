#!/bin/bash
# t3_mktd.acceptance.test.sh — mktd CLI 黑盒冒烟契约验收（红队，无实现依赖）
# 覆盖谓词：9.P1 / 9.P2 / 9.P3 / 9.P4 / 9.P5
# 依据：设计契约 D1/C3：
#   - bin=~/.local/bin/mktd；子命令闭集 quote/daily/fund/hk/index/cache(stats|clear)
#   - 9.P1 quote 冒烟 exit 0 ∧ 输出含价格字段 ∧ 时间戳字段
#   - 9.P2 同参二次调用输出含 cache:hit
#   - 9.P3 源码/config 定义 rate_limit_qps 与白名单（fs-grep 机械断言，非实现评审）
#   - 9.P4 非法子命令 exit 2 + stderr `unknown command`（契约字面量）
#   - 9.P5 cache stats 与 cache clear 各自 exit 0
# 门控：mktd bin 不存在 → SKIP_MKTD，exit 0（交付前门控）
# 黑盒纪律：不读实现源码；仅 CLI 驱动 + 关键词存在性 grep
# 用法：bash t3_mktd.acceptance.test.sh
# 退出码：0 = 全绿或 SKIP_MKTD；1 = 有 FAIL
set -u

MKTDATA_ROOT="${MKTDATA_ROOT:-$HOME/workspace/mktdata}"
MKTD_BIN="${MKTD_BIN:-$HOME/.local/bin/mktd}"

FAIL_COUNT=0

fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

echo "== t3_mktd: mktd CLI 黑盒契约验收（场景 9）=="

if [[ ! -x "$MKTD_BIN" ]]; then
  printf 'SKIP_MKTD\n'
  printf 'RESULT: SKIP (mktd bin 不存在或不可执行: %s)\n' "$MKTD_BIN"
  exit 0
fi

TMPDIR_T3="$(mktemp -d /tmp/t3-mktd-accept.XXXXXX)"
trap 'rm -rf "$TMPDIR_T3"' EXIT

# ============ 9.P1: quote 冒烟 exit 0 ∧ 价格字段 ∧ 时间戳字段 ============
# 候选符号逐个探测（黑盒不知道白名单内容，常见 A股/指数格式都试），首个全条件满足者锁定
QUOTE_SUB=""
QUOTE_ARG=""
for sym in "${MKTD_TEST_SYMBOL:-600519}" 600519 sh600519 sh000001; do
  out="$("$MKTD_BIN" quote "$sym" 2>/dev/null)"
  rc=$?
  if [[ $rc -eq 0 ]] \
    && printf '%s' "$out" | grep -Eiq 'price|最新价|现价|last|close|价格' \
    && printf '%s' "$out" | grep -Eiq 'time|时间|updated|日期|date|ts([^a-z]|$)'; then
    QUOTE_SUB="quote"
    QUOTE_ARG="$sym"
    break
  fi
done
if [[ -n "$QUOTE_SUB" ]]; then
  pass "9.P1"
else
  fail "9.P1" "quote 冒烟无一次满足 exit 0 ∧ 价格字段 ∧ 时间戳字段（候选=600519/sh600519/sh000001，可用 MKTD_TEST_SYMBOL 注入白名单内符号）"
fi

# ============ 9.P2: 同参二次调用含 cache:hit（契约字面量）============
if [[ -n "$QUOTE_SUB" ]]; then
  out2="$("$MKTD_BIN" "$QUOTE_SUB" "$QUOTE_ARG" 2>/dev/null)"
  rc2=$?
  if [[ $rc2 -eq 0 ]] && printf '%s' "$out2" | grep -q 'cache:hit'; then
    pass "9.P2"
  else
    fail "9.P2" "同参二次调用（mktd $QUOTE_SUB ${QUOTE_ARG}）未含 cache:hit 字面量（exit=${rc2}）"
  fi
else
  fail "9.P2" "9.P1 未锁定可用 quote 调用，无法验证缓存命中"
fi

# ============ 9.P3: 源码/config 含白名单 ∧ rate_limit_qps 定义（fs-grep）============
python3 - "$MKTDATA_ROOT" > "$TMPDIR_T3/p3.probe" <<'PYEOF'
import os
import re
import sys

root = sys.argv[1]
pat_rl = re.compile(r"rate_limit_qps")
pat_wl = re.compile(r"whitelist|白名单|allowlist|allowed[_a-z]*", re.IGNORECASE)
hits_rl = 0
hits_wl = 0
scanned = 0
if os.path.isdir(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in (".git", ".venv", "venv", "__pycache__", "node_modules")]
        for fn in filenames:
            if not fn.endswith((".py", ".yaml", ".yml", ".toml", ".json")):
                continue
            try:
                with open(os.path.join(dirpath, fn), encoding="utf-8", errors="replace") as fh:
                    txt = fh.read()
            except OSError:
                continue
            scanned += 1
            hits_rl += len(pat_rl.findall(txt))
            hits_wl += len(pat_wl.findall(txt))
ok = scanned > 0 and hits_rl > 0 and hits_wl > 0
print("9.P3:%s" % ("PASS" if ok else "FAIL scanned_files=%d rate_limit_qps_hits=%d whitelist_hits=%d（要求两者定义均存在）" % (scanned, hits_rl, hits_wl)))
print("9.P3-DETAIL scanned_files=%d rate_limit_qps_hits=%d whitelist_hits=%d root=%s" % (scanned, hits_rl, hits_wl, root))
PYEOF
while IFS= read -r line; do
  case "$line" in
    9.P3:PASS*) pass "9.P3" ;;
    9.P3:FAIL*) fail "9.P3" "${line#9.P3:FAIL }" ;;
    9.P3-DETAIL*) printf 'INFO 9.P3 %s\n' "${line#9.P3-DETAIL }" ;;
  esac
done < "$TMPDIR_T3/p3.probe"

# ============ 9.P4: 非法子命令 exit 2 + stderr `unknown command` ============
"$MKTD_BIN" definitely-not-a-real-subcommand > /dev/null 2> "$TMPDIR_T3/err.txt"
rc4=$?
if [[ $rc4 -eq 2 ]] && grep -q 'unknown command' "$TMPDIR_T3/err.txt"; then
  pass "9.P4"
else
  fail "9.P4" "非法子命令期望 exit 2 + stderr 含 unknown command，实得 exit=${rc4} stderr=[$(head -c 200 "$TMPDIR_T3/err.txt")]"
fi

# ============ 9.P5: cache stats 与 cache clear 各自 exit 0 ============
"$MKTD_BIN" cache stats > /dev/null 2>&1
rc_stats=$?
"$MKTD_BIN" cache clear > /dev/null 2>&1
rc_clear=$?
if [[ $rc_stats -eq 0 && $rc_clear -eq 0 ]]; then
  pass "9.P5"
else
  fail "9.P5" "cache stats exit=${rc_stats} / cache clear exit=${rc_clear}（契约要求均 exit 0）"
fi

if [[ $FAIL_COUNT -gt 0 ]]; then
  printf 'RESULT: FAIL=%d\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: ALL PASS\n'
exit 0
