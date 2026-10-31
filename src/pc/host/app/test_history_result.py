import random
import unittest
import zlib

from app.history_result import (
    FLAG_CAPTURE_ERROR,
    FLAG_COVERAGE_OK,
    FLAG_GAP_BAD_RANGE,
    FLAG_GAP_UNKNOWN,
    FLAG_OK,
    FLAG_TRUNCATED,
    HistoryResultError,
    decode_history_result,
    encode_history_result,
)


def sample(**overrides):
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


class HistoryResultTests(unittest.TestCase):
    def test_roundtrip_clean(self):
        data = sample(flags=FLAG_OK | FLAG_COVERAGE_OK, gap_count=0,
                      gap_first_meta=bytes(12), gap_last_meta=bytes(12),
                      gap_first_reason=0, gap_last_reason=0)
        record = decode_history_result(data)
        self.assertEqual(len(data), 128)
        self.assertEqual(record.transaction, bytes(range(32)))
        self.assertEqual(record.window, 1)
        self.assertEqual(record.token, 0x12345678)
        self.assertEqual(record.code, 0)
        self.assertEqual(record.frames, 3)
        self.assertEqual(record.gap_count, 0)
        self.assertEqual(record.lower_ms, 100)
        self.assertEqual(record.upper_ms, 300)
        self.assertTrue(record.ok)
        self.assertTrue(record.coverage_ok)
        self.assertFalse(record.truncated)

    def test_gap_flags_and_meta(self):
        data = sample(flags=FLAG_OK | FLAG_GAP_UNKNOWN,
                      gap_first_meta=bytes.fromhex("0000000700000000000000c8"),
                      gap_last_meta=bytes.fromhex("0000000800000000000000fa"))
        record = decode_history_result(data)
        self.assertTrue(record.gap_unknown)
        self.assertFalse(record.coverage_ok)
        self.assertEqual(record.gap_first_time_ms, 200)
        self.assertEqual(record.gap_last_time_ms, 250)
        self.assertEqual(record.gap_first_reason, 0x81)
        self.assertEqual(record.as_dict()["gap_count"], 1)

    def test_failure_flags(self):
        data = sample(flags=FLAG_TRUNCATED | FLAG_CAPTURE_ERROR | FLAG_GAP_BAD_RANGE)
        record = decode_history_result(data)
        self.assertFalse(record.ok)
        self.assertTrue(record.truncated)
        self.assertTrue(record.capture_error)
        self.assertTrue(record.gap_bad_range)
        self.assertFalse(record.coverage_ok)

    def test_crc_rejects_corruption(self):
        data = bytearray(sample())
        data[60] ^= 1
        with self.assertRaisesRegex(HistoryResultError, "CRC32"):
            decode_history_result(bytes(data))

    def test_bad_header_and_reserved(self):
        for index, value in ((0, ord("X")), (2, 2), (3, 9)):
            data = bytearray(sample())
            data[index] = value
            with self.assertRaises(HistoryResultError):
                decode_history_result(bytes(data))
        data = bytearray(sample())
        data[115] = 1
        data[124:128] = zlib.crc32(bytes(data[:124])).to_bytes(4, "big")
        with self.assertRaisesRegex(HistoryResultError, "reserved"):
            decode_history_result(bytes(data))

    def test_bad_length_and_code(self):
        with self.assertRaises(HistoryResultError):
            decode_history_result(sample()[:-1])
        data = bytearray(sample(code=5))
        data[124:128] = zlib.crc32(bytes(data[:124])).to_bytes(4, "big")
        with self.assertRaisesRegex(HistoryResultError, "code"):
            decode_history_result(bytes(data))

    def test_random_roundtrip(self):
        rng = random.Random(20261019)
        for _ in range(200):
            transaction = bytes(rng.randrange(256) for _ in range(32))
            first = bytes(rng.randrange(256) for _ in range(12))
            last = bytes(rng.randrange(256) for _ in range(12))
            flags = rng.randrange(64)
            data = encode_history_result(
                transaction=transaction,
                window=rng.randrange(4),
                token=rng.randrange(1 << 32),
                code=rng.randrange(5),
                frames=rng.randrange(1 << 32),
                gap_count=rng.randrange(1 << 32),
                lower_ms=rng.randrange(1 << 64),
                upper_ms=rng.randrange(1 << 64),
                gap_first_meta=first,
                gap_last_meta=last,
                gap_first_reason=rng.randrange(256),
                gap_last_reason=rng.randrange(256),
                flags=flags,
            )
            record = decode_history_result(data)
            self.assertEqual(record.transaction, transaction)
            self.assertEqual(record.flags, flags)
            self.assertEqual(record.gap_first_meta, first)
            self.assertEqual(record.gap_last_meta, last)


if __name__ == "__main__":
    unittest.main()
