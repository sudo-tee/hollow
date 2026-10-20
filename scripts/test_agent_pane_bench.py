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


if __name__ == "__main__":
    unittest.main(verbosity=2)
