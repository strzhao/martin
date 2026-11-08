#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
MIGRATE = ROOT / "scripts/hkstock/migrate_finance_runtime.py"
TARGETS = {"77d2b63aafcc", "13d88c36a30b", "a412382de9c4"}


class RuntimeMigrationTest(unittest.TestCase):
    def test_backs_up_and_changes_only_three_prompts_and_soul(self):
        temp = Path(tempfile.mkdtemp(prefix="finance-runtime-test-"))
        try:
            profile = temp / "profile"; profile.mkdir()
            (profile / "SOUL.md").write_text("old soul", encoding="utf-8")
            jobs_path = temp / "jobs.json"
            jobs = []
            for job_id in sorted(TARGETS):
                jobs.append({"id": job_id, "name": job_id, "prompt": "old", "schedule": {"expr": "keep"}, "provider": "keep-provider", "model": "keep-model", "deliver": "weixin:test-chat@im.wechat", "nested": {"keep": True}})
            jobs.append({"id": "untouched", "prompt": "do not change", "schedule": {"expr": "keep"}})
            jobs_path.write_text(json.dumps({"jobs": jobs, "updated_at": "old"}), encoding="utf-8")
            result = subprocess.run(["python3", str(MIGRATE), "--profile-dir", str(profile), "--cron-jobs", str(jobs_path), "--repo-root", "/repo", "--data-dir", "/repo/hkstock-data"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            after = json.loads(jobs_path.read_text(encoding="utf-8"))
            for before_job in jobs:
                after_job = next(job for job in after["jobs"] if job["id"] == before_job["id"])
                if before_job["id"] not in TARGETS:
                    self.assertEqual(after_job, before_job)
                    continue
                self.assertNotEqual(after_job["prompt"], "old")
                for key in ("schedule", "provider", "model", "deliver", "nested"):
                    self.assertEqual(after_job[key], before_job[key])
            morning = next(job for job in after["jobs"] if job["id"] == "77d2b63aafcc")
            self.assertIn("test-chat@im.wechat", morning["prompt"])
            self.assertIn("hkstock-ai-native-v1", morning["prompt"])
            weekly = next(job for job in after["jobs"] if job["id"] == "13d88c36a30b")
            self.assertNotIn("signal_review.py --input", weekly["prompt"])
            self.assertIn("workflow_id=hkstock-ai-native-v1", weekly["prompt"])
            self.assertIn("单 AI 研究员", (profile / "SOUL.md").read_text(encoding="utf-8"))
            self.assertTrue(list(profile.glob("SOUL.md.bak-finance-*")))
            self.assertTrue(list(temp.glob("jobs.json.bak-finance-*")))
            self.assertIn("MIGRATE_OK", result.stdout)
        finally:
            shutil.rmtree(temp)


if __name__ == "__main__":
    unittest.main()
