#!/usr/bin/env python3
"""Backup and migrate only hkstock SOUL plus the three existing finance cron prompts."""

import argparse
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "deploy/hkstock/runtime"
PROMPTS = {
    "77d2b63aafcc": "morning-brief.txt",
    "13d88c36a30b": "weekly-review.txt",
    "a412382de9c4": "watchdog.txt",
}


def atomic_write(path, text):
    temp = path.with_name(f".{path.name}.finance-tmp-{os.getpid()}")
    try:
        with temp.open("w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        shutil.copymode(path, temp)
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def backup(path, stamp):
    destination = path.with_name(f"{path.name}.bak-finance-{stamp}")
    if destination.exists():
        raise RuntimeError(f"backup already exists: {destination}")
    shutil.copy2(path, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-dir", type=Path, default=Path.home() / ".hermes/profiles/hkstock")
    parser.add_argument("--cron-jobs", type=Path, default=Path.home() / ".hermes/cron/jobs.json")
    parser.add_argument("--repo-root", type=Path, default=Path("/Users/stringzhao/workspace/martin"))
    parser.add_argument("--data-dir", type=Path, default=Path("/Users/stringzhao/workspace/martin/hkstock-data"))
    args = parser.parse_args()
    soul = args.profile_dir / "SOUL.md"
    if not soul.is_file() or not args.cron_jobs.is_file():
        parser.error("profile SOUL.md and cron jobs.json must exist")
    with args.cron_jobs.open(encoding="utf-8") as handle:
        config = json.load(handle)
    jobs = config.get("jobs")
    if not isinstance(jobs, list):
        parser.error("cron jobs.json has no jobs array")
    by_id = {job.get("id"): job for job in jobs if isinstance(job, dict)}
    missing = set(PROMPTS) - set(by_id)
    if missing:
        parser.error(f"missing required cron jobs: {','.join(sorted(missing))}")
    deliver = str(by_id["77d2b63aafcc"].get("deliver", ""))
    if not deliver.startswith("weixin:") or not deliver[len("weixin:"):]:
        parser.error("morning job has no weixin delivery target")
    chat_id = deliver[len("weixin:"):]
    replacements = {
        "{{REPO_ROOT}}": str(args.repo_root),
        "{{DATA_DIR}}": str(args.data_dir),
        "{{PROFILE_DIR}}": str(args.profile_dir),
        "{{WECHAT_CHAT_ID}}": chat_id,
    }
    rendered = {}
    for job_id, filename in PROMPTS.items():
        text = (RUNTIME / filename).read_text(encoding="utf-8")
        for placeholder, value in replacements.items():
            text = text.replace(placeholder, value)
        if "{{" in text:
            raise RuntimeError(f"unresolved placeholder in {filename}")
        rendered[job_id] = text
    new_soul = (RUNTIME / "SOUL.md").read_text(encoding="utf-8")
    stamp = dt.datetime.now().strftime("%Y%m%dT%H%M%S")
    backups = [backup(soul, stamp), backup(args.cron_jobs, stamp)]
    lock_path = args.cron_jobs.with_name(".jobs.lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            # Re-read under the cron lock so a concurrent scheduler update is not overwritten.
            with args.cron_jobs.open(encoding="utf-8") as handle:
                current = json.load(handle)
            current_by_id = {job.get("id"): job for job in current.get("jobs", []) if isinstance(job, dict)}
            for job_id, prompt in rendered.items():
                if job_id not in current_by_id:
                    raise RuntimeError(f"cron job disappeared during migration: {job_id}")
                current_by_id[job_id]["prompt"] = prompt
            current["updated_at"] = dt.datetime.now().astimezone().isoformat()
            atomic_write(args.cron_jobs, json.dumps(current, ensure_ascii=False, indent=2) + "\n")
            atomic_write(soul, new_soul)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    with args.cron_jobs.open(encoding="utf-8") as handle:
        readback = json.load(handle)
    readback_by_id = {job.get("id"): job for job in readback["jobs"]}
    for job_id, prompt in rendered.items():
        if readback_by_id[job_id]["prompt"] != prompt:
            raise RuntimeError(f"cron readback mismatch: {job_id}")
    if soul.read_text(encoding="utf-8") != new_soul:
        raise RuntimeError("SOUL readback mismatch")
    for path in backups:
        print(f"BACKUP_OK {path}")
    print(f"MIGRATE_OK profile={args.profile_dir} cron_jobs={args.cron_jobs} prompts={len(rendered)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
