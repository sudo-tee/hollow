#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-scroll}"
COUNT="${2:-4000}"

if ! command -v python3 >/dev/null 2>&1; then
	echo "bench.sh requires python3" >&2
	exit 1
fi

python3 - "$MODE" "$COUNT" <<'PY'
import os
import shutil
import signal
import sys
import time

mode = sys.argv[1]
count = int(sys.argv[2])
cols, rows = shutil.get_terminal_size((80, 24))
rows = max(4, rows)
cols = max(20, cols)

CSI = "\x1b["
RESET = CSI + "0m"
HIDE = CSI + "?25l"
SHOW = CSI + "?25h"
ALT_ON = CSI + "?1049h"
ALT_OFF = CSI + "?1049l"
CLEAR = CSI + "2J"
HOME = CSI + "H"

running = True

def cleanup(*_):
    global running
    running = False
    try:
        sys.stdout.write(RESET + SHOW + ALT_OFF)
        sys.stdout.flush()
    except Exception:
        pass

signal.signal(signal.SIGINT, cleanup)
signal.signal(signal.SIGTERM, cleanup)

palette = [f"{CSI}38;5;{i}m" for i in range(16, 256)]

def stat_line(name, elapsed, units, count):
    rate = count / elapsed if elapsed > 0 else 0.0
    return f"\n{name}: {count} {units} in {elapsed:.2f}s ({rate:.1f}/{units[:-1] if units.endswith('s') else units}/s)\n"

def make_scroll_line(i):
    color = palette[i % len(palette)]
    num = f"{i:07d}"
    body = (" abcdefghijklmnopqrstuvwxyz0123456789" * 8)[: max(0, cols - 12)]
    return f"{color}{num}{RESET}{body}\n"

def run_scroll(lines):
    sys.stdout.write(HIDE)
    sys.stdout.flush()
    start = time.perf_counter()
    written = 0
    for i in range(lines):
        if not running:
            break
        s = make_scroll_line(i)
        sys.stdout.write(s)
        written += len(s)
        if i % 200 == 0:
            sys.stdout.flush()
    sys.stdout.flush()
    elapsed = time.perf_counter() - start
    sys.stdout.write(RESET + SHOW)
    sys.stdout.write(stat_line("scroll", elapsed, "lines", max(1, i + 1 if lines else 0)))
    sys.stdout.write(f"bytes: {written} ({written / elapsed:.0f}/s)\n")

def frame_text(frame, row):
    base = (frame * 7 + row * 13) % len(palette)
    left = palette[base]
    right = palette[(base + 40) % len(palette)]
    label = f" frame={frame:05d} row={row:03d} ".ljust(22, " ")
    fill = ("<>[]{}()##==++--" * 32)[: max(0, cols - len(label))]
    split = max(0, len(fill) // 2)
    return f"{left}{label}{right}{fill[:split]}{left}{fill[split:]}{RESET}"

def run_repaint(frames):
    sys.stdout.write(HIDE + ALT_ON + CLEAR)
    sys.stdout.flush()
    start = time.perf_counter()
    done = 0
    for frame in range(frames):
        if not running:
            break
        parts = [HOME]
        for row in range(rows - 1):
            parts.append(frame_text(frame, row))
            parts.append("\n")
        parts.append(f"{CSI}0mrepaint benchmark  frame={frame:05d}  size={cols}x{rows}  Ctrl-C to stop")
        sys.stdout.write("".join(parts))
        sys.stdout.flush()
        done = frame + 1
    elapsed = time.perf_counter() - start
    cleanup()
    sys.stdout.write(stat_line("repaint", elapsed, "frames", max(1, done)))

if mode == "scroll":
    run_scroll(count)
elif mode == "repaint":
    run_repaint(count)
else:
    sys.stderr.write("usage: ./bench.sh [scroll|repaint] [count]\n")
    sys.exit(2)
PY
