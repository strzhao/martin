#!/usr/bin/env python3
"""Run one finite research turn through Hermes' production local one-shot entry."""

import argparse
import io
import json
import os
from pathlib import Path
import sys
import tempfile

from contextlib import redirect_stderr, redirect_stdout

from hermes_cli.oneshot import run_oneshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--client-env", type=json.loads, default={})
    args = parser.parse_args()
    os.chdir(args.cwd)
    for key, value in args.client_env.items():
        os.environ[key] = str(value)

    stdout = io.StringIO()
    stderr = io.StringIO()
    usage = {}
    with tempfile.TemporaryDirectory(prefix="oneshot-usage-", dir=os.environ.get("TMPDIR")) as temp:
        usage_path = Path(temp) / "usage.json"
        try:
            with redirect_stdout(stdout), redirect_stderr(stderr):
                code = run_oneshot(args.prompt, usage_file=str(usage_path))
            if usage_path.exists():
                usage = json.loads(usage_path.read_text(encoding="utf-8"))
        except Exception as exc:
            print(json.dumps({"code": 1, "error": type(exc).__name__, "message": str(exc)}, ensure_ascii=False), file=sys.stderr)
            return 1

    error_text = stderr.getvalue()
    if error_text:
        sys.stderr.write(error_text)
    print(json.dumps({
        "code": code,
        "result": stdout.getvalue(),
        "stop_reason": usage.get("turn_exit_reason"),
        "session_id": usage.get("session_id"),
        "provider": usage.get("provider"),
        "model": usage.get("model"),
        "completed": usage.get("completed"),
        "partial": usage.get("partial"),
        "failed": usage.get("failed"),
        "interrupted": usage.get("interrupted"),
    }, ensure_ascii=False))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
