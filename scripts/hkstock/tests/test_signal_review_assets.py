#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("signal_review", ROOT / "scripts/hkstock/signal_review.py")
signal_review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signal_review)


class SignalReviewAssetTest(unittest.TestCase):
    def test_daily_close_dispatches_a_share_and_hk_without_cross_call(self):
        with patch.object(signal_review, "_mktd_daily_close", return_value=[("2026-01-01", 1.0)]) as a_share, \
             patch.object(signal_review, "_hk_daily_close", return_value=[("2026-01-01", 2.0)]) as hk:
            self.assertEqual(signal_review._daily_close("a-stock", "TEST", 20), [("2026-01-01", 1.0)])
            self.assertEqual(signal_review._daily_close("hk", "TEST", 20), [("2026-01-01", 2.0)])
            self.assertEqual(signal_review._daily_close("fund", "TEST", 20), [])
            a_share.assert_called_once_with("TEST", 20)
            hk.assert_called_once_with("TEST", 20)

    def test_hk_parser_reads_akshare_json_and_sorts_without_third_party_import(self):
        response = Mock(returncode=0, stdout='proxy noise\n[["2026-01-02", 2.5], ["2026-01-01", 1.5]]\n')
        with patch.object(signal_review.os.path, "exists", return_value=True), \
             patch.object(signal_review.subprocess, "run", return_value=response) as run:
            rows = signal_review._hk_daily_close("00000", 20)
        self.assertEqual(rows, [("2026-01-01", 1.5), ("2026-01-02", 2.5)])
        self.assertEqual(run.call_args.args[0][0], signal_review.HK_PYTHON)
        self.assertIn("stock_hk_daily", run.call_args.args[0][2])
        self.assertNotIn("akshare", signal_review.__dict__)


if __name__ == "__main__":
    unittest.main()
