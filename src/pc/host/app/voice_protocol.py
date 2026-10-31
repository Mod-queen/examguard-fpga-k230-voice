"""Candidate VI96 telemetry / VC64 commands; board endpoint not yet integrated."""
from dataclasses import dataclass
import re
import struct
import zlib

from .protocol import ProtocolError


def _record(line, magic, size):
    if isinstance(line, bytes):
        try:
            line = line.decode('ascii')
        except UnicodeError as exc:
            raise ProtocolError('voice record not ASCII') from exc
    match = re.fullmatch(magic + r',([0-9a-fA-F]{' + str(size * 2) + r'})\n?', line)
    if not match:
        raise ProtocolError('voice record length/hex')
    raw = bytes.fromhex(match[1])
    if raw[:3] != magic.encode() + b'\1' or int.from_bytes(raw[4:6], 'big') != size:
        raise ProtocolError('voice header')
    if int.from_bytes(raw[-4:], 'big') != zlib.crc32(raw[:-4]):
        raise ProtocolError('voice CRC')
    return raw


def _line(raw):
    raw[-4:] = zlib.crc32(raw[:-4]).to_bytes(4, 'big')
    return bytes(raw[:2]) + b',' + raw.hex().upper().encode() + b'\n'


@dataclass(frozen=True)
class VoiceStatus:
    raw: bytes
    flags: int
    stage: int
    device: int
    boot: int
    session: int
    sequence: int
    round_id: int
    info_tag: int
    ticket: int
    seat: int
    monotonic_ms: int
    face: int
    info_state: int
    exam_state: int
    error: int
    command_token: int
    command_op: int
    command_result: int

    @property
    def binding(self):
        return self.device, self.boot, self.round_id, self.info_tag

    @property
    def help_pending(self):
        return bool(self.flags & 16)

    def encode(self):
        return b'VI,' + self.raw.hex().upper().encode() + b'\n'


def decode_voice_status(line):
    raw = _record(line, 'VI', 96)
    if raw[3] or raw[6] & ~127 or raw[7] > 5 or any(raw[62:92]):
        raise ProtocolError('VI reserved/stage')
    device, boot, session, seq, round_id, tag, ticket, seat, stamp = struct.unpack_from('!IIIIIQIIQ', raw, 8)
    face, info_state, exam_state, error = raw[52:56]
    token = int.from_bytes(raw[56:60], 'big')
    op, result = raw[60:62]
    if not all((device, boot, seq, round_id, tag, seat)) or face not in (1, 2, 3):
        raise ProtocolError('VI identity')
    if info_state > 8 or exam_state > 11 or error > 3 or op > 5 or result > 4:
        raise ProtocolError('VI state/result')
    if bool(raw[6] & 16) and not ticket or raw[6] & 32 and not ticket:
        raise ProtocolError('VI missing help ticket')
    if raw[7] == 3 and not session:
        raise ProtocolError('VI exam session missing')
    return VoiceStatus(raw, raw[6], raw[7], device, boot, session, seq, round_id, tag,
                       ticket, seat, stamp, face, info_state, exam_state, error, token, op, result)


def encode_voice_command(operation, token, status, display=None):
    if operation not in (1, 2, 3, 4, 5) or not 0 < token <= 0xffffffff:
        raise ProtocolError('VC operation/token')
    if operation in (1, 3, 5) and status.stage != 2 or operation == 2 and not status.help_pending:
        raise ProtocolError('VC operation unavailable')
    raw = bytearray(64)
    raw[:6] = b'VC\1' + bytes([operation]) + b'\0\x40'
    struct.pack_into('!IIIIQII', raw, 8, token, status.device, status.boot,
                      status.round_id, status.info_tag, status.ticket if operation == 2 else 0, status.seat)
    if operation==5:
        if not isinstance(display,bytes) or len(display)!=16:
            raise ProtocolError('VC display payload needs16 bytes')
        raw[40:56]=display
    return _line(raw)


def decode_voice_command(line):
    raw = _record(line, 'VC', 64)
    if raw[3] not in (1, 2, 3, 4, 5) or any(raw[6:8]) or any(raw[56:60]) or (raw[3]!=5 and any(raw[40:56])):
        raise ProtocolError('VC reserved/operation')
    token, device, boot, round_id, tag, ticket, seat = struct.unpack_from('!IIIIQII', raw, 8)
    if not all((token, device, boot, round_id, tag, seat)) or (raw[3] != 2 and ticket) or (raw[3] == 2 and not ticket):
        raise ProtocolError('VC identity/ticket')
    return raw[3], token, device, boot, round_id, tag, ticket, seat
