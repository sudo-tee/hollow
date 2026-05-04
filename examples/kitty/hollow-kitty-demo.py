#!/usr/bin/env python3
import argparse
import base64
import pathlib
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit a kitty inline PNG image")
    parser.add_argument("image", help="Path to a PNG file")
    parser.add_argument(
        "--no-response",
        action="store_true",
        help="Use q=2 so kitty tools do not wait for a response",
    )
    args = parser.parse_args()

    payload = base64.b64encode(pathlib.Path(args.image).read_bytes()).decode("ascii")
    q = "2" if args.no_response else "1"
    sys.stdout.write(f"\x1b_Ga=T,f=100,q={q};{payload}\x1b\\")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
