"""EG v2 DDR window datagrams; independent of legacy PG v1 / AL-EI IDs.

The entire transaction is immutable. A successful DDR result AND complete,
consistent frame coverage are both required for ``complete``. No receipt-time
or low-byte seq fallback is used here. This module does not perform socket I/O.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass, field

from .protocol import ProtocolError

HEADER = struct.Struct("!2sBBHBB32sI12sIIIHHH6s")
TRANSACTION = struct.Struct("!IIIQQBBH")
META = struct.Struct("!IQ")
HEADER_LENGTH = 80
KIND_FRAME = 1
KIND_RESULT = 2
DEFERRED, RESULT_OK, FRAME_END, STREAM_BAD = 1, 2, 4, 8


@dataclass(frozen=True)
class WindowPacket:
    kind: int
    flags: int
    transaction: bytes
    frame_index: int
    frame_id: int
    frame_time_ms: int
    byte_offset: int
    frame_bytes: int
    planned_frames: int
    width: int
    height: int
    payload: bytes

    @property
    def identity(self) -> tuple[int, int, int, int]:
        return TRANSACTION.unpack(self.transaction)[:4]

    @property
    def source_time_ms(self) -> int:
        return TRANSACTION.unpack(self.transaction)[4]

    @property
    def deferred(self) -> bool:
        return bool(self.flags & DEFERRED)


def decode_window_packet(datagram: bytes) -> WindowPacket:
    if len(datagram) < HEADER_LENGTH + 4:
        raise ProtocolError("EG v2 datagram is too short")
    (magic, version, kind, header_length, flags, pixel_format, transaction,
     frame_index, meta, offset, frame_bytes, planned, length, width, height,
     reserved) = HEADER.unpack_from(datagram)
    if (magic, version, header_length, pixel_format) != (b"EG", 2, 80, 1):
        raise ProtocolError("unsupported EG v2 header")
    if kind not in (KIND_FRAME, KIND_RESULT) or flags & ~15 or reserved != bytes(6):
        raise ProtocolError("unsupported EG v2 kind/flags/reserved")
    if len(datagram) != HEADER_LENGTH + length + 4:
        raise ProtocolError("EG v2 payload length mismatch")
    if zlib.crc32(datagram[:-4]) != struct.unpack("!I", datagram[-4:])[0]:
        raise ProtocolError("EG v2 CRC mismatch")
    if not width or not height or frame_bytes != width * height * 2:
        raise ProtocolError("EG v2 frame dimensions mismatch")
    frame_id, frame_time_ms = META.unpack(meta)
    if kind == KIND_FRAME:
        if flags & RESULT_OK or planned or not 0 < length <= 1024 or (length | offset) & 1:
            raise ProtocolError("invalid EG v2 frame payload/flags")
        if offset + length > frame_bytes:
            raise ProtocolError("EG v2 payload exceeds frame")
        if bool(flags & FRAME_END) != (offset + length == frame_bytes):
            # Malformed source boundaries are retained only with STREAM_BAD;
            # they can never establish a successful window.
            if not flags & STREAM_BAD:
                raise ProtocolError("EG v2 frame end disagrees with offset")
    elif length or offset or meta != bytes(12) or flags & FRAME_END:
        raise ProtocolError("invalid EG v2 result body")
    return WindowPacket(kind, flags, transaction, frame_index, frame_id,
                        frame_time_ms, offset, frame_bytes, planned, width,
                        height, datagram[HEADER_LENGTH:-4])


@dataclass
class _Frame:
    metadata: tuple[int, int]
    chunks: dict[int, bytes] = field(default_factory=dict)
    ended: bool = False

    def complete(self, size: int) -> bool:
        cursor = 0
        for offset, payload in sorted(self.chunks.items()):
            if offset != cursor:
                return False
            cursor += len(payload)
        return self.ended and cursor == size


class WindowAssembly:
    """One reset-epoch identity. Caller owns retention/expiry and persistence."""

    def __init__(self, first: WindowPacket, *, max_frames: int = 256,
                 max_frame_bytes: int = 4 * 1024 * 1024,
                 max_window_bytes: int = 64 * 1024 * 1024) -> None:
        self.transaction = first.transaction
        self.identity = first.identity
        self.width, self.height = first.width, first.height
        self.frame_bytes = first.frame_bytes
        self.deferred = first.deferred
        self.max_frames = max_frames
        self.max_frame_bytes = max_frame_bytes
        self.max_window_bytes = max_window_bytes
        self.frames: dict[int, _Frame] = {}
        self.result: WindowPacket | None = None
        self.stream_bad = False
        self.conflict = False
        self._stored_bytes = 0
        self.add(first)

    def _reject(self, message: str) -> None:
        self.conflict = True
        raise ProtocolError(message)

    def add(self, packet: WindowPacket) -> None:
        if (packet.transaction != self.transaction or packet.width != self.width or
                packet.height != self.height or packet.frame_bytes != self.frame_bytes or
                packet.deferred != self.deferred):
            self._reject("EG v2 window identity/context conflict")
        if packet.frame_bytes > self.max_frame_bytes:
            self._reject("EG v2 frame exceeds capacity")
        self.stream_bad |= bool(packet.flags & STREAM_BAD)
        if packet.kind == KIND_RESULT:
            if packet.frame_index > self.max_frames or packet.planned_frames > self.max_frames:
                self._reject("EG v2 result exceeds frame capacity")
            if self.result is not None and self.result != packet:
                self._reject("conflicting EG v2 results")
            self.result = packet
            if packet.flags & RESULT_OK and (not packet.planned_frames or packet.frame_index != packet.planned_frames):
                self.stream_bad = True
            if any(index >= packet.frame_index for index in self.frames):
                self.stream_bad = True
            return
        if packet.frame_index >= self.max_frames:
            self._reject("EG v2 frame index exceeds capacity")
        if self.result and packet.frame_index >= self.result.frame_index:
            self.stream_bad = True
        frame = self.frames.get(packet.frame_index)
        if frame is None:
            frame = _Frame((packet.frame_id, packet.frame_time_ms))
            self.frames[packet.frame_index] = frame
        if frame.metadata != (packet.frame_id, packet.frame_time_ms):
            self._reject("EG v2 source frame metadata conflict")
        end = packet.byte_offset + len(packet.payload)
        for offset, payload in frame.chunks.items():
            if offset == packet.byte_offset and payload == packet.payload:
                frame.ended |= bool(packet.flags & FRAME_END)
                return  # byte-identical retransmission, not another frame
            if max(offset, packet.byte_offset) < min(offset + len(payload), end):
                self._reject("conflicting/overlapping EG v2 chunks")
        if self._stored_bytes + len(packet.payload) > self.max_window_bytes:
            self._reject("EG v2 window exceeds byte capacity")
        frame.chunks[packet.byte_offset] = packet.payload
        self._stored_bytes += len(packet.payload)
        frame.ended |= bool(packet.flags & FRAME_END)

    @property
    def status(self) -> str:
        if self.conflict or self.stream_bad or (self.result and not self.result.flags & RESULT_OK):
            return "failed"
        if self.result is None:
            return "awaiting_result"
        count = self.result.planned_frames
        if set(self.frames) != set(range(count)):
            return "partial"
        if not all(frame.complete(self.frame_bytes) for frame in self.frames.values()):
            return "partial"
        return "complete"

    def frame_data(self, index: int) -> bytes:
        frame = self.frames[index]
        if not frame.complete(self.frame_bytes):
            raise ProtocolError("EG v2 frame is incomplete")
        return b"".join(payload for _, payload in sorted(frame.chunks.items()))
