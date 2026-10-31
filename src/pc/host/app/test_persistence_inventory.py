import struct
import unittest
import zlib

from app.persistence_inventory import HEADER, decode_report


def packet(rtc=None, eeprom=None, errors=None):
    rtc = rtc if rtc is not None else bytes.fromhex('000056341219011026')
    eeprom = eeprom if eeprom is not None else b'\xff' * 256
    raw = HEADER + bytes(errors or [0] * 9) + rtc + eeprom
    return raw + zlib.crc32(raw).to_bytes(4, 'big')


def slot(generation, boot):
    body = bytearray(b'EGCF\x01\x40\0\0' + struct.pack('<III', 1, generation, boot) + bytes(40))
    body += zlib.crc32(body).to_bytes(4, 'little')
    commit = b'EGCM' + struct.pack('<III', generation, generation ^ 0xffffffff, zlib.crc32(body[:60])) + bytes(12)
    commit += zlib.crc32(commit).to_bytes(4, 'little')
    return bytes(body) + commit + b'\xff' * 32


class InventoryTests(unittest.TestCase):
    def test_blank_and_rtc(self):
        report = decode_report(packet())
        self.assertTrue(report['all_devices_responded'])
        self.assertTrue(report['reserved_used_bytes_blank'])
        self.assertEqual(report['rtc']['local_datetime_unzoned'], '2026-10-19T12:34:56')
        self.assertIsNone(report['selected_slot'])

    def test_crc_framing_rejects(self):
        raw = packet()
        for changed in (raw[:-1], b'x' + raw, raw + raw, raw[:60] + bytes([raw[60] ^ 1]) + raw[61:]):
            with self.assertRaises(ValueError):
                decode_report(changed)

    def test_slot_selection_crc_and_ambiguity(self):
        report = decode_report(packet(eeprom=slot(2, 2) + slot(3, 3)))
        self.assertEqual(report['selected_slot'], 1)
        bad = bytearray(slot(3, 3)); bad[20] ^= 1
        self.assertEqual(decode_report(packet(eeprom=slot(2, 2) + bad))['selected_slot'], 0)
        self.assertTrue(decode_report(packet(eeprom=slot(2, 2) + slot(2, 2)))['ambiguous_slots'])

    def test_failed_reads_not_blank_or_trusted(self):
        report = decode_report(packet(errors=[1] + [2] * 8, rtc=bytes(9), eeprom=bytes(256)))
        self.assertFalse(report['reserved_used_bytes_blank'])
        self.assertFalse(report['all_devices_responded'])
        self.assertFalse(report['rtc']['calendar_valid'])
        self.assertFalse(report['slots'][0]['available'])

    def test_rtc_invalid_reasons(self):
        self.assertIn('voltage_low', decode_report(packet(rtc=bytes.fromhex('0000d6341219011026')))['rtc']['reasons'])
        self.assertFalse(decode_report(packet(rtc=bytes.fromhex('000000000031010226')))['rtc']['calendar_valid'])
