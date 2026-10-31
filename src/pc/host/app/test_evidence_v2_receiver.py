from contextlib import closing
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import struct
import zlib
import unittest
from unittest.mock import patch

from .evidence_v2 import HEADER, TRANSACTION, META, decode_window_packet
from .evidence_v2_receiver import EvidenceV2Receiver
from .evidence_v2_store import latest_revision, read_revision
from .protocol import ProtocolError
from .review import load_windows, transaction_windows, candidate_windows, exact_window, export_report
from .transaction_protocol import TransactionEventPacket
from .test_evidence_v2 import wire


def result_wire(**kwargs):
    return wire(kind=2, flags=2, index=1, count=1, payload=b'', **kwargs)


class EvidenceV2ReceiverTests(unittest.TestCase):
    def test_active_checkpoint_duplicate_traffic_and_failed_save_retry(self):
        now = [0.]
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root, clock=lambda: now[0], checkpoint_after=2.)
            first = wire(flags=0, payload=b'\x12\x34')
            receiver.ingest(first)
            for t in (1., 2.):
                now[0] = t
                receiver.ingest(first)  # never quiet, but checkpoint must happen
                receiver.flush()
            key = decode_window_packet(first).identity
            path = latest_revision(root, key)
            self.assertEqual(read_revision(path)[0]['reason'], 'checkpoint')
            self.assertIn(key, receiver.pending)
            self.assertEqual(receiver.pending[key].raw_bytes, len(first)+2)
            now[0] = 3.
            receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            now[0] = 4.
            with patch('app.evidence_v2_receiver.write_revision', side_effect=OSError('disk full')):
                with self.assertRaises(OSError):
                    receiver.flush()
            self.assertTrue(receiver.pending[key].dirty)
            self.assertEqual(latest_revision(root, key), path)
            receiver.flush()
            self.assertNotEqual(latest_revision(root, key), path)
            receiver.ingest(result_wire())
            self.assertEqual(read_revision(latest_revision(root, key))[1].status, 'complete')

    def test_disk_reserve_refuses_publish_without_deleting_or_evicting(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            first = wire(flags=0, payload=b'\x12\x34')
            receiver.ingest(first)
            key = decode_window_packet(first).identity
            with patch('app.evidence_v2_store.shutil.disk_usage') as usage:
                usage.return_value.free = 0
                with self.assertRaises(OSError):
                    receiver.flush(force=True)
            self.assertIn(key, receiver.pending)
            self.assertTrue(receiver.pending[key].dirty)
            self.assertIsNone(latest_revision(root, key))
            receiver.flush(force=True)
            path = latest_revision(root, key)
            before = (path/'packets.bin').read_bytes()
            receiver.ingest(result_wire())
            with patch('app.evidence_v2_store.shutil.disk_usage') as usage:
                usage.return_value.free = 0
                with self.assertRaises(OSError):
                    receiver.flush(force=True)
            self.assertEqual((path/'packets.bin').read_bytes(), before)

    def test_checkpoint_survives_process_kill_then_late_chunks_resume(self):
        with tempfile.TemporaryDirectory() as root:
            script = ("import os; from app.evidence_v2_receiver import EvidenceV2Receiver; "
                      "from app.test_evidence_v2 import wire; "
                      f"r=EvidenceV2Receiver({root!r},clock=lambda:0); "
                      "r.ingest(wire(flags=0,payload=b'\\x12\\x34')); "
                      "r.clock=lambda:11; r.ingest(wire(flags=0,payload=b'\\x12\\x34')); r.flush(); os._exit(9)")
            p = subprocess.run([sys.executable, '-c', script], cwd=Path(__file__).resolve().parents[1], timeout=15)
            self.assertEqual(p.returncode, 9)
            key = decode_window_packet(wire()).identity
            self.assertEqual(read_revision(latest_revision(root, key))[0]['reason'], 'checkpoint')
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            path = receiver.ingest(result_wire())
            self.assertEqual(read_revision(path)[1].frame_data(0), b'\x12\x34\x56\x78')

    def test_default_40frame_320x180_window_host_capacity_full_pixels(self):
        transaction = TRANSACTION.pack(1, 5, 3, 1, 0xffffffffffffffff, 1, 0, 0x3750)
        def encode(index, offset, payload, kind=1):
            flags = 2 if kind == 2 else 4 if offset+len(payload) == 115200 else 0
            raw = HEADER.pack(b'EG', 2, kind, 80, flags, 1, transaction, index,
                              META.pack(index+100, 0x1234567800000000+index) if kind == 1 else bytes(12),
                              offset, 115200, 40 if kind == 2 else 0, len(payload), 320, 180, bytes(6)) + payload
            return raw+struct.pack('!I', zlib.crc32(raw))
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(encode(40, 0, b'', kind=2))
            for frame in reversed(range(40)):
                pixels = frame.to_bytes(2, 'big')*57600
                for offset in reversed(range(0, 115200, 1024)):
                    receiver.ingest(encode(frame, offset, pixels[offset:offset+1024]))
            receiver.flush(force=True)
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            self.assertEqual(len(windows), 1)
            self.assertTrue(windows[0]['complete'])
            self.assertEqual(len(windows[0]['frames']), 40)
            _, window, packets = read_revision(windows[0]['path'])
            self.assertEqual(len(packets), 4521)
            for frame in range(40):
                self.assertEqual(window.frame_data(frame), frame.to_bytes(2, 'big')*57600)

    def test_one_click_services_owns_actual_eg_receiver_and_graceful_flush(self):
        from .services import Services, DEFAULTS, worker_specs
        from .test_services import free_ports, wait_until
        host = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {**DEFAULTS, **free_ports()}
            def only_images(cfg, stop_file, unused_host):
                command = worker_specs(cfg, stop_file, host)['images']
                command[command.index('--out')+1] = str(root/'images')
                return {'images': command}
            services = Services(config, host=root, port_list=lambda: [])
            with patch('app.services.worker_specs', side_effect=only_images):
                try:
                    services.start()
                    wait_until(lambda: 'UDP已监听' in services.status.get('images', ''))
                    with closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as sender:
                        sender.sendto(wire(flags=0, payload=b'\x12\x34'), ('127.0.0.1', config['image_port']))
                    time.sleep(.15)
                    services.stop()
                    self.assertEqual(services.processes['images'].returncode, 0)
                    windows, errors = load_windows(root/'images')
                    self.assertFalse(errors)
                    self.assertEqual(windows[0]['status'], 'awaiting_result')
                    self.assertIn('EGv2 awaiting_result', (services.log_dir/'images.log').read_text(encoding='utf-8'))
                finally:
                    if not services.closing:
                        services.stop()

    def test_same_uid_across_boot_and_session_is_separate_and_exact_only(self):
        def change(raw, boot, session):
            data = bytearray(raw[:-4])
            data[12:16] = boot.to_bytes(4, 'big')
            data[16:20] = session.to_bytes(4, 'big')
            return bytes(data) + struct.pack('!I', zlib.crc32(data))
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            events = []
            for boot, session in ((2, 3), (3, 3), (3, 4)):
                first = change(wire(uid=1), boot, session)
                receiver.ingest(first)
                receiver.ingest(change(result_wire(uid=1), boot, session))
                events.append(TransactionEventPacket(decode_window_packet(first).transaction))
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            self.assertEqual(len(windows), 3)
            for event in events:
                matches, _ = transaction_windows(event, windows)
                self.assertEqual(len(matches), 1)
                self.assertEqual(matches[0]['identity'], event.identity)

    def test_reordered_duplicates_atomic_complete_and_raw_preview_hashes(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(result_wire())
            receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            self.assertFalse(load_windows(root)[0])
            receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            path = receiver.ingest(wire(flags=0, payload=b'\x12\x34'))
            data, window, packets = read_revision(path)
            self.assertEqual(data['status'], 'complete')
            self.assertEqual(len(packets), 3)
            self.assertEqual(window.frame_data(0), b'\x12\x34\x56\x78')
            self.assertTrue((path/'frame_000.ppm').read_bytes().startswith(b'P6\n2 1\n255\n'))
            receiver.ingest(result_wire())
            self.assertEqual(receiver.written, 1)
            receiver.flush(force=True)
            self.assertEqual(receiver.written, 1)
            self.assertTrue(load_windows(root)[0][0]['complete'])

    def test_partial_raw_chunks_resume_after_stop_restart_and_result_late(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire(flags=0, payload=b'\x12\x34'))
            receiver.flush(force=True)
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            first = windows[0]['path']
            manifest, _, packets = read_revision(first)
            self.assertEqual(manifest['status'], 'awaiting_result')
            self.assertEqual(manifest['frames'], [])
            self.assertEqual(manifest['incomplete_frames'][0]['ranges'], [[0, 2]])
            old_bytes = (first/'manifest.json').read_bytes()
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(result_wire())
            receiver.flush(force=True)
            self.assertEqual(load_windows(root)[0][0]['status'], 'partial')
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            self.assertTrue(load_windows(root)[0][0]['complete'])
            self.assertEqual((first/'manifest.json').read_bytes(), old_bytes)
            receiver.flush(force=True)

    def test_revision_order_survives_pc_wall_clock_rollback(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire())
            receiver.flush(force=True)
            old = load_windows(root)[0][0]['path']
            with patch('app.evidence_v2_store.time.time_ns', return_value=1):
                receiver.ingest(result_wire())
            current = load_windows(root)[0][0]
            self.assertGreater(current['path'].name, old.name)
            self.assertTrue(current['complete'])

    def test_failed_result_all_pixels_never_success_and_result_only_preserved(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire())
            receiver.ingest(wire(kind=2, flags=0, index=1, count=1, payload=b''))
            receiver.ingest(wire(kind=2, flags=0, index=0, count=2, payload=b'', uid=7))
            receiver.flush(force=True)
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            self.assertEqual(len(windows), 2)
            self.assertTrue(all(w['status'] == 'failed' and not w['complete'] for w in windows))
            self.assertEqual(sorted(len(w['frames']) for w in windows), [0, 1])

    def test_late_conflict_overrides_prior_complete_and_latches_across_restart(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire())
            good = receiver.ingest(result_wire())
            with self.assertRaises(ProtocolError):
                receiver.ingest(wire(payload=b'\xab\xcd\xef\x12'))
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            self.assertEqual(windows[0]['status'], 'failed')
            self.assertNotEqual(windows[0]['path'], good)
            receiver.flush(force=True)
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire())
            receiver.ingest(result_wire())
            receiver.flush(force=True)
            self.assertEqual(load_windows(root)[0][0]['status'], 'failed')

    def test_capacity_eviction_quiet_and_disk_failure_never_silent_eviction(self):
        now = [0.]
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root, max_windows=1, clock=lambda: now[0])
            receiver.ingest(wire(uid=1))
            with patch('app.evidence_v2_receiver.write_revision', side_effect=OSError('disk full')):
                with self.assertRaisesRegex(OSError, 'disk full'):
                    receiver.ingest(wire(uid=2))
            self.assertEqual(list(receiver.pending)[0][-1], 1)
            receiver.ingest(wire(uid=2))
            self.assertEqual(len(receiver.pending), 1)
            self.assertEqual(len(load_windows(root)[0]), 1)
            now[0] = 4.
            receiver.flush()
            self.assertFalse(receiver.pending)
            self.assertEqual(len(load_windows(root)[0]), 2)
            tiny = EvidenceV2Receiver(root, max_bytes=1)
            with self.assertRaises(ProtocolError):
                tiny.ingest(wire(uid=3))
            self.assertFalse(tiny.pending)
            constrained = EvidenceV2Receiver(root, max_frames=2)
            with self.assertRaises(ProtocolError):
                constrained.ingest(wire(index=2, uid=3))

    def test_ingress_backlog_suppresses_expiry_but_not_checkpoint(self):
        now = [0.]
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root, clock=lambda: now[0],
                                          checkpoint_after=1., flush_after=2.)
            receiver.ingest(wire())
            now[0] = 3.
            receiver.flush(expire=False)
            self.assertEqual(len(receiver.pending), 1)
            self.assertEqual(receiver.written, 1)
            self.assertFalse(next(iter(receiver.pending.values())).dirty)
            # Once queued receipts drain, quiet expiry may evict without a
            # duplicate revision. Checkpointed bytes survive either way.
            receiver.flush()
            self.assertFalse(receiver.pending)
            self.assertEqual(receiver.written, 1)

    def test_failed_atomic_publication_is_hidden_old_revision_intact(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire())
            receiver.flush(force=True)
            before = load_windows(root)[0][0]
            with patch.object(Path, 'rename', side_effect=OSError('publish failed')):
                with self.assertRaisesRegex(OSError, 'publish failed'):
                    receiver.ingest(result_wire())
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            self.assertEqual(windows[0]['path'], before['path'])
            self.assertEqual(windows[0]['status'], 'awaiting_result')
            receiver.flush(force=True)
            self.assertTrue(load_windows(root)[0][0]['complete'])
            self.assertEqual(len(list(Path(root).glob('egv2_*/.pending_*'))), 1)

    def test_window_byte_limit_failure_survives_restore_and_identity_context_conflict(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root, max_window_bytes=2)
            receiver.ingest(wire(flags=0, payload=b'\x12\x34'))
            with self.assertRaises(ProtocolError):
                receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            windows, errors = load_windows(root)
            self.assertFalse(errors)
            self.assertEqual(windows[0]['status'], 'failed')
            receiver.flush(force=True)
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(result_wire())
            receiver.flush(force=True)
            self.assertEqual(load_windows(root)[0][0]['status'], 'failed')
            with self.assertRaises(ProtocolError):
                receiver.ingest(wire(source_time=1))
            self.assertEqual(load_windows(root)[0][0]['status'], 'failed')

    def test_host_global_capacity_rejection_latches_failed_without_buffer_growth(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root, max_bytes=170)
            receiver.ingest(wire(flags=0, payload=b'\x12\x34'))
            with self.assertRaises(ProtocolError):
                receiver.ingest(wire(offset=2, payload=b'\x56\x78'))
            self.assertLessEqual(sum(e.size for e in receiver.pending.values()), 170)
            receiver.flush(force=True)
            self.assertEqual(load_windows(root)[0][0]['status'], 'failed')

    def test_exact_context_identity_no_legacy_fallback_and_corrupt_latest_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            receiver = EvidenceV2Receiver(root)
            receiver.ingest(wire())
            receiver.ingest(result_wire())
            receiver.ingest(wire(uid=1))
            receiver.flush(force=True)
            windows, _ = load_windows(root)
            packet = TransactionEventPacket(decode_window_packet(wire()).transaction)
            matches, explanation = transaction_windows(packet, windows)
            self.assertEqual(len(matches), 1)
            self.assertIn('精确', explanation)
            mismatch = TransactionEventPacket(decode_window_packet(wire(source_time=2)).transaction)
            self.assertIn('冲突', transaction_windows(mismatch, windows)[1])
            self.assertFalse(transaction_windows(mismatch, windows)[0])
            self.assertFalse(candidate_windows(packet, windows))  # ET has no frame_id, still must not guess
            self.assertFalse(exact_window(1, windows))
            good = matches[0]['path']
            (good/'frame_000.ppm').write_bytes(b'corrupted')
            windows, errors = load_windows(root)
            self.assertEqual(len(windows), 1)
            self.assertEqual(len(errors), 1)

    def test_actual_udp_subprocess_auto_pg_and_eg_stop_resume_and_bad_crc(self):
        from .test_host import _image_chunk
        from .test_services import wait_until
        host = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)/'evidence'
            stop = Path(directory)/'stop'
            with closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            command = [sys.executable, '-u', str(host/'receive_evidence_udp.py'), '--port', str(port), '--out', str(root), '--stop-file', str(stop)]
            for run in range(2):
                if stop.exists():
                    stop.unlink()
                logpath = Path(directory)/f'run{run}.log'
                with logpath.open('w', encoding='utf-8') as log:
                    process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                    try:
                        wait_until(lambda: 'listening for image evidence' in logpath.read_text(encoding='utf-8'))
                        with closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as sender:
                            target = ('127.0.0.1', port)
                            if run == 0:
                                sender.sendto(_image_chunk(event_seq=5, frame_index=0, frame_id=1, pixel_offset=0, payload=b'ab'), target)
                                sender.sendto(wire(flags=0, payload=b'\x12\x34'), target)
                                bad = bytearray(wire());bad[-1] ^= 1
                                sender.sendto(bad, target)
                            else:
                                sender.sendto(result_wire(), target)
                                sender.sendto(wire(offset=2, payload=b'\x56\x78'), target)
                        time.sleep(.15)
                        stop.touch()
                        self.assertEqual(process.wait(timeout=8), 0, logpath.read_text(encoding='utf-8'))
                    finally:
                        if process.poll() is None:
                            process.terminate();process.wait(timeout=3)
                windows, errors = load_windows(root)
                self.assertFalse(errors)
                self.assertEqual(len(windows), 2)
                eg = next(w for w in windows if w.get('protocol') == 'EGv2')
                self.assertEqual(eg['status'], 'awaiting_result' if run == 0 else 'complete')
            self.assertIn('CRC mismatch', (Path(directory)/'run0.log').read_text())


if __name__ == '__main__':
    unittest.main()
