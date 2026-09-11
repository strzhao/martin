#!/usr/bin/env python3
"""hkstock-signal-review — 信号库复盘统计（D3，零第三方依赖）。

CLI:
    python3 scripts/hkstock/signal_review.py --input <signals.jsonl> [--window-days 20] [--log <path>]

stdout: JSON {"total", "valid", "invalid_lines":[{line,reason}], "hit_rate": {bullish, bearish}, "avg_confidence": {bullish, bearish}, "undetermined"}
exit 闭集: 一切可判定情形（文件缺失/空/全无效行）exit 0；仅意外异常（未捕获/IO 错误）exit 1。

命中口径（确定性）：信号日收盘 vs T+N 收盘（N 按 horizon 映射 intraday=1/swing=5/position=20，
行情经 mktd daily 获取；行情缺失的信号计入 undetermined，不进命中率）。
bullish 命中 = T+N > 信号日收盘；bearish 命中 = T+N < 信号日收盘；neutral 不计。
"""

import argparse
import datetime as _dt
import json
import os
import subprocess
import sys

REQUIRED_FIELDS = ("date", "asset", "symbol", "direction", "confidence", "horizon", "rationale", "source", "created_by")
ENUM_ASSET = {"a-stock", "hk", "fund", "futures"}
ENUM_DIRECTION = {"bullish", "bearish", "neutral"}
ENUM_HORIZON = {"intraday", "swing", "position"}
HORIZON_MAP = {"intraday": 1, "swing": 5, "position": 20}
MKTD = "/Users/stringzhao/.local/bin/mktd"
DEFAULT_LOG = "/Users/stringzhao/workspace/martin/hkstock-data/logs/signal-review-invalid.log"
WHITELIST_SYMBOL = None  # mktd 取数仅按信号内 symbol 调用 daily


def _now_date() -> _dt.date:
    return _dt.date.today()


def _validate_line(obj):
    """校验单条信号 dict；返回错误原因字符串，合法返回 None。"""
    for f in REQUIRED_FIELDS:
        if f not in obj:
            return "missing field: %s" % f
    d = str(obj["date"])
    try:
        _dt.datetime.strptime(d, "%Y-%m-%d")
    except ValueError:
        return "bad date: %r" % obj["date"]
    if obj["asset"] not in ENUM_ASSET:
        return "bad asset: %r" % obj["asset"]
    if obj["direction"] not in ENUM_DIRECTION:
        return "bad direction: %r" % obj["direction"]
    if obj["horizon"] not in ENUM_HORIZON:
        return "bad horizon: %r" % obj["horizon"]
    c = obj["confidence"]
    if not isinstance(c, (int, float)) or isinstance(c, bool) or not (0 <= float(c) <= 1):
        return "bad confidence: %r" % c
    r = obj["rationale"]
    if not isinstance(r, str) or not r.strip():
        return "empty rationale"
    s = obj["source"]
    if not isinstance(s, str) or not s.strip():
        return "empty source"
    if obj["created_by"] != "hkstock-worker":
        return "bad created_by: %r" % obj["created_by"]
    return None


def _log_invalid(log_path, lineno, reason):
    """失败留痕（D2）：`<日期> line<N> <原因>`；写日志失败不影响主流程。"""
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write("%s line%d %s\n" % (_now_date().isoformat(), lineno, reason))
    except OSError:
        pass


def parse_signals(path, log_path=DEFAULT_LOG):
    """解析 signals.jsonl → (total, valid_signals, invalid_lines)。

    文件不存在/空 = 可判定情形，返回 (0, [], [])。
    """
    total = 0
    valid = []
    invalid = []
    if not os.path.exists(path):
        return 0, [], []
    with open(path, "r", encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line:
                continue
            total += 1
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as e:
                reason = "json parse error: %s" % e.msg
                invalid.append({"line": lineno, "reason": reason})
                _log_invalid(log_path, lineno, reason)
                continue
            if not isinstance(obj, dict):
                reason = "not an object"
                invalid.append({"line": lineno, "reason": reason})
                _log_invalid(log_path, lineno, reason)
                continue
            reason = _validate_line(obj)
            if reason is not None:
                invalid.append({"line": lineno, "reason": reason})
                _log_invalid(log_path, lineno, reason)
                continue
            obj["_line"] = lineno
            valid.append(obj)
    return total, valid, invalid


def _mktd_daily_close(symbol, days):
    """mktd daily 取最近 days 个交易日 [{date, close}]；任何失败返回 []（→ undetermined）。"""
    if not os.path.exists(MKTD):
        return []
    try:
        out = subprocess.run(
            [MKTD, "daily", symbol, "--days", str(days), "--format", "json"],
            capture_output=True, text=True, timeout=90,
        )
        if out.returncode != 0:
            return []
        text = out.stdout
        start = text.find("[")
        end = text.rfind("]")
        if start < 0 or end <= start:
            return []
        rows = json.loads(text[start:end + 1])
        result = []
        for row in rows:
            d = str(row.get("date", row.get("日期", "")))[:10]
            c = row.get("close", row.get("收盘", row.get("close_price")))
            if d and isinstance(c, (int, float)):
                result.append((d, float(c)))
        result.sort(key=lambda x: x[0])
        return result
    except (OSError, ValueError, subprocess.SubprocessError):
        return []


def _close_on_or_before(rows, date_iso):
    """返回 date_iso 当日（或此前最近交易日）的收盘价；找不到返回 None。"""
    best = None
    for d, c in rows:
        if d <= date_iso:
            best = (d, c)
        else:
            break
    return best[1] if best else None


def _close_after(rows, date_iso, n):
    """信号日（或其前最近交易日）之后第 n 个交易日的收盘价；不足返回 None。"""
    idx = None
    for i, (d, _c) in enumerate(rows):
        if d <= date_iso:
            idx = i
        else:
            break
    if idx is None:
        return None
    target = idx + n
    if target < len(rows):
        return rows[target][1]
    return None


def review(valid, window_days):
    """按窗口与 horizon 映射计算命中率/平均置信度。"""
    cutoff = (_now_date() - _dt.timedelta(days=window_days)).isoformat()
    in_window = [s for s in valid if str(s["date"]) >= cutoff]
    undetermined = 0
    hits = {"bullish": 0, "bearish": 0}
    determined = {"bullish": 0, "bearish": 0}
    conf_sum = {"bullish": 0.0, "bearish": 0.0}
    conf_n = {"bullish": 0, "bearish": 0}
    close_cache = {}
    for s in in_window:
        direction = s["direction"]
        if direction in conf_sum:  # avg_confidence 只报 bullish/bearish（D3 输出键集）
            conf_sum[direction] += float(s["confidence"])
            conf_n[direction] += 1
        if direction == "neutral":
            continue
        n = HORIZON_MAP[s["horizon"]]
        symbol = str(s["symbol"])
        if symbol not in close_cache:
            close_cache[symbol] = _mktd_daily_close(symbol, n + 40)
        rows = close_cache[symbol]
        base = _close_on_or_before(rows, str(s["date"]))
        later = _close_after(rows, str(s["date"]), n)
        if base is None or later is None:
            undetermined += 1
            continue
        determined[direction] += 1
        if (direction == "bullish" and later > base) or (direction == "bearish" and later < base):
            hits[direction] += 1
    hit_rate = {}
    for d in ("bullish", "bearish"):
        hit_rate[d] = round(hits[d] / determined[d], 4) if determined[d] else None
    avg_confidence = {}
    for d in ("bullish", "bearish"):
        avg_confidence[d] = round(conf_sum[d] / conf_n[d], 4) if conf_n[d] else None
    return {
        "total": 0,
        "valid": 0,
        "invalid_lines": [],
        "hit_rate": hit_rate,
        "avg_confidence": avg_confidence,
        "undetermined": undetermined,
        "window_days": window_days,
        "reviewed": len(in_window),
    }


def main():
    ap = argparse.ArgumentParser(description="hkstock signal review stats")
    ap.add_argument("--input", required=True, help="signals.jsonl path")
    ap.add_argument("--window-days", type=int, default=20)
    ap.add_argument("--log", default=DEFAULT_LOG)
    args = ap.parse_args()
    try:
        total, valid, invalid = parse_signals(args.input, args.log)
        result = review(valid, args.window_days)
    except Exception as e:  # 意外异常/IO 错误 → exit 1（D3 exit 闭集）
        print("unexpected error: %s" % e, file=sys.stderr)
        return 1
    result["total"] = total
    result["valid"] = len(valid)
    result["invalid_lines"] = invalid
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
