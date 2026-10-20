#!/usr/bin/env python3
"""Compare native AgentPty adapters, not wire clients or actual GUI rendering."""
import argparse
import json
import platform
import resource
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bench", default="zig-out/bin/hollow-agent-pane-bench")
    parser.add_argument("--agent", default="zig-out/bin/hollow-agent")
    parser.add_argument("--panes", nargs="+", type=int, default=[1, 4, 16, 32])
    parser.add_argument("--frame-us", nargs="+", type=int, default=[0, 16667])
    parser.add_argument("--bytes", type=int, default=4 * 1024 * 1024)
    parser.add_argument("--connector-delay-ms", type=int, default=0)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--build-mode", default="unspecified")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    print(json.dumps(dict(metadata=dict(
        platform=platform.platform(), build_mode=args.build_mode,
        bench=args.bench, agent=args.agent, runs=args.runs,
        scope="preinstalled agent; native pane adapter; no VT/rendering/network emulation",
    ))), flush=True)
    for panes in args.panes:
        for frame_us in args.frame_us:
            for run in range(args.runs):
                for mode in (["pty", "mux"] if run % 2 == 0 else ["mux", "pty"]):
                    before = resource.getrusage(resource.RUSAGE_CHILDREN)
                    started = time.monotonic()
                    result = subprocess.run(
                        [args.bench, args.agent, mode, str(panes), str(args.bytes),
                         str(frame_us), str(args.connector_delay_ms)],
                        capture_output=True, text=True, check=True, timeout=150,
                    )
                    after = resource.getrusage(resource.RUSAGE_CHILDREN)
                    row = json.loads(result.stdout)
                    row.update(run=run, elapsed_seconds=time.monotonic() - started,
                               child_tree_cpu_seconds=(after.ru_utime + after.ru_stime
                                                       - before.ru_utime - before.ru_stime))
                    print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
