"""Read-only VD96 diagnostic decoder. Not a VI business-state substitute."""
from dataclasses import dataclass
import struct
from .voice_protocol import _record
from .protocol import ProtocolError


@dataclass(frozen=True)
class VoiceDiagnostics:
    raw: bytes
    flags: int
    stage: int
    device: int
    boot: int
    sequence: int
    monotonic_ms: int
    polls: int
    poll_ok: int
    nacks: int
    timeouts: int
    other_errors: int
    writes: int
    write_ok: int
    last_poll_error: int
    last_write_error: int
    last_clip: int
    last_data: int
    poll_stage: int
    poll_byte: int
    write_stage: int
    write_byte: int
    startup_error: int
    startup_stage: int
    startup_byte: int
    startup_requests: int
    startup_responses: int


def decode_voice_diagnostics(line):
    raw = _record(line.strip(), 'VD', 96)
    if raw[3] or raw[6] & 0xc0 or raw[7] > 5 or raw[67:70] != bytes((0, 0xd0, 0xe0)) or any(raw[78:92]):
        raise ProtocolError('VD reserved/stage/mapping')
    device, boot, seq, stamp = struct.unpack_from('!IIIQ', raw, 8)
    if not all((device, boot, seq)):
        raise ProtocolError('VD identity')
    values = struct.unpack_from('!7I', raw, 28)
    if any(raw[index] not in (0, 1, 2, 3, 255) for index in (56, 57, 64)):
        raise ProtocolError('VD error code')
    if any(raw[index] > 8 for index in (60, 62, 65)):
        raise ProtocolError('VD bus stage')
    requests, responses = struct.unpack_from('!II', raw, 70)
    return VoiceDiagnostics(raw, raw[6], raw[7], device, boot, seq, stamp,
                            *values, *raw[56:67], requests, responses)
