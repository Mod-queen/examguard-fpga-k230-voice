from datetime import datetime, timezone
import struct
import unittest
import zlib

from .maintenance_protocol import encode_command, rtc_payload, decode_result
from .persistent_config import PersistentConfig
from .protocol import ProtocolError


def result_line(error=0, operation=2, token=10, boot=18, **changes):
    raw = bytearray(b'MR\x01\x01\0\x60' + bytes((operation, error)) + struct.pack('!IIII', token, 1, boot, 18) +
                    bytes((1, 0, 0, 0, 1)) + bytes(3) + PersistentConfig().encode() +
                    bytes.fromhex('000056341221031026') + struct.pack('!h', 480) + bytes(17))
    for offset, value in changes.items():
        raw[int(offset)] = value
    return b'MR,' + (raw + zlib.crc32(raw).to_bytes(4, 'big')).hex().upper().encode() + b'\n'


class MaintenanceProtocolTests(unittest.TestCase):
    def test_explicit_PC_UTC8_source_and_command_crc(self):
        payload = rtc_payload(datetime(2026, 10, 20, 20, 30, 59, tzinfo=timezone.utc))
        self.assertEqual(payload[:9].hex(), '5930042103102601e0')
        line = encode_command(2, 10, 1, 18, payload)
        raw = bytes.fromhex(line[3:].decode())
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[20:52], payload)
        self.assertEqual(int.from_bytes(raw[60:], 'big'), zlib.crc32(raw[:60]))
        with self.assertRaises(ValueError):
            rtc_payload(datetime(2026, 1, 1))

    def test_profile_and_empty_load_commands(self):
        encode_command(0, 1, 1, 18)
        encode_command(1, 2, 1, 18, PersistentConfig().encode())
        for op, token, payload in ((0, 0, bytes(32)), (1, 2, b'x'*32), (0, 1, b'x'*32), (3, 1, bytes(32))):
            with self.assertRaises(ValueError):
                encode_command(op, token, 1, 18, payload)

    def test_strict_results_keep_partial_failure_and_recovery_separate(self):
        record = decode_result(result_line())
        self.assertEqual((record.device, record.boot, record.rtc_offset_minutes), (1, 18, 480))
        self.assertIn('成功', record.text())
        record = decode_result(result_line(error=4, **{'25': 3, '27': 2}))
        self.assertEqual((record.error, record.detail, record.recovery_error), (4, 3, 2))
        self.assertIn('失败', record.text())
        for line in (result_line()[:-2], result_line(**{'75': 1}), result_line(**{'64': 0x20})):
            with self.assertRaises(ProtocolError):
                decode_result(line)
