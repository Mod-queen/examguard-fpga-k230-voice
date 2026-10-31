"""RA v1 read-only anchor record. No UTC assumption or event-clock adjustment."""
from dataclasses import dataclass
import re
import struct
import zlib

from .persistence_inventory import rtc_summary
from .protocol import ProtocolError


@dataclass(frozen=True)
class RTCAnchor:
    raw: bytes
    device: int
    boot: int
    sequence: int
    lower_ms: int
    upper_ms: int
    error: int
    calendar_raw: bytes

    @property
    def trusted(self):
        return self.error == 0

    @property
    def calendar(self):
        return rtc_summary(self.calendar_raw)

    def text(self):
        calendar = self.calendar['local_datetime_unzoned'] if self.trusted else '无可信日期'
        return (f'RTC锚 {self.device}/{self.boot}/#{self.sequence} error={self.error} '
                f'{calendar}（无时区）单调读区间[{self.lower_ms},{self.upper_ms}]ms；不替换事件源时间')

    def encode(self):
        return b'RA,' + self.raw.hex().upper().encode('ascii') + b'\n'


def decode_rtc_anchor(line: bytes | str) -> RTCAnchor:
    if isinstance(line, bytes):
        try:
            line = line.decode('ascii')
        except UnicodeError as exc:
            raise ProtocolError('RA is not ASCII') from exc
    match = re.fullmatch(r'RA,([0-9a-fA-F]{128})\n?', line)
    if not match:
        raise ProtocolError('invalid RA line length/hex')
    raw = bytes.fromhex(match[1])
    if raw[:6] != b'RA\x01\x01\x00\x40' or any(raw[45:60]):
        raise ProtocolError('invalid RA header/reserved')
    if zlib.crc32(raw[:60]) != int.from_bytes(raw[60:], 'big'):
        raise ProtocolError('RA CRC mismatch')
    flags, error = raw[6:8]
    if error > 4 or flags != (1 if error == 0 else 0):
        raise ProtocolError('invalid RA trust/error flags')
    device, boot, sequence, lower, upper = struct.unpack_from('!IIIQQ', raw, 8)
    if not device or not boot or not sequence or (error != 4 and upper < lower):
        raise ProtocolError('invalid RA identity/bracket')
    record = RTCAnchor(raw, device, boot, sequence, lower, upper, error, raw[36:45])
    if record.trusted and not record.calendar['calendar_valid']:
        raise ProtocolError('RA claims trusted invalid calendar')
    return record
