import hashlib
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_connectors import ConnectorError, Podman


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="hollow-connector-")
        self.addCleanup(self.directory.cleanup)
        self.artifact = pathlib.Path(self.directory.name) / "agent"
        elf = bytearray(20)
        elf[:6] = b"\x7fELF\x02\x01"
        elf[18:20] = (62).to_bytes(2, "little")
        self.artifact.write_bytes(elf)
        self.connector = Podman(str(self.artifact), container="fixture")
        self.calls = []

    def run_command(self, args, **kwargs):
        self.calls.append(args)
        output, rc = b"", 0
        if args[-2:] == ["uname", "-m"]:
            output = b"x86_64\n"
        elif args[-2:] == ["printenv", "HOME"]:
            output = b"/home/test user\n"
        elif args[:3] == ["exec", "fixture", "/bin/sh"] and "test -x" in args[-1]:
            rc = 1
        return subprocess.CompletedProcess(args, rc, output, b"")

    def test_verified_upload_precedes_atomic_install(self):
        with patch.object(self.connector, "_run", side_effect=self.run_command):
            target = self.connector.deploy()
        digest = hashlib.sha256(self.artifact.read_bytes()).hexdigest()
        self.assertEqual(target, f"/home/test user/.cache/hollow/agents/linux-x86_64/{digest}/hollow-agent")
        copy = next(i for i, call in enumerate(self.calls) if call[0] == "cp")
        verify = next(i for i, call in enumerate(self.calls) if "sha256sum -c" in call[-1] and ".tmp-" in call[-1])
        install = next(i for i, call in enumerate(self.calls) if "chmod 700" in call[-1])
        self.assertLess(copy, verify)
        self.assertLess(verify, install)
        self.assertTrue(all("--user" not in call and "-t" not in call for call in self.calls))

    def test_bad_checksum_never_executes_or_installs_upload(self):
        def reject(args, **kwargs):
            result = self.run_command(args, **kwargs)
            if ".tmp-" in args[-1] and "sha256sum -c" in args[-1]:
                result.returncode = 1
            return result
        with patch.object(self.connector, "_run", side_effect=reject):
            with self.assertRaisesRegex(ConnectorError, "checksum"):
                self.connector.deploy()
        self.assertFalse(any("chmod 700" in call[-1] for call in self.calls))
        self.assertTrue(any(call[2:4] == ["rm", "-f"] for call in self.calls))

    def test_cross_artifact_mismatch_rejected_before_copy(self):
        data = bytearray(self.artifact.read_bytes())
        data[18:20] = (183).to_bytes(2, "little")
        self.artifact.write_bytes(data)
        with patch.object(self.connector, "_run", side_effect=self.run_command):
            with self.assertRaisesRegex(ConnectorError, "architecture mismatch"):
                self.connector.deploy()
        self.assertFalse(any(call[0] == "cp" for call in self.calls))

    def test_preinstalled_path_does_not_upload(self):
        self.connector.agent_path = "/opt/hollow/hollow-agent"
        with patch.object(self.connector, "_run", side_effect=self.run_command):
            self.assertEqual(self.connector.deploy(), self.connector.agent_path)
        self.assertFalse(any(call[0] == "cp" for call in self.calls))


if __name__ == "__main__":
    unittest.main()
