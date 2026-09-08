#!/bin/bash
# brief_guard.sh — hkstock 盘前简报守卫（T2 定时链路闸门，任务书契约 2026-09-08 终局仲裁口径）
#
# 口径终局（编排器仲裁 2026-09-08）：验收 SSOT = staging 目录任务书口径测试
#   （acceptance-staging/t2_*.acceptance.test.sh）。G1 早前迭代口径（exit 2 / skip:非交易日 /
#   briefs/guard-failures.log / --probe-url / guard:ok / brief-<date>.md）全部作废，勿回退。
#   曾有 G1 版本被写入本文件 3 次（17:05/17:29/17:47）均导致任务书验收 FAIL，已清偿。
#
# 三道闸：① 交易日判定（周末 → SKIP）② holdings 校验（validator + 空串兜底）
#         ③ 数据源探活（quant-futures venv 最小 akshare 调用，timeout 45s）
# 退出码语义（SSOT 谓词口径，契约 1:1）：
#   exit 0 + stdout 首行 SKIP_HOLIDAY   = 非交易日（周末判定 + 内置 2026 法定节假日表，
#                                         零网络依赖；跨年使用前须扩表）
#   exit 0 + 末行以 BRIEF_PAYLOAD: 开头 = 交易日且就绪（载荷含日期/holdings 概要/建卡指令）
#   exit 1                              = 失败（数据源失败 / holdings 缺失或校验不过；
#                                         stderr 给明确原因，并追加失败记录行到 guard-fail.log）
# 失败账本：hkstock-data/logs/guard-fail.log，行格式 `<日期> <原因>`（skip 分支零副作用不留痕）
# 测试钩子：HKSTOCK_GUARD_FAIL_SOURCE=1 注入数据源失败（跳到闸③失败）
# 取数源说明（2026-09-08 实测）：探活与取数走 akshare sina 族接口——本机对 push2.eastmoney.com
#   行情族实测空回复（多轮双路验证），*_em 实时行情族禁用；
#   可用替代源清单见 ~/.hermes/profiles/hkstock/skills/morning-brief/SKILL.md 第一节。
# 静态门：bash -n + shellcheck -S warning（scripts/contrib/tests/gate.sh 扫 scripts/hkstock）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOLDINGS_DEFAULT="$REPO_ROOT/hkstock-data/holdings.yaml"
VENV_PY="/Users/stringzhao/workspace/quant-futures/.venv/bin/python"
PROBE_TIMEOUT=45
FAIL_LOG_DIR="$REPO_ROOT/hkstock-data/logs"
FAIL_LOG="$FAIL_LOG_DIR/guard-fail.log"

TARGET_DATE="$(date +%F)"
HOLDINGS="$HOLDINGS_DEFAULT"

# --- 参数解析：--date YYYY-MM-DD（默认今天，注入测试用）/ --holdings <path> ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)
      [[ $# -ge 2 ]] || { printf 'brief_guard: FAIL: --date 缺参数\n' >&2; exit 1; }
      TARGET_DATE="$2"; shift 2 ;;
    --holdings)
      [[ $# -ge 2 ]] || { printf 'brief_guard: FAIL: --holdings 缺参数\n' >&2; exit 1; }
      HOLDINGS="$2"; shift 2 ;;
    *) printf 'brief_guard: FAIL: 未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# --- 失败出口：stderr 明确原因 + guard-fail.log 追加（<日期> <原因>，原因单行化防账本破格式） ---
fail() { # <原因>
  local reason
  reason="$(printf '%s' "$1" | tr '\n\r' '  ' | sed 's/  */ /g')"
  printf 'brief_guard: FAIL: %s\n' "$reason" >&2
  mkdir -p "$FAIL_LOG_DIR"
  printf '%s %s\n' "$TARGET_DATE" "$reason" >> "$FAIL_LOG"
  exit 1
}

# --- 闸①：交易日判定（周末 + 内置 2026 法定节假日表，零网络依赖） ---
# dow 取自 TARGET_DATE（默认今天，语义同 date +%u；--date 注入测试时按注入日期判定）
dow="$(date -j -f "%Y-%m-%d" "$TARGET_DATE" +%u 2>/dev/null)" \
  || dow="$(date -d "$TARGET_DATE" +%u 2>/dev/null)" \
  || dow="$(date +%u)"
if [[ "$dow" == "6" || "$dow" == "7" ]]; then
  printf 'SKIP_HOLIDAY\n'
  exit 0
fi
# 2026 法定节假日（A股休市日；调休上班周末不补录——A股周末固定休市；跨年使用前须扩表）。
# 覆盖残余活跃窗口（中秋 2026-09-25 周五 = 天文历固定；国庆 10/1-10/7 惯例），已过期条目留作存档。
HOLIDAYS_2026=(
  2026-01-01 2026-01-02 2026-01-03                                              # 元旦
  2026-02-15 2026-02-16 2026-02-17 2026-02-18 2026-02-19 2026-02-20 2026-02-21 2026-02-22  # 春节
  2026-04-04 2026-04-05 2026-04-06                                              # 清明
  2026-05-01 2026-05-02 2026-05-03 2026-05-04 2026-05-05                        # 劳动节
  2026-06-19 2026-06-20 2026-06-21                                              # 端午
  2026-09-25                                                                    # 中秋（周五）
  2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05 2026-10-06 2026-10-07  # 国庆
)
for h in ${HOLIDAYS_2026[@]+${HOLIDAYS_2026[@]}}; do
  if [[ "$TARGET_DATE" == "$h" ]]; then
    printf 'SKIP_HOLIDAY\n'
    exit 0
  fi
done

# --- 闸②：holdings 校验（validator 契约 + 空串兜底） ---
[[ -f "$HOLDINGS" ]] || fail "holdings 文件不存在: $HOLDINGS"
if ! python3 "$REPO_ROOT/scripts/hkstock/validate_holdings.py" --file "$HOLDINGS" >/dev/null 2>&1; then
  fail "holdings 校验不过: $(python3 "$REPO_ROOT/scripts/hkstock/validate_holdings.py" --file "$HOLDINGS" 2>&1 | head -n 1)"
fi
# validator 放行空串（T1 遗留），守卫兜底：accounts 非空且每个 symbol/name 非空字符串
guard_note="$(python3 - "$HOLDINGS" <<'PY' 2>&1
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
accounts = data.get("accounts") or []
if not accounts:
    sys.exit("accounts 为空")
for i, acc in enumerate(accounts):
    if not str(acc.get("name") or "").strip():
        sys.exit(f"accounts[{i}].name 为空字符串")
    for j, pos in enumerate(acc.get("positions") or []):
        for f in ("symbol", "name"):
            if not str(pos.get(f) or "").strip():
                sys.exit(f"accounts[{i}].positions[{j}].{f} 为空字符串")
PY
)" || fail "holdings 空串兜底校验不过: $guard_note"

# --- 闸③：数据源探活（venv python 最小 akshare 调用拉一只 A 股实时快照；sina 源，见头注） ---
if [[ "${HKSTOCK_GUARD_FAIL_SOURCE:-0}" == "1" ]]; then
  fail "数据源探活失败（HKSTOCK_GUARD_FAIL_SOURCE=1 注入）"
fi
if [[ ! -x "$VENV_PY" ]]; then
  fail "数据源探活失败: venv python 不存在: $VENV_PY"
fi
probe_out="$(timeout "$PROBE_TIMEOUT" "$VENV_PY" - <<'PY' 2>&1
import akshare as ak
df = ak.stock_zh_a_minute(symbol="sh600030", period="1", adjust="")
assert df is not None and len(df) > 0, "empty snapshot"
last = df.iloc[-1]
print("PROBE_OK", last["day"], last["close"])
PY
)" || fail "数据源探活失败（akshare sina ${PROBE_TIMEOUT}s 内无有效 A 股快照）"

# --- 全部通过 → 派单载荷（末行 BRIEF_PAYLOAD: 开头；概要零金额零成本） ---
summary="$(python3 - "$TARGET_DATE" "$HOLDINGS" <<'PY'
import json, sys, yaml
with open(sys.argv[2], encoding="utf-8") as fh:
    data = yaml.safe_load(fh)
accounts = data["accounts"]
payload = {
    "date": sys.argv[1],
    "holdings_summary": {
        "accounts": len(accounts),
        "positions": sum(len(a.get("positions") or []) for a in accounts),
        "account_names": [a.get("name") for a in accounts],
        "symbols": [p.get("symbol") for a in accounts for p in (a.get("positions") or [])],
    },
    "probe": "ok",
    "skill": "/Users/stringzhao/.hermes/profiles/hkstock/skills/morning-brief/SKILL.md",
    "brief_path": "/Users/stringzhao/workspace/martin/hkstock-data/briefs/"
    + sys.argv[1] + "-brief.md",
    "instruction": "按 SKILL.md 产出 C4 四段盘前简报并落盘 brief_path，期货段固定标注"
                   "「数据缺失：期货接入 T3 上线」，全段失败则 kanban_block 不产空简报",
}
print(json.dumps(payload, ensure_ascii=False))
PY
)" || fail "holdings 概要提取失败"

printf '数据源探活: %s\n' "$probe_out"
printf 'BRIEF_PAYLOAD: %s\n' "$summary"
exit 0
