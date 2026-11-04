import importlib.util
import os
from pathlib import Path
import select
import threading
import unittest

spec = importlib.util.spec_from_file_location("clipboard_probe", Path(__file__).parents[1] / "test_clipboard.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ReplyTest(unittest.TestCase):
    def test_bel_and_st_replies(self):
        self.assertEqual(probe.decode_reply(b"\x1b]52;c;aGVsbG8=\x07"), b"hello")
        self.assertEqual(probe.decode_reply(b"\x1b]52;c;aGVsbG8=\x1b\\"), b"hello")
        self.assertEqual(probe.decode_reply(b"\x1b]52;c;\x07"), b"")

    def test_invalid_replies_do_not_disclose_payload(self):
        for reply in (b"\x1b]52;p;secret\x07", b"\x1b]52;c;secret!\x07", b"secret"):
            with self.subTest(reply=reply):
                with self.assertRaises(RuntimeError) as error:
                    probe.decode_reply(reply)
                self.assertNotIn("secret", str(error.exception))


@unittest.skipUnless(os.name == "posix", "requires POSIX pseudoterminals")
class TerminalTest(unittest.TestCase):
    def setUp(self):
        import pty
        import termios
        self.master, self.slave = pty.openpty()
        self.path = os.ttyname(self.slave)
        self.saved = termios.tcgetattr(self.slave)

    def tearDown(self):
        os.close(self.master)
        os.close(self.slave)

    def assert_restored(self):
        import termios
        self.assertEqual(termios.tcgetattr(self.slave), self.saved)

    def peer(self, response):
        errors = []

        def run():
            try:
                query = bytearray()
                while not query.endswith(b"\x07"):
                    if not select.select([self.master], [], [], 2)[0]:
                        raise TimeoutError("probe did not send its request")
                    query.extend(os.read(self.master, 1024))
                self.assertEqual(bytes(query), probe.READ_QUERY)
                for byte in response:
                    os.write(self.master, bytes([byte]))
            except BaseException as exc:
                errors.append(exc)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread, errors

    def test_read_handles_split_reply_and_restores_terminal(self):
        thread, errors = self.peer(b"\x1b]52;c;aGVsbG8=\x1b\\")
        try:
            self.assertEqual(probe.query_clipboard(2, self.path), b"hello")
        finally:
            thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assert_restored()

    def test_timeout_restores_terminal(self):
        with self.assertRaisesRegex(RuntimeError, "Timed out"):
            probe.query_clipboard(0.02, self.path)
        self.assert_restored()

    def test_ctrl_c_restores_terminal(self):
        thread, errors = self.peer(b"\x03")
        try:
            with self.assertRaises(KeyboardInterrupt):
                probe.query_clipboard(2, self.path)
        finally:
            thread.join(3)
        self.assertEqual(errors, [])
        self.assert_restored()


if __name__ == "__main__":
    unittest.main()
