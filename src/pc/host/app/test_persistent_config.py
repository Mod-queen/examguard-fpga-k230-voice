import unittest

from .persistent_config import PersistentConfig, decode_config


class PersistentConfigTests(unittest.TestCase):
    def test_legacy_zero_and_canonical_profile_keep_default_behavior(self):
        default = PersistentConfig()
        self.assertEqual(decode_config(bytes(32)), default)
        self.assertEqual(decode_config(default.encode()), default)
        self.assertEqual(default.encode().hex(), '4547503101200000010000008c0aff7f00000000000000000000000000000000')

    def test_boundaries_offsets_and_seat_are_independent_metadata(self):
        for seat in (1, 0xffffffff):
            for duration in (60, 2700, 7200):
                for offset in (-720, 0, 480, 840, None):
                    for mute in (False, True):
                        item = PersistentConfig(seat, duration, offset, mute)
                        self.assertEqual(decode_config(item.encode()), item)

    def test_reserved_unknown_and_invalid_values_rejected(self):
        source = PersistentConfig().encode()
        for index in (0, 4, 5, 6, 7, 16, 17, 31):
            raw = bytearray(source);raw[index] ^= 2
            with self.assertRaises(ValueError):
                decode_config(bytes(raw))
        for item in (PersistentConfig(0), PersistentConfig(exam_duration_s=59),
                     PersistentConfig(exam_duration_s=7201), PersistentConfig(rtc_offset_minutes=841),
                     PersistentConfig(rtc_offset_minutes=-721), PersistentConfig(mute=1),
                     PersistentConfig(seat_id=True)):
            with self.assertRaises(ValueError):
                item.encode()
        with self.assertRaises(ValueError):
            decode_config(bytes(31))
