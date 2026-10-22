import hashlib
import importlib.util
import pathlib
import struct
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("agent_manifest", ROOT / "scripts/agent_manifest.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


def elf(machine, *, osabi=0, elf_type=2):
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    header[7] = osabi
    struct.pack_into("<HH", header, 16, elf_type, machine)
    struct.pack_into("<H", header, 52, 64)
    return bytes(header) + b"minimal static fixture"


class AgentManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.x86 = self.root / "x86-agent"
        self.arm = self.root / "arm-agent"
        self.output = self.root / "nested" / "SHA256SUMS"
        self.x86.write_bytes(elf(62))
        self.arm.write_bytes(elf(183, osabi=3, elf_type=3))

    def tearDown(self):
        self.temp.cleanup()

    def test_manifest_has_expected_digest_and_order(self):
        module.write_manifest(self.output, (self.x86, self.arm))
        expected = (
            f"{hashlib.sha256(self.x86.read_bytes()).hexdigest()}  linux-x86_64/hollow-agent\n"
            f"{hashlib.sha256(self.arm.read_bytes()).hexdigest()}  linux-aarch64/hollow-agent\n"
        )
        self.assertEqual(self.output.read_text(encoding="ascii"), expected)

    def test_cli_manifest_keeps_agent_manifest_format_and_separate_names(self):
        module.write_manifest(self.output, (self.x86, self.arm), "hollow-cli")
        self.assertEqual(self.output.read_text(encoding="ascii"),
                         f"{hashlib.sha256(self.x86.read_bytes()).hexdigest()}  linux-x86_64/hollow-cli\n"
                         f"{hashlib.sha256(self.arm.read_bytes()).hexdigest()}  linux-aarch64/hollow-cli\n")

    def test_rejects_swapped_architectures_without_replacing_output(self):
        self.output.parent.mkdir()
        self.output.write_text("previous manifest\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "expected x86_64 ELF"):
            module.write_manifest(self.output, (self.arm, self.x86))
        self.assertEqual(self.output.read_text(encoding="ascii"), "previous manifest\n")

    def test_rejects_bad_and_truncated_headers(self):
        cases = ((b"not ELF".ljust(64, b"\0"), "not an ELF"),
                 (elf(62)[:20], "truncated ELF header"),
                 (elf(62)[:4] + b"\x01" + elf(62)[5:], "64-bit little-endian"),
                 (elf(62, osabi=9), "expected Linux ELF"),
                 (elf(183), "expected x86_64 ELF"))
        for content, message in cases:
            with self.subTest(message=message):
                self.x86.write_bytes(content)
                with self.assertRaisesRegex(ValueError, message):
                    module.write_manifest(self.output, (self.x86, self.arm))
                self.assertFalse(self.output.exists())

    def test_missing_second_artifact_leaves_existing_output_intact(self):
        self.output.parent.mkdir()
        self.output.write_text("previous manifest\n", encoding="ascii")
        with self.assertRaisesRegex(ValueError, "missing-agent: No such file"):
            module.write_manifest(self.output, (self.x86, self.root / "missing-agent"))
        self.assertEqual(self.output.read_text(encoding="ascii"), "previous manifest\n")


if __name__ == "__main__":
    unittest.main()
