#!/usr/bin/env python3
"""Manually test Hollow OSC 52 clipboard writes and one-shot reads in a POSIX pane."""

import argparse
import base64
import binascii
from contextlib import contextmanager
import math
import os
import select
import sys
import time

try:
    import termios
    import tty
except ImportError:
    termios = tty = None


TEST_TEXT = b"clipboard-test"
READ_QUERY = b"\x1b]52;c;?\x07"
REPLY_PREFIX = b"\x1b]52;c;"
MAX_REPLY_BYTES = 128 * 1024


@contextmanager
def open_terminal(raw=False, path="/dev/tty"):
    if termios is None:
        raise RuntimeError("Run this script inside a WSL/Linux/macOS terminal pane, not PowerShell.")
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    except OSError as exc:
        raise RuntimeError("No controlling terminal; run inside a Hollow terminal pane.") from exc
    saved = None
    try:
        if raw:
            saved = termios.tcgetattr(fd)
            tty.setraw(fd, termios.TCSANOW)
        yield fd
    finally:
        try:
            if saved is not None:
                termios.tcsetattr(fd, termios.TCSANOW, saved)
        finally:
            os.close(fd)


def write_all(fd, data):
    while data:
        written = os.write(fd, data)
        if not written:
            raise RuntimeError("Terminal write failed.")
        data = data[written:]


def decode_reply(reply):
    if reply.endswith(b"\x07"):
        payload = reply[:-1]
    elif reply.endswith(b"\x1b\\"):
        payload = reply[:-2]
    else:
        raise RuntimeError("Incomplete OSC 52 reply.")
    if not payload.startswith(REPLY_PREFIX):
        raise RuntimeError("Unexpected terminal response (contents not displayed).")
    try:
        return base64.b64decode(payload[len(REPLY_PREFIX):], validate=True)
    except binascii.Error as exc:
        raise RuntimeError("Invalid base64 in OSC 52 reply (contents not displayed).") from exc


def query_clipboard(timeout=3.0, tty_path="/dev/tty"):
    reply = bytearray()
    with open_terminal(raw=True, path=tty_path) as fd:
        write_all(fd, READ_QUERY)
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                raise RuntimeError("Timed out: no complete OSC 52 reply. Rebuild/restart Hollow and retry.")
            byte = os.read(fd, 1)
            if not byte:
                raise RuntimeError("Terminal closed while waiting for clipboard reply.")
            if byte == b"\x03":
                raise KeyboardInterrupt
            reply.extend(byte)
            if len(reply) > MAX_REPLY_BYTES:
                raise RuntimeError("OSC 52 reply exceeded the test's size limit.")
            if reply.endswith(b"\x07") or reply.endswith(b"\x1b\\"):
                return decode_reply(bytes(reply))


def write_test_text():
    with open_terminal() as fd:
        write_all(fd, REPLY_PREFIX + base64.b64encode(TEST_TEXT) + b"\x07")
    print("Sent OSC 52 write: clipboard-test. Paste into an editor to verify.")


def read_test(timeout, expected=None):
    data = query_clipboard(timeout)
    # Never print clipboard contents: an existing approval might contain secrets.
    print(f"Received {len(data)} bytes; matches test text: {data == TEST_TEXT}")
    if not data:
        print("Empty reply: denied or an empty clipboard snapshot.")
    if expected == "denied" and data:
        print("FAIL: expected empty reply. Revoke existing approval and retry.")
        return False
    if expected == "test-text" and data != TEST_TEXT:
        print("FAIL: expected clipboard-test. Approve after setting test text, then retry within 30 seconds.")
        return False
    if expected:
        print("PASS")
    return True


def demo(timeout):
    print("Run inside a rebuilt/restarted Hollow WSL/Linux/macOS terminal pane.")
    print("This walkthrough replaces your clipboard with harmless test text.")
    if input("Continue? [y/N] ").strip().lower() not in ("y", "yes"):
        print("Cancelled; clipboard unchanged.")
        return True
    write_test_text()
    print("\n1. Default denial (revoke any previous approval before starting).")
    if not read_test(timeout, "denied"):
        return False
    print("\n2. Hollow should automatically ask 'Allow next clipboard read?'.")
    print("Select 'Allow once' (default is Deny). The first request was already denied.")
    print("If another dialog prevented the prompt, close it and use the command palette's")
    print("'Allow next clipboard read' action in this SAME pane.")
    input("Return here and press Enter within 30 seconds, without changing panes/windows: ")
    if not read_test(timeout, "test-text"):
        return False
    print("\n3. A second read must be denied: one-shot approval was consumed.")
    if not read_test(timeout, "denied"):
        return False
    print("\nAll three checks passed. Test text remains on your clipboard.")
    print("Dismiss any further clipboard confirmation with Deny or Escape.")
    print("Extra checks: approve, then wait >30 seconds or switch panes/windows;")
    print("'python3 scripts/test_clipboard.py read --expect denied' must get an empty reply.")
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("demo", "write", "read"), default="demo")
    parser.add_argument("--expect", choices=("denied", "test-text"), help="Check a read result; sets exit status.")
    parser.add_argument("--timeout", type=float, default=3.0, help="Reply timeout in seconds (default: 3).")
    args = parser.parse_args(argv)
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    if args.expect and args.mode != "read":
        parser.error("--expect is only valid with read mode")
    try:
        if args.mode == "write":
            print("Replacing clipboard with harmless test text.")
            write_test_text()
            return 0
        if args.mode == "read":
            return 0 if read_test(args.timeout, args.expect) else 1
        return 0 if demo(args.timeout) else 1
    except (OSError, RuntimeError, EOFError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nCancelled; terminal settings restored.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
