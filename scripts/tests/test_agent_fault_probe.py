import pathlib
import signal
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_fault_probe import kill_verified, verified_job


class FaultProbeTests(unittest.TestCase):
    def test_missing_or_reused_pid_is_never_signalled(self):
        kill = Mock()
        for current in (None, ("S", "new-start", 1)):
            with self.subTest(current=current):
                self.assertFalse(kill_verified(42, ("S", "old-start", 1),
                                               kill=kill, identify=lambda _: current))
        kill.assert_not_called()

    def test_matching_pid_is_signalled_and_exit_race_is_safe(self):
        original = ("S", "start", 1)
        kill = Mock()
        self.assertTrue(kill_verified(42, original, signal.SIGTERM,
                                      kill=kill, identify=lambda _: original))
        kill.assert_called_once_with(42, signal.SIGTERM)
        kill.side_effect = ProcessLookupError
        self.assertTrue(kill_verified(42, original, kill=kill, identify=lambda _: original))

    def test_guardian_and_workload_ancestry_must_match(self):
        guardian = ("S", "guardian-start", 10)
        workload = ("S", "workload-start", 20)
        processes = {20: guardian, 30: workload}
        self.assertTrue(verified_job(10, 20, guardian, {30: workload}, processes.get))
        processes[20] = ("S", "replacement", 10)
        self.assertFalse(verified_job(10, 20, guardian, {30: workload}, processes.get))
        processes[20] = guardian
        processes[30] = ("S", "workload-start", 10)
        self.assertFalse(verified_job(10, 20, guardian, {30: workload}, processes.get))

    def test_ancestor_cycle_does_not_hang_or_pass(self):
        guardian = ("S", "guardian-start", 10)
        workload = ("S", "workload-start", 40)
        processes = {20: guardian, 30: workload, 40: ("S", "other-start", 30)}
        self.assertFalse(verified_job(10, 20, guardian, {30: workload}, processes.get))


if __name__ == "__main__":
    unittest.main()
