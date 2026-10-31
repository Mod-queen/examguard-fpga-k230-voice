"""Decode/encode the fixed 128-byte history window result record (HR v1).

Wire layout is big-endian. CRC32 is the standard reflected CRC (init
0xFFFFFFFF, final invert, poly 0xEDB88320), identical to zlib.crc32 over the
first 124 bytes. This module does not prove window coverage; it only preserves
the FPGA's merged reader/gap verdict honestly.
"""
from __future__ import annotations

import struct
import zlib
from dataclasses import dataclass

MAGIC = b"HR"
VERSION = 1
KIND_WINDOW_RESULT = 1
RECORD_LENGTH = 128

FLAG_OK = 1 << 0
FLAG_TRUNCATED = 1 << 1
FLAG_CAPTURE_ERROR = 1 << 2
FLAG_GAP_UNKNOWN = 1 << 3
FLAG_GAP_BAD_RANGE = 1 << 4
FLAG_COVERAGE_OK = 1 << 5


class HistoryResultError(ValueError):
    pass


@dataclass(frozen=True)
class HistoryResult:
    transaction: bytes
    window: int
    token: int
    code: int
    frames: int
    gap_count: int
    lower_ms: int
    upper_ms: int
    gap_first_meta: bytes
    gap_last_meta: bytes
    gap_first_reason: int
    gap_last_reason: int
    flags: int

    @property
    def ok(self) -> bool:
        return bool(self.flags & FLAG_OK)

    @property
    def truncated(self) -> bool:
        return bool(self.flags & FLAG_TRUNCATED)

    @property
    def capture_error(self) -> bool:
        return bool(self.flags & FLAG_CAPTURE_ERROR)

    @property
    def gap_unknown(self) -> bool:
        return bool(self.flags & FLAG_GAP_UNKNOWN)

    @property
    def gap_bad_range(self) -> bool:
        return bool(self.flags & FLAG_GAP_BAD_RANGE)

    @property
    def coverage_ok(self) -> bool:
        return bool(self.flags & FLAG_COVERAGE_OK)

    @property
    def gap_first_time_ms(self) -> int:
        return int.from_bytes(self.gap_first_meta[4:12], "big")

    @property
    def gap_last_time_ms(self) -> int:
        return int.from_bytes(self.gap_last_meta[4:12], "big")

    def as_dict(self) -> dict:
        return {
            "transaction_hex": self.transaction.hex(),
            "window": self.window,
            "token": self.token,
            "code": self.code,
            "frames": self.frames,
            "gap_count": self.gap_count,
            "lower_ms": self.lower_ms,
            "upper_ms": self.upper_ms,
            "gap_first_meta_hex": self.gap_first_meta.hex(),
            "gap_last_meta_hex": self.gap_last_meta.hex(),
            "gap_first_reason": self.gap_first_reason,
            "gap_last_reason": self.gap_last_reason,
            "ok": self.ok,
            "truncated": self.truncated,
            "capture_error": self.capture_error,
            "gap_unknown": self.gap_unknown,
            "gap_bad_range": self.gap_bad_range,
            "coverage_ok": self.coverage_ok,
            "flags": self.flags,
        }


def decode_history_result(data: bytes) -> HistoryResult:
    if len(data) != RECORD_LENGTH:
        raise HistoryResultError(f"record length {len(data)} != {RECORD_LENGTH}")
    if data[0:2] != MAGIC:
        raise HistoryResultError("bad magic")
    if data[2] != VERSION:
        raise HistoryResultError(f"unsupported version {data[2]}")
    if data[3] != KIND_WINDOW_RESULT:
        raise HistoryResultError(f"unsupported kind {data[3]}")
    if int.from_bytes(data[4:6], "big") != RECORD_LENGTH:
        raise HistoryResultError("bad record length field")
    stored = int.from_bytes(data[124:128], "big")
    calc = zlib.crc32(data[:124]) & 0xFFFFFFFF
    if stored != calc:
        raise HistoryResultError(f"CRC32 mismatch {stored:08x} != {calc:08x}")
    if any(data[102:124]):
        raise HistoryResultError("reserved bytes are not zero")
    flags = data[6]
    code = int.from_bytes(data[48:52], "big")
    if code > 4:
        raise HistoryResultError(f"invalid result code {code}")
    return HistoryResult(
        transaction=bytes(data[8:40]),
        window=int.from_bytes(data[40:44], "big"),
        token=int.from_bytes(data[44:48], "big"),
        code=code,
        frames=int.from_bytes(data[52:56], "big"),
        gap_count=int.from_bytes(data[56:60], "big"),
        lower_ms=int.from_bytes(data[60:68], "big"),
        upper_ms=int.from_bytes(data[68:76], "big"),
        gap_first_meta=bytes(data[76:88]),
        gap_last_meta=bytes(data[88:100]),
        gap_first_reason=data[100],
        gap_last_reason=data[101],
        flags=flags,
    )


def encode_history_result(
    *,
    transaction: bytes,
    window: int,
    token: int,
    code: int,
    frames: int,
    gap_count: int,
    lower_ms: int,
    upper_ms: int,
    gap_first_meta: bytes = bytes(12),
    gap_last_meta: bytes = bytes(12),
    gap_first_reason: int = 0,
    gap_last_reason: int = 0,
    flags: int = 0,
) -> bytes:
    """Test/transport helper. The FPGA remains the authoritative producer."""
    if len(transaction) != 32:
        raise HistoryResultError("transaction must be 32 bytes")
    if len(gap_first_meta) != 12 or len(gap_last_meta) != 12:
        raise HistoryResultError("gap meta must be 12 bytes")
    head = struct.pack(">2sBBHBB", MAGIC, VERSION, KIND_WINDOW_RESULT, RECORD_LENGTH, flags, 0)
    body = bytearray()
    body += head
    body += transaction
    body += struct.pack(">IIII", window, token, code, frames)
    body += struct.pack(">IQQ", gap_count, lower_ms, upper_ms)
    body += gap_first_meta + gap_last_meta
    body += bytes((gap_first_reason & 0xFF, gap_last_reason & 0xFF))
    body += bytes(22)
    if len(body) != 124:
        raise HistoryResultError(f"internal record length {len(body)} != 124")
    return bytes(body) + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
