from dataclasses import replace
from contextlib import closing
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from .event_store import load_session
from .health_history import export_status_csv, report_lines
from .monitor import MonitorModel
from .protocol import EventPacket
from .test_evidence_health import health, status
from .evidence_health import EvidenceHealth
from .review import export_report


def sample(boot=7, phy=0x010002FE):
    words = list(health().words)
    words[0] = 0x02000070
    words[2], words[31] = boot, phy
    return status(EvidenceHealth(tuple(words)))


class HealthHistoryTests(unittest.TestCase):
    def test_receipts_survive_clear_reopen_utc_rollback_and_epoch_change(self):
        with tempfile.TemporaryDirectory() as root:
            with patch('app.monitor.time.monotonic_ns', side_effect=[100, 100, 4_000_000_101, 4_100_000_101, 4_200_000_101]):
                model = MonitorModel(session_root=root, max_events=1)
                model.apply(sample())
                with patch('app.monitor.utc_now', return_value='2000-01-01T00:00:00+00:00'):
                    model.apply(sample(phy=0x010003FE))
                model.apply(sample(boot=8))
                model.apply(status(None))
            model.clear_events()
            active = model.session_archive()
            self.assertEqual(len(active.statuses), 4)
            self.assertEqual(active.statuses[0].packet.evidence_health.time_ms, 0x12345678FFFFFFFF)
            self.assertEqual(model.snapshot().persisted_statuses, 4)
            model.close()
            archived = load_session(active.session_path)
            self.assertEqual(archived.statuses, active.statuses)
            text = '\n'.join(report_lines(archived))
            self.assertIn('超过3秒的间隔：1次', text)
            self.assertIn('| 1 | 1/2 | 1/7/3 | 2 | 0/0/0 | 1 |', text)
            self.assertIn('| 2 | 3/3 | 1/8/3 |', text)
            self.assertIn('未上报EHealth', text)
            out = Path(root) / 'health.csv'
            export_status_csv(out, archived)
            self.assertIn('elapsed_ns,canonical_st', out.read_text(encoding='utf-8'))
            report = Path(root) / 'report.md'
            export_report(report, None, [], [], session=archived)
            self.assertIn('健康接收历史 ST', report.read_text(encoding='utf-8'))

    def test_status_failure_does_not_inflate_event_failures_or_hide_on_recovery(self):
        with tempfile.TemporaryDirectory() as root:
            model = MonitorModel(session_root=root)
            try:
                with patch.object(model._store, 'append_status', side_effect=sqlite3.OperationalError('disk full')):
                    model.apply(sample())
                model.apply(sample())
                model.apply(EventPacket(1, 2, 3, 0, 1, 0x50))
                archive = model.session_archive()
                self.assertEqual((archive.persistence_failures, archive.transaction_failures, archive.status_failures), (0, 0, 1))
                self.assertEqual([r.receipt_id for r in archive.statuses], [2])
                self.assertIn('disk full', model.snapshot().persistence_error)
            finally:
                path = model._store.path
                model.close()
            archived = load_session(path)
            self.assertEqual((archived.status_packets, archived.status_failures), (2, 1))

    def test_committed_status_recovers_after_process_abrupt_exit(self):
        with tempfile.TemporaryDirectory() as root:
            script = ("import os; from app.monitor import MonitorModel; "
                      "from app.test_health_history import sample; "
                      f"m=MonitorModel(session_root={root!r}); m.apply(sample()); os._exit(9)")
            result = subprocess.run([sys.executable, '-c', script], cwd=Path(__file__).resolve().parents[1], timeout=15)
            self.assertEqual(result.returncode, 9)
            archive = load_session(next(Path(root).glob('*.sqlite3')))
            self.assertIsNone(archive.ended_at)
            self.assertEqual(archive.status_packets, 1)
            self.assertEqual(archive.statuses[0].packet, sample())

    def test_old_schema_has_no_fabricated_health_and_bad_status_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            model = MonitorModel(session_root=root)
            model.apply(sample())
            path = model._store.path
            model.close()
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('UPDATE status_history SET canonical_st=?', ('AL,1,2,3,0,1,80',))
            with self.assertRaises(ValueError):
                load_session(path)
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('DROP TABLE status_history')
                db.execute('UPDATE session SET schema_version=3')
            archive = load_session(path)
            self.assertEqual(archive.statuses, ())
            self.assertEqual(archive.status_packets, 0)


if __name__ == '__main__':
    unittest.main()
