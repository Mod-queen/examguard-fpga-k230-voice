"""Boot-bound MC/MR maintenance records; no implicit retries or old-RA rezoning."""
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import re
import struct
import zlib

from .persistent_config import decode_config
from .persistence_inventory import rtc_summary
from .protocol import ProtocolError

ERRORS = {0: '成功', 1: '启动未准入或考试中', 2: '不支持的操作', 3: '配置失败',
          4: 'RTC校时失败', 5: '命令字段非法', 6: '设备/boot不匹配',
          7: '请求号已用于其它内容', 8: '请求号过旧', 9: '内部操作回执不一致'}


def encode_command(operation, request_id, device, boot, payload=bytes(32)):
    if operation not in (0, 1, 2) or type(payload) is not bytes or len(payload) != 32:
        raise ValueError('Invalid maintenance operation or payload')
    if any(type(v) is not int or not 1 <= v <= 0xffffffff for v in (request_id, device, boot)):
        raise ValueError('Nonzero uint32 request/device/boot required')
    if operation == 0 and any(payload):
        raise ValueError('LOAD takes no payload')
    if operation == 1:
        decode_config(payload)
    if operation == 2:
        if any(payload[9:]) or not -720 <= int.from_bytes(payload[7:9], 'big', signed=True) <= 840:
            raise ValueError('Invalid RTC offset/reserved')
        if not rtc_summary(bytes(2) + payload[:7])['calendar_valid']:
            raise ValueError('Invalid RTC calendar')
    raw = b'MC\x01\x01\x00\x40' + bytes((operation, 0)) + struct.pack('!III', request_id, device, boot) + payload + bytes(8)
    return b'MC,' + (raw + zlib.crc32(raw).to_bytes(4, 'big')).hex().upper().encode() + b'\n'


def rtc_payload(now=None, offset_minutes=480):
    """PC clock converted explicitly to agreed fixed UTC+8 by default."""
    if type(offset_minutes) is not int or not -720 <= offset_minutes <= 840:
        raise ValueError('Invalid fixed UTC offset')
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError('Clock source must be timezone-aware')
    date = now.astimezone(timezone(timedelta(minutes=offset_minutes)))
    if not 2000 <= date.year <= 2099:
        raise ValueError('RTC supports 2000..2099 only')
    bcd = lambda v: (v // 10) * 16 + v % 10
    return bytes((bcd(date.second), bcd(date.minute), bcd(date.hour), bcd(date.day),
                  date.isoweekday() % 7, bcd(date.month), bcd(date.year - 2000))) + struct.pack('!h', offset_minutes) + bytes(23)


@dataclass(frozen=True)
class MaintenanceResult:
    raw: bytes
    operation: int
    error: int
    request_id: int
    device: int
    boot: int
    generation: int
    config_known: bool
    detail: int
    store_error: int
    recovery_error: int
    write_attempted: bool
    config_raw: bytes
    rtc_raw: bytes
    rtc_offset_minutes: int | None

    def text(self):
        return (f'维护#{self.request_id} op={self.operation} {self.device}/{self.boot} gen={self.generation} '
                f'{ERRORS[self.error]} detail={self.detail} store={self.store_error} recovery={self.recovery_error}')


def decode_result(line):
    if isinstance(line, bytes):
        try:
            line = line.decode('ascii')
        except UnicodeError as exc:
            raise ProtocolError('MR is not ASCII') from exc
    match = re.fullmatch(r'MR,([0-9a-fA-F]{192})\n?', line)
    if not match:
        raise ProtocolError('Invalid MR length/hex')
    raw = bytes.fromhex(match[1])
    if raw[:6] != b'MR\x01\x01\x00\x60' or zlib.crc32(raw[:92]) != int.from_bytes(raw[92:], 'big'):
        raise ProtocolError('Invalid MR header/CRC')
    operation, error = raw[6:8]
    token, device, boot, generation = struct.unpack_from('!IIII', raw, 8)
    if error not in ERRORS or not device or (not token and error != 5) or raw[24] > 1 or raw[25] > 6 or raw[26] > 15 or raw[27] > 3 or raw[28] > 1 or any(raw[29:32]) or any(raw[75:92]):
        raise ProtocolError('Invalid MR identity/flags/reserved')
    if not error and (operation > 2 or not boot or not generation):
        raise ProtocolError('Invalid successful MR')
    config = raw[32:64]
    if raw[24]:
        try:
            decode_config(config)
        except ValueError as exc:
            raise ProtocolError('MR claims known invalid config') from exc
    offset = int.from_bytes(raw[73:75], 'big', signed=True)
    if offset != 0x7fff and not -720 <= offset <= 840:
        raise ProtocolError('Invalid MR RTC offset')
    if operation == 2 and error == 0 and not rtc_summary(raw[64:73])['calendar_valid']:
        raise ProtocolError('MR claims successful invalid RTC')
    return MaintenanceResult(raw, operation, error, token, device, boot, generation,
                             bool(raw[24]), raw[25], raw[26], raw[27], bool(raw[28]),
                             config, raw[64:73], None if offset == 0x7fff else offset)
