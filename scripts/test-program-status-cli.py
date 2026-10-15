#!/usr/bin/env python3
"""Program-status CLI regression tests; no running GUI required."""
import contextlib
import io
import pathlib
import runpy
import os
import socket
import struct
import subprocess
import sys
import threading
import json
import unittest

MODULE = runpy.run_path(str(pathlib.Path(__file__).with_name("hollow-cli")))


class ProgramStatusCliTests(unittest.TestCase):
    def run_cli(self, args, payload=None):
        cli = MODULE["HollowCli"]()
        requests = []

        def query(channel, params):
            requests.append((channel, params))
            return {"kind": "result", "status": "ok", "payload": payload}

        cli.query = query
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = cli.run(["program-status", *args])
        self.assertEqual(result, 0)
        return requests, output.getvalue()

    def test_set_preserves_text_and_target(self):
        requests, output = self.run_cli([
            "set", "blocked", "--pane", "42", "--id", "build/tests",
            "--kind", "permission", "--progress", "0", "--app", "demo",
            "--message", 'Allow "deploy"?\nNext step',
        ])
        self.assertEqual(requests, [("program_status_set", {
            "pane": 42, "id": "build/tests", "state": "blocked", "kind": "permission",
            "progress": 0, "app": "demo", "message": 'Allow "deploy"?\nNext step',
        })])
        self.assertEqual(output, "")

    def test_get_outputs_records(self):
        requests, output = self.run_cli(["get", "--pane", "42"], [{"state": "working"}])
        self.assertEqual(requests, [("program_status_get", {"pane": 42})])
        self.assertEqual(output, '[{"state":"working"}]\n')

    def test_clear_defaults_to_entire_pane(self):
        requests, _ = self.run_cli(["clear"])
        self.assertEqual(requests, [("program_status_clear", {"id": ""})])
        requests, _ = self.run_cli(["clear", "--id", "build"])
        self.assertEqual(requests, [("program_status_clear", {"id": "build"})])

    def test_invalid_progress_kind_and_target_do_not_send(self):
        for args in (["set", "working", "--progress", "101"],
                     ["set", "done", "--progress", "10"],
                     ["set", "working", "--kind", "auth"],
                     ["get", "--pane", "0"]):
            with self.subTest(args=args), self.assertRaises(MODULE["CliError"]):
                self.run_cli(args)


@unittest.skipUnless(os.environ.get("HOLLOW_NATIVE_CLI"), "set HOLLOW_NATIVE_CLI to a built native executable")
class ProgramStatusSocketTests(unittest.TestCase):
    def roundtrip(self, prefix, args, reply):
        requests = []
        errors = []
        with socket.socket() as server:
            server.bind(("127.0.0.1", 0))
            server.listen(1)
            server.settimeout(10)

            def serve():
                try:
                    with server.accept()[0] as connection:
                        connection.settimeout(10)
                        def read_exact(count):
                            data = b""
                            while len(data) < count:
                                chunk = connection.recv(count - len(data))
                                if not chunk:
                                    raise EOFError("short frame")
                                data += chunk
                            return data
                        length = struct.unpack("<I", read_exact(4))[0]
                        requests.append(json.loads(read_exact(length)))
                        payload = json.dumps(reply).encode()
                        connection.sendall(struct.pack("<I", len(payload)) + payload)
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=serve)
            thread.start()
            try:
                result = subprocess.run([*prefix, "program-status", *args], capture_output=True,
                                        text=True, timeout=15, env={**os.environ,
                                        "HOLLOW_COMMAND_ADDR": "127.0.0.1:%d" % server.getsockname()[1],
                                        "HOLLOW_PANE_ID": "101"})
            finally:
                thread.join(timeout=12)
        self.assertFalse(errors, (result.returncode, result.stdout, result.stderr))
        self.assertFalse(thread.is_alive())
        return requests[0], result

    def clients(self):
        return ([sys.executable, str(pathlib.Path(__file__).with_name("hollow-cli"))],
                [os.environ["HOLLOW_NATIVE_CLI"], "cli"])

    def test_both_clients_send_shared_set_get_clear_requests(self):
        for prefix in self.clients():
            for args, channel in ((["set", "working", "--progress", "25", "--id", "build", "--pane", "42"], "set"),
                                  (["get"], "get"), (["clear", "--id", "build"], "clear")):
                with self.subTest(client=prefix, command=channel):
                    request, result = self.roundtrip(prefix, args, {"kind": "result", "status": "ok", "payload": []})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(request["kind"], "get_htp")
                    self.assertEqual(request["channel"], "program_status_" + channel)
                    self.assertEqual(request["pane_id"], 101)
                    if channel == "set":
                        self.assertEqual(request["params"], {"state": "working", "progress": 25, "id": "build", "pane": 42})
                    self.assertEqual(result.stdout, "[]\n" if channel == "get" else "")

    def test_both_clients_fail_on_host_rejection(self):
        for prefix in self.clients():
            with self.subTest(client=prefix):
                _, result = self.roundtrip(prefix, ["get", "--pane", "42"],
                                           {"kind": "error", "status": "invalid_args", "error": "unknown pane id"})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unknown pane id", result.stderr)


if __name__ == "__main__":
    unittest.main()
