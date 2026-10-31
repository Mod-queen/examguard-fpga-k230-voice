"""Application packets for FPGA image evidence over UDP."""

from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass
from pathlib import Path

from .image_store import ImageEvidenceFrame, write_image_evidence
from .protocol import ProtocolError


MAGIC = b"PG"
VERSION = 1
KIND_IMAGE_FRAME = 1
PIXEL_FORMAT_GRAY8 = 0
PIXEL_FORMAT_RGB565 = 1
HEADER_LENGTH = 32
MAX_PAYLOAD = 1024
HEADER = struct.Struct("!2sBBHBBHIHIIBBHHH")

_FORMAT_NAMES = {PIXEL_FORMAT_GRAY8: "GRAY8", PIXEL_FORMAT_RGB565: "RGB565"}


def bytes_per_pixel(pixel_format: int) -> int:
    if pixel_format == PIXEL_FORMAT_RGB565:
        return 2
    if pixel_format == PIXEL_FORMAT_GRAY8:
        return 1
    raise ProtocolError(f"unsupported pixel format: {pixel_format}")


@dataclass(frozen=True)
class ImageFrameChunk:
    """One application datagram before or after wire encoding."""

    event_seq: int
    frame_index: int
    frame_count: int
    frame_id: int
    timestamp_ms: int
    config_version: int
    width: int
    height: int
    pixel_offset: int
    payload: bytes
    pixel_format: int = PIXEL_FORMAT_GRAY8


def encode_image_chunk(chunk: ImageFrameChunk) -> bytes:
    _validate_chunk(chunk)
    header = HEADER.pack(
        MAGIC,
        VERSION,
        KIND_IMAGE_FRAME,
        HEADER_LENGTH,
        chunk.event_seq,
        chunk.frame_index,
        chunk.frame_count,
        chunk.pixel_offset,
        len(chunk.payload),
        chunk.frame_id,
        chunk.timestamp_ms,
        chunk.config_version,
        chunk.pixel_format,
        chunk.width,
        chunk.height,
        0,
    )
    crc = zlib.crc32(header + chunk.payload) & 0xFFFFFFFF
    return header + chunk.payload + struct.pack("!I", crc)


def decode_image_chunk(datagram: bytes) -> ImageFrameChunk:
    if len(datagram) < HEADER_LENGTH + 4:
        raise ProtocolError("image datagram is too short")
    fields = HEADER.unpack(datagram[:HEADER_LENGTH])
    (
        magic,
        version,
        kind,
        header_length,
        event_seq,
        frame_index,
        frame_count,
        pixel_offset,
        payload_length,
        frame_id,
        timestamp_ms,
        config_version,
        pixel_format,
        width,
        height,
        _reserved_b,
    ) = fields
    if magic != MAGIC or version != VERSION or kind != KIND_IMAGE_FRAME:
        raise ProtocolError("unsupported image datagram")
    if header_length != HEADER_LENGTH:
        raise ProtocolError("unsupported image header length")
    if payload_length != len(datagram) - HEADER_LENGTH - 4:
        raise ProtocolError("image payload length mismatch")
    expected_crc = struct.unpack("!I", datagram[-4:])[0]
    actual_crc = zlib.crc32(datagram[:-4]) & 0xFFFFFFFF
    if actual_crc != expected_crc:
        raise ProtocolError("image datagram CRC mismatch")
    chunk = ImageFrameChunk(
        event_seq=event_seq,
        frame_index=frame_index,
        frame_count=frame_count,
        frame_id=frame_id,
        timestamp_ms=timestamp_ms,
        config_version=config_version,
        width=width,
        height=height,
        pixel_offset=pixel_offset,
        payload=datagram[HEADER_LENGTH:-4],
        pixel_format=pixel_format,
    )
    _validate_chunk(chunk)
    return chunk


def _validate_chunk(chunk: ImageFrameChunk) -> None:
    values = (
        ("event_seq", chunk.event_seq, 0, 0xFF),
        ("frame_index", chunk.frame_index, 0, 0xFF),
        ("frame_count", chunk.frame_count, 1, 0xFFFF),
        ("frame_id", chunk.frame_id, 0, 0xFFFFFFFF),
        ("timestamp_ms", chunk.timestamp_ms, 0, 0xFFFFFFFF),
        ("config_version", chunk.config_version, 0, 0xFF),
        ("width", chunk.width, 1, 0xFFFF),
        ("height", chunk.height, 1, 0xFFFF),
        ("pixel_offset", chunk.pixel_offset, 0, 0xFFFFFFFF),
    )
    for name, value, minimum, maximum in values:
        if not isinstance(value, int) or not minimum <= value <= maximum:
            raise ProtocolError(f"{name} out of range")
    if chunk.frame_index >= chunk.frame_count:
        raise ProtocolError("frame index is outside frame count")
    if chunk.pixel_format not in _FORMAT_NAMES:
        raise ProtocolError("unsupported image pixel format")
    if not isinstance(chunk.payload, bytes):
        raise ProtocolError("image payload must be bytes")
    if not 0 < len(chunk.payload) <= MAX_PAYLOAD:
        raise ProtocolError("image payload length out of range")
    frame_size = chunk.width * chunk.height * bytes_per_pixel(chunk.pixel_format)
    if chunk.pixel_offset + len(chunk.payload) > frame_size:
        raise ProtocolError("image payload exceeds frame size")


class EvidenceUdpReassembler:
    """Reassemble out-of-order image datagrams and persist completed events."""

    def __init__(self) -> None:
        self._assemblies: dict[tuple[int, int], dict[str, object]] = {}
        self._frames: dict[tuple[int, int], ImageEvidenceFrame] = {}
        self._frame_counts: dict[int, int] = {}
        self._window_base: dict[int, int] = {}
        self._fallback_width = 0
        self._fallback_height = 0

    def current_base(self, event_seq: int) -> int | None:
        """Implied frame-0 id of the window currently buffered for an event."""
        return self._window_base.get(event_seq)

    def ingest(self, datagram: bytes) -> ImageEvidenceFrame | None:
        chunk = decode_image_chunk(datagram)
        base = _frame0_id(chunk.frame_id, chunk.frame_index)
        known_base = self._window_base.get(chunk.event_seq)
        if known_base is None:
            self._window_base[chunk.event_seq] = base
        elif base != known_base:
            if not _frame_base_newer(base, known_base):
                # A late datagram from a window we have already moved past.
                return None
            # The FPGA reuses the 8-bit event_seq for a later window; drop the
            # stale window so its chunks do not collide with this one.
            self._reset_event(chunk.event_seq)
            self._window_base[chunk.event_seq] = base
        self._frame_counts[chunk.event_seq] = chunk.frame_count
        self._fallback_width = chunk.width
        self._fallback_height = chunk.height
        key = (chunk.event_seq, chunk.frame_index)
        if key in self._frames:
            return None

        total = chunk.width * chunk.height * bytes_per_pixel(chunk.pixel_format)
        assembly = self._assemblies.get(key)
        if assembly is None:
            assembly = {
                "chunk": chunk,
                "pixels": bytearray(total),
                "received": bytearray(total),
                "received_count": 0,
            }
            self._assemblies[key] = assembly
        else:
            original = assembly["chunk"]
            if not isinstance(original, ImageFrameChunk) or not _same_frame(original, chunk):
                raise ProtocolError("image chunks disagree on frame metadata")

        pixels = assembly["pixels"]
        received = assembly["received"]
        if not isinstance(pixels, bytearray) or not isinstance(received, bytearray):
            raise RuntimeError("invalid reassembly state")
        received_count = int(assembly["received_count"])
        for offset, value in enumerate(chunk.payload, start=chunk.pixel_offset):
            if received[offset]:
                if pixels[offset] != value:
                    raise ProtocolError("conflicting duplicate image chunk")
            else:
                pixels[offset] = value
                received[offset] = 1
                received_count += 1
        assembly["received_count"] = received_count
        if received_count != total:
            return None

        frame = ImageEvidenceFrame(
            seq=chunk.event_seq,
            index=chunk.frame_index,
            frame_id=chunk.frame_id,
            timestamp_ms=chunk.timestamp_ms,
            config_version=chunk.config_version,
            width=chunk.width,
            height=chunk.height,
            pixels=bytes(pixels),
            pixel_format=_FORMAT_NAMES[chunk.pixel_format],
        )
        self._frames[key] = frame
        del self._assemblies[key]
        return frame

    def write_event(
        self,
        root: str | Path,
        event_seq: int,
        expected_count: int | None = None,
        require_frames: bool = True,
        directory_suffix: str = "",
    ) -> Path:
        """Persist one event window, optionally allowing missing/empty frames.

        With require_frames=False a window may be written even when some or all
        of its image frames never fully arrived (UDP loss), so partial evidence
        is still preserved with a complete=False manifest.
        """
        if expected_count is None:
            expected_count = self._frame_counts.get(event_seq)
        if expected_count is None:
            raise ValueError("no image datagrams received for event")
        frames = [
            frame
            for (seq, _index), frame in sorted(self._frames.items())
            if seq == event_seq
        ]
        if not frames and require_frames:
            raise ValueError("no complete image frames received for event")
        first = frames[0] if frames else None
        return write_image_evidence(
            root,
            event_seq=event_seq,
            expected_count=expected_count,
            frames=frames,
            width=first.width if first else self._fallback_width,
            height=first.height if first else self._fallback_height,
            pixel_format=first.pixel_format if first else "GRAY8",
            directory_suffix=directory_suffix,
        )

    def forget(self, event_seq: int) -> None:
        """Drop any buffered state for an event that has already been written.

        The FPGA event sequence is 8-bit and can repeat (or a single incident
        can trigger several windows), so a finished event must be released
        before the same sequence number is used again.
        """
        self._reset_event(event_seq)
        self._frame_counts.pop(event_seq, None)
        self._window_base.pop(event_seq, None)

    def _reset_event(self, event_seq: int) -> None:
        for key in [k for k in self._frames if k[0] == event_seq]:
            del self._frames[key]
        for key in [k for k in self._assemblies if k[0] == event_seq]:
            del self._assemblies[key]


def _frame0_id(frame_id: int, frame_index: int) -> int:
    """Frame id that frame 0 of this window would carry.

    Within one evidence window ``frame_id`` grows by one per frame, so
    ``frame_id - frame_index`` is constant and identifies the window even
    when the 8-bit ``event_seq`` is reused by a later window.
    """
    return (frame_id - frame_index) & 0xFFFFFFFF


def _frame_base_newer(candidate: int, current: int) -> bool:
    """True when ``candidate`` is a later window than ``current`` (wrap aware)."""
    return 0 < ((candidate - current) & 0xFFFFFFFF) < 0x80000000


def _same_frame(left: ImageFrameChunk, right: ImageFrameChunk) -> bool:
    return (
        left.event_seq == right.event_seq
        and left.frame_index == right.frame_index
        and left.frame_count == right.frame_count
        and left.frame_id == right.frame_id
        and left.timestamp_ms == right.timestamp_ms
        and left.config_version == right.config_version
        and left.width == right.width
        and left.height == right.height
        and left.pixel_format == right.pixel_format
    )
