#!/usr/bin/env python3
"""Normalize an AI-written report for byte-stable WeChat delivery; never sends anything."""

import argparse
import os
from pathlib import Path
import sys

HERMES_AGENT_ROOT = Path(os.environ.get("HERMES_AGENT_ROOT", "/Users/stringzhao/workspace/hermes-agent"))
sys.path.insert(0, str(HERMES_AGENT_ROOT))

from plugins.platforms.weixin.adapter import _normalize_markdown_blocks, _wrap_copy_friendly_lines_for_weixin


def wechat_normalize(content):
    return _wrap_copy_friendly_lines_for_weixin(_normalize_markdown_blocks(content))


def normalize(path):
    content = path.read_text(encoding="utf-8")
    normalized = wechat_normalize(content)
    if wechat_normalize(normalized) != normalized:
        print("FAIL WeChat normalization is not idempotent", file=sys.stderr)
        return 1
    path.write_text(normalized, encoding="utf-8")
    print(f"PASS wechat-normalize {path}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    normalize_parser = sub.add_parser("normalize")
    normalize_parser.add_argument("path", type=Path)
    args = parser.parse_args()
    return normalize(args.path)


if __name__ == "__main__":
    raise SystemExit(main())
