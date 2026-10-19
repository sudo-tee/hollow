import copy
import hashlib
import json
import os
import pathlib
import sys
import subprocess
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_pty_bench import parse_focus_profiles, parse_queue_profiles, percentile, stderr_text, validate


class AgentPtyBenchTests(unittest.TestCase):
    def focus_profile(self):
        event = {"sequence": 1, "group": 7, "stream": 2, "dispatch_ns": 10, "ready_ns": 12,
                 "enqueue_ns": 15, "payload_begin": 122, "payload_end": 132,
                 "first_write_ns": 20, "complete_write_ns": None, "stop": None}
        return {"schema": 1, "queued_wire_bytes": 140, "written_wire_bytes": 123,
                "consumed_wire_bytes": 123, "discarded_wire_bytes": 0,
                "focus": {"schema": 1, "capacity": 64, "accepted": 1, "dropped": 0, "events": [event]}}

    def test_focus_parser_preserves_partial_payload_pending_and_censored_records(self):
        profile = self.focus_profile()
        self.assertEqual(parse_focus_profiles("AGENT_FOCUS_PROFILE " + json.dumps(profile)), [profile])
        event = profile["focus"]["events"][0]
        event["stop"] = "discarded"
        self.assertIsNone(parse_focus_profiles("AGENT_FOCUS_PROFILE " + json.dumps(profile))[0]["focus"]["events"][0]["complete_write_ns"])
        event.update(ready_ns=None, enqueue_ns=None, payload_begin=None, payload_end=None, first_write_ns=None, stop="released")
        self.assertEqual(parse_focus_profiles("AGENT_FOCUS_PROFILE " + json.dumps(profile)), [profile])
        self.assertEqual(parse_focus_profiles("AGENT_QUEUE_PROFILE {}"), [])

    def test_focus_parser_rejects_corrupt_identity_timestamps_offsets_and_false_completions(self):
        for update in ({"sequence": 0}, {"group": 0}, {"stream": 3}, {"ready_ns": 9}, {"enqueue_ns": None},
                       {"first_write_ns": 14}, {"complete_write_ns": 21}, {"payload_begin": 123},
                       {"payload_end": 141}, {"stop": "superseded"}, {"stop": "invented"}):
            profile = self.focus_profile()
            profile["focus"]["events"][0].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):
                parse_focus_profiles("AGENT_FOCUS_PROFILE " + json.dumps(profile))
        for update in ({"schema": True}, {"capacity": 65}, {"accepted": 2}, {"dropped": 1}):
            profile = self.focus_profile()
            profile["focus"].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):
                parse_focus_profiles("AGENT_FOCUS_PROFILE " + json.dumps(profile))

    def test_focus_parser_accepts_bounded_overflow_and_unenqueued_supersession(self):
        profile = self.focus_profile()
        event = profile["focus"]["events"][0]
        event.update(ready_ns=None, enqueue_ns=None, payload_begin=None, payload_end=None,
                     first_write_ns=None, stop="superseded")
        profile["focus"].update(accepted=65, dropped=1, events=[dict(event, sequence=index + 1) for index in range(64)])
        self.assertEqual(parse_focus_profiles("AGENT_FOCUS_PROFILE " + json.dumps(profile)), [profile])

    def test_focus_refresh_identity_and_exact_sequence_count(self):
        config, result = self.prompt()
        config.update(backend="shared", focus_scheduler=True, focus_every=16)
        result.update(backend="shared", focus_scheduler=True, focus_ack_ns=1, focus_every=16,
                      focus_refreshes=[{"sequence": index + 2, "before_prompt_index": prompt, "ack_ns": 42}
                                       for index, prompt in enumerate((0, 16, 32))])
        self.assertEqual(len(validate(result, config)["focus_refreshes"]), 3)
        for update in ({"focus_every": True}, {"focus_every": 0}, {"focus_refreshes": []},
                       {"focus_refreshes": [{"sequence": 1, "before_prompt_index": 0, "ack_ns": 0}] * 3}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate(dict(result, **update), config)

    def test_focus_identity_requires_shared_negotiation_and_ack(self):
        config, result = self.prompt()
        config.update(backend="shared", focus_scheduler=True)
        result.update(backend="shared", focus_scheduler=True, focus_ack_ns=42)
        self.assertEqual(validate(result, config)["focus_ack_ns"], 42)
        for update in ({"focus_scheduler": False}, {"focus_scheduler": 1}, {"focus_ack_ns": None},
                       {"focus_ack_ns": 0}, {"focus_ack_ns": True}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate(dict(result, **update), config)
        with self.assertRaises(ValueError):
            validate(result, dict(config, backend="agent"))
        with self.assertRaises(ValueError):
            validate(dict(result, focus_scheduler=False), dict(config, focus_scheduler=False))

    def test_focus_cli_rejects_nonshared_backend(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "agent_pty_bench.py"
        env = dict(os.environ)
        env.pop("HOLLOW_AGENT_QUEUE_PROFILE", None)
        result = subprocess.run([sys.executable, str(script), "--focus-scheduler", "--output", "/nonexistent/output"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --backend shared", result.stderr)

    def queue_profile(self):
        def samples():
            return {"count": 0, "sum": 0, "max": 0, "log2": [0] * 64}
        return {"schema": 1,
                "class_order": ["other", "pty_data", "exec_data", "filesystem_reply", "pty_input_ack", "pty_resize_ack", "pty_close_ack"],
                "request_order": ["pty_input", "pty_resize", "pty_close", "exec", "filesystem"],
                "classes": [{"enqueued": 0, "untracked": 0, "discarded": 0, "bytes_ahead": samples(),
                             "first_write_ns": samples(), "complete_write_ns": samples()} for _ in range(7)],
                "request_handler_ns": [samples() for _ in range(5)],
                "dispatch_ns": samples(), "poll_ns": samples(), "poll_with_complete_command_ns": samples(),
                "pending": 0, "max_pending": 0, "queued_wire_bytes": 0,
                "written_wire_bytes": 0, "discarded_wire_bytes": 0}

    def test_queue_profile_parser_keeps_pending_and_untracked_censoring(self):
        profile = self.queue_profile()
        stats = profile["classes"][4]
        stats.update(enqueued=2, untracked=1)
        stats["bytes_ahead"].update(count=2)
        stats["bytes_ahead"]["log2"][0] = 2
        profile.update(pending=1, max_pending=1024, queued_wire_bytes=100)
        parsed = parse_queue_profiles("unrelated diagnostic\nAGENT_QUEUE_PROFILE " + json.dumps(profile) + "\n")
        self.assertEqual(parsed, [profile])
        self.assertEqual(parsed[0]["classes"][4]["complete_write_ns"]["count"], 0)
        self.assertEqual(parse_queue_profiles("AGENT_PROFILE {}\n"), [])

    def test_queue_profile_parser_rejects_malformed_or_unbounded_snapshots(self):
        for update in ({"pending": 1}, {"max_pending": 1025}, {"written_wire_bytes": 1},
                       {"classes": [None] * 7}, {"class_order": []}, {"request_handler_ns": []},
                       {"dispatch_ns": {"count": 1, "sum": 1, "max": 1, "log2": [0] * 64}}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                parse_queue_profiles("AGENT_QUEUE_PROFILE " + json.dumps(dict(self.queue_profile(), **update)))
        for value in ("{", "null", "[]"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_queue_profiles("AGENT_QUEUE_PROFILE " + value)

    def test_queue_profiling_requires_stderr_inheritance(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "agent_pty_bench.py"
        env = dict(os.environ, HOLLOW_AGENT_QUEUE_PROFILE="1")
        result = subprocess.run([sys.executable, str(script), "--output", "/nonexistent/output"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --telemetry", result.stderr)

    def test_bounded_bulk_trace_identity_and_atomic_exception_accounting(self):
        profile = self.queue_profile()
        profile.update(bounded_bulk=True, bulk_frames=2, bulk_deferred=1,
                       bulk_oversized_frames=1, bulk_max_queued_bytes=100000)
        self.assertEqual(parse_queue_profiles("AGENT_QUEUE_PROFILE " + json.dumps(profile)), [profile])
        for update in ({"bounded_bulk": 1}, {"bulk_frames": -1}, {"bulk_oversized_frames": 3},
                       {"bulk_max_queued_bytes": 4194305}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                parse_queue_profiles("AGENT_QUEUE_PROFILE " + json.dumps(dict(profile, **update)))

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

    def test_bulk_progress_histograms_and_resize_counts_are_checked(self):
        config, result = self.prompt()
        config.update(backend="shared", bulk="mixed", bulk_exec_bytes=524288, resize_every=8)
        histogram = [0] * 64
        histogram[10] = 2
        timing = {"count": 2, "total_ns": 3000, "max_ns": 1500, "ns_log2": histogram}
        result.update(backend="shared", bulk="mixed", bulk_lane="shared", resize_every=8, resizes_issued=5,
                      bulk_stats={"fs": timing, "exec": timing, "fs_bytes": 32768, "exec_bytes": 1048576})
        validate(copy.deepcopy(result), config)
        for update in ({"bulk_lane": "separate_agent"}, {"resizes_issued": 4},
                       {"bulk_stats": dict(result["bulk_stats"], fs_bytes=1)},
                       {"bulk_stats": dict(result["bulk_stats"], exec=dict(timing, count=0))},
                       {"bulk_stats": dict(result["bulk_stats"], fs=dict(timing, ns_log2=[]))}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate(dict(result, **update), config)
        config["separate_bulk"] = True
        result.update(separate_bulk=True, bulk_lane="separate_agent")
        validate(copy.deepcopy(result), config)
        for update in ({"separate_bulk": False}, {"separate_bulk": 1}, {"bulk_lane": "shared"}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate(dict(result, **update), config)

    def test_separate_bulk_rejects_ambiguous_or_inactive_topologies_before_launch(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "agent_pty_bench.py"
        for backend, modes in (("native", ["mixed"]), ("all", ["mixed"]), ("shared", ["off"]), ("shared", ["off", "mixed"])):
            result = subprocess.run([sys.executable, str(script), "--separate-bulk", "--backend", backend,
                                     "--bulk", *modes, "--binary", "/nonexistent/benchmark", "--output", "/nonexistent/output"],
                                    capture_output=True, text=True)
            with self.subTest(backend=backend, modes=modes):
                self.assertEqual(result.returncode, 2)
                self.assertIn("--separate-bulk requires", result.stderr)

    def test_shared_bulk_does_not_silently_raise_sixteen_job_limit(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "agent_pty_bench.py"
        result = subprocess.run([sys.executable, str(script), "--backend", "shared", "--sessions", "16",
                                 "--bulk", "mixed", "--binary", "/nonexistent/benchmark", "--output", "/nonexistent/output"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("16-job limit", result.stderr)


if __name__ == "__main__":
    unittest.main()
