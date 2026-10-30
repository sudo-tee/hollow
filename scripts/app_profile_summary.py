#!/usr/bin/env python3
"""Summarize raw opt-in Hollow frame samples; nearest-rank percentiles."""
import argparse
import csv
import json
import math


def stats(values):
    values = sorted(values)
    if not values:
        return None
    def percentile(p):
        return values[max(0, math.ceil(p * len(values)) - 1)] / 1_000_000
    return {"n": len(values), "p50_ms": percentile(.50), "p95_ms": percentile(.95),
            "p99_ms": percentile(.99), "max_ms": values[-1] / 1_000_000}


def summarize(path, warmup, rendered_only, start_ns=None, end_ns=None):
    with open(path, newline="", encoding="utf-8") as f:
        header = f.readline().strip()
        if not header.startswith("# dropped="):
            raise ValueError("missing dropped sample count")
        dropped = int(header.split("=", 1)[1])
        rows = list(csv.DictReader(f))
    rows = rows[warmup:]
    if start_ns is not None:
        rows = [row for row in rows if int(row["start_ns"]) >= start_ns]
    if end_ns is not None:
        rows = [row for row in rows if int(row["start_ns"]) < end_ns]
    if rendered_only:
        rows = [row for row in rows if row["rendered"] == "1"]
    starts = [int(row["start_ns"]) for row in rows]
    return {"dropped": dropped, "selected_callbacks": len(rows),
            "wall_callback": stats([int(r["elapsed_ns"]) for r in rows]),
            "thread_cpu": stats([int(r["thread_cpu_ns"]) for r in rows if r["thread_cpu_ns"]]),
            "active_wall": stats([int(r["active_wall_ns"]) for r in rows if r.get("active_wall_ns")]),
            "selected_start_intervals": stats([b-a for a, b in zip(starts, starts[1:])])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv")
    parser.add_argument("--warmup", type=int, default=0, help="discard initial callbacks before filtering")
    parser.add_argument("--rendered-only", action="store_true")
    parser.add_argument("--metadata", help="runner metadata JSON; select its monotonic measurement phase")
    args = parser.parse_args()
    if args.warmup < 0:
        parser.error("warmup must be nonnegative")
    metadata = {}
    if args.metadata:
        with open(args.metadata, encoding="utf-8-sig") as f:
            metadata = json.load(f)
    print(json.dumps(summarize(args.csv, args.warmup, args.rendered_only,
                               metadata.get("phase_start_ns"), metadata.get("phase_end_ns")), indent=2))


if __name__ == "__main__":
    main()
