import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_pty_resources import Records, identity, parse_stat


def stat(pid=12, start=30, cpu=9, rss=4, state="S", threads=2):
    return dict(pid=pid, start_ticks=start, cpu_ticks=cpu, rss_pages=rss,
                state=state, threads=threads, ppid=1)


class ResourceTests(unittest.TestCase):
    def test_stat_handles_spaces_and_closing_parentheses_in_comm(self):
        fields = ["S", "1"] + ["0"] * 20
        for index, value in ((11, 7), (12, 2), (17, 2), (19, 30), (21, -1)):
            fields[index] = str(value)
        parsed = parse_stat("12 (name ) with spaces) " + " ".join(fields))
        self.assertEqual(parsed, stat(rss=0))

    def test_pid_reuse_monotonic_cpu_and_simultaneous_rss(self):
        records = Records()
        records.observe(stat(), 1)
        records.observe(stat(cpu=8), 2)
        records.observe(stat(start=40, cpu=3), 3)
        self.assertEqual(len(records.processes), 2)
        self.assertNotEqual(identity(stat()), identity(stat(start=40)))
        row = records.sample([stat(start=40), stat(pid=14, state="Z", rss=999)], 3, 4096)
        self.assertEqual(row["observed_cpu_ticks"], 12)
        self.assertEqual(row["summed_rss_bytes"], 16384)
        self.assertEqual(row["live_processes"], 1)
        self.assertEqual(row["zombies"], 1)
        self.assertEqual(row["threads"], 2)

    def test_capacity_loss_explicit_not_silent(self):
        records = Records(process_capacity=1, sample_capacity=1)
        self.assertTrue(records.observe(stat(), 1))
        self.assertFalse(records.observe(stat(pid=13), 2))
        records.sample([stat()], 1, 4096)
        records.sample([stat()], 2, 4096)
        self.assertEqual(records.dropped_process_observations, 1)
        self.assertEqual(records.dropped_samples, 1)
        self.assertEqual(len(records.processes), 1)
        self.assertEqual(len(records.samples), 1)

    @unittest.skipUnless(sys.platform == "linux" and hasattr(os, "pidfd_open"), "Linux pidfds required")
    def test_real_child_output_exit_sampling_and_no_overwrite(self):
        script = Path(__file__).resolve().parents[1] / "agent_pty_resources.py"
        with tempfile.TemporaryDirectory(dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None) as directory:
            output = Path(directory) / "result.json"
            command = [sys.executable, str(script), "--interval-ms", "10", "--output", str(output), "--",
                       sys.executable, "-c", "import time; print('sampled'); time.sleep(.1); raise SystemExit(7)"]
            completed = subprocess.run(command, capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 7, completed.stderr)
            result = json.loads(output.read_text())
            self.assertEqual(result["returncode"], 7)
            self.assertFalse(result["timed_out"])
            self.assertFalse(result["qualification"])
            self.assertEqual(result["cleanup_signals"], [])
            self.assertTrue(result["processes"])
            self.assertGreater(max(row["summed_rss_bytes"] for row in result["samples"]), 0)
            self.assertEqual(Path(str(output) + ".stdout").read_text(), "sampled\n")
            before = output.read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(output.read_bytes(), before)

    @unittest.skipUnless(sys.platform == "linux" and hasattr(os, "pidfd_open"), "Linux pidfds required")
    def test_discovers_child_forked_from_non_main_thread(self):
        script = Path(__file__).resolve().parents[1] / "agent_pty_resources.py"
        with tempfile.TemporaryDirectory(dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None) as directory:
            output = Path(directory) / "result.json"
            code = ("import subprocess,sys,threading; "
                    "t=threading.Thread(target=lambda: subprocess.run([sys.executable,'-c','import time; time.sleep(.3)'])); "
                    "t.start(); t.join()")
            completed = subprocess.run([sys.executable, str(script), "--interval-ms", "10", "--output", str(output),
                                        "--", sys.executable, "-c", code], capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            result = json.loads(output.read_text())
            self.assertGreaterEqual(max(row["live_processes"] for row in result["samples"]), 2)
            self.assertGreaterEqual(max(row["threads"] for row in result["samples"]), 3)
            self.assertEqual(result["cleanup_signals"], [])
            self.assertEqual(result["dropped_process_observations"], 0)

    @unittest.skipUnless(sys.platform == "linux" and hasattr(os, "pidfd_open"), "Linux pidfds required")
    def test_timeout_cleans_only_owned_process(self):
        script = Path(__file__).resolve().parents[1] / "agent_pty_resources.py"
        with tempfile.TemporaryDirectory(dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None) as directory:
            output = Path(directory) / "result.json"
            completed = subprocess.run([sys.executable, str(script), "--timeout", "1", "--output", str(output),
                                        "--", sys.executable, "-c", "import time; time.sleep(60)"],
                                       capture_output=True, timeout=10)
            self.assertEqual(completed.returncode, 124, completed.stderr)
            result = json.loads(output.read_text())
            self.assertTrue(result["timed_out"])
            self.assertTrue(result["cleanup_signals"])
            self.assertTrue(all(s["pid"] == result["root_pid"] for s in result["cleanup_signals"]))
