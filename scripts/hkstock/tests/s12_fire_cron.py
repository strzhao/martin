#!/usr/bin/env python3
"""Fire the existing cron through Hermes' production per-fire prompt API (test driver only)."""

import argparse
import json
import os
from pathlib import Path
import sys

HERMES_AGENT_ROOT = Path(os.environ.get("HERMES_AGENT_ROOT", "/Users/stringzhao/workspace/hermes-agent"))
sys.path.insert(0, str(HERMES_AGENT_ROOT))

from tools.cronjob_tools import cronjob


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--run-context", required=True)
    args = parser.parse_args()
    raw = cronjob(action="run", job_id=args.job_id, prompt=args.run_context)
    payload = json.loads(raw)
    job = payload.get("job") or {}
    result = {
        "success": bool(payload.get("success")),
        "executed": job.get("executed"),
        "execution_mode": job.get("execution_mode"),
        "execution_success": job.get("execution_success"),
        "error": payload.get("error") or job.get("execution_error") or job.get("execution_skipped"),
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["success"] and result.get("error") in {None, ""} else 1


if __name__ == "__main__":
    raise SystemExit(main())
