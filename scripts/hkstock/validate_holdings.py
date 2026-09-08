#!/usr/bin/env python3
"""validate_holdings.py — hkstock 持仓文件 schema 校验器（hkstock 数据层验收门）。

用法:
    python3 scripts/hkstock/validate_holdings.py --file <path>

退出码语义（契约 1:1）:
    0 = 合法（stdout 含 "valid"）
    1 = 非法（结构可解析但字段违规；stderr 指明违规字段）
    2 = 文件不存在 / 解析失败

零依赖：仅用 python3 标准库（yaml 用 PyYAML，已在本机确认可用）。
"""

import argparse
import sys

ACCOUNT_TYPES = {"stock", "fund", "hk", "futures"}
CURRENCIES = {"CNY", "HKD"}

REQUIRED_ACCOUNT_FIELDS = ("name", "type", "positions")
REQUIRED_POSITION_FIELDS = ("symbol", "name", "qty", "cost", "currency")


def fail(msg: str) -> int:
    print(f"invalid: {msg}", file=sys.stderr)
    return 1


def validate(data) -> int:
    if not isinstance(data, dict):
        return fail("顶层必须是映射（dict）")

    accounts = data.get("accounts")
    if accounts is None:
        return fail("缺 required 顶层字段: accounts")
    if not isinstance(accounts, list):
        return fail("accounts 必须是列表")
    if not accounts:
        return fail("accounts 不得为空")

    for i, acc in enumerate(accounts):
        label = f"accounts[{i}]"
        if not isinstance(acc, dict):
            return fail(f"{label} 必须是映射")
        for f in REQUIRED_ACCOUNT_FIELDS:
            if acc.get(f) is None:
                return fail(f"{label} 缺 required 字段: {f}")
        if acc["type"] not in ACCOUNT_TYPES:
            return fail(
                f"{label}.type 非法值: {acc['type']!r}（允许 {sorted(ACCOUNT_TYPES)}）"
            )
        positions = acc["positions"]
        if not isinstance(positions, list) or not positions:
            return fail(f"{label}.positions 必须是非空列表")
        for j, pos in enumerate(positions):
            plabel = f"{label}.positions[{j}]"
            if not isinstance(pos, dict):
                return fail(f"{plabel} 必须是映射")
            for f in REQUIRED_POSITION_FIELDS:
                if pos.get(f) is None:
                    return fail(f"{plabel} 缺 required 字段: {f}")
            if not isinstance(pos["qty"], (int, float)) or isinstance(pos["qty"], bool):
                return fail(f"{plabel}.qty 必须是数值")
            if pos["qty"] <= 0:
                return fail(f"{plabel}.qty 必须大于 0，实际 {pos['qty']!r}")
            if not isinstance(pos["cost"], (int, float)) or isinstance(pos["cost"], bool):
                return fail(f"{plabel}.cost 必须是数值")
            if pos["cost"] < 0:
                return fail(f"{plabel}.cost 不得为负，实际 {pos['cost']!r}")
            if pos["currency"] not in CURRENCIES:
                return fail(
                    f"{plabel}.currency 非法值: {pos['currency']!r}（允许 {sorted(CURRENCIES)}）"
                )

    watchlist = data.get("watchlist")
    if watchlist is None:
        return fail("缺 required 顶层字段: watchlist")
    if not isinstance(watchlist, list):
        return fail("watchlist 必须是列表")
    for i, w in enumerate(watchlist):
        if not isinstance(w, dict):
            return fail(f"watchlist[{i}] 必须是映射")
        for f in ("symbol", "name"):
            if w.get(f) is None:
                return fail(f"watchlist[{i}] 缺 required 字段: {f}")

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="校验 hkstock holdings.yaml schema")
    parser.add_argument("--file", required=True, help="holdings.yaml 路径")
    args = parser.parse_args()

    try:
        import yaml
    except ImportError:
        print("invalid: 系统缺少 PyYAML，无法解析", file=sys.stderr)
        return 2

    try:
        with open(args.file, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"invalid: 文件不存在: {args.file}", file=sys.stderr)
        return 2
    except (yaml.YAMLError, OSError, UnicodeDecodeError) as exc:
        print(f"invalid: 解析失败: {exc}", file=sys.stderr)
        return 2

    rc = validate(data)
    if rc == 0:
        n_pos = sum(len(a.get("positions", [])) for a in data["accounts"])
        print(
            f"valid: {len(data['accounts'])} accounts / {n_pos} positions / "
            f"{len(data['watchlist'])} watchlist"
        )
    return rc


if __name__ == "__main__":
    sys.exit(main())
