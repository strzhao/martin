#!/usr/bin/env python3
import filecmp
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
DEPLOY = ROOT / "scripts/hkstock/deploy_finance.sh"


class DeployFinanceTest(unittest.TestCase):
    def test_deploys_stable_bins_and_skill_with_cmp_without_private_data(self):
        temp = Path(tempfile.mkdtemp(prefix="deploy-finance-test-"))
        try:
            profile = temp / "profile"
            user_bin = temp / "user-bin/zcode-finance"
            result = subprocess.run(
                ["bash", str(DEPLOY)],
                env={**os.environ, "HKSTOCK_PROFILE_DIR": str(profile), "ZCODE_FINANCE_BIN": str(user_bin)},
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(filecmp.cmp(ROOT / "scripts/finance/zcode-mcp-bridge.mjs", profile / "bin/zcode-finance", shallow=False))
            self.assertTrue(filecmp.cmp(ROOT / "scripts/finance/zcode-mcp-bridge.mjs", user_bin, shallow=False))
            self.assertTrue(filecmp.cmp(ROOT / "scripts/hkstock/research_guard.py", profile / "bin/research_guard.py", shallow=False))
            comparison = filecmp.dircmp(ROOT / "deploy/hkstock/morning-brief", profile / "skills/morning-brief")
            self.assertEqual(comparison.left_only, [])
            self.assertEqual(comparison.right_only, [])
            self.assertEqual(comparison.diff_files, [])
            self.assertFalse((profile / "hkstock-data").exists())
            self.assertIn("CMP_OK", result.stdout)
        finally:
            shutil.rmtree(temp)


if __name__ == "__main__":
    unittest.main()
