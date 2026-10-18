import contextlib
import os
import pathlib
import socket
import stat
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from agent_connectors import ConnectorError
from agent_mock_socket import BUFFER_LIMIT, MAX_CONNECTIONS, MockSocket, relay, shutdown_write


@unittest.skipUnless(os.name == "posix" and hasattr(socket, "AF_UNIX"), "Linux/POSIX mock socket fixture")
class MockSocketTests(unittest.TestCase):
    def test_binary_fragmentation_backpressure_and_ordered_half_close(self):
        for fragment in (1, 257, BUFFER_LIMIT):
            with self.subTest(fragment=fragment), self._socket_pairs() as streams:
                client, left, right, server = streams
                for endpoint in streams:
                    endpoint.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
                client.settimeout(10)
                server.settimeout(10)
                result, errors = [], []

                def pump():
                    try:
                        result.append(relay(left.fileno(), left.fileno(), right.fileno(), right.fileno(),
                                            lambda: shutdown_write(right), lambda: shutdown_write(left), fragment=fragment))
                    except BaseException as exc:
                        errors.append(exc)

                thread = threading.Thread(target=pump, daemon=True)
                thread.start()
                payload = bytes(range(256)) * (4 if fragment == 1 else 1024)
                response = b"\xff\x00'\nreply" * 257

                def send():
                    client.sendall(payload)
                    client.shutdown(socket.SHUT_WR)

                writer = threading.Thread(target=send, daemon=True)
                writer.start()
                received = bytearray()
                while data := server.recv(8192):
                    received.extend(data)
                self.assertEqual(received, payload)
                # Request EOF must not destroy the reverse response stream.
                server.sendall(response)
                server.shutdown(socket.SHUT_WR)
                received.clear()
                while data := client.recv(8192):
                    received.extend(data)
                self.assertEqual(received, response)
                writer.join(2)
                thread.join(2)
                self.assertFalse(thread.is_alive())
                self.assertFalse(writer.is_alive())
                self.assertFalse(errors)
                self.assertEqual(len(result), 1)
                self.assertGreater(result[0], 0)
                self.assertLessEqual(result[0], BUFFER_LIMIT)

    @staticmethod
    @contextlib.contextmanager
    def _socket_pairs():
        pairs = (*socket.socketpair(), *socket.socketpair())
        try:
            yield pairs
        finally:
            for stream in pairs:
                stream.close()

    def test_private_endpoint_and_owned_cleanup(self):
        fixture = MockSocket(sys.executable)
        fixture.start()
        directory, path = pathlib.Path(fixture.directory.name), pathlib.Path(fixture.path)
        try:
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(fixture.argv()[-2:], ["--fragment", str(BUFFER_LIMIT)])
        finally:
            fixture.close()
        self.assertFalse(directory.exists())
        with self.assertRaises(ConnectorError):
            fixture.argv()

    def test_stop_interrupts_idle_or_backpressured_relay(self):
        with self._socket_pairs() as streams:
            client, left, right, server = streams
            right.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
            stop = threading.Event()
            result, errors = [], []
            def pump():
                try:
                    result.append(relay(left.fileno(), left.fileno(), right.fileno(), right.fileno(),
                                        lambda: shutdown_write(right), lambda: shutdown_write(left), stop))
                except BaseException as exc:
                    errors.append(exc)
            thread = threading.Thread(target=pump, daemon=True)
            thread.start()
            client.setblocking(False)
            # The server deliberately never reads. The producer eventually
            # backpressures instead of requiring an unbounded queue.
            chunk = b"x" * BUFFER_LIMIT
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline:
                try:
                    client.send(chunk)
                except BlockingIOError:
                    break
            stop.set()
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertFalse(errors)
            self.assertEqual(len(result), 1)
            self.assertLessEqual(result[0], BUFFER_LIMIT)

    def test_rejects_invalid_fragment_without_creating_listener(self):
        for size in (0, -1, BUFFER_LIMIT + 1):
            with self.assertRaises(ConnectorError):
                MockSocket(sys.executable, fragment=size)

    def test_missing_endpoint_fails_without_protocol_stdout(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "agent_mock_socket.py"
        result = subprocess.run([sys.executable, str(script), "bridge", "--socket", "/nonexistent/hollow-owned-test.sock"],
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"mock socket bridge:", result.stderr)

    def test_connection_admission_is_bounded_and_teardown_joins_workers(self):
        popen = subprocess.Popen
        peers = []
        fixture = MockSocket(sys.executable)
        # A fake stdio agent blocks until EOF. Its processes belong only to this
        # test; no installed agent/build artifact or wire behavior is required.
        def child(*args, **kwargs):
            return popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read()"], **kwargs)
        try:
            with patch("agent_mock_socket.subprocess.Popen", side_effect=child):
                fixture.start()
                for _ in range(MAX_CONNECTIONS):
                    peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    peer.connect(fixture.path)
                    peers.append(peer)
                deadline = time.monotonic() + 5
                while fixture.accepted < MAX_CONNECTIONS and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(fixture.accepted, MAX_CONNECTIONS)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as extra:
                    extra.settimeout(3)
                    extra.connect(fixture.path)
                    self.assertEqual(extra.recv(1), b"")
                self.assertLessEqual(len(fixture.clients), MAX_CONNECTIONS)
                fixture.close()
                self.assertFalse(fixture.workers)
        finally:
            for peer in peers:
                peer.close()
            fixture.close()


if __name__ == "__main__":
    unittest.main()
