import signal
import unittest
from unittest.mock import Mock

import agent_fault_probe as probe


class FaultProbeSafetyTests(unittest.TestCase):
    def test_identity_parses_spaces_in_comm(self):
        # stat fields after `)` begin with state (field 3); starttime is field 22.
        fields = ["S"] + [str(i) for i in range(4, 23)]
        with unittest.mock.patch.object(probe.Path, "read_text", return_value="123 (name with spaces) " + " ".join(fields)):
            self.assertEqual(probe.identity(123), ("S", "22", 4))

    def test_verified_job_requires_guardian_directly_under_agent(self):
        snapshots = {20: ("S", "g", 10), 21: ("S", "w", 20), 22: ("S", "d", 21)}
        with unittest.mock.patch.object(probe, "identity", side_effect=lambda pid: snapshots.get(pid)):
            self.assertTrue(probe.verified_job(10, 20, snapshots[20], {21: snapshots[21], 22: snapshots[22]}))
            snapshots[20] = ("S", "g", 11)
            self.assertFalse(probe.verified_job(10, 20, ("S", "g", 10), {21: snapshots[21]}))

    def test_cleanup_refuses_reused_pid(self):
        identify = Mock(return_value=("S", "new-start", 1))
        kill = Mock()
        self.assertFalse(probe.kill_verified(42, ("S", "old-start", 1), kill=kill, identify=identify))
        kill.assert_not_called()

    def test_cleanup_signals_same_identity_only(self):
        identify = Mock(return_value=("S", "same-start", 1))
        kill = Mock()
        self.assertTrue(probe.kill_verified(42, ("S", "same-start", 1), signal.SIGKILL,
                                            kill=kill, identify=identify))
        kill.assert_called_once_with(42, signal.SIGKILL)

    def test_zombie_is_not_reaped_success(self):
        state = {7: ("Z", "start", 1)}
        with unittest.mock.patch.object(probe, "identity", side_effect=lambda pid: state.get(pid)):
            self.assertEqual(probe._wait_snapshot([7], probe.time.monotonic()), {7: state[7]})


if __name__ == "__main__":
    unittest.main()
