#!/usr/bin/env python3
"""Record and compare deterministic renderer benchmark snapshots."""

from __future__ import annotations

import argparse
import datetime
import json
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_HISTORY = ROOT / ".bench-history" / "renderer-bench.jsonl"
WORKLOAD_FIELDS = (
    "scenario",
    "mode",
    "rows",
    "cols",
    "frames",
    "chunk_bytes",
    "input_checksum",
)
METRICS = ("median_ns", "p95_ns")


def git_value(*args: str, default: str = "unknown") -> str:
    try:
        result = subprocess.run(
            ["git", *args],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return default
    return result.stdout.strip() or default


def git_dirty() -> bool:
    return bool(git_value("status", "--porcelain", "--untracked-files=all", default=""))


def zig_version(zig: str) -> str:
    try:
        result = subprocess.run(
            [zig, "version"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return result.stdout.strip() or "unknown"


def benchmark_command(args: argparse.Namespace) -> list[str]:
    command = [args.zig, "build", "run-renderer-bench", f"-Doptimize={args.optimize}", "--"]
    if args.scenario is not None:
        command.extend(("--scenario", args.scenario))
    if args.input is not None:
        command.extend(("--input", args.input))
    if args.frames is not None:
        command.extend(("--frames", str(args.frames)))
    if args.rows is not None:
        command.extend(("--rows", str(args.rows)))
    if args.cols is not None:
        command.extend(("--cols", str(args.cols)))
    if args.chunk_bytes is not None:
        command.extend(("--chunk-bytes", str(args.chunk_bytes)))
    if args.warmup is not None:
        command.extend(("--warmup", str(args.warmup)))
    if args.iterations is not None:
        command.extend(("--iterations", str(args.iterations)))
    if args.mode is not None:
        command.extend(("--mode", args.mode))
    command.append("--json")
    return command


def parse_benchmark_output(stdout: str) -> dict[str, Any]:
    for line in reversed(stdout.splitlines()):
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and "stages" in value:
            return value
    raise RuntimeError("benchmark did not emit JSON result")


def run_benchmark(command: list[str]) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            command,
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=None,
            text=True,
        )
    except OSError as error:
        raise RuntimeError(f"failed to start benchmark: {error}") from error
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"benchmark failed with exit code {error.returncode}") from error
    return parse_benchmark_output(completed.stdout)


def make_record(result: dict[str, Any], command: list[str], zig: str) -> dict[str, Any]:
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    return {
        "recorded_at": timestamp,
        "commit": git_value("rev-parse", "HEAD"),
        "dirty": git_dirty(),
        "environment": {
            "zig": zig_version(zig),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "command": command,
        "result": result,
    }


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def append_record(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as history:
        history.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")


def unwrap(value: dict[str, Any]) -> dict[str, Any]:
    result = value.get("result")
    return result if isinstance(result, dict) else value


def load_records(path: Path) -> list[dict[str, Any]]:
    if path.suffix == ".json":
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise RuntimeError(f"invalid JSON in {path}: {error}") from error
        if not isinstance(value, dict):
            raise RuntimeError(f"expected JSON object in {path}")
        return [value]

    records: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as history:
        for line_number, line in enumerate(history, 1):
            if not line.strip():
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(f"invalid JSON in {path}:{line_number}: {error}") from error
            if not isinstance(value, dict):
                raise RuntimeError(f"expected JSON object in {path}:{line_number}")
            records.append(value)
    return records


def workload_key(result: dict[str, Any]) -> tuple[Any, ...]:
    return tuple(result.get(field) for field in WORKLOAD_FIELDS)


def latest_matching(records: list[dict[str, Any]], target: dict[str, Any]) -> dict[str, Any] | None:
    target_key = workload_key(target)
    for record in reversed(records):
        if workload_key(unwrap(record)) == target_key:
            return record
    return None


def compare_records(current: dict[str, Any], baseline: dict[str, Any], max_regression: float) -> int:
    current_result = unwrap(current)
    baseline_result = unwrap(baseline)
    if workload_key(current_result) != workload_key(baseline_result):
        raise RuntimeError("current result and baseline describe different workloads")

    failures = 0
    print("stage metric baseline current delta")
    for stage, current_stats in current_result.get("stages", {}).items():
        baseline_stats = baseline_result.get("stages", {}).get(stage)
        if not isinstance(current_stats, dict) or not isinstance(baseline_stats, dict):
            continue
        for metric in METRICS:
            baseline_value = baseline_stats.get(metric)
            current_value = current_stats.get(metric)
            if not isinstance(baseline_value, (int, float)) or not isinstance(current_value, (int, float)) or baseline_value <= 0:
                continue
            delta = current_value / baseline_value - 1.0
            print(f"{stage} {metric} {baseline_value:.0f} {current_value:.0f} {delta:+.2%}")
            if delta > max_regression:
                failures += 1

    if failures:
        print(f"regression: {failures} metric(s) exceed {max_regression:.2%}", file=sys.stderr)
        return 1
    return 0


def add_benchmark_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--optimize", default="ReleaseFast")
    parser.add_argument("--scenario", choices=("repaint", "scroll", "styled", "replay"))
    parser.add_argument("--input")
    parser.add_argument("--frames", type=int)
    parser.add_argument("--rows", type=int)
    parser.add_argument("--cols", type=int)
    parser.add_argument("--chunk-bytes", type=int)
    parser.add_argument("--warmup", type=int)
    parser.add_argument("--iterations", type=int)
    parser.add_argument("--mode", choices=("parse", "render-state", "render", "pipeline"))


def record_command(args: argparse.Namespace) -> int:
    command = benchmark_command(args)
    baseline_records = load_records(args.baseline) if args.baseline is not None else None
    result = run_benchmark(command)
    record = make_record(result, command, args.zig)
    append_record(args.history, record)
    if args.save_baseline is not None:
        write_json(args.save_baseline, record)
    if args.baseline is not None:
        baseline = latest_matching(baseline_records or [], result)
        if baseline is None:
            raise RuntimeError("baseline has no matching workload")
        status = compare_records(record, baseline, args.max_regression)
    else:
        status = 0
    print(json.dumps(result, indent=2, sort_keys=True))
    print(f"history: {args.history}")
    return status


def compare_command(args: argparse.Namespace) -> int:
    current_records = load_records(args.history)
    if not current_records:
        raise RuntimeError(f"history is empty: {args.history}")
    current = current_records[-1]
    current_result = unwrap(current)

    if args.baseline is None:
        if len(current_records) < 2:
            raise RuntimeError("need at least two snapshots when --baseline is omitted")
        baseline = latest_matching(current_records[:-1], current_result)
    else:
        baseline = latest_matching(load_records(args.baseline), current_result)
    if baseline is None:
        raise RuntimeError("no matching baseline snapshot")
    return compare_records(current, baseline, args.max_regression)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    record = subparsers.add_parser("record", help="run benchmark and append snapshot")
    record.add_argument("--history", type=Path, default=DEFAULT_HISTORY)
    record.add_argument("--baseline", type=Path)
    record.add_argument("--save-baseline", type=Path)
    record.add_argument("--max-regression", type=float, default=0.05)
    add_benchmark_options(record)
    record.set_defaults(handler=record_command)

    compare = subparsers.add_parser("compare", help="compare latest snapshot with baseline")
    compare.add_argument("--history", type=Path, default=DEFAULT_HISTORY)
    compare.add_argument("--baseline", type=Path)
    compare.add_argument("--max-regression", type=float, default=0.05)
    compare.set_defaults(handler=compare_command)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return args.handler(args)
    except (OSError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
