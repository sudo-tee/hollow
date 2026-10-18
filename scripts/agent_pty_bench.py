#!/usr/bin/env python3
"""Preserve paired native/agent adapter measurements; never claim rollout parity."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import itertools
import json
import math
import os
import platform
import subprocess
import sys
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
    if not (1 <= args.runs <= 100 and 1 <= args.samples <= 100000 and 1 <= args.timeout <= 3600
            and all(1 <= size <= 1024 for size in args.size_mib) and all(1 <= n <= 16 for n in args.sessions)):
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
    workloads = ["prompt", "output"] if args.workload == "both" else [args.workload]
    sources = ["src/agent_pty_bench.zig", "src/pty/agent.zig", "src/pty/pty_posix.zig",
               "src/host/transport.zig", "src/agent/main.zig", "src/agent/exec.zig",
               "src/agent/supervisor.zig", "scripts/agent_pty_bench.py"]
    metadata = {
        "kind": "metadata", "schema": 1, "utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "scope": "headless 1..16 PTY adapters; no GUI/focus policy/fs bulk/WSL bypass or rollout qualification",
        "qualification": False, "revision": git("rev-parse", "HEAD"),
        "dirty_paths": git("status", "--short"), "source_sha256": {name: sha(ROOT / name) for name in sources},
        "binary": str(binary), "binary_sha256": sha(binary),
        "local_agent_sha256": sha(agent) if agent.exists() else None,
        "connector_argv": connector, "remote_agent_identity": "not attested" if connector_json else "local_agent_sha256",
        "platform": platform.platform(), "machine": platform.machine(), "cpu_count": os.cpu_count(),
        "python": sys.version, "command": sys.argv, "cwd": os.getcwd(),
        "ordering": "backend order alternates each independent run",
        "environment": {key: os.environ[key] for key in ("WSL_DISTRO_NAME", "WSL_INTEROP", "HOLLOW_AGENT_PROFILE") if key in os.environ},
    }
    with args.output.open("x", encoding="utf-8") as output:
        def emit(row: dict) -> None:
            output.write(json.dumps(row, separators=(",", ":")) + "\n")
            output.flush()

        emit(metadata)
        for run in range(args.runs):
            for sessions, load, workload in itertools.product(args.sessions, args.load, workloads):
                if sessions == 1 and load != "idle":
                    continue  # A noisy neighbor requires at least two sessions.
                for size in ([0] if workload == "prompt" else args.size_mib):
                    for backend in (backends if run % 2 == 0 else backends[::-1]):
                        config = {"backend": backend, "workload": workload, "samples": args.samples,
                                   "allocator": args.allocator, "telemetry": args.telemetry,
                                   "sessions": sessions, "load": load,
                                    "bytes": size * 1024 * 1024 if size else 1,
                                    "timeout_ms": min(args.timeout, 30) * 1000,
                                   "connector_argv": connector if backend in ("agent", "shared") else []}
                        try:
                            completed = subprocess.run([str(binary), json.dumps(config)], check=True,
                                                       capture_output=True, text=True, timeout=args.timeout)
                            result = validate(json.loads(completed.stdout), config)
                        except Exception as error:
                            emit({"kind": "failure", "run": run, "config": config, "error": str(error),
                                  "stderr": stderr_text(error), "qualification": False})
                            raise
                        emit({"kind": "measurement", "run": run, "config": config,
                              "result": result, "stderr": completed.stderr})
                        summary = result.get("latency_ms", result.get("mib_per_second"))
                        print(f"run={run} {backend} sessions={sessions} load={load} {workload} size_mib={size}: {summary}", flush=True)


if __name__ == "__main__":
    main()
