"""Receive PGv1/EGv2 image evidence and HR results on the same UDP port.

The FPGA sends one UDP datagram per <=1024-byte image chunk, with a 32-byte
header (magic "PG") and a trailing CRC32, to <pc>:6102. This runner reassembles
each event window and writes manifest.json, timeline.csv and PGM frames.

A window is written as soon as all of its frames are complete. If UDP loss
leaves a window incomplete, it is still persisted (manifest complete=false,
missing frames listed) once it has been quiet for --flush-after seconds, so
received partial evidence is saved. EGv2 also checkpoints active windows;
packets still in network/kernel buffers or memory at forced termination may be lost.

Usage:
    python receive_evidence_udp.py --port 6102 --out evidence_out
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
import queue
import signal
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from app.evidence_udp import EvidenceUdpReassembler, decode_image_chunk  # noqa: E402
from app.protocol import ProtocolError  # noqa: E402
from app.evidence_v2_receiver import EvidenceV2Receiver
from app.history_result_receiver import HistoryResultReceiver
from app.udp_ingress import UdpIngress


def main() -> None:
    parser = argparse.ArgumentParser(description="Receive FPGA image evidence over UDP")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6102)
    parser.add_argument("--out", default="evidence_out")
    parser.add_argument('--stop-file', type=Path, help='launcher-owned graceful stop signal')
    parser.add_argument("--rcvbuf", type=int, default=16 * 1024 * 1024)
    parser.add_argument('--ingress-max-bytes', type=int, default=64*1024*1024,
                        help='bounded payload queue between socket reader and archive processing')
    parser.add_argument('--ingress-max-packets', type=int, default=65536)
    parser.add_argument('--diagnostics', type=Path,
                        help='receive/processing statistics JSON (default: <out>/udp_ingress_diagnostics.json)')
    parser.add_argument('--eg-max-windows', type=int, default=8)
    parser.add_argument('--eg-max-bytes', type=int, default=64*1024*1024)
    parser.add_argument('--eg-checkpoint-after', type=float, default=10.,
                        help='checkpoint dirty EGv2 windows even under continuous input')
    parser.add_argument('--eg-min-free-bytes', type=int, default=64*1024*1024,
                        help='advisory free-space reserve for EGv2 revisions; never deletes archives')
    parser.add_argument('--hr-max-records', type=int, default=4096,
                        help='bounded in-memory HR duplicate table; files are never deleted')
    parser.add_argument('--stop-drain-seconds', type=float, default=2.,
                        help='bounded UDP queue drain before final save; active senders may exceed this limit')
    parser.add_argument(
        "--flush-after",
        type=float,
        default=3.0,
        help="seconds of silence after which an incomplete window is written",
    )
    parser.add_argument(
        "--dedup-seconds",
        type=float,
        default=8.0,
        help="keep only the first window per event_seq within this time window",
    )
    args = parser.parse_args()
    if (args.flush_after <= 0 or args.eg_max_windows <= 0 or args.eg_max_bytes <= 0 or
            args.eg_checkpoint_after <= 0 or args.eg_min_free_bytes < 0 or args.stop_drain_seconds < 0 or
            args.hr_max_records <= 0 or args.rcvbuf <= 0 or
            args.ingress_max_bytes <= 0 or args.ingress_max_packets <= 0):
        parser.error('flush and EG capacity limits must be positive')

    def eg_written(path, status):
        print(f'wrote {path} [EGv2 {status}]', flush=True)

    eg = EvidenceV2Receiver(args.out, flush_after=args.flush_after, max_windows=args.eg_max_windows,
                            max_bytes=args.eg_max_bytes, on_write=eg_written,
                            checkpoint_after=args.eg_checkpoint_after, min_free_bytes=args.eg_min_free_bytes)
    hr = HistoryResultReceiver(args.out, max_records=args.hr_max_records,
                               on_write=lambda path, record: print(f'wrote {path} [HR window={record.window}]', flush=True))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Windows SO_REUSEADDR can silently let another receiver steal datagrams.
    if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    except OSError as exc:
        print(f"warning: could not raise SO_RCVBUF: {exc}", flush=True)
    sock.bind((args.bind, args.port))
    sock.settimeout(.1)
    actual_rcvbuf = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    ingress = UdpIngress(sock, max_bytes=args.ingress_max_bytes,
                         max_packets=args.ingress_max_packets,
                         drain_seconds=args.stop_drain_seconds, stop_file=args.stop_file)
    ingress.start()
    # Ctrl+C requests the same drain as the launcher's stop file. Do not throw a
    # KeyboardInterrupt into an archive write or lose the datagram being decoded.
    previous_sigint = signal.signal(signal.SIGINT, lambda *_: ingress.request_stop())
    print(f"listening for image evidence on udp {args.bind}:{args.port}", flush=True)
    print(f"writing events under {Path(args.out).resolve()}", flush=True)
    print(f'UDP INGRESS: rcvbuf_requested={args.rcvbuf} rcvbuf_actual={actual_rcvbuf} '
          f'queue_bytes={args.ingress_max_bytes} queue_packets={args.ingress_max_packets}', flush=True)

    diagnostics_path = args.diagnostics or Path(args.out)/'udp_ingress_diagnostics.json'
    next_diagnostics = time.monotonic()+2
    next_expiry = time.monotonic()+.1

    def save_diagnostics(*, final=False, saved=False):
        stats = ingress.snapshot()
        stats.update(schema='examguard-udp-ingress-v1', updated_utc=datetime.now(timezone.utc).isoformat(),
                     final=final, archives_saved=saved, capture_drained=drained,
                     application_queue_complete=bool(final and drained and saved and
                         not stats['queue_dropped_packets'] and not stats['error']),
                     rcvbuf_requested=args.rcvbuf,
                     rcvbuf_actual=actual_rcvbuf, eg_revisions=eg.written, eg_rejected=eg.rejected,
                     hr_written=hr.written, hr_duplicates=hr.duplicates, hr_rejected=hr.rejected,
                     interpretation='recvfrom observations only; missing before this boundary cannot distinguish '
                                    'FPGA/network/kernel loss. Frame0 offsets are header-only, not CRC-validated.')
        diagnostics_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = diagnostics_path.with_suffix(diagnostics_path.suffix+'.tmp')
        tmp.write_text(json.dumps(stats, indent=2)+'\n', encoding='utf-8')
        os.replace(tmp, diagnostics_path)

    reassembler = EvidenceUdpReassembler()
    expected: dict[int, int] = {}
    completed: dict[int, set[int]] = {}
    last_seen: dict[int, float] = {}
    recent_write: dict[int, float] = {}

    def drop(event_seq: int) -> None:
        reassembler.forget(event_seq)
        expected.pop(event_seq, None)
        completed.pop(event_seq, None)
        last_seen.pop(event_seq, None)

    def finish(event_seq: int, partial: bool) -> None:
        now = time.monotonic()
        previous = recent_write.get(event_seq)
        if previous is not None and now - previous < args.dedup_seconds:
            print(f"skip duplicate window for event {event_seq}", flush=True)
            drop(event_seq)
            return
        recent_write[event_seq] = now

        suffix = ""
        index = 1
        while (Path(args.out) / f"event_{event_seq:04d}{suffix}").exists():
            index += 1
            suffix = f"_{index}"
        path = reassembler.write_event(
            args.out, event_seq,
            expected_count=expected.get(event_seq),
            require_frames=not partial,
            directory_suffix=suffix,
        )
        done = len(completed.get(event_seq, ()))
        tag = "partial" if partial else "complete"
        print(f"wrote {path} [{tag} {done}/{expected.get(event_seq, '?')}]", flush=True)
        drop(event_seq)

    drained = False
    try:
        while True:
            try:
                arrival = ingress.get(timeout=.1)
            except queue.Empty:
                arrival = False
            if arrival is None:
                drained = True
                break  # Reader stopped AND every queued packet was consumed.
            if arrival:
                datagram, address = arrival.data, arrival.address
                stage = {b'EG': 'EG', b'HR': 'HR', b'PG': 'PG'}.get(datagram[:2], 'other')
                started = time.monotonic_ns()
                try:
                    if datagram[:2] == b'HR':
                        hr.ingest(datagram)
                    elif datagram[:2] == b'EG':
                        eg.ingest(datagram)
                    else:
                        chunk = decode_image_chunk(datagram)
                        previous_base = reassembler.current_base(chunk.event_seq)
                        frame = reassembler.ingest(datagram)
                        expected[chunk.event_seq] = chunk.frame_count
                        last_seen[chunk.event_seq] = time.monotonic()
                        if reassembler.current_base(chunk.event_seq) != previous_base:
                            completed[chunk.event_seq] = set()
                        if frame is not None:
                            done = completed.setdefault(chunk.event_seq, set())
                            done.add(frame.index)
                            if len(done) == chunk.frame_count:
                                finish(chunk.event_seq, partial=False)
                except ProtocolError as exc:
                    print(f'drop datagram from {address}: {exc}', flush=True)
                finally:
                    ingress.record_processing(stage, time.monotonic_ns()-started, arrival)
            # Backlog suppresses quiet expiry, not active checkpoints. Consumer
            # receipts retain their existing clock semantics.
            if time.monotonic() >= next_expiry:
                started = time.monotonic_ns()
                try:
                    now = time.monotonic()
                    empty = ingress.backlog_empty()
                    if empty:
                        for event_seq in list(last_seen):
                            if now - last_seen[event_seq] >= args.flush_after:
                                finish(event_seq, partial=True)
                    eg.flush(expire=empty)
                finally:
                    ingress.record_processing('expiry', time.monotonic_ns()-started)
                next_expiry = time.monotonic()+.1
            if time.monotonic() >= next_diagnostics:
                save_diagnostics()
                next_diagnostics = time.monotonic()+2
    finally:
        # On processing/disk failure stop reception before flushing already
        # assembled data. The unprocessed queue remains accounted in diagnostics.
        ingress.close()
        stop_started = time.monotonic()
        print('EVIDENCE STOP: checkpointing received windows', flush=True)
        saved = False
        try:
            for event_seq in list(last_seen):
                finish(event_seq, partial=True)
            eg.flush(force=True)
            saved = True
            stats = ingress.snapshot()
            completion = 'COMPLETE' if drained and not stats['queue_dropped_packets'] else 'INCOMPLETE'
            print(f'EVIDENCE STOP {completion} elapsed_s={time.monotonic()-stop_started:.3f} '
                  f'eg_revisions={eg.written} eg_rejected={eg.rejected} '
                  f'hr_written={hr.written} hr_duplicates={hr.duplicates} hr_rejected={hr.rejected} '
                  f'udp_received={stats["received_packets"]} queue_dropped={stats["queue_dropped_packets"]}', flush=True)
            if stats['queue_dropped_packets']:
                print('EVIDENCE UDP LOSS: ingress queue overflow; capture is incomplete. See diagnostics.', flush=True)
        finally:
            try:
                ingress.close()
                save_diagnostics(final=True, saved=saved)
            finally:
                signal.signal(signal.SIGINT, previous_sigint)
                sock.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        print(f'EVIDENCE ERROR: {exc}', file=sys.stderr, flush=True)
        raise SystemExit(1)
