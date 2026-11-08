#!/usr/bin/env python3
"""Project a real new WeChat delivery into a receipt; never fabricates or repairs evidence."""

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time

HERMES_AGENT_ROOT = Path(os.environ.get("HERMES_AGENT_ROOT", "/Users/stringzhao/workspace/hermes-agent"))
sys.path.insert(0, str(HERMES_AGENT_ROOT))
from plugins.platforms.weixin.adapter import _normalize_markdown_blocks, _wrap_copy_friendly_lines_for_weixin


def report_id(text):
    match = re.search(r"(?m)^report_id:\s*([^\s]+)\s*$", text)
    return match.group(1) if match else None


def normalized(text):
    return _wrap_copy_friendly_lines_for_weixin(_normalize_markdown_blocks(text))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-db", type=Path, required=True)
    parser.add_argument("--executions-db", type=Path, required=True)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--chat-id", required=True)
    parser.add_argument("--report-path", type=Path, required=True)
    parser.add_argument("--expected-report-id", required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--timeout-seconds", type=int, default=6000)
    parser.add_argument("--since", type=float)
    parser.add_argument("--direct-result", type=Path)
    args = parser.parse_args()
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.touch()
    started = args.since if args.since is not None else time.time()
    deadline = time.time() + args.timeout_seconds
    while time.time() < deadline:
        if args.report_path.is_file():
            local = args.report_path.read_text(encoding="utf-8")
            generated_id = report_id(local)
            if generated_id == args.expected_report_id and args.nonce in generated_id and normalized(local) == local:
                if args.direct_result and args.direct_result.is_file():
                    marker = json.loads(args.direct_result.read_text(encoding="utf-8"))
                    result = json.loads(marker.get("stdout") or "{}")
                    if (marker.get("code") == 0 and result.get("success") is True and result.get("mirrored") is True
                            and result.get("platform") == "weixin" and result.get("chat_id") == args.chat_id
                            and result.get("message_id") and marker.get("started_at", 0) >= started - 1):
                        db = sqlite3.connect(f"file:{args.state_db}?mode=ro", uri=True)
                        row = db.execute(
                            "select m.content,m.timestamp from messages m join sessions s on s.id=m.session_id "
                            "where m.role='assistant' and m.timestamp>=? and instr(s.session_key,?)>0 and m.content=? "
                            "order by m.timestamp desc limit 1",
                            (started - 1, args.chat_id, local),
                        ).fetchone()
                        db.close()
                        if row and report_id(row[0]) == generated_id:
                            receipt = {
                                "delivery_status": "delivered", "report_generated": True,
                                "report_id": generated_id, "generated_report_id": generated_id,
                                "local_report_path": str(args.report_path), "delivered_content": row[0],
                                "delivery_obligation_id": f"direct:{result['message_id']}",
                                "delivered_at": row[1], "cron_execution_id": None, "nonce": args.nonce,
                            }
                            with args.receipt.open("a", encoding="utf-8") as handle:
                                handle.write(json.dumps(receipt, ensure_ascii=False) + "\n")
                            print("RECEIPT_OK direct send success and mirrored content matched")
                            return 0
                db = sqlite3.connect(f"file:{args.state_db}?mode=ro", uri=True)
                rows = db.execute(
                    "select obligation_id,content,state,created_at from delivery_obligations "
                    "where platform='weixin' and chat_id=? and created_at>? order by created_at asc",
                    (args.chat_id, started - 1),
                ).fetchall()
                db.close()
                for obligation_id, content, state, created_at in rows:
                    delivered_id = report_id(content)
                    if delivered_id != generated_id:
                        continue
                    if state != "delivered" or content != local:
                        print("FAIL matching report has non-delivered state or content mismatch", file=sys.stderr)
                        return 2
                    execution_id = None
                    if args.executions_db.is_file():
                        executions = sqlite3.connect(f"file:{args.executions_db}?mode=ro", uri=True)
                        row = executions.execute(
                            "select id from executions where job_id=? and claimed_at>=? order by claimed_at desc limit 1",
                            (args.job_id, dt.datetime.fromtimestamp(started - 1, dt.timezone.utc).isoformat()),
                        ).fetchone()
                        executions.close()
                        execution_id = row[0] if row else None
                    receipt = {
                        "delivery_status": "delivered",
                        "report_generated": True,
                        "report_id": delivered_id,
                        "generated_report_id": generated_id,
                        "local_report_path": str(args.report_path),
                        "delivered_content": content,
                        "delivery_obligation_id": obligation_id,
                        "delivered_at": created_at,
                        "cron_execution_id": execution_id,
                        "nonce": args.nonce,
                    }
                    with args.receipt.open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps(receipt, ensure_ascii=False) + "\n")
                    print("RECEIPT_OK real delivered content matched generated report")
                    return 0
        time.sleep(5)
    print("TIMEOUT waiting for a new exact delivered report", file=sys.stderr)
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
