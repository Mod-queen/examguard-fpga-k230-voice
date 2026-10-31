import struct
import unittest
import zlib

from .evidence_v2 import HEADER, META, TRANSACTION, WindowAssembly, decode_window_packet
from .protocol import ProtocolError


def wire(*, kind=1, flags=4, index=0, offset=0, payload=b"\x12\x34\x56\x78",
         count=0, uid=0x1234567800000001, source_time=0xDEADBEEFFFFFFFFF,
         frame_id=17, frame_time=0xFEDCBA9800000001, reserved=bytes(6)):
    transaction = TRANSACTION.pack(1, 2, 3, uid, source_time, 2, 0, 0x0350)
    meta = META.pack(frame_id, frame_time) if kind == 1 else bytes(12)
    raw = HEADER.pack(b"EG", 2, kind, 80, flags, 1, transaction, index, meta,
                      offset, 4, count, len(payload), 2, 1, reserved) + payload
    return raw + struct.pack("!I", zlib.crc32(raw))


def result(**kwargs):
    return decode_window_packet(wire(kind=2, flags=2, index=1, count=1, payload=b"", **kwargs))


class EvidenceV2Tests(unittest.TestCase):
    def test_full_64bit_identity_time_and_pixels_require_result(self):
        packet = decode_window_packet(wire())
        self.assertEqual(packet.identity, (1, 2, 3, 0x1234567800000001))
        self.assertEqual(packet.source_time_ms, 0xDEADBEEFFFFFFFFF)
        self.assertEqual(packet.frame_time_ms, 0xFEDCBA9800000001)
        window = WindowAssembly(packet)
        self.assertEqual(window.status, "awaiting_result")
        window.add(result())
        self.assertEqual(window.status, "complete")
        self.assertEqual(window.frame_data(0), b"\x12\x34\x56\x78")

    def test_reorder_result_first_chunks_last_duplicate(self):
        window = WindowAssembly(result())
        window.add(decode_window_packet(wire(offset=2, payload=b"\x56\x78")))
        self.assertEqual(window.status, "partial")
        first = decode_window_packet(wire(flags=0, payload=b"\x12\x34"))
        window.add(first)
        window.add(first)
        window.add(result())
        self.assertEqual(window.status, "complete")
        self.assertEqual(len(window.frames), 1)

    def test_failed_verdict_never_promoted_by_all_pixels(self):
        failed = decode_window_packet(wire(kind=2, flags=0, index=1, count=1, payload=b""))
        window = WindowAssembly(failed)
        window.add(decode_window_packet(wire()))
        self.assertEqual(window.status, "failed")
        only_result = WindowAssembly(decode_window_packet(wire(kind=2, flags=0, count=2, payload=b"")))
        self.assertEqual(only_result.status, "failed")

    def test_count_mismatch_and_bad_source_are_failed(self):
        for flags in (2, 10):
            packet = decode_window_packet(wire(kind=2, flags=flags, index=0, count=1, payload=b""))
            self.assertEqual(WindowAssembly(packet).status, "failed")
        window = WindowAssembly(decode_window_packet(wire(flags=12)))
        window.add(result())
        self.assertEqual(window.status, "failed")
        empty_ok = decode_window_packet(wire(kind=2, flags=2, index=0, count=0, payload=b""))
        self.assertEqual(WindowAssembly(empty_ok).status, "failed")

    def test_same_low_uid_never_merges_and_context_conflict_latches(self):
        window = WindowAssembly(decode_window_packet(wire()))
        for packet in (decode_window_packet(wire(uid=1)),
                       decode_window_packet(wire(source_time=0))):
            with self.assertRaises(ProtocolError):
                window.add(packet)
        self.assertEqual(window.status, "failed")

    def test_overlap_metadata_result_conflicts(self):
        for packet in (decode_window_packet(wire(payload=b"\x00\x00\x00\x00")),
                       decode_window_packet(wire(frame_id=18)),
                       decode_window_packet(wire(frame_time=1))):
            window = WindowAssembly(decode_window_packet(wire()))
            with self.assertRaises(ProtocolError):
                window.add(packet)
            self.assertEqual(window.status, "failed")
        window = WindowAssembly(result())
        with self.assertRaises(ProtocolError):
            window.add(decode_window_packet(wire(kind=2, flags=0, index=1, count=1, payload=b"")))

    def test_missing_result_frame_and_chunk_stay_partial(self):
        window = WindowAssembly(decode_window_packet(wire(flags=0, payload=b"\x12\x34")))
        self.assertEqual(window.status, "awaiting_result")
        window.add(result())
        self.assertEqual(window.status, "partial")
        with self.assertRaises(ProtocolError):
            window.frame_data(0)
        window = WindowAssembly(result())
        self.assertEqual(window.status, "partial")

    def test_crc_lengths_reserved_and_semantics_rejected(self):
        raw = bytearray(wire())
        raw[50] ^= 1
        invalid = [bytes(raw), wire()[:-1], b"PG\x01", wire(reserved=b"\x01" * 6),
                   wire(flags=16), wire(offset=1), wire(flags=0), wire(count=1),
                   wire(kind=2, payload=b"12"), wire(payload=b"")]
        for raw in invalid:
            with self.subTest(raw=raw[:8]), self.assertRaises(ProtocolError):
                decode_window_packet(raw)

    def test_capacity_limits(self):
        with self.assertRaises(ProtocolError):
            WindowAssembly(decode_window_packet(wire(index=10)), max_frames=2)
        with self.assertRaises(ProtocolError):
            WindowAssembly(decode_window_packet(wire()), max_frame_bytes=2)
        with self.assertRaises(ProtocolError):
            WindowAssembly(decode_window_packet(wire()), max_window_bytes=2)


if __name__ == "__main__":
    unittest.main()
