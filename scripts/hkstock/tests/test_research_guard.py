#!/usr/bin/env python3
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
GUARD = ROOT / "scripts/hkstock/research_guard.py"
FIXTURE_EVIDENCE = ROOT / "scripts/hkstock/tests/fixtures/research/evidence"


class ResearchGuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="research-guard-test-"))
        self.data = self.temp / "data"
        shutil.copytree(FIXTURE_EVIDENCE, self.data / "evidence")
        for name in ("briefs", "events", "theses", "reviews"):
            (self.data / name).mkdir(parents=True)
        self.env = {**os.environ, "HKSTOCK_DATA_DIR": str(self.data)}

    def tearDown(self):
        shutil.rmtree(self.temp)

    def run_guard(self, *args, env=None):
        return subprocess.run(
            ["python3", str(GUARD), *map(str, args)],
            env={**self.env, **(env or {})}, capture_output=True, text=True,
        )

    def evidence(self, evidence_id):
        return json.loads((self.data / "evidence" / f"{evidence_id}.json").read_text())

    def save_evidence(self, obj, name=None):
        path = self.data / "evidence" / f"{name or obj['id']}.json"
        path.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
        return path

    def write_thesis(self, text=None, subject="STOCK-A"):
        content = text or f"""---
workflow_id: hkstock-ai-native-v1
report_id: thesis-STOCK-A-r1
subject: {subject}
revision: 1
updated_at: 2026-01-10T09:00:00+08:00
review_after: 2026-01-15
---
# STOCK-A thesis

## 当前观点
持有；商业质量未变。[EStockA]

## 关键假设
收入质量保持稳定。

## 反证与风险
现金流持续弱于利润则重检。

## 证据
[EStockA]

## 观点历史
### revision 1
- revision: 1
- 当时证据: [EStockA]
- 触发条件: 首次建档
"""
        path = self.data / "theses" / f"{subject}.md"
        path.write_text(content, encoding="utf-8")
        return path

    def write_event(self):
        self.write_thesis()
        path = self.data / "events" / "EVT-1.md"
        path.write_text("""---
workflow_id: hkstock-ai-native-v1
report_id: event-EVT-1
event_id: EVT-1
---
# 事件深研

## 事件影响
行动：持有
教学式原因：利润质量比单季收入更重要。
触发条件：现金流连续两期恶化则重检。
仓位建议：相对上限 10%。
证据：[EStockA]
thesis：[STOCK-A thesis](../theses/STOCK-A.md)
""", encoding="utf-8")
        return path

    def valid_brief_text(self):
        return """---
workflow_id: hkstock-ai-native-v1
report_id: brief-unit-1
---
# 盘前简报

## 组合观点
| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |
|---|---|---|---|---|---|
| STOCK-A | 持有 | 相对上限 10% | 利润与现金流要一起验证 | 现金流连续两期恶化 | [EStockA] |
| STOCK-H | 观望 | 待补持仓数据 | HKD 与 CNY 不可直接比较 | 统一币种后重估 | [EStockH] |
| ETF-TEST | 持有 | 相对上限 8% | 跟踪误差比短期涨跌重要 | 跟踪质量持续下降 | [EEtf] |
| FUND-ACTIVE | 不判断 | 待补证据 | 证据冲突：经理任期口径不一致 | 核对定报原文 | [EActiveFund] |

## 证据与数据缺口
- FUND-ACTIVE：证据冲突，经理真实任期需核对定报原文。
- 持仓穿透与重叠：ETF-TEST 持有 STOCK-A，FUND-ACTIVE 持有 STOCK-H；已计入组合隐性集中度。
- [事件深研 EVT-1](../events/EVT-1.md)（仅引用摘要，不内嵌全文）。
"""

    def write_brief(self, text=None):
        self.write_event()
        path = self.data / "briefs" / "unit-brief.md"
        path.write_text(text or self.valid_brief_text(), encoding="utf-8")
        return path

    def test_evidence_accepts_anonymous_stock_hk_etf_and_active_fund(self):
        result = self.run_guard("evidence", self.data / "evidence")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS evidence", result.stdout)

    def test_evidence_rejects_missing_fields_enums_page_time_filename_and_auth(self):
        mutations = []
        missing = self.evidence("EStockA"); del missing["currency"]; mutations.append(missing)
        bad_enum = self.evidence("EStockA"); bad_enum["asset_type"] = "bond"; mutations.append(bad_enum)
        bad_page = self.evidence("EStockA"); bad_page["page"] = 0; mutations.append(bad_page)
        bad_time = self.evidence("EStockA"); bad_time["retrieved_at"] = "2026-11-01"; mutations.append(bad_time)
        auth = self.evidence("EStockA"); auth["raw_response"] = {"nested": {"authorization": "synthetic-secret"}}; mutations.append(auth)
        for key in ("oauth:bigmodel:access_token", "zcodejwttoken", "accessToken"):
            nested = self.evidence("EStockA"); nested["raw_response"] = {"nested": {key: "synthetic-nonsecret"}}; mutations.append(nested)
        for index, obj in enumerate(mutations):
            with self.subTest(index=index):
                path = self.save_evidence(obj, f"EBad{index}")
                result = self.run_guard("evidence", path)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"FAIL evidence {path} --", result.stderr)
        wrong_name = self.evidence("EStockA")
        path = self.save_evidence(wrong_name, "EWrongFilename")
        self.assertEqual(self.run_guard("evidence", path).returncode, 1)

    def test_evidence_supersedes_chain_must_be_closed_and_acyclic(self):
        old = self.evidence("EStockA"); old["id"] = "EVersion1"
        new = copy.deepcopy(old); new["id"] = "EVersion2"; new["supersedes"] = "EVersion1"
        self.save_evidence(old); self.save_evidence(new)
        self.assertEqual(self.run_guard("evidence", self.data / "evidence").returncode, 0)
        old["supersedes"] = "EVersion2"; self.save_evidence(old)
        self.assertEqual(self.run_guard("evidence", self.data / "evidence").returncode, 1)
        old["supersedes"] = "EMissing"; self.save_evidence(old)
        self.assertEqual(self.run_guard("evidence", self.data / "evidence").returncode, 1)

    def test_valid_brief_event_thesis_and_fund_penetration_pass(self):
        brief = self.write_brief()
        result = self.run_guard("brief", brief)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.run_guard("thesis", self.data / "theses").returncode, 0)

    def test_report_id_is_unique_across_product_directories(self):
        brief = self.write_brief()
        event = self.data / "events" / "EVT-1.md"
        event.write_text(event.read_text(encoding="utf-8").replace("report_id: event-EVT-1", "report_id: brief-unit-1"), encoding="utf-8")
        result = self.run_guard("brief", brief)
        self.assertEqual(result.returncode, 1)
        self.assertIn("across data root", result.stderr)

    def test_brief_requires_local_evidence_latest_version_and_no_judgment_on_gaps(self):
        text = self.valid_brief_text().replace("[EStockH]", "[EDoesNotExist]")
        self.assertEqual(self.run_guard("brief", self.write_brief(text)).returncode, 1)
        text = self.valid_brief_text().replace("| STOCK-A | 持有 |", "| STOCK-A | 买入 |").replace("利润与现金流要一起验证", "证据不足")
        self.assertEqual(self.run_guard("brief", self.write_brief(text)).returncode, 1)
        new = self.evidence("EStockA"); new["id"] = "EStockAV2"; new["supersedes"] = "EStockA"; self.save_evidence(new)
        self.assertEqual(self.run_guard("brief", self.write_brief()).returncode, 1)

    def test_brief_enforces_fallback_all_source_failure_position_and_fund_rules(self):
        text = self.valid_brief_text().replace("FUND-ACTIVE：证据冲突", "降级：原因：VIP 超时；FUND-ACTIVE：证据冲突")
        self.assertEqual(self.run_guard("brief", self.write_brief(text)).returncode, 1)
        text = self.valid_brief_text() + "\n全部源不可用，旧证据仍作为当前。\n"
        self.assertEqual(self.run_guard("brief", self.write_brief(text)).returncode, 1)
        text = self.valid_brief_text().replace("待补持仓数据 | HKD", "待补持仓数据，建议 100 元 | HKD")
        self.assertEqual(self.run_guard("brief", self.write_brief(text)).returncode, 1)
        text = self.valid_brief_text().replace("持仓穿透与重叠", "基金持仓")
        self.assertEqual(self.run_guard("brief", self.write_brief(text)).returncode, 1)

    def test_thesis_requires_sections_history_revision_and_current_latest_evidence(self):
        thesis = self.write_thesis()
        original = thesis.read_text()
        self.assertEqual(self.run_guard("thesis", thesis).returncode, 0)
        bad = original.replace("## 反证与风险", "## 风险")
        self.assertEqual(self.run_guard("thesis", self.write_thesis(bad)).returncode, 1)
        bad = original.replace("- 触发条件: 首次建档", "- 说明: 首次建档")
        self.assertEqual(self.run_guard("thesis", self.write_thesis(bad)).returncode, 1)
        new = self.evidence("EStockA"); new["id"] = "EStockAV2"; new["supersedes"] = "EStockA"; self.save_evidence(new)
        self.assertEqual(self.run_guard("thesis", thesis).returncode, 1)
        history_only = original.replace("持有；商业质量未变。[EStockA]", "持有；商业质量未变。[EStockAV2]").replace("## 证据\n[EStockA]", "## 证据\n[EStockAV2]")
        result = self.run_guard("thesis", self.write_thesis(history_only))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def valid_review(self):
        return """---
workflow_id: hkstock-ai-native-v1
report_id: review-unit-1
review_date: 2026-01-31
---
# thesis 周复盘

## 到期复盘
| 标的 | 结论 | 原假设 | 新增证据变化 |
|---|---|---|---|
| STOCK-A | 待观察 | 收入质量保持稳定 | [EStockA] 尚无新增现金流证据 |

## 证据与数据缺口
等待下一份定报。
"""

    def test_review_covers_all_due_theses_and_rejects_price_hit_rate_as_main_criterion(self):
        self.write_thesis()
        review = self.data / "reviews" / "unit.md"; review.write_text(self.valid_review(), encoding="utf-8")
        self.assertEqual(self.run_guard("review", review).returncode, 0)
        review.write_text(self.valid_review().replace("| STOCK-A |", "| OTHER |"), encoding="utf-8")
        self.assertEqual(self.run_guard("review", review).returncode, 1)
        review.write_text(self.valid_review() + "\n主判据：T+5 命中率 50%。\n", encoding="utf-8")
        self.assertEqual(self.run_guard("review", review).returncode, 1)
        review.write_text(self.valid_review().replace("| STOCK-A | 待观察 |", "| STOCK-A | 猜对 |") + "\n待观察只是其他段落的干扰词。\n", encoding="utf-8")
        self.assertEqual(self.run_guard("review", review).returncode, 1)
        review.write_text(self.valid_review().replace("| STOCK-A | 待观察 |", "| STOCK-A | 验证 |"), encoding="utf-8")
        self.assertEqual(self.run_guard("review", review).returncode, 1)

    def test_usage_errors_are_exit_two(self):
        self.assertEqual(self.run_guard().returncode, 2)
        self.assertEqual(self.run_guard("evidence", self.temp / "missing").returncode, 2)
        result = self.run_guard("unknown", self.temp)
        self.assertEqual(result.returncode, 2)
        self.assertIn("USAGE_ERROR", result.stderr)

    def test_side_effect_audit_must_be_nonempty_cover_run_and_reject_synthetic_violations(self):
        brief = self.write_brief()
        audit = self.temp / "audit.jsonl"
        run_env = {"HKSTOCK_AUDIT_LOG": str(audit), "HKSTOCK_RUN_ID": "unit-run"}
        self.assertEqual(self.run_guard("brief", brief, env=run_env).returncode, 1)
        audit.write_text('{"run_id":"other","action":"read","target":"fixture"}\n', encoding="utf-8")
        self.assertEqual(self.run_guard("brief", brief, env=run_env).returncode, 1)
        audit.write_text('{"run_id":"unit-run","action":"process_start","target":"fixture-process"}\n', encoding="utf-8")
        self.assertEqual(self.run_guard("brief", brief, env=run_env).returncode, 0)
        for action, target in (("broker_order", "STOCK-A"), ("trade", "STOCK-A"), ("cancel", "STOCK-A"), ("write", "/repo/out/a-share-trade-log.md"), ("provider_modify", "model.provider"), ("wechat_send", "fixture-chat")):
            with self.subTest(action=action, target=target):
                audit.write_text('{"run_id":"unit-run","action":"process_start","target":"fixture-process"}\n' + json.dumps({"run_id": "unit-run", "action": action, "target": target}) + "\n", encoding="utf-8")
                self.assertEqual(self.run_guard("brief", brief, env=run_env).returncode, 1)
    def test_brief_guard_hkstock_data_dir_isolates_holdings_and_failure_log(self):
        holdings = self.data / "holdings.yaml"
        holdings.write_text("""accounts:
  - name: fixture
    type: stock
    positions:
      - symbol: STOCK-A
        name: Anonymous
        qty: 1
        cost: 1
        currency: CNY
watchlist: []
""", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/hkstock/brief_guard.sh"), "--date", "2026-11-04"],
            env={**self.env, "HKSTOCK_GUARD_FAIL_SOURCE": "1"}, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        log = self.data / "logs/guard-fail.log"
        self.assertTrue(log.is_file())
        self.assertIn("HKSTOCK_GUARD_FAIL_SOURCE=1", log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
