#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-scroll}"
COUNT="${2:-4000}"

if ! command -v python3 >/dev/null 2>&1; then
	echo "bench.sh requires python3" >&2
	exit 1
fi

RATE="${3:-100}"
python3 - "$MODE" "$COUNT" "$RATE" <<'PY'
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
    singular = units[:-2] if units.endswith("es") else (units[:-1] if units.endswith("s") else units)
    return f"\n{name}: {count} {units} in {elapsed:.2f}s ({rate:.1f}/{singular}/s)\n"

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

def make_keypress_line(i, cols):
    """Build a single line of content as nvim would redraw on j/k scroll."""
    color = palette[i % len(palette)]
    num = f"{i:07d}"
    body = (" abcdefghijklmnopqrstuvwxyz0123456789" * 8)[: max(0, cols - len(num) - 1)]
    return f"{color}{num} {body}{RESET}"

def run_keypress(presses, rate_hz=100):
    """
    Simulate rapid j/k scrolling in nvim:
      - Enter alt screen, hide cursor
      - Fill viewport with initial content
      - Each 'keypress': scroll viewport up 1 line (CSI S), position cursor
        on the last content row, write the new line that scrolled into view
      - Sleep between keypresses to match rate_hz
      - Report: total keypresses, elapsed time, average and min/max inter-frame gap
    """
    interval = 1.0 / rate_hz  # target time between keypresses

    sys.stdout.write(HIDE + ALT_ON + CLEAR + HOME)
    # Fill the viewport with initial content (rows-1 lines of data, last line = status)
    content_rows = rows - 1
    for r in range(content_rows):
        sys.stdout.write(make_keypress_line(r, cols) + "\n")
    sys.stdout.flush()

    line_counter = content_rows  # next line number to write
    frame_times = []
    done = 0
    last_t = time.perf_counter()
    start = last_t

    for _ in range(presses):
        if not running:
            break

        # Scroll viewport up 1 line and write the new bottom line
        # CSI 1 S  → scroll up 1 (top line disappears, blank appears at bottom)
        # CSI <rows>;1 H → move to first column of last content row (1-indexed)
        sys.stdout.write(
            f"{CSI}1S"
            f"{CSI}{content_rows};1H"
            + make_keypress_line(line_counter, cols)
        )
        # Update status bar on final row
        sys.stdout.write(
            f"{CSI}{rows};1H"
            f"{CSI}0m"
            f"keypress bench  press={line_counter - content_rows + 1:05d}/{presses}"
            f"  size={cols}x{rows}  rate={rate_hz}hz  Ctrl-C to stop"
        )
        sys.stdout.flush()

        line_counter += 1
        now = time.perf_counter()
        elapsed_this = now - last_t
        frame_times.append(elapsed_this)
        last_t = now
        done += 1

        # pace to target rate: sleep whatever is left of the interval
        sleep_for = interval - elapsed_this
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    cleanup()

    if frame_times:
        avg_ms = (sum(frame_times) / len(frame_times)) * 1000
        min_ms = min(frame_times) * 1000
        max_ms = max(frame_times) * 1000
        p99_ms = sorted(frame_times)[int(len(frame_times) * 0.99)] * 1000
    else:
        avg_ms = min_ms = max_ms = p99_ms = 0.0

    sys.stdout.write(stat_line("keypress", elapsed, "presses", max(1, done)))
    sys.stdout.write(
        f"inter-press gap (ms):  avg={avg_ms:.2f}  min={min_ms:.2f}  "
        f"max={max_ms:.2f}  p99={p99_ms:.2f}\n"
    )
    sys.stdout.write(
        f"target rate: {rate_hz}hz  ({interval*1000:.1f}ms/press)\n"
    )

if mode == "scroll":
    run_scroll(count)
elif mode == "repaint":
    run_repaint(count)
elif mode == "keypress":
    rate = int(sys.argv[3]) if len(sys.argv) > 3 else 100
    run_keypress(count, rate_hz=rate)
else:
    sys.stderr.write("usage: ./bench.sh [scroll|repaint|keypress] [count] [rate_hz]\n")
    sys.exit(2)
PY
