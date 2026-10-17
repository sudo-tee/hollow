#!/usr/bin/env python3
"""Write SHA-256 manifest for bundled agent artifacts (no network access)."""
import argparse
import hashlib
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("artifacts", nargs=2, type=Path)
    args = parser.parse_args()
    records = []
    for arch, artifact in zip(("x86_64", "aarch64"), args.artifacts):
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        records.append(f"{digest}  linux-{arch}/hollow-agent\n")
    args.output.write_text("".join(records), encoding="ascii")


if __name__ == "__main__":
    main()
