"""配置加载与权限校验。

config.yaml 必须 0600；不满足时自动 chmod。
"""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "config.yaml"
EXAMPLE_PATH = ROOT / "config.example.yaml"


def ensure_secure_mode(path: Path) -> None:
    """确保 config.yaml 权限不可被组/其他读写。"""
    mode = path.stat().st_mode
    if mode & 0o077:
        path.chmod(mode & ~0o077)
        print(f"[config] 已收紧 {path} 权限到 0600", file=sys.stderr)


def load() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        if not EXAMPLE_PATH.exists():
            raise FileNotFoundError(f"配置不存在：{CONFIG_PATH}")
        # 首次运行：复制模板
        CONFIG_PATH.write_text(EXAMPLE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        CONFIG_PATH.chmod(0o600)
        print(f"[config] 已从模板创建 {CONFIG_PATH}，请先运行 `cli.py setup` 完成配置", file=sys.stderr)

    ensure_secure_mode(CONFIG_PATH)
    with CONFIG_PATH.open("r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return data


def save(data: dict[str, Any]) -> None:
    CONFIG_PATH.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
    CONFIG_PATH.chmod(0o600)


def get(data: dict[str, Any], path: str, default: Any = None) -> Any:
    """点号路径取值：get(d, 'client.url')。"""
    cur: Any = data
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def require(data: dict[str, Any], path: str) -> Any:
    val = get(data, path)
    if val in (None, "", []):
        raise RuntimeError(f"配置缺失：{path}，请先运行 `cli.py setup`")
    return val
