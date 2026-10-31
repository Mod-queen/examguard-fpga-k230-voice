import json
import tempfile
import unittest
from pathlib import Path

from app.history_result import FLAG_OK, encode_history_result
from app.history_result_receiver import HistoryResultReceiver
from app.protocol import ProtocolError


def record(**overrides):
    kwargs = dict(
        transaction=bytes(range(32)),
        window=1,
        token=0x12345678,
        code=0,
        frames=3,
        gap_count=1,
        lower_ms=100,
        upper_ms=300,
        gap_first_meta=bytes.fromhex("0000000700000000000000c8"),
        gap_last_meta=bytes.fromhex("0000000700000000000000c8"),
        gap_first_reason=0x81,
        gap_last_reason=0x81,
        flags=FLAG_OK,
    )
    kwargs.update(overrides)
    return encode_history_result(**kwargs)


class HistoryResultReceiverTests(unittest.TestCase):
    def test_writes_raw_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            seen = []
            receiver = HistoryResultReceiver(tmp, on_write=lambda p, r: seen.append(p))
            data = record()
            path = receiver.ingest(data)
            self.assertTrue(path.is_file())
            self.assertEqual(receiver.written, 1)
            self.assertEqual(seen, [path])
            target = path.parent
            self.assertEqual((target / "raw.hr").read_bytes(), data)
            manifest = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schema"], "examguard-history-result-v1")
            self.assertEqual(manifest["raw_bytes"], 128)
            self.assertEqual(manifest["raw_sha256"], __import__("hashlib").sha256(data).hexdigest())
            self.assertEqual(manifest["result"]["window"], 1)
            self.assertEqual(manifest["result"]["gap_count"], 1)
            self.assertEqual(manifest["result"]["gap_first_reason"], 0x81)
            self.assertFalse(any(target.glob("*.tmp")))

    def test_duplicate_identical_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            receiver = HistoryResultReceiver(tmp)
            data = record()
            first = receiver.ingest(data)
            second = receiver.ingest(data)
            self.assertEqual(first, second)
            self.assertEqual(receiver.written, 1)
            self.assertEqual(receiver.duplicates, 1)

    def test_conflicting_duplicate_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receiver = HistoryResultReceiver(tmp)
            receiver.ingest(record())
            with self.assertRaisesRegex(ProtocolError, "conflicting"):
                receiver.ingest(record(frames=4))
            self.assertEqual(receiver.written, 1)
            self.assertEqual(receiver.rejected, 1)

    def test_corrupt_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receiver = HistoryResultReceiver(tmp)
            data = bytearray(record())
            data[60] ^= 1
            with self.assertRaisesRegex(ProtocolError, "CRC32"):
                receiver.ingest(bytes(data))
            self.assertEqual(receiver.written, 0)
            self.assertEqual(receiver.duplicates, 0)

    def test_separate_windows_and_limit_does_not_delete(self):
        with tempfile.TemporaryDirectory() as tmp:
            receiver = HistoryResultReceiver(tmp, max_records=1)
            p1 = receiver.ingest(record(window=0, token=1))
            p2 = receiver.ingest(record(window=1, token=2))
            self.assertNotEqual(p1, p2)
            self.assertEqual(receiver.written, 2)
            self.assertTrue(p1.is_file())
            self.assertTrue(p2.is_file())
            # The in-memory duplicate table is bounded, but disk files stay.
            receiver.ingest(record(window=0, token=1))
            self.assertEqual(receiver.written, 2)

    def test_bad_length_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            receiver = HistoryResultReceiver(tmp)
            with self.assertRaisesRegex(ProtocolError, "length"):
                receiver.ingest(b"HR")
            self.assertEqual(receiver.written, 0)


if __name__ == "__main__":
    unittest.main()
