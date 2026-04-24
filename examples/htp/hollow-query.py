#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import select
import sys
import termios
import time
import tty
import subprocess

PREFIX = b"\x1b]1337;Hollow;"
ST = b"\x1b\\"


def next_request_id(prefix: str) -> str:
    return f"{prefix}-{os.getpid()}-{time.time_ns()}"


def build_query_frame(request_id: str, name: str, params_json: str) -> bytes:
    params = json.loads(params_json)
    payload = json.dumps(
        {
            "kind": "query",
            "id": request_id,
            "name": name,
            "params": params,
        },
        separators=(",", ":"),
    ).encode("utf-8")
    return PREFIX + payload + ST


def parse_json_frame(text: str):
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return None


def iter_frames(fd, timeout: float):
    deadline = time.monotonic() + timeout
    buf = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            return
        chunk = os.read(fd, 4096)
        if not chunk:
            return
        buf.extend(chunk)
        while True:
            start = buf.find(PREFIX)
            if start < 0:
                if len(buf) > len(PREFIX):
                    del buf[:-len(PREFIX)]
                break
            end = buf.find(ST, start + len(PREFIX))
            if end < 0:
                if start > 0:
                    del buf[:start]
                break
            payload = bytes(buf[start + len(PREFIX) : end])
            del buf[: end + len(ST)]
            yield payload.decode("utf-8", "replace")


def query_once(name: str, params_json: str, timeout: float, id_prefix: str):
    request_dir = os.environ.get("HOLLOW_REQUEST_DIR")
    transport = os.environ.get("HOLLOW_TRANSPORT", "auto")
    if not request_dir and os.environ.get("WSL_DISTRO_NAME"):
        request_dir = discover_wsl_request_dir()
    if request_dir and transport != "osc":
        try:
            return query_once_file(request_dir, name, params_json, timeout, id_prefix)
        except OSError as exc:
            if transport == "file":
                raise
            print(f"hollow_query: file transport failed ({exc}), falling back to osc", file=sys.stderr)

    request_id = next_request_id(id_prefix)
    frame = build_query_frame(request_id, name, params_json)

    fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    old = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        os.write(fd, frame)
        for text in iter_frames(fd, timeout):
            frame_json = parse_json_frame(text)
            if frame_json is None:
                continue
            if frame_json.get("request_id") == request_id and frame_json.get("kind") in {"result", "error"}:
                print(text)
                return 0
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
        os.close(fd)

    print(f"hollow_query: timed out waiting for reply to {request_id}", file=sys.stderr)
    return 1


def discover_wsl_request_dir():
    try:
        base = pathlib.Path("/mnt/c/Users")
        if not base.exists():
            return None
        candidates = sorted(base.glob("*/AppData/Local/hollow/htp-requests"), key=lambda p: p.stat().st_mtime, reverse=True)
        for path in candidates:
            if path.is_dir():
                return str(path)
    except OSError:
        pass
    return None


def query_once_file(request_dir: str, name: str, params_json: str, timeout: float, id_prefix: str):
    request_id = next_request_id(id_prefix)
    request_root = pathlib.Path(request_dir)
    request_root.mkdir(parents=True, exist_ok=True)
    request_path = request_root / f"{request_id}.request.json"
    reply_path = request_root / f"{request_id}.reply.json"
    if reply_path.exists():
        reply_path.unlink()
    payload = {
        "pane_id": int(os.environ.get("HOLLOW_PANE_ID", "0")),
        "name": name,
        "params": json.loads(params_json),
        "reply_file": str(reply_path),
    }
    request_path.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if reply_path.exists():
            text = reply_path.read_text(encoding="utf-8")
            try:
                reply_path.unlink()
            except OSError:
                pass
            print(text)
            return 0
        time.sleep(0.02)

    print(f"hollow_query: timed out waiting for file reply to {request_id}", file=sys.stderr)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("params_json", nargs="?", default="{}")
    parser.add_argument("timeout", nargs="?", type=float, default=1.5)
    parser.add_argument("--id-prefix", default="hollowq")
    args = parser.parse_args()
    raise SystemExit(query_once(args.name, args.params_json, args.timeout, args.id_prefix))


if __name__ == "__main__":
    main()
