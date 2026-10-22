#!/usr/bin/env python3
"""Write SHA-256 manifest for bundled agent artifacts (no network access)."""
import argparse
import hashlib
import os
from pathlib import Path
import tempfile


EXPECTED_MACHINES = (62, 183)
CHUNK_SIZE = 512 * 1024


def _digest_linux_elf(path, architecture, machine):
    try:
        with path.open("rb") as artifact:
            header = artifact.read(64)
            if len(header) < 64:
                raise ValueError(f"{path}: truncated ELF header")
            if header[:4] != b"\x7fELF":
                raise ValueError(f"{path}: not an ELF file")
            if header[4] != 2 or header[5] != 1:
                raise ValueError(f"{path}: expected 64-bit little-endian ELF")
            if header[6] != 1 or header[7] not in (0, 3):
                raise ValueError(f"{path}: expected Linux ELF")
            elf_type = int.from_bytes(header[16:18], "little")
            elf_machine = int.from_bytes(header[18:20], "little")
            header_size = int.from_bytes(header[52:54], "little")
            if elf_type not in (2, 3) or header_size < 64:
                raise ValueError(f"{path}: invalid ELF header")
            if elf_machine != machine:
                raise ValueError(f"{path}: expected {architecture} ELF (e_machine {machine})")
            artifact.seek(0)
            digest = hashlib.sha256()
            while chunk := artifact.read(CHUNK_SIZE):
                digest.update(chunk)
            return digest.hexdigest()
    except OSError as error:
        raise ValueError(f"{path}: {error.strerror}") from None


def write_manifest(output, artifacts, name="hollow-agent"):
    output = Path(output)
    artifacts = tuple(Path(artifact) for artifact in artifacts)
    if len(artifacts) != 2:
        raise ValueError("expected x86_64 and aarch64 artifacts in that order")

    records = []
    for architecture, machine, artifact in zip(("x86_64", "aarch64"), EXPECTED_MACHINES, artifacts):
        digest = _digest_linux_elf(artifact, architecture, machine)
        records.append(f"{digest}  linux-{architecture}/{name}\n")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", dir=output.parent, delete=False) as file:
            temporary = Path(file.name)
            file.write("".join(records))
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", choices=("hollow-agent", "hollow-cli"), default="hollow-agent")
    parser.add_argument("output", type=Path)
    parser.add_argument("artifacts", nargs=2, type=Path)
    args = parser.parse_args()
    try:
        write_manifest(args.output, args.artifacts, args.name)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
