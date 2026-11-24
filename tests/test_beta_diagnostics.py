import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from performance_report import summarize

ROOT = Path(__file__).resolve().parents[1]


class PerformanceReportTests(unittest.TestCase):
    def report(self, events):
        return {"schema": 1, "kind": "performance", "capture_id": "fixture",
                "duration_ms": 60000, "finish_reason": "timeout", "events": events}

    def test_hang_without_recovery_survives_at_timeout(self):
        report = self.report([
            {"t_ms": 1000, "event": "main_queue.stalled", "fields": {"pending_ms": 300}},
            {"t_ms": 60000, "event": "capture.stopped",
             "fields": {"main_queue_pending_ms": 59000, "display_link_max_gap_ms": 200}},
        ])
        result = summarize(report)
        self.assertEqual(result["max_main_queue_delay_ms"], 59000)
        self.assertEqual(result["max_display_link_gap_ms"], 200)
        self.assertEqual(result["duration_seconds"], 60)

    def test_recovery_and_plugin_cost_are_separate_evidence(self):
        result = summarize(self.report([
            {"t_ms": 900, "event": "plugin.slow_span",
             "fields": {"name": "plugin.editor_customization", "elapsed_ms": 120}},
            {"t_ms": 800, "event": "main_queue.recovered", "fields": {"delay_ms": 500}},
            {"t_ms": 1000, "event": "performance.sample",
             "fields": {"memory_bytes": 128 * 1024 * 1024, "display_link_max_gap_ms": 50}},
        ]))
        self.assertEqual(result["max_main_queue_delay_ms"], 500)
        self.assertEqual(result["slow_spans"][0]["elapsed_ms"], 120)
        self.assertEqual(result["peak_memory_mib"], 128)

    def test_unknown_and_malformed_reports_are_rejected(self):
        for report in ({}, [], {"kind": "performance", "schema": 2},
                       self.report("bad"), self.report([None])):
            with self.subTest(report=report), self.assertRaises(ValueError):
                summarize(report)

    def test_invalid_metrics_do_not_poison_summary(self):
        result = summarize(self.report([
            {"event": "performance.sample", "fields": {"memory_bytes": float("nan")}},
            {"event": "performance.sample", "fields": "not-a-map"},
        ]))
        self.assertEqual(result["peak_memory_mib"], 0)

    def test_capture_and_cpu_are_unknown_in_old_reports(self):
        result = summarize(self.report([]))
        self.assertIsNone(result["initial_screen_captured"])
        self.assertIsNone(result["peak_main_cpu_percent"])

    def test_new_sampling_preserves_evidence_without_counting_stall_twice(self):
        report = self.report([
            {"t_ms": 300, "event": "main_queue.stalled", "fields": {"pending_ms": 300}},
            {"t_ms": 400, "event": "main_queue.recovered", "fields": {"delay_ms": 400}},
            {"t_ms": 1000, "event": "performance.sample", "fields": {
                "main_cpu_percent": 90, "process_cpu_percent": 220}},
            {"t_ms": 2000, "event": "performance.sample", "fields": {
                "main_cpu_percent": -1, "process_cpu_percent": -1}},
            {"t_ms": 1100, "event": "screen.capture_changed", "fields": {"captured": True}},
            {"t_ms": 1200, "event": "main_thread.sample", "fields": {
                "reason": "display_delivery_gap", "pause_ms": 0.2, "frames": [{
                    "resolved": True, "image": "fixture.dylib", "uuid": "fixture",
                    "image_offset": 4096, "symbol": "work", "symbol_offset": 4}]}},
        ])
        report["environment"] = {"screen_captured": False}
        report["diagnostics_revision"] = 2
        result = summarize(report)
        self.assertEqual(result["completed_main_queue_delays_over_250ms"], 1)
        self.assertEqual(result["peak_main_cpu_percent"], 90)
        self.assertEqual(result["peak_process_cpu_percent"], 220)
        self.assertIs(result["initial_screen_captured"], False)
        self.assertIs(result["screen_capture_changes"][0]["captured"], True)
        self.assertEqual(result["sampled_code_locations"][0]["image_offset"], 4096)
        self.assertEqual(result["thread_samples"][0]["pause_ms"], 0.2)


class PerformancePolicyHostTests(unittest.TestCase):
    def test_actual_c_policy_at_deadline_and_stall_boundaries(self):
        command = json.loads(os.environ["AMPROJ_POLICY_CC"]) if os.environ.get("AMPROJ_POLICY_CC") else None
        if command is None:
            compiler = shutil.which("clang") or shutil.which("cc")
            if not compiler:
                self.skipTest("A C compiler is required for the actual policy test")
            command = [compiler]
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / ("policy.exe" if os.name == "nt" else "policy")
            subprocess.run(command + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(ROOT / "tests/performance_policy_host.c"), "-o", str(binary)], check=True,
                           capture_output=True, timeout=90)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
