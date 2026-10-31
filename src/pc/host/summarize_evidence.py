"""Summarise FPGA image-evidence windows written by receive_evidence_udp.py.

Scans an evidence_out directory and reports, per event and in aggregate:
  - complete / partial windows
  - frames expected vs received (missing frame indices)
  - an independent-loss estimate of the per-datagram loss from the frame loss
    (each frame is FRAME_BYTES / 1024 packets, so p_frame ~= 1-(1-p)^n).

Usage:
    python summarize_evidence.py --dir D:\\fpga_race\\host\\evidence_out
"""

from __future__ import annotations

import argparse
import glob
import json
import os

FRAME_BYTES = 160 * 90 * 2        # RGB565 160x90
CHUNK_BYTES = 1024
CHUNKS_PER_FRAME = (FRAME_BYTES + CHUNK_BYTES - 1) // CHUNK_BYTES


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=r"D:\fpga_race\host\evidence_out")
    args = ap.parse_args()

    dirs = sorted(glob.glob(os.path.join(args.dir, "event_*")))
    comp = part = 0
    exp_total = got_total = 0
    worst = []

    for d in dirs:
        m = os.path.join(d, "manifest.json")
        if not os.path.exists(m):
            continue
        with open(m, encoding="utf-8") as f:
            j = json.load(f)
        exp = int(j.get("expected_frames", 0) or 0)
        frames = j.get("frames", []) or []
        got = len(frames)
        complete = bool(j.get("complete"))
        exp_total += exp
        got_total += got
        if complete:
            comp += 1
        else:
            part += 1
        missing = exp - got
        if missing > 0:
            worst.append((os.path.basename(d), missing, exp))
        print(f"{os.path.basename(d):>14}  {'complete' if complete else 'PARTIAL ':>8}  "
              f"{got:>2}/{exp:<2}  missing={missing}")

    print("-" * 56)
    print(f"events            : {len(dirs)}  (complete {comp}, partial {part})")
    print(f"frames expected   : {exp_total}")
    print(f"frames received   : {got_total}")
    if exp_total:
        frame_loss = 1.0 - got_total / exp_total
        print(f"frame delivery    : {100.0 * got_total / exp_total:.3f}%  (frame loss {100.0 * frame_loss:.3f}%)")
        # Estimate per-datagram loss assuming independent loss.
        p_frame = frame_loss
        p_pkt = 1.0 - (1.0 - p_frame) ** (1.0 / CHUNKS_PER_FRAME) if p_frame > 0 else 0.0
        print(f"est. datagram loss: {100.0 * p_pkt:.4f}%  "
              f"(each frame = {CHUNKS_PER_FRAME} datagrams of <= {CHUNK_BYTES} B)")
    if worst:
        print("worst windows     : " + ", ".join(f"{n}(-{m})" for n, m, _ in worst[:8]))


if __name__ == "__main__":
    main()
