#!/usr/bin/env python3
"""Preserve paired native/agent adapter measurements; never claim rollout parity."""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import itertools
import json
import math
import os
import platform
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def percentile(samples: list[int], fraction: float) -> int:
    return sorted(samples)[max(0, math.ceil(len(samples) * fraction) - 1)]


def stderr_text(error: Exception) -> str | None:
    value = getattr(error, "stderr", None)
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value


def parse_queue_profiles(stderr: str) -> list[dict]:
    """Validate optional agent-side snapshots without mistaking censored spans for completions."""
    profiles = []
    classes = ["other", "pty_data", "exec_data", "filesystem_reply", "pty_input_ack", "pty_resize_ack", "pty_close_ack"]
    requests = ["pty_input", "pty_resize", "pty_close", "exec", "filesystem"]

    def integer(value):
        return type(value) is int and value >= 0

    def samples(value):
        if not isinstance(value, dict):
            raise ValueError("invalid queue profile samples")
        count, total, maximum, histogram = (value.get(k) for k in ("count", "sum", "max", "log2"))
        if (not all(integer(n) for n in (count, total, maximum)) or maximum > total
                or not isinstance(histogram, list) or len(histogram) != 64
                or not all(integer(n) for n in histogram) or sum(histogram) != count
                or (count == 0 and (total != 0 or maximum != 0))):
            raise ValueError("invalid queue profile histogram")
        return count

    for line in stderr.splitlines():
        if not line.startswith("AGENT_QUEUE_PROFILE "):
            continue
        profile = json.loads(line.removeprefix("AGENT_QUEUE_PROFILE "))
        if (not isinstance(profile, dict) or type(profile.get("schema")) is not int or profile.get("schema") != 1 or profile.get("class_order") != classes
                or profile.get("request_order") != requests
                or not isinstance(profile.get("classes"), list) or len(profile["classes"]) != len(classes)
                or not isinstance(profile.get("request_handler_ns"), list) or len(profile["request_handler_ns"]) != len(requests)):
            raise ValueError("invalid queue profile identity")
        if "bounded_bulk" in profile:
            if type(profile["bounded_bulk"]) is not bool:
                raise ValueError("invalid bounded bulk identity")
            for name in ("bulk_frames", "bulk_deferred", "bulk_oversized_frames", "bulk_max_queued_bytes"):
                if not integer(profile.get(name)):
                    raise ValueError("invalid bounded bulk counters")
            if profile["bulk_max_queued_bytes"] > 4194304 or profile["bulk_oversized_frames"] > profile["bulk_frames"]:
                raise ValueError("out-of-bounds bulk counters")
        for name in ("dispatch_ns", "poll_ns", "poll_with_complete_command_ns"):
            samples(profile.get(name))
        for timing in profile["request_handler_ns"]:
            samples(timing)
        pending = 0
        for stats in profile["classes"]:
            if not isinstance(stats, dict):
                raise ValueError("invalid queue profile class")
            enqueued, untracked, discarded = (stats.get(k) for k in ("enqueued", "untracked", "discarded"))
            if not all(integer(n) for n in (enqueued, untracked, discarded)):
                raise ValueError("invalid queue profile accounting")
            ahead = samples(stats.get("bytes_ahead"))
            first = samples(stats.get("first_write_ns"))
            complete = samples(stats.get("complete_write_ns"))
            if ahead != enqueued or not complete <= first <= enqueued - untracked or complete + discarded > enqueued - untracked:
                raise ValueError("invalid queue profile span counts")
            pending += enqueued - untracked - complete - discarded
        counters = [profile.get(k) for k in ("pending", "max_pending", "queued_wire_bytes", "written_wire_bytes", "discarded_wire_bytes")]
        if (not all(integer(n) for n in counters) or counters[0] != pending
                or not counters[0] <= counters[1] <= 1024 or counters[2] < counters[3] + counters[4]):
            raise ValueError("invalid queue profile bounded counters")
        profiles.append(profile)
    return profiles


def validate(result: dict, config: dict) -> dict:
    if (result.get("backend") != config["backend"]
            or result.get("workload") != config["workload"]
            or result.get("exit_code") != 0 or result.get("qualification") is not False
            or not isinstance(result.get("spawn_to_ready_ns"), int)
            or result["spawn_to_ready_ns"] <= 0):
        raise ValueError("benchmark identity, readiness or clean exit check failed")
    if "allocator" in config and result.get("allocator") != config["allocator"]:
        raise ValueError("benchmark allocator does not match requested allocator")
    if "sessions" in config:
        if result.get("sessions") != config["sessions"] or result.get("load") != config["load"]:
            raise ValueError("benchmark session count/load mismatch")
        counts, gaps = result.get("background_bytes"), result.get("background_max_gap_ns")
        if (not isinstance(counts, list) or not isinstance(gaps, list)
                or len(counts) != config["sessions"] - 1 or len(gaps) != len(counts)
                or any(type(n) is not int or n < 0 for n in counts + gaps)
                or type(result.get("background_elapsed_ns")) is not int or result["background_elapsed_ns"] <= 0):
            raise ValueError("invalid bounded background counters")
        for index, count in enumerate(counts):
            should_progress = config["load"] != "idle" and not (config["load"] == "stalled" and index == 0)
            if (should_progress and count == 0) or (not should_progress and count != 0):
                raise ValueError("background starvation or unexpected idle/stalled consumption")
        if config["backend"] != "native" and not 0 <= result.get("stalled_buffered", 65537) <= 65536:
            raise ValueError("stalled output exceeds per-session cap")
    if "bulk" in config:
        mode = config["bulk"]
        lane = "off" if mode == "off" else "shared" if config["backend"] == "shared" else "separate_agent"
        stats = result.get("bulk_stats")
        if result.get("bulk") != mode or result.get("bulk_lane") != lane or not isinstance(stats, dict):
            raise ValueError("bulk workload/lane identity mismatch")
        for operation, size in (("fs", 16384), ("exec", config["bulk_exec_bytes"])):
            timing = stats.get(operation, {})
            count, total, maximum = timing.get("count"), timing.get("total_ns"), timing.get("max_ns")
            histogram = timing.get("ns_log2")
            active = mode in (operation, "mixed")
            if (any(type(n) is not int or n < 0 for n in (count, total, maximum))
                    or not isinstance(histogram, list) or len(histogram) != 64
                    or any(type(n) is not int or n < 0 for n in histogram)
                    or sum(histogram) != count or stats.get(operation + "_bytes") != count * size
                    or (active and (count == 0 or total <= 0 or maximum <= 0 or maximum > total))
                    or (not active and (count != 0 or total != 0 or maximum != 0))):
                raise ValueError("bulk progress, checksum-size accounting or bounded timing counters invalid")
        every = config["resize_every"]
        expected = (config["samples"] + 31) // every + 1 if every and config["workload"] == "prompt" else 0
        if result.get("resize_every") != every or result.get("resizes_issued") != expected:
            raise ValueError("resize workload identity/count mismatch")
    if config.get("telemetry") and config["backend"] in ("agent", "shared"):
        metrics = result.get("telemetry")
        if (not isinstance(metrics, dict) or any(type(value) is not int or value < 0 for value in metrics.values())
                or metrics.get("max_pty_buffered", 65537) > 65536
                or metrics.get("max_queued_bytes", 4194305) > 4194304):
            raise ValueError("invalid or out-of-bounds transport telemetry")
    if config["workload"] == "prompt":
        samples = result.get("samples_ns")
        if (not isinstance(samples, list) or len(samples) != config["samples"]
                or any(type(item) is not int or item <= 0 for item in samples)):
            raise ValueError("invalid raw latency samples")
        result["latency_ms"] = {
            label: percentile(samples, fraction) / 1_000_000
            for label, fraction in (("p50", .50), ("p95", .95), ("p99", .99), ("max", 1.0))
        }
    else:
        digest = hashlib.sha256()
        remaining = config["bytes"]
        while remaining:
            chunk = bytes(min(remaining, 65536))
            digest.update(chunk)
            remaining -= len(chunk)
        if (result.get("bytes") != config["bytes"] or result.get("sha256") != digest.hexdigest()
                or type(result.get("elapsed_ns")) is not int or result["elapsed_ns"] <= 0):
            raise ValueError("invalid throughput size, checksum or timing")
        result["mib_per_second"] = config["bytes"] / (1024 * 1024) / (result["elapsed_ns"] / 1e9)
    return result


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/hollow-agent-pty-bench")
    parser.add_argument("--agent", type=Path, default=ROOT / "zig-out/bin/hollow-agent")
    parser.add_argument("--connector-argv", help="JSON argv for a prepared agent; no automatic bootstrap")
    parser.add_argument("--backend", choices=("both", "all", "native", "agent", "shared"), default="both")
    parser.add_argument("--sessions", type=int, nargs="+", default=[1], help="total foreground + background PTYs, 1..16")
    parser.add_argument("--load", choices=("idle", "noisy", "stalled"), nargs="+", default=["idle"])
    parser.add_argument("--bulk", choices=("off", "fs", "exec", "mixed"), nargs="+", default=["off"])
    parser.add_argument("--bulk-path", help="prepared target path containing exactly 16 KiB of zero bytes; local fixture created if omitted")
    parser.add_argument("--bulk-exec-bytes", type=int, default=524288, help="checked bytes per repeated non-PTY EXEC, 1..1048576")
    parser.add_argument("--resize-every", type=int, default=0, help="resize before every Nth prompt, including warmups; 0 disables")
    parser.add_argument("--workload", choices=("both", "prompt", "output"), default="both")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--samples", type=int, default=5000)
    parser.add_argument("--size-mib", type=int, nargs="+", default=[10])
    parser.add_argument("--timeout", type=int, default=120, help="wall deadline per subprocess, seconds")
    parser.add_argument("--allocator", choices=("page", "smp", "debug"), default="debug",
                        help="client allocator; debug matches the GUI's thread-safe DebugAllocator")
    parser.add_argument("--telemetry", action="store_true", help="enable fixed-size host I/O counters")
    parser.add_argument("--output", type=Path, required=True, help="new JSONL file; existing files are never overwritten")
    args = parser.parse_args()
    if "HOLLOW_AGENT_QUEUE_PROFILE" in os.environ and not args.telemetry:
        parser.error("HOLLOW_AGENT_QUEUE_PROFILE requires --telemetry to inherit agent stderr")
    if not (1 <= args.runs <= 100 and 1 <= args.samples <= 100000 and 1 <= args.timeout <= 3600
            and all(1 <= size <= 1024 for size in args.size_mib) and all(1 <= n <= 16 for n in args.sessions)
            and 1 <= args.bulk_exec_bytes <= 1048576 and 0 <= args.resize_every <= 100000):
        parser.error("runs/samples/timeout/size outside bounded benchmark limits")
    if all(n == 1 for n in args.sessions) and "idle" not in args.load:
        parser.error("no runnable cases: noisy/stalled load requires at least two sessions")
    binary = args.binary.resolve()
    agent = args.agent.resolve()
    connector_json = args.connector_argv or os.environ.get("HOLLOW_TEST_CONNECTOR_ARGV")
    connector = json.loads(connector_json) if connector_json else [str(agent), "stdio"]
    if (not isinstance(connector, list) or not connector
            or any(not isinstance(arg, str) or "\0" in arg for arg in connector) or not connector[0]):
        parser.error("connector must be a nonempty JSON argv array without NUL")
    backends = ["native", "agent", "shared"] if args.backend == "all" else ["native", "agent"] if args.backend == "both" else [args.backend]
    if "shared" in backends and any(n + (0 if mode == "off" else 2 if mode == "mixed" else 1) > 16
                                    for n, mode in itertools.product(args.sessions, args.bulk)):
        parser.error("shared PTYs plus bulk workers exceed the unchanged 16-job limit")
    needs_file = any(mode in ("fs", "mixed") for mode in args.bulk)
    if needs_file and connector_json and not args.bulk_path:
        parser.error("remote fs bulk requires --bulk-path to a prepared 16 KiB zero fixture")
    with contextlib.ExitStack() as resources:
        bulk_path = args.bulk_path
        if needs_file and not bulk_path:
            directory = resources.enter_context(tempfile.TemporaryDirectory(
                prefix="hollow-pty-bulk-", dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None))
            fixture = Path(directory) / "zeros"
            fixture.write_bytes(bytes(16384))
            bulk_path = str(fixture)
        run_benchmarks(args, binary, agent, connector, connector_json, backends, bulk_path)


def run_benchmarks(args, binary, agent, connector, connector_json, backends, bulk_path):
    workloads = ["prompt", "output"] if args.workload == "both" else [args.workload]
    sources = ["src/agent_pty_bench.zig", "src/pty/agent.zig", "src/pty/pty_posix.zig",
               "src/host/transport.zig", "src/agent/main.zig", "src/agent/exec.zig",
               "src/agent/supervisor.zig", "scripts/agent_pty_bench.py", "src/agent_pty_bench_bulk.zig",
               "src/host/operations.zig", "src/agent/fs.zig", "src/agent/queue_profile.zig", "src/agent/bulk_delivery.zig"]
    metadata = {
        "kind": "metadata", "schema": 1, "utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "headless PTY adapters with optional fs/exec interference; no GUI/focus policy/WSL bypass or rollout qualification",
        "bulk_fixture": {"path": bulk_path, "expected_bytes": 16384,
                         "expected_sha256": hashlib.sha256(bytes(16384)).hexdigest()} if bulk_path else None,
        "bulk_placement": "same connection for shared PTYs; separate agent for native/dedicated PTYs",
        "qualification": False, "revision": git("rev-parse", "HEAD"),
        "dirty_paths": git("status", "--short"), "source_sha256": {name: sha(ROOT / name) for name in sources},
        "binary": str(binary), "binary_sha256": sha(binary),
        "local_agent_sha256": sha(agent) if agent.exists() else None,
        "connector_argv": connector, "remote_agent_identity": "not attested" if connector_json else "local_agent_sha256",
        "platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
        "python": sys.version, "command": sys.argv, "cwd": os.getcwd(),
        "ordering": "backend order alternates each independent run",
        "environment": {key: os.environ[key] for key in ("WSL_DISTRO_NAME", "WSL_INTEROP", "HOLLOW_AGENT_PROFILE", "HOLLOW_AGENT_QUEUE_PROFILE", "HOLLOW_AGENT_BOUNDED_BULK") if key in os.environ},
    }
    with args.output.open("x", encoding="utf-8") as output:
        def emit(row: dict) -> None:
            output.write(json.dumps(row, separators=(",", ":")) + "\n")
            output.flush()

        emit(metadata)
        for run in range(args.runs):
            for sessions, load, workload, bulk in itertools.product(args.sessions, args.load, workloads, args.bulk):
                if sessions == 1 and load != "idle":
                    continue  # A noisy neighbor requires at least two sessions.
                for size in ([0] if workload == "prompt" else args.size_mib):
                    for backend in (backends if run % 2 == 0 else backends[::-1]):
                        config = {"backend": backend, "workload": workload, "samples": args.samples,
                                   "allocator": args.allocator, "telemetry": args.telemetry,
                                    "sessions": sessions, "load": load,
                                    "bulk": bulk, "bulk_path": bulk_path if bulk in ("fs", "mixed") else None,
                                    "bulk_exec_bytes": args.bulk_exec_bytes, "resize_every": args.resize_every,
                                    "bytes": size * 1024 * 1024 if size else 1,
                                    "timeout_ms": min(args.timeout, 30) * 1000,
                                   "connector_argv": connector if backend in ("agent", "shared") or bulk != "off" else []}
                        try:
                            completed = subprocess.run([str(binary), json.dumps(config)], check=True,
                                                       capture_output=True, text=True, timeout=args.timeout)
                            result = validate(json.loads(completed.stdout), config)
                            queue_profiles = parse_queue_profiles(completed.stderr)
                            if ("HOLLOW_AGENT_QUEUE_PROFILE" in os.environ and not connector_json
                                    and backend in ("agent", "shared") and not queue_profiles):
                                raise ValueError("requested agent queue profile missing")
                            if not connector_json and backend in ("agent", "shared"):
                                expected = "HOLLOW_AGENT_BOUNDED_BULK" in os.environ
                                if any(p.get("bounded_bulk", False) != expected for p in queue_profiles):
                                    raise ValueError("bounded bulk trace does not match requested local scheduler")
                        except Exception as error:
                            emit({"kind": "failure", "run": run, "config": config, "error": str(error),
                                  "stderr": stderr_text(error), "qualification": False})
                            raise
                        emit({"kind": "measurement", "run": run, "config": config,
                              "result": result, "stderr": completed.stderr, "agent_queue_profiles": queue_profiles})
                        summary = result.get("latency_ms", result.get("mib_per_second"))
                        print(f"run={run} {backend} sessions={sessions} load={load} bulk={bulk} {workload} size_mib={size}: {summary}", flush=True)


if __name__ == "__main__":
    main()
