#!/usr/bin/env python3
"""Measure the existing framed host/agent helper over private pipes."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import select
import shlex
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELLO, INPUT, OUTPUT, RESIZE, EXIT = 1, 2, 3, 4, 5
HEADER = struct.Struct("<BI")
SENTINEL = b"\x00HOLLOW_BENCH_DONE_9d1a\x00"
READY = b"BENCH_READY\n"
ECHO_COMMAND = (
    "stty raw -echo; exec python3 -u -c "
    + shlex.quote("import os\nos.write(1,b'" + READY.decode().replace("\n", "\\n") + "')\n"
                  "buf=b''\nmarker=" + repr(SENTINEL) + "\n"
                  "while True:\n"
                  " b=os.read(0,65536)\n"
                  " if not b: break\n"
                  " buf+=b\n"
                  " i=buf.find(marker)\n"
                  " if i>=0:\n"
                  "  os.write(1,buf[:i]); break\n"
                  " if b'\\x00' not in buf: os.write(1,buf); buf=b''; continue\n"
                  " n=max(0,len(buf)-len(marker)+1)\n"
                  " if n: os.write(1,buf[:n]); buf=buf[n:]")
)


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def write_all(fd: int, data: bytes, timeout: float) -> None:
    view = memoryview(data)
    deadline = time.monotonic() + timeout
    while view:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([], [fd], [], remaining)[1]:
            raise TimeoutError("timed out writing helper protocol")
        try:
            n = os.write(fd, view)
        except BlockingIOError:
            continue
        view = view[n:]


def read_exact(proc: subprocess.Popen, count: int, deadline: float) -> bytes:
    out = bytearray()
    fd = proc.stdout.fileno()
    while len(out) < count:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            raise TimeoutError("timed out reading helper protocol")
        chunk = os.read(fd, count - len(out))
        if not chunk:
            raise RuntimeError("helper closed protocol stdout")
        out.extend(chunk)
    return bytes(out)


def frame(proc: subprocess.Popen, deadline: float) -> tuple[int, bytes]:
    kind, size = HEADER.unpack(read_exact(proc, HEADER.size, deadline))
    if size > 16 * 1024 * 1024:
        raise RuntimeError(f"unreasonable frame length: {size}")
    return kind, read_exact(proc, size, deadline)


def send(proc: subprocess.Popen, kind: int, payload: bytes = b"") -> None:
    write_all(proc.stdin.fileno(), HEADER.pack(kind, len(payload)) + payload, proc._bench_timeout)


def receive_output(proc: subprocess.Popen, count: int, deadline: float) -> bytes:
    out = bytearray()
    pending = getattr(proc, "_bench_pending", bytearray())
    if pending:
        take = min(count, len(pending))
        out.extend(pending[:take])
        del pending[:take]
        proc._bench_pending = pending
    while len(out) < count:
        kind, payload = frame(proc, deadline)
        if kind == OUTPUT:
            take = min(count - len(out), len(payload))
            out.extend(payload[:take])
            pending.extend(payload[take:])
            proc._bench_pending = pending
        elif kind == EXIT:
            raise RuntimeError(f"helper exited early: {payload!r}")
        else:
            raise RuntimeError(f"unexpected helper frame: {kind}")
    return bytes(out)


def start_helper(launcher: list[str], command: str, timeout: float) -> tuple[subprocess.Popen, int]:
    started_ns = time.monotonic_ns()
    proc = subprocess.Popen(launcher + ["--command", command, "--close-on-exit"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, bufsize=0)
    os.set_blocking(proc.stdin.fileno(), False)
    proc._bench_timeout = timeout
    try:
        kind, payload = frame(proc, time.monotonic() + timeout)
        if (kind, payload) != (HELLO, b"HWB\x01"):
            raise RuntimeError(f"invalid HELLO frame: {kind}, {payload!r}")
        send(proc, RESIZE, struct.pack("<HH", 120, 40))
        ready = bytearray()
        deadline = time.monotonic() + timeout
        while READY not in ready:
            kind, payload = frame(proc, deadline)
            if kind != OUTPUT:
                raise RuntimeError(f"unexpected frame before readiness: {kind}")
            ready.extend(payload)
            if len(ready) > 65536:
                raise RuntimeError("readiness output exceeded limit")
        return proc, time.monotonic_ns() - started_ns
    except BaseException:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        raise


def finish(proc: subprocess.Popen, timeout: float, send_sentinel: bool = True) -> None:
    if getattr(proc, "_bench_pending", b""):
        raise RuntimeError("unexpected trailing output buffered before shutdown")
    if send_sentinel:
        send(proc, INPUT, SENTINEL)
    # Child echoes only bytes preceding sentinel, then exits normally. Sentinel
    # therefore produces no output; EXIT status validates graceful completion.
    deadline = time.monotonic() + timeout
    while True:
        kind, payload = frame(proc, deadline)
        if kind == OUTPUT:
            raise RuntimeError(f"unexpected output during shutdown: {payload!r}")
        if kind != EXIT or len(payload) != 4:
            raise RuntimeError(f"invalid shutdown frame: {kind}, {payload!r}")
        status = struct.unpack("<I", payload)[0]
        break
    rc = proc.wait(timeout=timeout)
    if status != 0 or rc != 0:
        raise RuntimeError(f"nonzero helper/child status: frame={status}, process={rc}")


def run_prompt_run(launcher: list[str], timeout: float, run_index: int, samples: int) -> list[dict]:
    proc, ready_ns = start_helper(launcher, ECHO_COMMAND, timeout)
    rows = []
    try:
        for sample_index in range(samples):
            token = f"HOLLOW_BENCH_{run_index:03d}_{sample_index:06d}_{uuid.uuid4().hex}\n".encode()
            started = time.monotonic_ns()
            send(proc, INPUT, token)
            echoed = receive_output(proc, len(token), time.monotonic() + timeout)
            ended = time.monotonic_ns()
            if echoed != token:
                raise RuntimeError("echo token mismatch")
            rows.append({"run_index": run_index, "sample_index": sample_index,
                         "round_trip_ns": ended - started, "ready_ns_from_spawn": ready_ns,
                         "echo_bytes": len(token)})
        finish(proc, timeout)
        return rows
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def run_throughput(launcher: list[str], timeout: float, run_index: int, size_mib: int, direction: str) -> dict:
    size = size_mib * 1024 * 1024
    command = throughput_command(size, direction)
    proc, _ = start_helper(launcher, command, timeout)
    chunk = bytes(range(256)) * 256
    expected = hashlib.sha256()
    for _ in range(size // len(chunk)):
        expected.update(chunk)
    digest = expected.hexdigest()
    try:
        started = time.monotonic_ns()
        # Respect frame cap; output is consumed while sending to avoid pipe backpressure.
        count = 0
        received = hashlib.sha256()
        deadline = time.monotonic() + timeout
        if direction == "output":
            send(proc, INPUT, b"G")
            while count < size:
                part = receive_output(proc, min(65536, size - count), deadline)
                received.update(part)
                count += len(part)
        else:
            while count < size:
                part = chunk[:min(32768, size - count)]
                send(proc, INPUT, part)
                received.update(receive_output(proc, len(part), deadline))
                count += len(part)
            send(proc, INPUT, SENTINEL)
        finish(proc, timeout, send_sentinel=False)
        elapsed = time.monotonic_ns() - started
        actual_hash = received.hexdigest()
        if count != size or actual_hash != digest:
            raise RuntimeError(f"throughput verification failed: {count} bytes, {actual_hash}")
        return {"run_index": run_index, "direction": direction, "size_bytes": size, "verified_bytes": count,
                "sha256": actual_hash, "elapsed_ns": elapsed,
                "mib_per_second": size_mib * 1e9 / elapsed}
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def throughput_command(size: int, direction: str = "output") -> str:
    if direction == "output":
        body = (f"import os\nos.write(1,{READY!r})\n"
                "if os.read(0,1)!=b'G': raise SystemExit(2)\n"
                f"n={size}\nb=bytes(range(256))*256\n"
                "while n:\n v=memoryview(b)[:min(n,len(b))]\n"
                " while v:\n  s=os.write(1,v); n-=s; v=v[s:]\n"
                "os._exit(0)")
        return "stty raw -echo; exec python3 -u -c " + shlex.quote(body)
    body = (f"import os\nos.write(1,{READY!r})\nn={size}\nr=0\nwhile r<n:\n b=os.read(0,min(65536,n-r))\n if not b: raise SystemExit(2)\n os.write(1,b); r+=len(b)\n"
            f"s=b''\nwhile len(s)<{len(SENTINEL)}: s+=os.read(0,{len(SENTINEL)}-len(s))\n"
            f"if s != {SENTINEL!r}: raise SystemExit(3)\nos._exit(0)")
    return "stty raw -echo; exec python3 -u -c " + shlex.quote(body)


def percentile(values: list[int], pct: float) -> int:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int((len(ordered) - 1) * pct + 0.999999)))]


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="workload", required=True)
    for name in ("prompt", "throughput"):
        s = sub.add_parser(name)
        s.add_argument("--launcher-json", required=True, help="JSON argv array; supports launcher flags")
        s.add_argument("--runs", type=int, default=5)
        s.add_argument("--timeout", type=float, default=15)
        s.add_argument("--output", type=Path, default=Path("agent-bench.jsonl"))
        if name == "prompt":
            s.add_argument("--samples", type=int, default=5000, help="echo samples per independent run")
        else:
            s.add_argument("--size-mib", type=int, choices=(10, 100), default=10)
            s.add_argument("--direction", choices=("output", "echo"), default="output")
    return p


def main() -> int:
    args = build_parser().parse_args()
    launcher = json.loads(args.launcher_json)
    if not isinstance(launcher, list) or not launcher or not all(isinstance(x, str) for x in launcher):
        raise SystemExit("--launcher-json must be a non-empty JSON array of strings")
    minimum_runs = 1 if getattr(args, "samples", 5000) < 5000 else 5
    if args.runs < minimum_runs or args.timeout <= 0:
        raise SystemExit(f"--runs must be >={minimum_runs} and --timeout positive")
    if args.workload == "prompt" and args.samples < 1:
        raise SystemExit("--samples must be positive")
    source = ROOT / "src/wsl_bypass.zig"
    helper = Path(launcher[-1])
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    metadata = {"recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "run_id": str(uuid.uuid4()), "workload": args.workload,
                "machine": platform.machine(), "platform": platform.platform(),
                "python": platform.python_version(), "source_sha256": sha(source),
                "source_revision": revision,
                "build_flags": os.environ.get("HOLLOW_BENCH_BUILD_FLAGS", "unrecorded; not qualified"),
                "launcher_argv": launcher, "environment": {k: os.environ[k] for k in
                    ("WSL_DISTRO_NAME", "WSL_INTEROP", "PATH") if k in os.environ},
                "helper_executable": str(helper) if helper.is_file() else None,
                "helper_sha256": sha(helper) if helper.is_file() else None,
                "qualification": False,
                "command_template": launcher + ["--command", ECHO_COMMAND, "--close-on-exit"] if args.workload == "prompt" else launcher + ["--command", throughput_command(args.size_mib * 1024 * 1024, args.direction), "--close-on-exit"],
                "runs": args.runs, "samples_per_run": getattr(args, "samples", None)}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    summaries = []
    with args.output.open("a", encoding="utf-8") as out:
        out.write(json.dumps({"metadata": metadata}, sort_keys=True) + "\n")
        for run_index in range(args.runs):
            if args.workload == "prompt":
                samples = run_prompt_run(launcher, args.timeout, run_index, args.samples)
                for sample in samples:
                    out.write(json.dumps({**metadata, "sample": sample}, sort_keys=True) + "\n")
                values = [row["round_trip_ns"] for row in samples]
                summary = {"run_index": run_index, "samples": len(samples),
                           "p50_ns": percentile(values, .50), "p95_ns": percentile(values, .95),
                           "p99_ns": percentile(values, .99)}
            else:
                sample = run_throughput(launcher, args.timeout, run_index, args.size_mib, args.direction)
                out.write(json.dumps({**metadata, "sample": sample}, sort_keys=True) + "\n")
                summary = sample
            summaries.append(summary)
            out.write(json.dumps({**metadata, "summary": summary}, sort_keys=True) + "\n")
            out.flush()
            print(f"run {run_index + 1}/{args.runs}: {summary}", file=sys.stderr)
        if args.workload == "prompt":
            # Summaries retain per-run percentiles; raw samples remain JSONL.
            out.write(json.dumps({**metadata, "aggregate": {"run_summaries": summaries}}, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, TimeoutError, ValueError) as exc:
        print(f"agent-bench: {exc}", file=sys.stderr)
        raise SystemExit(2)
