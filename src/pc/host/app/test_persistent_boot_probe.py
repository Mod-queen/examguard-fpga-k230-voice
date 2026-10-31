import struct
import unittest
import zlib

from .persistent_boot_probe import decode_report


def record(generation, boot):
    body = bytearray(b'EGCF\x01\x40\0\0' + bytes(56))
    struct.pack_into('<III', body, 8, 1, generation, boot)
    struct.pack_into('<I', body, 60, zlib.crc32(body[:60]))
    commit = bytearray(b'EGCM' + bytes(28))
    struct.pack_into('<III', commit, 4, generation, generation ^ 0xffffffff, zlib.crc32(body[:60]))
    struct.pack_into('<I', commit, 28, zlib.crc32(commit[:28]))
    return bytes(body + commit) + b'\xff' * 32


def packet(boot=1, error=0):
    result = bytearray(b'PB\x01\x01\0\x40' + bytes(58))
    slot = (boot - 1) % 2
    result[6:10] = bytes((2 if boot == 1 else 0, 3 if boot == 1 else 1, error, 3 | (slot << 2)))
    struct.pack_into('<III', result, 12, 1, boot, boot)
    result[60:] = zlib.crc32(result[:60]).to_bytes(4, 'big')
    media = bytearray(b'\xff' * 256)
    media[slot * 128:(slot + 1) * 128] = record(boot, boot)
    if boot > 1:
        media[(1 - slot) * 128:(2 - slot) * 128] = record(boot - 1, boot - 1)
    inventory = b'PS\x01\x01\x01\x1c' + bytes(9) + bytes.fromhex('000035401420021026') + media
    return bytes(result) + inventory + zlib.crc32(inventory).to_bytes(4, 'big')


class BootProbeTests(unittest.TestCase):
    def test_first_format_and_two_resets(self):
        one, two, three = packet(1), packet(2), packet(3)
        self.assertTrue(decode_report(one)['verified'])
        self.assertTrue(decode_report(two, one)['verified'])
        self.assertTrue(decode_report(three, two)['verified'])

    def test_crc_framing_and_reserved(self):
        original = packet()
        for offset in (0, 12, 63, 100, 347):
            bad = bytearray(original); bad[offset] ^= 1
            with self.assertRaises(ValueError):
                decode_report(bytes(bad))
        for bad in (original[:-1], original + b'\0'):
            with self.assertRaises(ValueError):
                decode_report(bad)
        bad = bytearray(original); bad[10] = 1
        bad[60:64] = zlib.crc32(bad[:60]).to_bytes(4, 'big')
        with self.assertRaises(ValueError):
            decode_report(bytes(bad))

    def test_no_success_from_crc_alone(self):
        self.assertFalse(decode_report(packet(error=9))['verified'])
        bad = bytearray(packet()); bad[24] = 1
        bad[60:64] = zlib.crc32(bad[:60]).to_bytes(4, 'big')
        self.assertIn('independent_inventory_result_mismatch', decode_report(bytes(bad))['reasons'])

    def test_skipped_repeated_and_changed_old_slot(self):
        self.assertFalse(decode_report(packet(3), packet(1))['verified'])
        self.assertFalse(decode_report(packet(2), packet(2))['verified'])
        bad = bytearray(packet(2))
        bad[88:216] = record(7, 7)  # independently CRC-valid old slot, incorrectly changed
        bad[-4:] = zlib.crc32(bad[64:-4]).to_bytes(4, 'big')
        self.assertIn('previous_active_slot_changed', decode_report(bytes(bad), packet(1))['reasons'])

    def test_inventory_error_and_tail(self):
        for offset in (71, 88 + 96):
            bad = bytearray(packet()); bad[offset] = 1
            bad[-4:] = zlib.crc32(bad[64:-4]).to_bytes(4, 'big')
            self.assertFalse(decode_report(bytes(bad))['verified'])


if __name__ == '__main__':
    unittest.main()
