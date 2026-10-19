#!/usr/bin/env python3
"""Diagnostic: isolate Linux PTY read scaling without Hollow/framing/credits.

Workers discard output after counting bytes. This is NOT a multiplexed backend
or a parity result: it excludes the shared transport, queues, and scheduling.
A fixed worker count services any number of PTYs (not one worker per pane).
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import errno
import json
import os
import platform
import pty
import select
import subprocess
import sys
import time
import tty


def drain(fds):
    fds = list(fds)
    count = reads = read_ns = 0
    cpu = time.thread_time()
    while fds:
        ready = select.select(fds, [], [], 5)[0]
        if not ready:
            raise TimeoutError("PTY made no progress")
        for fd in ready:
            started = time.perf_counter_ns()
            try:
                data = os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            read_ns += time.perf_counter_ns() - started
            reads += 1
            count += len(data)
            if not data:
                fds.remove(fd)
    return dict(bytes=count, reads=reads, read_seconds=read_ns / 1e9,
                cpu_seconds=time.thread_time() - cpu)


def benchmark(panes, workers, size):
    children, masters = [], []
    code = (
        "import os; os.write(1,b'READY'); os.read(0,1); "
        f"exec('left={size}\\nwhile left:\\n n=os.write(1,b\"x\"*min(left,65536)); left-=n')"
    )
    try:
        for _ in range(panes):
            master, slave = pty.openpty()
            masters.append(master)
            try:
                tty.setraw(slave)
                children.append(subprocess.Popen(
                    [sys.executable, "-c", code], stdin=slave, stdout=slave, stderr=slave,
                ))
            finally:
                os.close(slave)
            os.set_blocking(master, False)
        for master in masters:
            ready = bytearray()
            while len(ready) < 5:
                if not select.select([master], [], [], 5)[0]:
                    raise TimeoutError("child startup stalled")
                chunk = os.read(master, 5 - len(ready))
                if not chunk:
                    raise EOFError("child exited before ready")
                ready.extend(chunk)
            assert ready == b"READY"
        with ThreadPoolExecutor(max_workers=workers) as pool:
            jobs = [pool.submit(drain, masters[i::workers]) for i in range(workers)]
            started = time.perf_counter()
            for master in masters:
                os.write(master, b"g")
            results = [job.result() for job in jobs]
            elapsed = time.perf_counter() - started
        assert sum(r["bytes"] for r in results) == panes * size
        for child in children:
            assert child.wait(timeout=3) == 0
        return dict(panes=panes, workers=workers, bytes=panes * size, seconds=elapsed,
                    mib_per_second=panes * size / 2**20 / elapsed,
                    reader_cpu_seconds=sum(r["cpu_seconds"] for r in results),
                    reads=sum(r["reads"] for r in results),
                    aggregate_read_seconds=sum(r["read_seconds"] for r in results))
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
        for master in masters:
            os.close(master)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--panes", type=int, nargs="+", default=[4, 16, 32])
    parser.add_argument("--workers", type=int, nargs="+", default=[1, 2, 4])
    parser.add_argument("--bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if min(*args.panes, *args.workers, args.bytes, args.runs) < 1:
        parser.error("all counts must be positive")
    print(json.dumps(dict(metadata=dict(platform=platform.platform(), python=sys.version,
          logical_cpus=os.cpu_count(),
          scope="raw PTY drain only; no transport, flow control, fairness, or rendering"))), flush=True)
    for panes in args.panes:
        for run in range(args.runs):
            for workers in args.workers[::1 if run % 2 == 0 else -1]:
                print(json.dumps(dict(run=run, **benchmark(panes, workers, args.bytes))), flush=True)


if __name__ == "__main__":
    main()
