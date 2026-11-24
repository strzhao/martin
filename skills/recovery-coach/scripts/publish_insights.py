#!/usr/bin/env python3
"""把恢复教练的判读产物提交给 Soma receiver。

用法（任意目录）：

    python3 publish_insights.py [draft.json]

先在本地按 soma.insights.v1 校验，再 POST 到 receiver 的 /v1/insights；receiver 写时再校验一次
并原子落盘。成功打印回执；失败打印字段级原因并非零退出，改 draft 重跑即可。

退出码：0 成功 · 2 draft 不合规范 · 3 凭证无效（401/403）· 4 receiver 未开写通道（501）
· 5 receiver 拒收（413/422）· 6 连不上 receiver。

凭证：依次找环境变量 SOMA_AI_TOKEN、~/workspace/recovery-coach/.secrets/ai-token.json 的 token 键。
规范真源：harmony-space services/soma-receiver/docs/insights-v1.md。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

SCHEMA_ID = "soma.insights.v1"
STATUS_VALUES = ("green", "yellow", "red")
DIMENSION_KEYS = ("sleep", "recovery", "illness", "activity", "subjective", "experiment")
DEFAULT_DRAFT = Path("~/workspace/recovery-coach/insights/draft.json")
DEFAULT_TOKEN_FILE = Path("~/workspace/recovery-coach/.secrets/ai-token.json")
# receiver 只在本机监听；自托管形态用环境变量 SOMA_RECEIVER_URL 覆盖
DEFAULT_RECEIVER_URL = "http://127.0.0.1:8765"
# 判读产物是几百字节的 JSON，本机回环 15 秒足够；再久说明 receiver 卡死
TIMEOUT_SECONDS = 15

EXIT_OK = 0
EXIT_INVALID_DRAFT = 2
EXIT_UNAUTHORIZED = 3
EXIT_WRITE_DISABLED = 4
EXIT_REJECTED = 5
EXIT_UNREACHABLE = 6


def validate(doc: object) -> tuple[list[str], list[str]]:
    """返回 (errors, warnings)。errors 覆盖并严于 receiver 的写时校验，warnings 只提醒不拦。"""
    if not isinstance(doc, dict):
        return ["顶层必须是 JSON 对象"], []

    errors: list[str] = []
    warnings: list[str] = []

    if doc.get("schema") != SCHEMA_ID:
        errors.append(f"schema 必须是 {SCHEMA_ID!r}，现在是 {doc.get('schema')!r}")

    generated_at = doc.get("generated_at")
    if not isinstance(generated_at, str):
        errors.append("generated_at 必须是带时区的 ISO 时间字符串，如 2026-11-24T10:10:00+08:00")
    else:
        try:
            parsed = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
        except ValueError:
            errors.append(f"generated_at 解析不了：{generated_at!r}，写成 2026-11-24T10:10:00+08:00 这种")
        else:
            if parsed.tzinfo is None:
                errors.append("generated_at 缺时区，结尾要带 +08:00")

    if doc.get("status") not in STATUS_VALUES:
        errors.append(f"status 必须是 green / yellow / red 之一，现在是 {doc.get('status')!r}")

    headline = doc.get("headline")
    if not isinstance(headline, str) or not headline.strip():
        errors.append("headline 必须是非空字符串")

    alerts = doc.get("alerts")
    if alerts is not None:
        if not isinstance(alerts, list):
            errors.append("alerts 必须是数组")
        else:
            for index, alert in enumerate(alerts):
                if not isinstance(alert, dict) or not str(alert.get("title", "")).strip():
                    errors.append(f"alerts[{index}] 必须是对象且有非空 title")
                    continue
                for field in ("title", "action"):
                    if field in alert and not isinstance(alert[field], str):
                        errors.append(f"alerts[{index}].{field} 必须是字符串")

    dimensions = doc.get("dimensions")
    if dimensions is not None:
        if not isinstance(dimensions, list):
            errors.append("dimensions 必须是数组")
        else:
            keys = [d.get("key") for d in dimensions if isinstance(d, dict)]
            if sorted(keys) != sorted(DIMENSION_KEYS):
                warnings.append(
                    "dimensions 应为六条，key 闭集 sleep/recovery/illness/activity/subjective/experiment；"
                    f"现在是 {keys}"
                )

    for field in ("period", "data_coverage"):
        if field in doc and doc[field] is not None and not isinstance(doc[field], dict):
            errors.append(f"{field} 必须是对象")

    return errors, warnings


def load_token(token_file: Path) -> str | None:
    env_token = os.environ.get("SOMA_AI_TOKEN", "").strip()
    if env_token:
        return env_token
    if not token_file.is_file():
        return None
    try:
        secret = json.loads(token_file.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if isinstance(secret, str):
        return secret.strip() or None
    if isinstance(secret, dict):
        token = secret.get("token")
        if isinstance(token, str) and token.strip():
            return token.strip()
    return None


def post(url: str, token: str, body: bytes) -> tuple[int | None, str]:
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as error:
        return None, str(error)


def main() -> int:
    parser = argparse.ArgumentParser(description="提交判读产物到 Soma receiver（soma.insights.v1）")
    parser.add_argument("draft", nargs="?", type=Path, default=DEFAULT_DRAFT, help="判读产物 JSON 路径")
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE, help="AI 凭证 JSON 路径")
    parser.add_argument("--receiver", default=os.environ.get("SOMA_RECEIVER_URL", DEFAULT_RECEIVER_URL), help="receiver 地址")
    args = parser.parse_args()

    draft_path = args.draft.expanduser()
    if not draft_path.is_file():
        print(f"找不到判读产物：{draft_path}", file=sys.stderr)
        return EXIT_INVALID_DRAFT
    try:
        doc = json.loads(draft_path.read_text(encoding="utf-8"))
    except ValueError as error:
        print(f"判读产物不是合法 JSON：{error}", file=sys.stderr)
        return EXIT_INVALID_DRAFT

    errors, warnings = validate(doc)
    for warning in warnings:
        print(f"提醒：{warning}", file=sys.stderr)
    if errors:
        print("判读产物不合规范，改完重跑：", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return EXIT_INVALID_DRAFT

    token = load_token(args.token_file.expanduser())
    if token is None:
        print(
            "没有 AI 凭证：设环境变量 SOMA_AI_TOKEN，或把凭证 JSON 放到 "
            f"{args.token_file.expanduser()}（health-bridge receiver create-ai-token --output-secret）。",
            file=sys.stderr,
        )
        return EXIT_UNAUTHORIZED

    status, text = post(f"{args.receiver.rstrip('/')}/v1/insights", token, draft_path.read_bytes())
    if status is None:
        print(f"连不上 receiver（{args.receiver}）：{text}。确认 receiver 在跑。", file=sys.stderr)
        return EXIT_UNREACHABLE
    if status == 200:
        print(f"已提交，receiver 已落盘：{text}")
        return EXIT_OK
    if status in (401, 403):
        print(f"凭证无效（HTTP {status}）：{text}。凭证必须是 ai- 前缀 label 的 token。", file=sys.stderr)
        return EXIT_UNAUTHORIZED
    if status == 501:
        print("receiver 没开写通道（HTTP 501）：启动时要带 --insights <路径>。", file=sys.stderr)
        return EXIT_WRITE_DISABLED
    print(f"receiver 拒收（HTTP {status}）：{text}", file=sys.stderr)
    return EXIT_REJECTED


if __name__ == "__main__":
    sys.exit(main())
