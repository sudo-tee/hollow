import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("windows_teardown", Path(__file__).parents[1] / "agent_windows_teardown_tests.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def stat(pid, parent, start=123, state="S", name="owned process"):
    fields = [state, str(parent)] + ["0"] * 17 + [str(start)]
    return f"{pid} ({name}) " + " ".join(fields)


class WindowsTeardownTests(unittest.TestCase):
    def test_proc_identity_handles_spaces_and_parentheses(self):
        self.assertEqual(probe.proc_identity(stat(42, 7, name="owned (test) process")), {"pid": 42, "ppid": 7, "state": "S", "starttime": 123})

    def test_same_identity_zombie_is_not_gone(self):
        with patch.object(Path, "read_text", return_value=stat(42, 7, state="Z")):
            self.assertFalse(probe.observe({"pid": 42, "starttime": 123})["gone"])

    def test_pid_reuse_is_not_survival(self):
        with patch.object(Path, "read_text", return_value=stat(42, 7, start=124)):
            self.assertTrue(probe.observe({"pid": 42, "starttime": 123})["gone"])

    def test_witnesses_require_matching_ancestry(self):
        text = "\n".join("WINDOWS_LUA_" + label + "_BEFORE " + stat(pid, parent) for label, pid, parent in (("TEARDOWN", 44, 43), ("GUARDIAN", 43, 42), ("AGENT", 42, 1)))
        self.assertEqual(probe.witnesses(text)["agent"]["pid"], 42)
        with self.assertRaises(ValueError):
            probe.witnesses(text.replace("44 (owned process) S 43", "44 (owned process) S 99"))
        with self.assertRaises(ValueError):
            probe.witnesses(text + "\n" + text)


if __name__ == "__main__":
    unittest.main()
