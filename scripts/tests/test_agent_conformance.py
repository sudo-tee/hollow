import importlib.util
import pathlib
import struct
import unittest
import base64

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("agent_conformance", ROOT / "scripts/agent_conformance.py")
module = importlib.util.module_from_spec(spec)
import sys
sys.path.insert(0, str(ROOT / "scripts"))
spec.loader.exec_module(module)


class WireHarnessTests(unittest.TestCase):
    def test_header_is_exact_little_endian_22_byte_layout(self):
        encoded = module.frame(module.REQUEST, 0x0807060504030201, 2, b"abc")
        self.assertEqual(len(encoded), 25)
        self.assertEqual(encoded[:22], struct.pack("<IBBQQ", 3, 3, 0, 0x0807060504030201, 2))
        self.assertEqual(encoded[22:], b"abc")

    def test_all_message_kinds_match_v1_numbers(self):
        self.assertEqual((module.HELLO, module.HELLO_ACK, module.REQUEST, module.RESPONSE,
                          module.ERROR, module.DATA, module.CANCEL, module.PING, module.PONG,
                          module.WINDOW_UPDATE), tuple(range(1, 11)))

    def test_frame_rejects_oversize_payload(self):
        with self.assertRaises(ValueError):
            module.frame(module.DATA, payload=b"x" * (module.MAX_FRAME + 1))

    def test_data_frame_has_tighter_limit(self):
        with self.assertRaises(ValueError):
            module.frame(module.DATA, payload=b"x" * (module.MAX_DATA + 1))

    def test_exec_stream_allocator_is_even_and_monotonic(self):
        client = module.AgentClient.__new__(module.AgentClient)
        client.next_stream = 2
        import threading
        client.lock = threading.Lock()
        self.assertEqual(client.allocate_streams(), (2, 4))
        self.assertEqual(client.allocate_streams(), (6, 8))

    def test_binary_path_helpers_preserve_non_utf8(self):
        value = b"/tmp/name-\xff\x00"
        self.assertEqual(module.unb64(module.b64(value)), value)

    def test_frame_kind_and_header_fields(self):
        encoded = module.frame(module.DATA, 17, 24, b"payload")
        length, kind, flags, rid, sid = module.HEADER.unpack(encoded[:module.HEADER.size])
        self.assertEqual((length, kind, flags, rid, sid), (7, module.DATA, 0, 17, 24))
        self.assertEqual(encoded[module.HEADER.size:], b"payload")


if __name__ == "__main__":
    unittest.main()
