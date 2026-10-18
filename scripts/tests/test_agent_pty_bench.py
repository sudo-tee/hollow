import copy
import hashlib
import pathlib
import sys
import subprocess
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_pty_bench import percentile, stderr_text, validate


class AgentPtyBenchTests(unittest.TestCase):
    def prompt(self):
        return ({"backend": "agent", "workload": "prompt", "samples": 3},
                {"backend": "agent", "workload": "prompt", "exit_code": 0,
                 "qualification": False, "spawn_to_ready_ns": 1,
                 "samples_ns": [3000000, 1000000, 2000000]})

    def test_nearest_rank_percentiles_keep_raw_samples(self):
        config, result = self.prompt()
        samples = result["samples_ns"].copy()
        measured = validate(result, config)
        self.assertEqual(measured["samples_ns"], samples)
        self.assertEqual(measured["latency_ms"], {"p50": 2, "p95": 3, "p99": 3, "max": 3})
        self.assertEqual(percentile([8], .99), 8)

    def test_rejects_incomplete_or_invalid_prompt_samples(self):
        config, result = self.prompt()
        for samples in ([], [1, 2], [1, 2, -1], [1, 2, True], [1, 2, "3"]):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                validate(dict(result, samples_ns=samples), config)

    def test_rejects_bad_exit_identity_readiness_or_qualification(self):
        config, result = self.prompt()
        for key, value in (("exit_code", 7), ("backend", "native"), ("workload", "output"),
                           ("qualification", True), ("spawn_to_ready_ns", 0)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(dict(result, **{key: value}), config)

    def test_throughput_requires_exact_size_checksum_and_positive_time(self):
        config = {"backend": "native", "workload": "output", "bytes": 131073}
        result = {"backend": "native", "workload": "output", "exit_code": 0,
                  "qualification": False, "spawn_to_ready_ns": 1, "bytes": 131073,
                  "sha256": hashlib.sha256(bytes(131073)).hexdigest(), "elapsed_ns": 1000000000}
        measured = validate(copy.deepcopy(result), config)
        self.assertAlmostEqual(measured["mib_per_second"], 131073 / 1048576)
        for key, value in (("bytes", 131072), ("sha256", "incorrect"), ("elapsed_ns", 0)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(dict(result, **{key: value}), config)

    def test_timeout_stderr_remains_json_serializable(self):
        error = subprocess.TimeoutExpired(["fixture"], 1, stderr=b"diagnostic\xff")
        self.assertEqual(stderr_text(error), "diagnostic\ufffd")
        self.assertIsNone(stderr_text(ValueError("bad output")))

    def test_allocator_identity_and_telemetry_bounds_are_checked(self):
        config, result = self.prompt()
        config.update(allocator="debug", telemetry=True)
        with self.assertRaises(ValueError):
            validate(result, config)
        result.update(allocator="debug", telemetry={"max_pty_buffered": 65536, "max_queued_bytes": 4096})
        validate(copy.deepcopy(result), config)
        for metrics in ({"max_pty_buffered": 65537, "max_queued_bytes": 0},
                        {"max_pty_buffered": 0, "max_queued_bytes": 4194305},
                        {"max_pty_buffered": -1, "max_queued_bytes": 0}):
            with self.subTest(metrics=metrics), self.assertRaises(ValueError):
                validate(dict(result, telemetry=metrics), config)

    def test_shared_identity_and_background_progress_are_checked(self):
        config, result = self.prompt()
        config.update(backend="shared", sessions=4, load="stalled")
        result.update(backend="shared", sessions=4, load="stalled", background_bytes=[0, 10, 20],
                      background_max_gap_ns=[0, 100, 200], background_elapsed_ns=1000, stalled_buffered=65536)
        validate(copy.deepcopy(result), config)
        for update in ({"sessions": 8}, {"load": "idle"}, {"background_bytes": [0, 0, 20]},
                       {"background_bytes": [1, 10, 20]}, {"background_max_gap_ns": []},
                       {"stalled_buffered": 65537}, {"background_elapsed_ns": 0}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate(dict(result, **update), config)

    def test_single_session_noisy_only_is_not_a_successful_empty_dataset(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "agent_pty_bench.py"
        result = subprocess.run([sys.executable, str(script), "--sessions", "1", "--load", "noisy",
                                 "--binary", "/nonexistent/benchmark", "--output", "/nonexistent/output"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("no runnable cases", result.stderr)


if __name__ == "__main__":
    unittest.main()
