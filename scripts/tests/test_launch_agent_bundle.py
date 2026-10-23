"""Exercise Windows installer staging without modifying a real installation."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FILES = ("linux-x86_64/hollow-agent", "linux-aarch64/hollow-agent", "SHA256SUMS")
CLI_FILES = ("linux-x86_64/hollow-cli", "linux-aarch64/hollow-cli", "SHA256SUMS")


class LaunchAgentBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(ROOT / "launch.sh", self.root / "launch.sh")
        (self.root / "src/lua").mkdir(parents=True)
        (self.root / "src/lua/core.lua").write_text("-- fixture\n")
        (self.root / "conf").mkdir()
        (self.root / "conf/init.lua").write_text("-- fixture\n")
        (self.root / "zig-out/bin").mkdir(parents=True)
        for name in ("hollow.exe", "hollow-native.exe", "hollow-gui.exe", "hollow-cli.exe"):
            (self.root / "zig-out/bin" / name).write_bytes(b"fixture exe")
        self.bundle = self.root / "zig-out/agents"
        for name in FILES:
            path = self.bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        self.cli_bundle = self.root / "zig-out/cli"
        for name in CLI_FILES:
            path = self.cli_bundle / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        tools = self.root / "tools"
        tools.mkdir()
        wslpath = tools / "wslpath"
        wslpath.write_text('#!/bin/sh\nprintf "%s\\n" "$HOLLOW_TEST_INSTALL_DIR"\n')
        wslpath.chmod(0o755)
        self.install = self.root / "installed app"
        self.env = {
            **os.environ,
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "HOLLOW_TEST_INSTALL_DIR": str(self.install),
        }

    def launch(self):
        return subprocess.run(
            ["bash", str(self.root / "launch.sh"), "--no-build", "--install", "--build-only"],
            env=self.env, text=True, capture_output=True, timeout=10,
        )

    def test_installs_complete_agent_bundle_beside_executable(self):
        result = self.launch()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in FILES:
            self.assertEqual((self.install / "agents" / name).read_bytes(), name.encode())
        for name in CLI_FILES:
            self.assertEqual((self.install / "cli" / name).read_bytes(), name.encode())
        self.assertTrue((self.install / "hollow-cli.exe").is_file())
        self.assertTrue((self.install / "hollow-native.exe").is_file())
        self.assertTrue((self.install / "src/lua/core.lua").is_file())

    def test_missing_bundle_fails_before_overwriting_installation(self):
        (self.bundle / FILES[1]).unlink()
        self.install.mkdir()
        previous = self.install / "hollow-native.exe"
        previous.write_bytes(b"previous executable")
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zig build agent-all", result.stderr)
        self.assertEqual(previous.read_bytes(), b"previous executable")

    def test_missing_cli_bundle_fails_before_overwriting_installation(self):
        (self.cli_bundle / CLI_FILES[1]).unlink()
        self.install.mkdir()
        previous = self.install / "hollow-cli.exe"
        previous.write_bytes(b"previous cli")
        result = self.launch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zig build cli-all", result.stderr)
        self.assertEqual(previous.read_bytes(), b"previous cli")


if __name__ == "__main__":
    unittest.main()
