#!/usr/bin/env python3

import argparse
import pathlib
import sys
import time


def default_log_path() -> pathlib.Path:
    return pathlib.Path.cwd() / "hollow.log"


def emit(text: str) -> None:
    sys.stdout.write(text)
    sys.stdout.flush()


def read_from(path: pathlib.Path, offset: int, remainder: str) -> tuple[int, str]:
    try:
        with path.open("r", encoding="utf-8", errors="replace", newline="") as f:
            f.seek(offset)
            chunk = f.read()
            offset = f.tell()
    except FileNotFoundError:
        return 0, remainder

    if not chunk:
        return offset, remainder

    text = remainder + chunk
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith(("\n", "\r")):
        remainder = lines.pop()
    else:
        remainder = ""
    for line in lines:
        emit(line)
    return offset, remainder


def follow(path: pathlib.Path, interval: float, start: str) -> int:
    offset = 0
    remainder = ""
    last_sig = None

    while True:
        try:
            stat = path.stat()
            sig = (stat.st_ino, stat.st_size, stat.st_mtime_ns)
        except FileNotFoundError:
            sig = None

        if sig is None:
            if last_sig is not None:
                offset = 0
                remainder = ""
                last_sig = None
            time.sleep(interval)
            continue

        inode, size, _mtime_ns = sig

        if last_sig is None:
            if start == "end":
                offset = size
            else:
                offset = 0
            remainder = ""
        else:
            last_inode, last_size, _last_mtime_ns = last_sig
            if inode != last_inode or size < offset or size < last_size:
                offset = 0
                remainder = ""

        offset, remainder = read_from(path, offset, remainder)
        last_sig = sig
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Poll-follow hollow.log on filesystems where tail -F is unreliable.",
    )
    parser.add_argument("path", nargs="?", default=str(default_log_path()))
    parser.add_argument(
        "--interval",
        type=float,
        default=0.2,
        help="poll interval in seconds (default: 0.2)",
    )
    parser.add_argument(
        "--start",
        choices=("end", "beginning"),
        default="end",
        help="start at end of file or replay from beginning (default: end)",
    )
    args = parser.parse_args()
    return follow(pathlib.Path(args.path), args.interval, args.start)


if __name__ == "__main__":
    raise SystemExit(main())
