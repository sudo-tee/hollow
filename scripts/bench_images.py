#!/usr/bin/env python3
"""Visible Kitty image workloads for bench.sh.

These workloads emit Kitty graphics protocol traffic to stdout. Run them in
the terminal being measured; they are intentionally not headless renderer
benchmarks.
"""

import argparse
import atexit
import base64
import signal
import shutil
import sys
import time


ESC = b"\x1b"
CSI = ESC + b"["
ST = ESC + b"\\"
RESET = CSI + b"0m"
HIDE = CSI + b"?25l"
SHOW = CSI + b"?25h"
ALT_ON = CSI + b"?1049h"
ALT_OFF = CSI + b"?1049l"
CLEAR = CSI + b"2J"
HOME = CSI + b"H"

terminal_size = shutil.get_terminal_size((80, 24))
COLS = max(24, terminal_size.columns)
ROWS = max(4, terminal_size.lines)

out = sys.stdout.buffer
running = True
restored = False
bytes_written = 0
animation_ids = []


def write_bytes(data, chunk_bytes=0):
    global bytes_written
    if chunk_bytes > 0:
        for offset in range(0, len(data), chunk_bytes):
            chunk = data[offset:offset + chunk_bytes]
            out.write(chunk)
            out.flush()
            bytes_written += len(chunk)
    else:
        out.write(data)
        bytes_written += len(data)


def kitty(params, payload=b""):
    separator = b";" if payload else b""
    return ESC + b"_G" + params.encode("ascii") + separator + payload + ST


def pixels(width, height, seed):
    result = bytearray(width * height * 4)
    for y in range(height):
        for x in range(width):
            base = (seed * 31 + x * 7 + y * 13) & 0xff
            offset = (y * width + x) * 4
            result[offset:offset + 4] = bytes((
                (base + 37) & 0xff,
                (base + 113) & 0xff,
                (base + 197) & 0xff,
                180 if (x + y + seed) % 7 == 0 else 255,
            ))
    return bytes(result)


def image_command(image_id, width, height, seed, action="T", extra=(), z=0, gap_ms=None):
    params = [f"a={action}", "f=32", f"i={image_id}"]
    params.extend(extra)
    params.extend((f"s={width}", f"v={height}"))
    if action == "T":
        params.extend(("c=2", "r=2", f"z={z}", "C=1"))
    elif action == "f":
        if gap_ms is None:
            raise ValueError("animated frame requires gap_ms")
        params.append(f"z={gap_ms}")
    params.append("q=2")
    return kitty(",".join(params), base64.b64encode(pixels(width, height, seed)))


def animation_control(image_id, gap_ms=80):
    # r=1,z=N gives the root frame a gap; s=3 starts playback and v=1
    # loops forever. Without s=3 Ghostty leaves the animation stopped.
    return kitty(f"a=a,i={image_id},r=1,z={gap_ms},s=3,v=1,q=2")


def cursor(row, col):
    return CSI + f"{row};{col}H".encode("ascii")


def layout(image_count, image_size):
    cell_width = max(3, (image_size + 10) // 11)
    cell_height = max(2, (image_size + 24) // 25)
    gap_x = cell_width + 2
    gap_y = cell_height + 2
    grid_cols = max(1, (COLS - 1) // gap_x)
    grid_rows = max(1, (ROWS - 3) // gap_y)
    count = min(image_count, grid_cols * grid_rows)
    positions = [
        (1 + (index // grid_cols) * gap_y, 1 + (index % grid_cols) * gap_x)
        for index in range(count)
    ]
    return positions


def transmit_static_scene(image_count, image_size, seed, chunk_bytes, extras=True):
    positions = layout(image_count, image_size)
    for index, (row, col) in enumerate(positions):
        write_bytes(cursor(row, col) + image_command(
            index + 1,
            image_size,
            image_size,
            seed * 100 + index,
            extra=("p=1",) if index == 0 else (),
            z=(-2147483647, -1, 0)[index % 3],
        ), chunk_bytes)

    if not extras or not positions:
        return len(positions)

    # Virtual placement: Kitty resolves U+10EEEE placeholder cells into an
    # image placement. Keep it above status text on small terminals.
    virtual_id = len(positions) + 1
    virtual_row = max(1, ROWS - 2)
    write_bytes(cursor(virtual_row, 1) + image_command(
        virtual_id,
        image_size,
        image_size,
        seed * 100 + virtual_id,
        extra=("U=1",),
    ), chunk_bytes)
    placeholders = "\U0010EEEE\u0305\u0305\U0010EEEE\u0305\u030d".encode("utf-8")
    write_bytes(cursor(virtual_row, 1) + CSI + f"38;5;{virtual_id % 256}m".encode("ascii") + placeholders + CSI + b"39m", chunk_bytes)

    # Relative placement: attach child image to first fixed image.
    child_id = virtual_id + 1
    write_bytes(cursor(1, 1) + image_command(
        child_id,
        image_size,
        image_size,
        seed * 100 + child_id,
        extra=("P=1", "Q=1", "H=1", "V=1"),
        z=1,
    ), chunk_bytes)
    return len(positions) + 2


def status(name, tick, total, image_count, image_size):
    text = f" {name}  tick={tick:05d}/{total}  images={image_count}  pixels={image_size}  size={COLS}x{ROWS}  Ctrl-C to stop"
    body = text[:COLS].ljust(COLS)
    write_bytes(cursor(ROWS, 1) + CSI + b"2K" + CSI + b"38;5;250m" + body.encode("utf-8") + RESET)


def restore_terminal():
    global restored
    if restored:
        return
    restored = True
    for image_id in animation_ids:
        write_bytes(kitty(f"a=a,i={image_id},s=1,q=2"))
    write_bytes(kitty("a=d,d=A,q=2") + kitty("a=d,d=I,q=2") + RESET + SHOW + ALT_OFF)
    out.flush()


def stop(*_):
    global running
    running = False
    restore_terminal()


def report(name, done, elapsed, start_bytes):
    elapsed = max(elapsed, 1e-9)
    delta_bytes = bytes_written - start_bytes
    average_ms = (elapsed / max(done, 1)) * 1000
    sys.stdout.write(
        f"\n{name}: {done} ticks in {elapsed:.2f}s ({done / elapsed:.1f}/tick/s)"
        f" size={COLS}x{ROWS}\n"
        f"bytes: {delta_bytes} ({delta_bytes / elapsed:.0f}/s)\n"
        f"tick duration (ms): {average_ms:.2f}\n"
    )
    sys.stdout.flush()


def run_image(args):
    write_bytes(HIDE + ALT_ON + CLEAR + HOME)
    placements = transmit_static_scene(args.images, args.size, 0, args.chunk_bytes)
    status("image", 0, args.count, placements, args.size)
    out.flush()

    start = time.perf_counter()
    start_bytes = bytes_written
    done = 0
    interval = 1.0 / args.rate_hz
    for tick in range(args.count):
        if not running:
            break
        tick_start = time.perf_counter()
        # Static scene: images are transmitted once above. Only the status
        # row changes, so the visible images stay still.
        status("image", tick + 1, args.count, placements, args.size)
        out.flush()
        done += 1
        sleep_for = interval - (time.perf_counter() - tick_start)
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    restore_terminal()
    report("image", done, elapsed, start_bytes)


def run_animation(args):
    write_bytes(HIDE + ALT_ON + CLEAR + HOME)
    positions = layout(args.images, args.size)
    for index, (row, col) in enumerate(positions):
        image_id = index + 1
        animation_ids.append(image_id)
        write_bytes(cursor(row, col) + image_command(
            image_id,
            args.size,
            args.size,
            index * 100,
            extra=("p=1",) if index == 0 else (),
            z=-1 if index % 2 == 0 else 0,
        ), args.chunk_bytes)
        for frame in range(1, args.animation_frames):
            write_bytes(cursor(row, col) + image_command(
                image_id,
                args.size,
                args.size,
                index * 100 + frame,
                action="f",
                gap_ms=args.frame_delay_ms,
            ), args.chunk_bytes)
        write_bytes(animation_control(image_id, gap_ms=args.frame_delay_ms), args.chunk_bytes)

    status("image-animation", 0, args.count, len(positions), args.size)
    out.flush()
    start = time.perf_counter()
    start_bytes = bytes_written
    done = 0
    interval = 1.0 / args.rate_hz
    for tick in range(args.count):
        if not running:
            break
        tick_start = time.perf_counter()
        status("image-animation", tick + 1, args.count, len(positions), args.size)
        out.flush()
        done += 1
        sleep_for = interval - (time.perf_counter() - tick_start)
        if sleep_for > 0.0001:
            time.sleep(sleep_for)

    elapsed = time.perf_counter() - start
    restore_terminal()
    report("image-animation", done, elapsed, start_bytes)


def parse_args(mode):
    parser = argparse.ArgumentParser(prog=f"bench.sh {mode}")
    parser.add_argument("count", nargs="?", type=int, default=120, help="image redraws or animation status ticks")
    parser.add_argument("rate_hz", nargs="?", type=float, default=30.0, help="target update rate")
    parser.add_argument("images", nargs="?", type=int, default=6, help="number of images")
    parser.add_argument("size", nargs="?", type=int, default=48, help="image width and height in pixels")
    if mode == "image":
        parser.add_argument("chunk_bytes", nargs="?", type=int, default=0, help="transport write chunk size")
    else:
        parser.add_argument("animation_frames", nargs="?", type=int, default=4, help="frames per animated image")
        parser.add_argument("frame_delay_ms", nargs="?", type=int, default=80, help="animation frame delay")
        parser.add_argument("--chunk-bytes", type=int, default=0, help="transport write chunk size")
    args = parser.parse_args(sys.argv[2:])
    if mode == "image" and args.chunk_bytes < 0:
        parser.error("chunk_bytes must be non-negative")
    if mode == "image-animation" and args.chunk_bytes < 0:
        parser.error("--chunk-bytes must be non-negative")
    if args.count < 1 or args.rate_hz <= 0 or args.images < 1 or args.size < 1 or args.size > 96:
        parser.error("count, rate_hz, images must be positive; size must be 1..96")
    if mode == "image-animation" and (args.animation_frames < 2 or args.frame_delay_ms < 1):
        parser.error("animation_frames must be at least 2 and frame_delay_ms positive")
    return args


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("image", "image-animation"):
        sys.stderr.write("usage: bench_images.py image|image-animation [ARGS...]\n")
        return 2
    args = parse_args(mode)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    atexit.register(restore_terminal)
    if mode == "image":
        run_image(args)
    else:
        run_animation(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
