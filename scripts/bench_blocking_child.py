#!/usr/bin/env python3
"""Write a fixed payload to stdout while recording progress and throughput.

Runs inside the target pane for the bypass-blocking bench mode: keeps producing
output so a stalled relay is visible as missing progress.

Usage:
    bench_blocking_child.py RESULT_PATH READY_PATH [CHUNKS]
"""

import os
import sys
import time

result_path, ready_path = sys.argv[1:3]
chunks = int(sys.argv[3]) if len(sys.argv) > 3 else 1024
payload = (b"blocking-relay-output-" * 1024)[:16384]

with open(ready_path, "w", encoding="ascii") as ready:
    ready.write("ready\n")

started = time.perf_counter()
written = 0
for index in range(chunks):
    offset = 0
    while offset < len(payload):
        offset += os.write(sys.stdout.fileno(), payload[offset:])
    written += len(payload)
    if index % 32 == 0:
        with open(result_path + ".progress", "w", encoding="ascii") as progress:
            progress.write(f"chunks={index + 1}/{chunks} bytes={written}\n")

elapsed = time.perf_counter() - started
with open(result_path, "w", encoding="ascii") as result:
    result.write(
        f"bypass-blocking: completed bytes={written} elapsed={elapsed:.2f}s "
        f"throughput={written / max(elapsed, 1e-9) / (1024 * 1024):.1f}MiB/s\n"
    )