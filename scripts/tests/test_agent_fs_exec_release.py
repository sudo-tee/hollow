import argparse
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from agent_fs_exec_release import commands
import agent_fs_exec_release as release


class ReleaseChecksTests(unittest.TestCase):
    def options(self, profiles):
        return argparse.Namespace(zig="zig-0.16", build_option=["-Dhost-lua-include=/headers"],
                                  output=Path("/report"), profile=profiles, distro="TestDistro",
                                  wsl_user="tester", wsl_artifact="C:\\agents\\hollow-agent", wsl_agent_path="/opt/hollow-agent")

    def test_local_has_build_lua_conformance_containment_and_no_pty_rollout(self):
        checks = dict(commands(self.options(["local"])))
        self.assertEqual(len(checks), 6)
        self.assertIn("test-host-lua-flat", checks["build-and-native"])
        self.assertIn("-Dhost-lua-include=/headers", checks["build-and-native"])
        self.assertIn("local-subprocess", checks["local-conformance"])
        for command in checks.values():
            self.assertFalse(any("agent_pty_bench" in arg or "test-agent-pty" == arg for arg in command))

    def test_requested_profiles_use_real_fixture_and_production_lua(self):
        checks = dict(commands(self.options(["podman", "ssh", "docker", "socket", "wsl"])))
        self.assertIn("podman-bootstrap", checks["podman-production"])
        self.assertIn("1000:1000", checks["podman-production"])
        self.assertIn("--conformance", checks["docker-production"])
        self.assertNotIn("--docker", checks["docker-production"])
        self.assertIn("--conformance", checks["ssh-production"])
        self.assertIn("--fragment", checks["socket-conformance-and-loss"])
        self.assertIn("TestDistro", checks["wsl-production"])
        self.assertIn("/opt/hollow-agent", checks["wsl-conformance"])
        for name in ("podman-production", "ssh-production", "docker-production", "socket-conformance-and-loss", "wsl-production"):
            self.assertIn("test-host-lua", checks[name])
            self.assertIn("test-host-lua-flat", checks[name])

    def test_failed_or_unavailable_requested_check_never_passes_report(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None) as directory:
            output = Path(directory) / "report"
            with patch.object(sys, "argv", ["release", "--profile", "local", "docker", "--output", str(output)]), \
                 patch.object(release, "commands", return_value=[("missing-docker", ["docker", "info"])]), \
                 patch.object(release.subprocess, "check_output", side_effect=["revision\n", ""]), \
                 patch.object(release.subprocess, "run", side_effect=FileNotFoundError("docker unavailable")):
                self.assertEqual(release.main(), 1)
            import json
            report = json.loads((output / "report.json").read_text())
            self.assertFalse(report["checks_passed"])
            self.assertFalse(report["checks"][0]["passed"])
            self.assertIn("docker", report["selected_profiles"])
            self.assertIn("wsl", report["unverified_profiles"])
            self.assertNotIn("docker", report["unverified_profiles"])
            self.assertIn("unavailable", report["checks"][0]["error"])

    def test_success_only_qualifies_selected_checks_and_never_overwrites(self):
        with tempfile.TemporaryDirectory(dir="/tmp/opencode" if Path("/tmp/opencode").is_dir() else None) as directory:
            output = Path(directory) / "report"
            argv = ["release", "--profile", "local", "--output", str(output)]
            with patch.object(sys, "argv", argv), \
                 patch.object(release, "commands", return_value=[("local", ["test"])]), \
                 patch.object(release.subprocess, "check_output", side_effect=["revision\n", ""]), \
                 patch.object(release.subprocess, "run", return_value=argparse.Namespace(returncode=0)):
                self.assertEqual(release.main(), 0)
            import json
            report = json.loads((output / "report.json").read_text())
            self.assertTrue(report["checks_passed"])
            self.assertEqual(report["selected_profiles"], ["local"])
            self.assertIn("docker", report["unverified_profiles"])
            before = (output / "report.json").read_bytes()
            with patch.object(sys, "argv", argv), self.assertRaises(FileExistsError):
                release.main()
            self.assertEqual((output / "report.json").read_bytes(), before)
