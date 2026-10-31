"""ASCII protocol definitions for host <-> FPGA communication."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Union

if TYPE_CHECKING:
    from .evidence_health import EvidenceHealth
    from .transaction_protocol import TransactionEventPacket
    from .rtc_anchor import RTCAnchor
    from .maintenance_protocol import MaintenanceResult
    from .board_monitor import BoardMonitor
    from .voice_protocol import VoiceStatus


class ProtocolError(ValueError):
    """Raised when an incoming protocol line is malformed."""


@dataclass
class RegionConfig:
    region_id: int
    x0: int
    y0: int
    x1: int
    y1: int


@dataclass
class EventPacket:
    frame_id: int
    timestamp: int
    stage_id: int
    zone_id: int
    risk_level: int
    event_code: int


@dataclass
class EvidencePacket:
    """One sample from the FPGA evidence ring.

    Field order matches the fixed-width ``EV`` line exactly.
    """

    seq: int
    index: int
    frame_id: int
    timestamp_ms: int
    stage_id: int
    risk_level: int
    zone_id: int
    event_code: int
    motion_pickup: int
    motion_operation: int
    motion_forbidden: int
    config_version: int
    health_flags: int


@dataclass
class EvidenceEndPacket:
    """Marks the end of an evidence window."""

    seq: int
    count: int


CONFIG_STATUS_NAMES = {
    0: "OK",
    1: "region out of range",
    2: "invalid x range",
    3: "invalid y range",
    4: "threshold out of range",
    5: "malformed line",
}


@dataclass
class ConfigAckPacket:
    """Acknowledgement of a configuration request."""

    version: int
    status: int

    @property
    def accepted(self) -> bool:
        return self.status == 0

    @property
    def status_name(self) -> str:
        return CONFIG_STATUS_NAMES.get(self.status, f"unknown ({self.status})")


@dataclass
class EventIdentityPacket:
    """Protocol v2 EI line: the event identity that follows an AL event.

    Fields are fixed-width hexadecimal: device, boot, session (32-bit each) and
    a 64-bit monotonic event uid. This is FPGA-issued runtime identity, not a
    cross-power-cycle persistent id (no EEPROM/RTC yet).
    """

    device_id: int
    boot_id: int
    session_id: int
    uid: int
    # v2.1: the per-event sequence the image evidence window also carries, so an
    # AL/EI can be bound to its window exactly. Absent in v2.0 EI lines.
    event_seq: int | None = None


@dataclass
class StatusPacket:
    frame_id: int
    state_id: int
    risk_level: int
    zone_id: int
    timestamp: int
    event_code: int
    motion_pickup: int = 0
    motion_operation: int = 0
    motion_forbidden: int = 0
    # C04/v2: health flags on the 11-field ST line. 0 = healthy. Absent in the
    # 10-field v1 line (defaults to 0; callers must not assume health was seen).
    health_flags: int = 0
    # v2.3 optional authoritative timer. Absent means unknown, never infer it
    # from uptime/AL reception. Both values belong to the same ST snapshot.
    remaining_s: int | None = None
    exam_duration_s: int | None = None
    evidence_health: EvidenceHealth | None = None


Packet = Union[
    StatusPacket,
    EventPacket,
    EventIdentityPacket,
    EvidencePacket,
    EvidenceEndPacket,
    ConfigAckPacket,
    "TransactionEventPacket",
    "RTCAnchor",
    "MaintenanceResult",
    "BoardMonitor",
    "VoiceStatus",
]


def encode_status(packet: StatusPacket) -> bytes:
    """Encode one status update as a newline-terminated ASCII line."""
    _validate_range("frame_id", packet.frame_id, 0, 0xFFFFFFFF)
    _validate_range("state_id", packet.state_id, 0, 0xF)
    _validate_range("risk_level", packet.risk_level, 0, 0xF)
    _validate_range("zone_id", packet.zone_id, 0, 0xF)
    _validate_range("timestamp", packet.timestamp, 0, 0xFFFFFFFFFFFFFFFF)
    _validate_range("event_code", packet.event_code, 0, 0xFF)
    _validate_range("motion_pickup", packet.motion_pickup, 0, 0xFF)
    _validate_range("motion_operation", packet.motion_operation, 0, 0xFF)
    _validate_range("motion_forbidden", packet.motion_forbidden, 0, 0xFF)
    _validate_status(packet)
    timer = (f",{packet.remaining_s},{packet.exam_duration_s}"
              if packet.remaining_s is not None else "")
    evidence = f",{packet.evidence_health.encode()}" if packet.evidence_health is not None else ""
    return (
        f"ST,{packet.frame_id},{packet.state_id},{packet.risk_level},"
        f"{packet.zone_id},{packet.timestamp},{packet.event_code},"
        f"{packet.motion_pickup},{packet.motion_operation},"
        f"{packet.motion_forbidden},{packet.health_flags}{timer}{evidence}\n"
    ).encode("ascii")


def encode_event(packet: EventPacket) -> bytes:
    """Encode one alarm event as a newline-terminated ASCII line."""
    _validate_range("frame_id", packet.frame_id, 0, 0xFFFFFFFF)
    _validate_range("timestamp", packet.timestamp, 0, 0xFFFFFFFFFFFFFFFF)
    _validate_range("stage_id", packet.stage_id, 0, 0xF)
    _validate_range("zone_id", packet.zone_id, 0, 0xF)
    _validate_range("risk_level", packet.risk_level, 0, 0xF)
    _validate_range("event_code", packet.event_code, 0, 0xFF)
    return (
        f"AL,{packet.frame_id},{packet.timestamp},{packet.stage_id},"
        f"{packet.zone_id},{packet.risk_level},{packet.event_code}\n"
    ).encode("ascii")


def encode_event_identity(packet: EventIdentityPacket) -> bytes:
    """Encode an ``EI`` identity line in the FPGA's fixed-width form.

    Identity fields are hex; the optional trailing event_seq is 3-digit decimal
    to mirror the serializer's ``event code`` field.
    """
    _validate_event_identity(packet)
    line = (f"EI,{packet.device_id:08x},{packet.boot_id:08x},"
            f"{packet.session_id:08x},{packet.uid:016x}")
    if packet.event_seq is not None:
        line += f",{packet.event_seq:03d}"
    return (line + "\n").encode("ascii")


def encode_evidence(packet: EvidencePacket) -> bytes:
    """Encode one evidence sample as a fixed-width ``EV`` line.

    The width matches the FPGA serializer, so a host-generated stream can be
    replayed through the real decoder in tests.
    """
    _validate_evidence(packet)
    return (
        f"EV,{packet.seq:03d},{packet.index:02d},{packet.frame_id:010d},"
        f"{packet.timestamp_ms:010d},{packet.stage_id},{packet.risk_level},"
        f"{packet.zone_id},{packet.event_code:03d},{packet.motion_pickup:03d},"
        f"{packet.motion_operation:03d},{packet.motion_forbidden:03d},"
        f"{packet.config_version:03d},{packet.health_flags:03d}\n"
    ).encode("ascii")


def encode_evidence_end(packet: EvidenceEndPacket) -> bytes:
    """Encode the evidence window terminator as an ``EO`` line."""
    _validate_evidence_end(packet)
    return f"EO,{packet.seq:03d},{packet.count:03d}\n".encode("ascii")


def encode_config_request(
    *,
    region_id: int,
    x0: int,
    y0: int,
    x1: int,
    y1: int,
    threshold: int,
) -> bytes:
    """Encode one ROI update request as an ``RC`` line.

    The FPGA owns the configuration version, so the host does not send one; it
    reads the accepted version back from the acknowledgement.
    """
    _validate_range("region_id", region_id, 1, 3)
    _validate_range("x0", x0, 0, 4095)
    _validate_range("y0", y0, 0, 4095)
    _validate_range("x1", x1, 0, 4095)
    _validate_range("y1", y1, 0, 4095)
    _validate_range("threshold", threshold, 0, 255)
    if x1 <= x0:
        raise ProtocolError("x1 must be greater than x0")
    if y1 <= y0:
        raise ProtocolError("y1 must be greater than y0")
    return (
        f"RC,{region_id},{x0},{y0},{x1},{y1},{threshold}\n".encode("ascii")
    )


def decode_packet(data: bytes | str) -> Packet:
    """Decode one `ST` or `AL` line from the FPGA."""
    if isinstance(data, bytes):
        try:
            line = data.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ProtocolError("packet is not ASCII") from exc
    else:
        line = data

    fields = line.strip().split(",")
    if not fields or not fields[0]:
        raise ProtocolError("empty packet")

    try:
        if fields[0] == "ST" and len(fields) in (10, 11, 13, 14):
            values = [_parse_int(value) for value in fields[1:10]]
            health = _parse_int(fields[10]) if len(fields) >= 11 else 0
            timer = (dict(remaining_s=_parse_int(fields[11]), exam_duration_s=_parse_int(fields[12]))
                     if len(fields) >= 13 else {})
            if len(fields) == 14:
                from .evidence_health import decode_evidence_health
                timer['evidence_health'] = decode_evidence_health(fields[13])
            packet = StatusPacket(*values, health_flags=health, **timer)
            _validate_status(packet)
            return packet
        if fields[0] == "AL" and len(fields) == 7:
            values = [_parse_int(value) for value in fields[1:]]
            packet = EventPacket(*values)
            _validate_event(packet)
            return packet
        if fields[0] == "ET" and len(fields) == 2:
            from .transaction_protocol import decode_transaction_event
            return decode_transaction_event(fields[1])
        if fields[0] == "RA" and len(fields) == 2:
            from .rtc_anchor import decode_rtc_anchor
            return decode_rtc_anchor(line.strip())
        if fields[0] == "MR" and len(fields) == 2:
            from .maintenance_protocol import decode_result
            return decode_result(line.strip())
        if fields[0] == "BM" and len(fields) == 2:
            from .board_monitor import decode_board_monitor
            return decode_board_monitor(line.strip())
        if fields[0] == "VI" and len(fields) == 2:
            from .voice_protocol import decode_voice_status
            return decode_voice_status(line.strip())
        if fields[0] == "EI" and len(fields) in (5, 6):
            try:
                values = [int(value, 16) for value in fields[1:5]]
            except ValueError as exc:
                raise ProtocolError("invalid hex field") from exc
            event_seq = _parse_int(fields[5]) if len(fields) == 6 else None
            packet = EventIdentityPacket(*values, event_seq=event_seq)
            _validate_event_identity(packet)
            return packet
        if fields[0] == "EV" and len(fields) == 14:
            values = [_parse_int(value) for value in fields[1:]]
            packet = EvidencePacket(*values)
            _validate_evidence(packet)
            return packet
        if fields[0] == "EO" and len(fields) == 3:
            values = [_parse_int(value) for value in fields[1:]]
            packet = EvidenceEndPacket(*values)
            _validate_evidence_end(packet)
            return packet
        if fields[0] == "CA" and len(fields) == 3:
            values = [_parse_int(value) for value in fields[1:]]
            packet = ConfigAckPacket(*values)
            _validate_config_ack(packet)
            return packet
    except (TypeError, ValueError) as exc:
        raise ProtocolError("invalid numeric field") from exc

    raise ProtocolError("unsupported packet shape")


def _parse_int(value: str) -> int:
    if not value or value.startswith("-"):
        raise ProtocolError("negative or empty numeric field")
    return int(value, 10)


def _validate_range(name: str, value: int, minimum: int, maximum: int) -> None:
    if not isinstance(value, int) or not minimum <= value <= maximum:
        raise ProtocolError(f"{name} out of range")


def _validate_status(packet: StatusPacket) -> None:
    if packet.evidence_health is not None:
        from .evidence_health import EvidenceHealth, decode_evidence_health
        if not isinstance(packet.evidence_health, EvidenceHealth) or packet.remaining_s is None:
            raise ProtocolError("evidence health requires typed extension and timer")
        decode_evidence_health(packet.evidence_health.encode())
    _validate_range("frame_id", packet.frame_id, 0, 0xFFFFFFFF)
    _validate_range("state_id", packet.state_id, 0, 0xF)
    _validate_range("risk_level", packet.risk_level, 0, 0xF)
    _validate_range("zone_id", packet.zone_id, 0, 0xF)
    _validate_range("timestamp", packet.timestamp, 0, 0xFFFFFFFFFFFFFFFF)
    _validate_range("event_code", packet.event_code, 0, 0xFF)
    _validate_range("motion_pickup", packet.motion_pickup, 0, 0xFF)
    _validate_range("motion_operation", packet.motion_operation, 0, 0xFF)
    _validate_range("motion_forbidden", packet.motion_forbidden, 0, 0xFF)
    _validate_range("health_flags", packet.health_flags, 0, 0xFF)
    if (packet.remaining_s is None) != (packet.exam_duration_s is None):
        raise ProtocolError("timer fields must be supplied together")
    if packet.remaining_s is not None:
        _validate_range("exam_duration_s", packet.exam_duration_s, 1, 65535)
        _validate_range("remaining_s", packet.remaining_s, 0, packet.exam_duration_s)


def _validate_event(packet: EventPacket) -> None:
    _validate_range("frame_id", packet.frame_id, 0, 0xFFFFFFFF)
    _validate_range("timestamp", packet.timestamp, 0, 0xFFFFFFFFFFFFFFFF)
    _validate_range("stage_id", packet.stage_id, 0, 0xF)
    _validate_range("zone_id", packet.zone_id, 0, 0xF)
    _validate_range("risk_level", packet.risk_level, 0, 0xF)
    _validate_range("event_code", packet.event_code, 0, 0xFF)


def _validate_event_identity(packet: EventIdentityPacket) -> None:
    _validate_range("device_id", packet.device_id, 0, 0xFFFFFFFF)
    _validate_range("boot_id", packet.boot_id, 0, 0xFFFFFFFF)
    _validate_range("session_id", packet.session_id, 0, 0xFFFFFFFF)
    _validate_range("uid", packet.uid, 0, 0xFFFFFFFFFFFFFFFF)
    if packet.event_seq is not None:
        _validate_range("event_seq", packet.event_seq, 0, 0xFFFF)


def _validate_evidence(packet: EvidencePacket) -> None:
    _validate_range("seq", packet.seq, 0, 0xFF)
    _validate_range("index", packet.index, 0, 0xFF)
    _validate_range("frame_id", packet.frame_id, 0, 0xFFFFFFFF)
    _validate_range("timestamp_ms", packet.timestamp_ms, 0, 0xFFFFFFFF)
    _validate_range("stage_id", packet.stage_id, 0, 0xF)
    _validate_range("risk_level", packet.risk_level, 0, 0xF)
    _validate_range("zone_id", packet.zone_id, 0, 0xF)
    _validate_range("event_code", packet.event_code, 0, 0xFF)
    _validate_range("motion_pickup", packet.motion_pickup, 0, 0xFF)
    _validate_range("motion_operation", packet.motion_operation, 0, 0xFF)
    _validate_range("motion_forbidden", packet.motion_forbidden, 0, 0xFF)
    _validate_range("config_version", packet.config_version, 0, 0xFF)
    _validate_range("health_flags", packet.health_flags, 0, 0xFF)


def _validate_evidence_end(packet: EvidenceEndPacket) -> None:
    _validate_range("seq", packet.seq, 0, 0xFF)
    _validate_range("count", packet.count, 0, 0xFF)


def _validate_config_ack(packet: ConfigAckPacket) -> None:
    _validate_range("version", packet.version, 0, 0xFF)
    _validate_range("status", packet.status, 0, 0xFF)
