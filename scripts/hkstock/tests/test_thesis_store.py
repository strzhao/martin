#!/usr/bin/env python3
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
STORE = ROOT / "scripts/hkstock/thesis_store.py"


def history_block(text, revision):
    match = re.search(rf"(?ms)^### revision {revision}\s*$([\s\S]*?)(?=^### revision|\Z)", text)
    return match.group(0) if match else ""


class ThesisStoreTest(unittest.TestCase):
    def test_update_preserves_previous_history_content(self):
        with tempfile.TemporaryDirectory(prefix="thesis-store-test-") as directory:
            path = Path(directory) / "00700.HK.md"
            path.write_text("""---
workflow_id: hkstock-ai-native-v1
report_id: thesis-00700-r1
subject: 00700.HK
revision: 1
updated_at: 2026-01-01T00:00:00Z
review_after: 2026-02-01
---
## 当前观点
观望

## 关键假设
现金流覆盖资本开支。[EOld001]

## 反证与风险
现金流低于资本开支则重检。[EOld001]

## 证据
- 支持：[EOld001]

## 观点历史
### revision 1
- revision: 1
- updated_at: 2026-01-01T00:00:00Z
- conclusion: 观望
- 当时证据: [EOld001]（原始锚点保持原样）
- 触发条件: 首次建档
""", encoding="utf-8")
            before = history_block(path.read_text(encoding="utf-8"), 1)
            result = subprocess.run([
                "python3", str(STORE), "update", "--path", str(path),
                "--evidence", "ENew001", "--conclusion", "持有",
                "--trigger", "若后续现金流证伪则复盘", "--kind", "支持",
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            after_text = path.read_text(encoding="utf-8")
            # 新 revision 前允许增加一个分隔空行；旧记录的非空内容必须逐字不变。
            self.assertEqual(history_block(after_text, 1).rstrip(), before.rstrip())
            self.assertIn("### revision 2", after_text)
            self.assertIn("revision: 2", after_text)


if __name__ == "__main__":
    unittest.main()
