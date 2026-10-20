#!/usr/bin/env python3
"""Smoke native pane-adapter diagnostics against the freshly built agent."""
import json
import os
import subprocess
import unittest


class PaneBenchTests(unittest.TestCase):
    def test_counts_startups_connections_bytes_and_queue_bounds(self):
        bench = os.environ["HOLLOW_TEST_PANE_BENCH"]
        agent = os.environ["HOLLOW_TEST_AGENT"]
        for mode in ("pty", "mux"):
            for frame_us in (0, 16667):
                with self.subTest(mode=mode, frame_us=frame_us):
                    result = subprocess.run(
                        [bench, agent, mode, "2", "131072", str(frame_us), "0"],
                        env=dict(os.environ, HOLLOW_PANE_BENCH_ECHO_SAMPLES="0", HOLLOW_PANE_BENCH_READ_CHUNK="65536", HOLLOW_PANE_BENCH_DRAIN_BYTES="16384"),
                        capture_output=True, text=True, check=True, timeout=15,
                    )
                    row = json.loads(result.stdout)
                    self.assertEqual(row["received"], [131072, 131072])
                    self.assertEqual(len(row["startup_ms"]), 2)
                    self.assertTrue(all(value > 0 for value in row["startup_ms"]))
                    self.assertEqual(row["connections"], 1 if mode == "mux" else 2)
                    self.assertLessEqual(row["queue_high_water"], 4 * 1024 * 1024)
                    self.assertLessEqual(row["mux_output_reservation_high_water"], 16 * 1024 * 1024)
                    self.assertGreater(row["mib_per_second"], 0)

    def test_backlog_echo_counts_actual_samples_and_each_flood(self):
        for mode in ("pty", "mux"):
            for frame_us in (0, 16667):
                with self.subTest(mode=mode, frame_us=frame_us):
                    result = subprocess.run(
                        [os.environ["HOLLOW_TEST_PANE_BENCH"], os.environ["HOLLOW_TEST_AGENT"],
                         mode, "4", "131072", str(frame_us), "0"],
                        env=dict(os.environ, HOLLOW_PANE_BENCH_ECHO_SAMPLES="20",
                                 HOLLOW_PANE_BENCH_READ_CHUNK="4096", HOLLOW_PANE_BENCH_DRAIN_BYTES="16384"),
                        capture_output=True, text=True, check=True, timeout=15,
                    )
                    row = json.loads(result.stdout)
                    self.assertEqual(row["samples"], 20)
                    self.assertEqual(len(row["flood_bytes"]), 3)
                    self.assertTrue(all(value > 0 for value in row["flood_bytes"]))
                    self.assertEqual(row["read_chunk"], 4096)
                    self.assertEqual(row["connections"], 1 if mode == "mux" else 4)
                    self.assertGreater(row["echo_ms"]["p50"], 0)
                    self.assertLessEqual(row["echo_ms"]["p50"], row["echo_ms"]["p95"])
                    self.assertLessEqual(row["echo_ms"]["p95"], row["echo_ms"]["p99"])
                    self.assertLessEqual(row["echo_ms"]["p99"], row["echo_ms"]["max"])
                    self.assertLessEqual(row["queue_high_water"], 4 * 1024 * 1024)
                    self.assertLessEqual(row["mux_output_reservation_high_water"], 16 * 1024 * 1024)
                    if mode == "mux":
                        # Real consumption can notify; empty focus polling cannot.
                        max_notifications = 40 + row["drain_turns"] * 3 * 4 + 16
                        self.assertLessEqual(row["ui_notifications"], max_notifications)


if __name__ == "__main__":
    unittest.main(verbosity=2)
