#!/usr/bin/env python3
"""Atomic, append-only thesis updates with per-subject lock and lock status probe."""

import argparse
import datetime as dt
import fcntl
import os
from pathlib import Path
import re


def parse(text):
    match = re.match(r"\A---\n(.*?)\n---\s*\n?", text, re.S)
    if not match:
        raise ValueError("thesis frontmatter is required")
    meta = {}
    for line in match.group(1).splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            meta[key.strip()] = value.strip()
    return meta, text[match.end():]


def replace_section(body, name, content):
    matches = list(re.finditer(r"(?m)^##\s+([^\n]+?)\s*$", body))
    for index, match in enumerate(matches):
        if match.group(1).strip() == name:
            end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
            return body[:match.end()] + "\n" + content.rstrip() + "\n" + body[end:]
    raise ValueError(f"missing thesis section: {name}")


def append_section(body, name, content):
    matches = list(re.finditer(r"(?m)^##\s+([^\n]+?)\s*$", body))
    for index, match in enumerate(matches):
        if match.group(1).strip() == name:
            end = matches[index + 1].start() if index + 1 < len(matches) else len(body)
            return body[:end].rstrip() + "\n" + content.rstrip() + "\n" + body[end:]
    raise ValueError(f"missing thesis section: {name}")


def update(path, evidence, conclusion, trigger, kind):
    lock_path = path.with_name(f"{path.name}.lock")
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"LOCKED {path}")
            return 3
        try:
            meta, body = parse(path.read_text(encoding="utf-8"))
            revision = int(meta["revision"]) + 1
            now = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
            meta["revision"] = str(revision)
            meta["updated_at"] = now
            meta["report_id"] = f"thesis-{meta['subject']}-r{revision}"
            frontmatter = "---\n" + "\n".join(f"{key}: {value}" for key, value in meta.items()) + "\n---\n"
            body = replace_section(body, "当前观点", f"{conclusion}\n\n触发条件：{trigger}")
            body = append_section(body, "证据", f"- {kind}：[{evidence}]")
            if kind == "挑战":
                body = append_section(body, "反证与风险", f"- 挑战证据 [{evidence}] 要求重检当前假设。")
            history = (
                f"\n### revision {revision}\n"
                f"- revision: {revision}\n"
                f"- updated_at: {now}\n"
                f"- conclusion: {conclusion}\n"
                f"- 当时证据: [{evidence}]\n"
                f"- 触发条件: {trigger}\n"
            )
            body = append_section(body, "观点历史", history)
            temp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
            try:
                temp.write_text(frontmatter + body, encoding="utf-8")
                os.replace(temp, path)
            finally:
                if temp.exists():
                    temp.unlink()
            print(f"UPDATED {path} revision={revision}")
            return 0
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def status(path):
    lock_path = path.with_name(f"{path.name}.lock")
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"LOCKED {path}")
            return 3
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    print(f"UNLOCKED {path}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    edit = sub.add_parser("update")
    edit.add_argument("--path", type=Path, required=True)
    edit.add_argument("--evidence", required=True)
    edit.add_argument("--conclusion", required=True)
    edit.add_argument("--trigger", required=True)
    edit.add_argument("--kind", choices=["支持", "挑战"], default="支持")
    probe = sub.add_parser("status")
    probe.add_argument("--path", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "update":
        if not re.fullmatch(r"E[A-Za-z0-9_-]+", args.evidence):
            parser.error("evidence must match ^E[A-Za-z0-9_-]+$")
        return update(args.path, args.evidence, args.conclusion, args.trigger, args.kind)
    return status(args.path)


if __name__ == "__main__":
    raise SystemExit(main())
