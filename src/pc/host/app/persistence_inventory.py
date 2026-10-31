"""Strict PS1 read-only RTC/EEPROM inventory report decoder."""
from __future__ import annotations

from datetime import datetime
import hashlib
import struct
import zlib

HEADER = b'PS\x01\x01\x01\x1c'
LENGTH = 284


def rtc_summary(raw: bytes) -> dict:
    if len(raw) != 9:
        raise ValueError('RTC snapshot must contain registers 00..08')
    reasons = []
    if raw[2] & 0x80:
        reasons.append('voltage_low')
    if raw[0] & 0x20:
        reasons.append('stopped')
    if raw[0] & 0x88:
        reasons.append('test_mode')
    if raw[7] & 0x80:
        reasons.append('unsupported_century')

    def bcd(n):
        if n & 15 > 9 or n >> 4 > 9:
            raise ValueError('invalid_bcd')
        return (n >> 4) * 10 + (n & 15)

    text = None
    try:
        text = datetime(2000 + bcd(raw[8]), bcd(raw[7] & 31), bcd(raw[5] & 63),
                        bcd(raw[4] & 63), bcd(raw[3] & 127), bcd(raw[2] & 127)).isoformat()
        if raw[6] & 7 > 6:
            reasons.append('invalid_weekday')
    except ValueError:
        reasons.append('invalid_calendar')
    return {'raw_hex': raw.hex(), 'calendar_valid': not reasons, 'reasons': reasons,
            'local_datetime_unzoned': text,
            'interpretation': 'Single raw read only: not rollover-checked, UTC, calibrated, or an event time anchor.'}


def slot_summary(raw: bytes) -> dict:
    if len(raw) != 96:
        raise ValueError('slot used area must contain 96 bytes')
    body, commit = raw[:64], raw[64:]
    device, generation, boot = struct.unpack_from('<III', body, 8)
    body_crc = zlib.crc32(body[:60])
    reasons = []
    if body[:8] != b'EGCF\x01\x40\0\0':
        reasons.append('body_header')
    if not device or not generation or not boot:
        reasons.append('zero_identity')
    if body[52:60] != bytes(8):
        reasons.append('body_reserved')
    if int.from_bytes(body[60:], 'little') != body_crc:
        reasons.append('body_crc')
    if commit[:4] != b'EGCM':
        reasons.append('commit_magic')
    gen, inverse, crc = struct.unpack_from('<III', commit, 4)
    if (gen, inverse, crc) != (generation, generation ^ 0xffffffff, body_crc):
        reasons.append('commit_binding')
    if commit[16:28] != bytes(12):
        reasons.append('commit_reserved')
    if int.from_bytes(commit[28:], 'little') != zlib.crc32(commit[:28]):
        reasons.append('commit_crc')
    return {'blank': raw == b'\xff' * 96, 'valid': not reasons, 'reasons': reasons,
            'device': device, 'generation': generation, 'boot': boot,
            'config_hex': body[20:52].hex()}


def decode_report(raw: bytes) -> dict:
    if len(raw) != LENGTH or raw[:6] != HEADER:
        raise ValueError('wrong/incomplete PS1 header or length (expected 284 bytes)')
    if zlib.crc32(raw[:-4]) != int.from_bytes(raw[-4:], 'big'):
        raise ValueError('PS1 CRC mismatch')
    errors = list(raw[6:15])
    if any(e > 3 for e in errors):
        raise ValueError('invalid I2C error code')
    eeprom = raw[24:280]
    slots = []
    for index in range(2):
        # Each slot uses 3 pages out of 4 in the inventory window.
        first_page = index * 4
        available = all(e == 0 for e in errors[1 + first_page:4 + first_page])
        summary = slot_summary(eeprom[index * 128:index * 128 + 96]) if available else {'valid': False, 'blank': None, 'reasons': ['i2c_unavailable']}
        summary.update(index=index, address=0x1e00 + index * 128, available=available)
        slots.append(summary)
    valid = [s for s in slots if s['valid']]
    ambiguous = len(valid) == 2 and (valid[0]['device'] != valid[1]['device'] or valid[0]['generation'] == valid[1]['generation'])
    selected = max(valid, key=lambda s: s['generation'])['index'] if valid and not ambiguous else None
    rtc = rtc_summary(raw[15:24]) if not errors[0] else {'calendar_valid': False, 'reasons': ['i2c_unavailable']}
    return {'schema': 'examguard-persistence-inventory-v1', 'raw_sha256': hashlib.sha256(raw).hexdigest(),
            'i2c_errors': errors, 'all_devices_responded': not any(errors), 'rtc': rtc,
            'eeprom_base': 0x1e00, 'eeprom_bytes': 256, 'eeprom_sha256': hashlib.sha256(eeprom).hexdigest(),
            'eeprom_hex': eeprom.hex(), 'reserved_used_bytes_blank': all(s['available'] and s['blank'] for s in slots),
            'slots': slots, 'ambiguous_slots': ambiguous, 'selected_slot': selected,
            'interpretation': 'Read-only inventory; no RTC clock write, EEPROM format, boot allocation, or proof of persistent event identity.'}
