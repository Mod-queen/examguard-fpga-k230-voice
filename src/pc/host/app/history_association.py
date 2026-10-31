"""Associate HR result records with EGv2 pixel-window revisions.

The full 256-bit transaction is the only join key. A transaction may have one
HR result (per window/token) and one or more EGv2 revisions. Pixel completeness
and the HR verdict are kept separate: neither side can wash out the other.
This is an offline/index layer, not a coverage proof or a host capture epoch.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

from .history_result import decode_history_result


@dataclass(frozen=True)
class HistoryRecord:
    manifest_path: Path
    raw_path: Path
    transaction_hex: str
    window: int
    token: int
    code: int
    frames: int
    gap_count: int
    gap_unknown: bool
    gap_bad_range: bool
    truncated: bool
    capture_error: bool
    coverage_ok: bool
    lower_ms: int
    upper_ms: int
    raw_sha256: str
    ok: bool = True
    gap_first_time_ms: int = 0
    gap_last_time_ms: int = 0
    gap_first_reason: int = 0
    gap_last_reason: int = 0


@dataclass(frozen=True)
class PixelRecord:
    manifest_path: Path
    transaction_hex: str
    status: str
    complete: bool
    received_frames: int
    expected_frames: int | None
    missing_indices: tuple[int, ...]
    stream_bad: bool
    identity: tuple[int, ...]


@dataclass(frozen=True)
class Association:
    transaction_hex: str
    verdict: str
    history: tuple[HistoryRecord, ...]
    pixels: tuple[PixelRecord, ...]
    reason: str


def _load_history(path: Path) -> HistoryRecord:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != "examguard-history-result-v1":
        raise ValueError(f"unsupported HR manifest: {path}")
    raw_path = path.parent / "raw.hr"
    raw = raw_path.read_bytes()
    if len(raw) != manifest.get("raw_bytes") or __import__("hashlib").sha256(raw).hexdigest() != manifest.get("raw_sha256"):
        raise ValueError(f"HR raw/manifest mismatch: {path}")
    record = decode_history_result(raw)
    if manifest.get('result') != record.as_dict():
        raise ValueError(f"HR decoded fields/manifest mismatch: {path}")
    return HistoryRecord(
        manifest_path=path, raw_path=raw_path,
        transaction_hex=record.transaction.hex().upper(),
        window=record.window, token=record.token, code=record.code, frames=record.frames,
        gap_count=record.gap_count, gap_unknown=record.gap_unknown,
        gap_bad_range=record.gap_bad_range, truncated=record.truncated,
        capture_error=record.capture_error, coverage_ok=record.coverage_ok,
        lower_ms=record.lower_ms, upper_ms=record.upper_ms,
        raw_sha256=manifest["raw_sha256"],
        ok=record.ok, gap_first_time_ms=record.gap_first_time_ms,
        gap_last_time_ms=record.gap_last_time_ms,
        gap_first_reason=record.gap_first_reason, gap_last_reason=record.gap_last_reason,
    )


def _load_pixels(path: Path) -> PixelRecord:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("protocol") != "EGv2":
        raise ValueError(f"unsupported EGv2 manifest: {path}")
    missing = manifest.get("missing_indices") or []
    return PixelRecord(
        manifest_path=path,
        transaction_hex=str(manifest["transaction_hex"]).upper(),
        status=str(manifest["status"]),
        complete=bool(manifest.get("complete")),
        received_frames=int(manifest.get("received_frames", 0)),
        expected_frames=manifest.get("expected_frames"),
        missing_indices=tuple(missing),
        stream_bad=bool(manifest.get("stream_bad")),
        identity=tuple(manifest.get("identity", ())),
    )


def read_history_record(path) -> HistoryRecord:
    """Validate immutable HR raw/manifest fields before displaying a result."""
    return _load_history(Path(path))


def load_history_records(root) -> dict[str, list[HistoryRecord]]:
    root = Path(root)
    index: dict[str, list[HistoryRecord]] = {}
    for path in sorted((root / "history_results").rglob("manifest.json")):
        record = _load_history(path)
        index.setdefault(record.transaction_hex, []).append(record)
    return index


def load_pixel_records(root) -> dict[str, list[PixelRecord]]:
    root = Path(root)
    index: dict[str, list[PixelRecord]] = {}
    for path in sorted(root.glob("egv2_*/revision_*/manifest.json")):
        record = _load_pixels(path)
        index.setdefault(record.transaction_hex, []).append(record)
    return index


def _pixel_ok(record: PixelRecord) -> bool:
    return (record.complete and not record.stream_bad and record.status != "failed"
            and not record.missing_indices)


def verdict_for(transaction_hex: str, history, pixels) -> Association:
    history = tuple(history)
    pixels = tuple(pixels)
    if not history:
        return Association(transaction_hex, "awaiting_result", history, pixels,
                           "no HR result for transaction")
    if any(r.code != 0 or r.capture_error or r.gap_bad_range for r in history):
        return Association(transaction_hex, "failed", history, pixels,
                           "HR code/capture_error/bad_range")
    if any(r.truncated or r.gap_unknown or r.gap_count != 0 for r in history):
        return Association(transaction_hex, "degraded", history, pixels,
                            "known truncation/gap/unknown; not continuous coverage")
    if not pixels:
        return Association(transaction_hex, "awaiting_pixels", history, pixels,
                           "no EGv2 pixel window for transaction")
    if any(not _pixel_ok(p) for p in pixels):
        return Association(transaction_hex, "partial", history, pixels,
                           "HR is gap-free but EGv2 pixels are incomplete/failed")
    if not all(r.coverage_ok and r.ok for r in history):
        return Association(transaction_hex, "degraded", history, pixels,
                           "HR coverage_ok is false")
    return Association(transaction_hex, "complete", history, pixels,
                       "HR gap-free and EGv2 complete; still one event window, not a long-run proof")


def associate(root) -> list[Association]:
    history = load_history_records(root)
    pixels = load_pixel_records(root)
    keys = sorted(set(history) | set(pixels))
    return [verdict_for(key, history.get(key, ()), pixels.get(key, ())) for key in keys]
