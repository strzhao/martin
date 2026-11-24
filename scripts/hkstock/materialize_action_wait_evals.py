#!/usr/bin/env python3
"""Materialize inline morning-brief eval fixtures into an isolated directory."""

import argparse
import json
import re
import shutil
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("evals", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    text = args.evals.read_text()
    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.mkdir(parents=True)

    pattern = re.compile(
        r"^### 场景 ([123ABCD89])：([^\n]+)\n(.*?)(?=^### 场景 |^## 执行与观察回收)",
        re.MULTILINE | re.DOTALL,
    )
    metadata = []
    for match in pattern.finditer(text):
        case, title, body = match.group(1), match.group(2).strip(), match.group(3)
        query = re.search(r"\*\*query\*\*：([^\n]+)", body)
        as_of = re.search(r"\*\*as_of\*\*：([^\n]+)", body)
        if not query or not as_of:
            raise RuntimeError(f"Missing query or as_of for case {case}")

        case_dir = args.output / case
        case_dir.mkdir()
        (case_dir / "query.txt").write_text(query.group(1).strip() + "\n")
        files = []
        for file_match in re.finditer(
            r"^- `([^`]+)`\s*\n\n```[^\n]*\n(.*?)\n```",
            body,
            re.MULTILINE | re.DOTALL,
        ):
            relative, content = file_match.group(1), file_match.group(2) + "\n"
            destination = case_dir / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
            files.append(relative)
        if not files:
            raise RuntimeError(f"No fixtures found for case {case}")
        metadata.append(
            {
                "case": case,
                "title": title,
                "as_of": as_of.group(1).strip(),
                "query": query.group(1).strip(),
                "files": files,
            }
        )

    if len(metadata) != 9:
        raise RuntimeError(f"Expected 9 cases, found {len(metadata)}")
    (args.output / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n"
    )
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
