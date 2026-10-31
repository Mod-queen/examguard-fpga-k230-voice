"""Persist low-resolution image evidence windows for replay and reports."""

from __future__ import annotations

import csv
import json
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class ImageEvidenceFrame:
    """One decoded image frame and the metadata bound to it."""

    seq: int
    index: int
    frame_id: int
    timestamp_ms: int
    config_version: int
    width: int
    height: int
    pixels: bytes
    pixel_format: str = "GRAY8"

    @property
    def crc32(self) -> str:
        return f"{zlib.crc32(self.pixels) & 0xFFFFFFFF:08x}"


SUPPORTED_FORMATS = {"GRAY8": 1, "RGB565": 2}


def _rgb565_to_rgb888(pixels: bytes) -> bytes:
    """Expand raw RGB565 (big-endian, 2 bytes/pixel) to RGB888."""
    if len(pixels) % 2 != 0:
        raise ValueError("RGB565 payload must have an even length")
    out = bytearray(len(pixels) // 2 * 3)
    for i in range(0, len(pixels), 2):
        value = (pixels[i] << 8) | pixels[i + 1]
        r = (value >> 11) & 0x1F
        g = (value >> 5) & 0x3F
        b = value & 0x1F
        j = (i // 2) * 3
        out[j] = (r << 3) | (r >> 2)
        out[j + 1] = (g << 2) | (g >> 4)
        out[j + 2] = (b << 3) | (b >> 2)
    return bytes(out)


def write_image_evidence(
    root: str | Path,
    *,
    event_seq: int,
    expected_count: int,
    frames: Iterable[ImageEvidenceFrame],
    width: int,
    height: int,
    pixel_format: str = "GRAY8",
    directory_suffix: str = "",
) -> Path:
    """Write one event directory and return its path.

    The first transport contract is deliberately limited to GRAY8/PGM. The
    manifest and timeline are transport-neutral so RGB565 can be added after
    the FPGA transfer path is fixed.
    """
    if not 0 <= event_seq <= 0xFF:
        raise ValueError("event_seq must fit in 8 bits")
    if expected_count < 0:
        raise ValueError("expected_count must be non-negative")
    if width < 1 or height < 1:
        raise ValueError("image dimensions must be positive")
    if pixel_format not in SUPPORTED_FORMATS:
        raise ValueError(f"unsupported pixel format: {pixel_format}")
    bytes_per_pixel = SUPPORTED_FORMATS[pixel_format]

    frame_list = list(frames)
    by_index: dict[int, ImageEvidenceFrame] = {}
    expected_bytes = width * height * bytes_per_pixel
    for frame in frame_list:
        if frame.seq != event_seq:
            raise ValueError("frame sequence does not match event sequence")
        if not 0 <= frame.index < expected_count:
            raise ValueError("frame index is outside the event window")
        if frame.index in by_index:
            raise ValueError("duplicate frame index")
        if (
            frame.width != width
            or frame.height != height
            or frame.pixel_format != pixel_format
        ):
            raise ValueError("frame format does not match the event window")
        if len(frame.pixels) != expected_bytes:
            raise ValueError("frame payload size does not match dimensions")
        by_index[frame.index] = frame

    event_dir = Path(root) / f"event_{event_seq:04d}{directory_suffix}"
    event_dir.parent.mkdir(parents=True, exist_ok=True)
    event_dir.mkdir(parents=True, exist_ok=False)
    missing_indices = [
        index for index in range(expected_count) if index not in by_index
    ]
    manifest_frames: list[dict[str, int | str]] = []

    for index in sorted(by_index):
        frame = by_index[index]
        if pixel_format == "GRAY8":
            filename = f"frame_{index:03d}.pgm"
            payload = f"P5\n{width} {height}\n255\n".encode("ascii") + frame.pixels
        else:
            filename = f"frame_{index:03d}.ppm"
            payload = (
                f"P6\n{width} {height}\n255\n".encode("ascii")
                + _rgb565_to_rgb888(frame.pixels)
            )
        (event_dir / filename).write_bytes(payload)
        manifest_frames.append(
            {
                "index": frame.index,
                "frame_id": frame.frame_id,
                "timestamp_ms": frame.timestamp_ms,
                "config_version": frame.config_version,
                "file": filename,
                "bytes": len(frame.pixels),
                "crc32": frame.crc32,
            }
        )

    manifest = {
        "schema_version": 1,
        "event_seq": event_seq,
        "expected_frames": expected_count,
        "received_frames": len(by_index),
        "complete": not missing_indices,
        "missing_indices": missing_indices,
        "width": width,
        "height": height,
        "pixel_format": pixel_format,
        "frames": manifest_frames,
    }
    (event_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    with (event_dir / "timeline.csv").open(
        "w", newline="", encoding="utf-8"
    ) as csv_file:
        writer = csv.writer(csv_file)
        writer.writerow(
            [
                "index",
                "status",
                "frame_id",
                "timestamp_ms",
                "config_version",
                "file",
                "crc32",
            ]
        )
        extension = "pgm" if pixel_format == "GRAY8" else "ppm"
        for index in range(expected_count):
            frame = by_index.get(index)
            if frame is None:
                writer.writerow([index, "missing", "", "", "", "", ""])
            else:
                writer.writerow(
                    [
                        index,
                        "received",
                        frame.frame_id,
                        frame.timestamp_ms,
                        frame.config_version,
                        f"frame_{index:03d}.{extension}",
                        frame.crc32,
                    ]
                )
    return event_dir
