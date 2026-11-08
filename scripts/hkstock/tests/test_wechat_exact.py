#!/usr/bin/env python3
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/hkstock/wechat_exact.py"


class WechatExactTest(unittest.TestCase):
    def test_normalization_is_idempotent_and_preserves_recommendation_columns(self):
        with tempfile.TemporaryDirectory(prefix="wechat-exact-test-") as directory:
            path = Path(directory) / "brief.md"
            path.write_text("""---
workflow_id: hkstock-ai-native-v1
report_id: brief-fixture
---

## 组合观点


| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |
|---|---|---|---|---|---|
| TEST | 持有 | 相对上限 10% | 现金流验证商业质量 | 现金流证伪则复盘 | [E001] |

""" + "这是一段需要按微信复制友好规则换行的中文说明。" * 80, encoding="utf-8")
            command = ["python3", str(SCRIPT), "normalize", str(path)]
            first = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            normalized = path.read_text(encoding="utf-8")
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(path.read_text(encoding="utf-8"), normalized)
            for column in ("行动", "仓位建议", "教学式原因", "改变观点的条件"):
                self.assertIn(column, normalized)
            self.assertNotIn("\n\n\n", normalized)


if __name__ == "__main__":
    unittest.main()
