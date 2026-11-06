"""Check shell integration activation without requiring a GUI pane ID."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ShellIntegrationTests(unittest.TestCase):
    def check_shell(self, shell, pane_id, transport, active):
        executable = shutil.which(shell)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("HOLLOW_", "_HOLLOW_"))}
        if pane_id is not None:
            env["HOLLOW_PANE_ID"] = pane_id
        if transport is not None:
            env["HOLLOW_TRANSPORT"] = transport

        # Discard initial tty reports; capture the real command-start event
        # through the shell's transport helper instead of needing /dev/tty.
        if shell == "fish":
            script = """
source $argv[1] 2>/dev/null
functions -q __hollow_preexec; or exit 0
function __hollow_tty_print
end
function hollow_htp_send_raw
    printf '%s\\n' "$argv[1]"
end
emit fish_preexec ': regression.txt'
"""
            args = ["--no-config", "-c", script, str(ROOT / "shell-integration/fish.fish")]
        else:
            command = "trap '_hollow_preexec' DEBUG; : regression.txt" if shell == "bash" else "_hollow_preexec ': regression.txt'"
            script = """
source "$1" 2>/dev/null
trap - DEBUG 2>/dev/null
type _hollow_preexec >/dev/null 2>&1 || exit 0
_hollow_tty_printf() { :; }
__hollow_tty_print() { :; }
hollow_htp_send_raw() { printf '%s\\n' "$1"; }
_hollow_cmd_started=0
""" + command
            flags = ["--noprofile", "--norc"] if shell == "bash" else ["-f"]
            args = [*flags, "-c", script, "hollow-test", str(ROOT / f"shell-integration/{shell}.{'sh' if shell == 'bash' else 'zsh'}")]

        result = subprocess.run([executable, *args], env=env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        if active:
            event = json.loads(result.stdout)
            self.assertEqual(event["name"], "command_started")
            self.assertEqual(event["payload"]["command"], ": regression.txt")
            self.assertEqual(event["payload"]["cwd"], os.getcwd())
        else:
            self.assertEqual(result.stdout, "")

    def check_activation(self, shell):
        if shutil.which(shell) is None:
            self.skipTest(f"{shell} is not installed")
        for pane_id, transport, active in (
            (None, "osc", True),
            ("", "osc", True),
            ("42", None, True),
            (None, None, False),
            (None, "socket", False),
        ):
            with self.subTest(pane_id=pane_id, transport=transport):
                self.check_shell(shell, pane_id, transport, active)

    def test_bash_activation(self):
        self.check_activation("bash")

    def test_zsh_activation(self):
        self.check_activation("zsh")

    def test_fish_activation(self):
        self.check_activation("fish")


if __name__ == "__main__":
    unittest.main()
