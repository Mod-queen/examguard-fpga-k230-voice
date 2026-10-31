"""EEPROM config256 application profile; zero is the existing legacy defaults.

This codec does not write hardware or change capture event identity. Stored RTC
offset is fixed-offset metadata only; None preserves the unzoned RTC contract.
"""
from dataclasses import dataclass
import struct


@dataclass(frozen=True)
class PersistentConfig:
    seat_id: int = 1
    exam_duration_s: int = 2700
    rtc_offset_minutes: int | None = None
    mute: bool = False

    def validate(self):
        if type(self.seat_id) is not int or not 1 <= self.seat_id <= 0xffffffff:
            raise ValueError('seat_id must be 1..FFFFFFFF; not the device identity')
        if type(self.exam_duration_s) is not int or not 60 <= self.exam_duration_s <= 7200:
            raise ValueError('exam_duration_s must be 60..7200')
        if self.rtc_offset_minutes is not None and (type(self.rtc_offset_minutes) is not int or
                                                   not -720 <= self.rtc_offset_minutes <= 840):
            raise ValueError('RTC fixed offset must be -720..840 minutes or unknown')
        if type(self.mute) is not bool:
            raise ValueError('mute must be boolean')
        return self

    def encode(self):
        self.validate()
        offset = 0x7fff if self.rtc_offset_minutes is None else self.rtc_offset_minutes
        return b'EGP1\x01\x20\0\0' + struct.pack('<IHhB', self.seat_id, self.exam_duration_s,
                                                offset, int(self.mute)) + bytes(15)


def decode_config(raw):
    if type(raw) is not bytes or len(raw) != 32:
        raise ValueError('Configuration requires exactly 32 bytes')
    if raw == bytes(32):
        return PersistentConfig()
    if raw[:8] != b'EGP1\x01\x20\0\0' or raw[16] & 0xfe or raw[17:] != bytes(15):
        raise ValueError('Unsupported configuration header/reserved fields')
    seat, duration, offset, flags = struct.unpack_from('<IHhB', raw, 8)
    return PersistentConfig(seat, duration, None if offset == 0x7fff else offset, bool(flags)).validate()
