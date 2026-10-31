"""Summarize HR result <-> EGv2 pixel-window association for one output root."""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.history_association import associate  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Associate HR results with EGv2 windows")
    parser.add_argument("--root", default="evidence_out")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    associations = associate(args.root)
    counts = Counter(item.verdict for item in associations)
    payload = {
        "root": str(Path(args.root).resolve()),
        "counts": dict(sorted(counts.items())),
        "transactions": [
            {
                "transaction_hex": item.transaction_hex,
                "verdict": item.verdict,
                "reason": item.reason,
                "history": [
                    {
                        "manifest": str(r.manifest_path),
                        "window": r.window, "token": r.token, "code": r.code,
                        "frames": r.frames, "gap_count": r.gap_count,
                        "gap_unknown": r.gap_unknown, "truncated": r.truncated,
                        "capture_error": r.capture_error, "coverage_ok": r.coverage_ok,
                        "lower_ms": r.lower_ms, "upper_ms": r.upper_ms,
                    } for r in item.history
                ],
                "pixels": [
                    {
                        "manifest": str(p.manifest_path), "status": p.status,
                        "complete": p.complete, "received_frames": p.received_frames,
                        "expected_frames": p.expected_frames,
                        "missing_indices": list(p.missing_indices),
                        "stream_bad": p.stream_bad,
                    } for p in item.pixels
                ],
            } for item in associations
        ],
    }
    text = json.dumps(payload, ensure_ascii=False, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {args.out}")
    else:
        print(text)


if __name__ == "__main__":
    main()
