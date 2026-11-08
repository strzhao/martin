#!/usr/bin/env python3
"""One-shot, read-only migration of legacy ZCode A-share artifacts into hkstock-data."""

import argparse
import datetime as dt
import hashlib
import os
from pathlib import Path

LEGACY_FILES = [
    "out/a-share-position-plan.md",
    "out/a-share-rulebook.md",
    "out/a-share-trade-log.md",
    "out/a-share-market-ledger.md",
]
WORKFLOW = ".zcode/workflow-drafts/A股建仓方案调研与设计.dwf.ts"
PROFILE_MARKER = "<!-- A_SHARE_LEGACY_MIGRATION -->"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temp.write_text(text, encoding="utf-8")
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--date", default=dt.date.today().isoformat())
    args = parser.parse_args()
    root = args.repo_root.resolve()
    data = args.data_dir.resolve()
    paths = [root / relative for relative in LEGACY_FILES]
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        raise SystemExit(f"MIGRATION_ERROR missing legacy files: {','.join(missing)}")
    before = {path: sha256(path) for path in paths}
    workflow = root / WORKFLOW
    lines = [
        "# A 股旧工作流一次性迁移摘要",
        "",
        f"- migration_date: {args.date}",
        "- ownership: hkstock-data 是唯一实时事实源；旧文件只读归档，不持续同步。",
        "- trading: 不自动交易；实际持仓以 holdings.yaml 为准。",
        "- cutover_status: blocked_no_verified_legacy_disable_entry",
        "- cutover_boundary: 旧 ZCode 自动写账/出票入口尚无可安全验证的停用机制；本次只迁移只读快照，不宣称旧链已停用，禁止新链回写。",
        f"- workflow_readonly: {WORKFLOW}（exists={workflow.is_file()}）",
        "",
        "## 保留的规则、仓位约束与交易事实",
        "",
    ]
    for relative in LEGACY_FILES:
        path = root / relative
        lines.extend([
            f"### {relative}",
            "",
            f"- sha256: {before[path]}",
            "- disposition: 原文只读保留；以下内容仅作一次迁移快照。",
            "",
            "```markdown",
            path.read_text(encoding="utf-8").rstrip(),
            "```",
            "",
        ])
    destination = data / "migrations" / f"a-share-legacy-{args.date}.md"
    atomic_write(destination, "\n".join(lines) + "\n")

    profile = data / "investor-profile.md"
    if profile.is_file() and PROFILE_MARKER not in profile.read_text(encoding="utf-8"):
        original = profile.read_text(encoding="utf-8")
        backup = profile.with_name(f"{profile.name}.bak-before-a-share-migration-{args.date.replace('-', '')}")
        if not backup.exists():
            atomic_write(backup, original)
        addition = (
            f"\n\n{PROFILE_MARKER}\n"
            "## 旧 A 股工作流迁移约束\n"
            f"- 旧规则、仓位约束与交易事实的一次迁移快照：`migrations/{destination.name}`。\n"
            "- 旧 out/a-share-* 仅作历史证据，不是实时组合、观点或信号事实源；禁止持续同步或双写。\n"
        )
        atomic_write(profile, original.rstrip() + addition + "\n")

    after = {path: sha256(path) for path in paths}
    if before != after:
        raise SystemExit("MIGRATION_ERROR legacy source changed during migration")
    print(f"MIGRATION_OK summary={destination} legacy_files={len(paths)} source_hash_unchanged=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
