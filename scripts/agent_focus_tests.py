#!/usr/bin/env python3
"""Local experimental focus contract/correctness, not performance qualification."""
import argparse
import json
import os
import subprocess
import unittest

from agent_connectors import ProcessConnection
from agent_conformance import DATA, ERROR, RESPONSE, b64
from agent_pty import PtyClient


class FocusTests(unittest.TestCase):
    agent = "zig-out/bin/hollow-agent"

    def client(self, *, bounded=True, enabled=True, negotiate=True):
        env = dict(os.environ)
        for key in ("HOLLOW_AGENT_BOUNDED_BULK", "HOLLOW_AGENT_FOCUS_SCHEDULER",
                    "HOLLOW_AGENT_PROFILE", "HOLLOW_AGENT_QUEUE_PROFILE"):
            env.pop(key, None)
        if bounded:
            env["HOLLOW_AGENT_BOUNDED_BULK"] = "1"
        if enabled:
            env["HOLLOW_AGENT_FOCUS_SCHEDULER"] = "1"
        connection = ProcessConnection(subprocess.Popen([self.agent, "stdio"], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0, start_new_session=True))
        client = PtyClient(connection)
        self.addCleanup(client.close)
        if negotiate:
            client.start(focus=True)
        return client

    def test_both_flags_and_hello_are_required(self):
        for bounded, enabled, hello_focus in ((False, True, True), (True, False, True), (True, True, False)):
            with self.subTest(bounded=bounded, enabled=enabled, hello_focus=hello_focus):
                client = self.client(bounded=bounded, enabled=enabled, negotiate=False)
                _, _, _, payload = client.hello(json.dumps({"major": 1, "experimental_pty": True,
                                                            "experimental_focus": hello_focus}).encode())
                self.assertNotIn("experimental.focus", json.loads(payload)["capabilities"])
                self.assertEqual(client.request("FOCUS_UPDATE", {})[1]["code"], "unsupported")

    def test_focus_sequences_generation_and_invalid_target_are_isolated(self):
        client = self.client()
        pane = client.spawn(["/bin/sleep", "60"], logical_session=7)
        self.assertEqual(client.focus(10, 7, pane.stream)[:2], (RESPONSE, {"applied": True, "sequence": 10}))
        self.assertEqual(client.focus(9, 999, 999)[:2], (RESPONSE, {"applied": False, "sequence": 10}))
        for fields in ({"sequence": 11, "generation": "old"}, {"sequence": 11, "active_session_id": 8},
                       {"sequence": 11, "active_stream_id": pane.stream + 2}, {"sequence": 0}):
            body = {"generation": client.focus_generation, "sequence": 11,
                    "active_session_id": 7, "active_stream_id": pane.stream, **fields}
            self.assertEqual(client.request("FOCUS_UPDATE", body)[1]["code"], "invalid_argument")
        # Invalid requests must not consume focus sequence or kill another pane.
        self.assertEqual(client.focus(11, 0)[:2], (RESPONSE, {"applied": True, "sequence": 11}))
        self.assertEqual(pane.resize(40, 90)[0], RESPONSE)

    def test_generation_cannot_cross_connections(self):
        first, second = self.client(), self.client()
        self.assertNotEqual(first.focus_generation, second.focus_generation)
        body = {"generation": first.focus_generation, "sequence": 1,
                "active_session_id": 0, "active_stream_id": 0}
        self.assertEqual(second.request("FOCUS_UPDATE", body)[1]["code"], "invalid_argument")
        self.assertEqual(second.focus(1, 0)[1], {"applied": True, "sequence": 1})

    def test_closed_focus_and_slot_reuse_do_not_retarget_old_stream(self):
        client = self.client()
        old = client.spawn(["/bin/sleep", "60"], logical_session=7)
        self.assertEqual(client.focus(1, 7, old.stream)[0], RESPONSE)
        self.assertEqual(old.close()[0], RESPONSE)
        while old.receive()[0] == DATA:
            pass
        new = client.spawn(["/bin/sleep", "60"], logical_session=7)
        self.assertNotEqual(old.stream, new.stream)
        self.assertEqual(client.focus(2, 7, old.stream)[1]["code"], "invalid_argument")
        self.assertEqual(client.focus(2, 7, new.stream)[1], {"applied": True, "sequence": 2})

    def test_churn_exact_output_bulk_and_zero_credit_pane(self):
        client = self.client()
        panes = [client.spawn(["/bin/sh", "-c", "stty raw -echo; head -c 131072 /dev/zero; read line"],
                              logical_session=1 + index // 4, credit=0 if index == 7 else 65536)
                 for index in range(8)]
        received = [bytearray() for _ in panes]
        sequence = 0
        for _ in range(8):
            for index, pane in enumerate(panes[:7]):
                sequence += 1
                self.assertTrue(client.focus(sequence, 1 + index // 4, pane.stream)[1]["applied"])
                event = pane.receive()
                self.assertEqual(event[0], DATA)
                received[index].extend(event[1])
                pane.grant(len(event[1]))
            # Completed bulk remains serviceable amid focus and stopped credit.
            stdout, stderr = client.allocate_streams()
            kind, body, output = client.request("EXEC", {"argv_b64": [b64(b"/bin/printf"), b64(b"bulk")],
                "stdout_stream_id": stdout, "stderr_stream_id": stderr}, stream_ids=(stdout, stderr))
            self.assertEqual(kind, RESPONSE)
            self.assertEqual(output[stdout], b"bulk")
        for index, pane in enumerate(panes):
            if index == 7:
                self.assertTrue(pane.events.empty())
                # Explicit downstream credit resumes stopped output, no reconnect.
                pane.grant(65536)
            while len(received[index]) < 131072:
                event = pane.receive()
                self.assertEqual(event[0], DATA)
                received[index].extend(event[1])
                pane.grant(len(event[1]))
            self.assertEqual(received[index], bytes(131072))
            self.assertEqual(pane.input(b"\n")[0], RESPONSE)
            event = pane.receive()
            self.assertEqual(event[0], RESPONSE)
            self.assertEqual(event[1]["exit_code"], 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", default=FocusTests.agent)
    args, remaining = parser.parse_known_args()
    FocusTests.agent = args.agent
    unittest.main(argv=[__file__, *remaining], verbosity=2)
