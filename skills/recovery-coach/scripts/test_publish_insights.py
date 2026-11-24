#!/usr/bin/env python3
"""publish_insights.py 的自测，零依赖：

    python3 scripts/test_publish_insights.py
"""
from __future__ import annotations

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("publish_insights.py")
VALID = {
    "schema": "soma.insights.v1",
    "generated_at": "2026-11-24T10:10:00+08:00",
    "status": "green",
    "headline": "🟢 一切正常。",
    "alerts": [],
}
# 本机 1 号端口没有服务，用来模拟 receiver 没在跑
DEAD_RECEIVER = "http://127.0.0.1:1"


class FakeReceiver(http.server.BaseHTTPRequestHandler):
    """只认 Bearer good 的假 receiver；reply_status 可按用例改成拒收码。"""

    reply_status = 200

    def do_POST(self) -> None:  # noqa: N802 - http.server 约定的方法名
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if self.headers.get("Authorization") != "Bearer good":
            self._reply(401, {"error": "unauthorized"})
        elif self.path != "/v1/insights":
            self._reply(404, {"error": "not_found"})
        elif self.reply_status == 200:
            self._reply(200, {"stored": True})
        else:
            self._reply(self.reply_status, {"error": "insights_invalid", "detail": "headline empty"})

    def _reply(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args: object) -> None:
        pass


def publish(args: list[str], token_file: Path | None = None, env_token: str | None = None) -> subprocess.CompletedProcess[str]:
    env = {key: value for key, value in os.environ.items() if key != "SOMA_AI_TOKEN"}
    if env_token is not None:
        env["SOMA_AI_TOKEN"] = env_token
    command = [sys.executable, str(SCRIPT), *args]
    if token_file is not None:
        command += ["--token-file", str(token_file)]
    return subprocess.run(command, capture_output=True, text=True, env=env, check=False)


class PublishInsightsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeReceiver)
        cls.receiver = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory(prefix="publish-insights-test-")
        cls.root = Path(cls.tmp.name)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.tmp.cleanup()

    def setUp(self) -> None:
        FakeReceiver.reply_status = 200

    def write_draft(self, doc: object, name: str = "draft.json") -> list[str]:
        path = self.root / name
        path.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        return [str(path), "--receiver", self.receiver]

    def test_valid_draft_is_accepted(self) -> None:
        result = publish(self.write_draft(VALID), env_token="good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("已提交", result.stdout)

    def test_token_can_come_from_secret_file(self) -> None:
        token_file = self.root / "ai-token.json"
        token_file.write_text(json.dumps({"label": "ai-recovery-coach", "token": "good"}), encoding="utf-8")
        result = publish(self.write_draft(VALID), token_file=token_file)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_token_is_unauthorized(self) -> None:
        result = publish(self.write_draft(VALID), env_token="nope")
        self.assertEqual(result.returncode, 3, result.stderr)

    def test_missing_token_names_the_fix(self) -> None:
        result = publish(self.write_draft(VALID), token_file=self.root / "missing.json")
        self.assertEqual(result.returncode, 3)
        self.assertIn("create-ai-token", result.stderr)

    def test_receiver_rejection_codes(self) -> None:
        for status, expected in ((422, 5), (413, 5), (501, 4)):
            with self.subTest(status=status):
                FakeReceiver.reply_status = status
                result = publish(self.write_draft(VALID), env_token="good")
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_unreachable_receiver(self) -> None:
        path = self.root / "draft.json"
        path.write_text(json.dumps(VALID), encoding="utf-8")
        result = publish([str(path), "--receiver", DEAD_RECEIVER], env_token="good")
        self.assertEqual(result.returncode, 6)
        self.assertIn("连不上 receiver", result.stderr)

    def test_invalid_drafts_name_the_field(self) -> None:
        cases = {
            "schema": ({**VALID, "schema": "soma.insights.v2"}, "schema"),
            "timezone": ({**VALID, "generated_at": "2026-11-24T10:10:00"}, "时区"),
            "unparseable": ({**VALID, "generated_at": "昨天早上"}, "generated_at"),
            "status": ({**VALID, "status": "amber"}, "status"),
            "headline": ({**VALID, "headline": "   "}, "headline"),
            "alerts": ({**VALID, "alerts": [{"action": "x"}]}, "alerts[0]"),
            "not_object": (["nope"], "顶层"),
        }
        for name, (doc, expected) in cases.items():
            with self.subTest(case=name):
                result = publish(self.write_draft(doc), env_token="good")
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(expected, result.stderr)

    def test_wrong_dimension_count_warns_but_submits(self) -> None:
        doc = {**VALID, "dimensions": [{"key": "sleep", "label": "睡眠规律性", "verdict": "green"}]}
        result = publish(self.write_draft(doc), env_token="good")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("提醒：dimensions", result.stderr)

    def test_missing_draft_file(self) -> None:
        result = publish([str(self.root / "absent.json"), "--receiver", self.receiver], env_token="good")
        self.assertEqual(result.returncode, 2)
        self.assertIn("找不到判读产物", result.stderr)


if __name__ == "__main__":
    unittest.main()
