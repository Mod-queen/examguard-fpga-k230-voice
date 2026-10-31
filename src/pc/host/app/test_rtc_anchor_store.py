"""Real common parser/model/FULL SQLite/report integration; no board operations."""
from contextlib import redirect_stdout, closing
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import session_report
from .event_store import load_session
from .monitor import MonitorModel
from .protocol import decode_packet
from .test_rtc_anchor import line


class RTCAnchorStoreTests(unittest.TestCase):
    def test_parser_duplicates_clear_full_receipts_reopen_and_offline_report(self):
        with tempfile.TemporaryDirectory() as directory:
            model=MonitorModel(session_root=directory,max_events=1)
            model.apply(decode_packet(line()))
            model.apply(decode_packet(line()))
            model.apply(decode_packet(line(1)))
            model.clear_events()
            snapshot=model.snapshot()
            self.assertEqual(snapshot.anchor_packets,3)
            self.assertEqual(snapshot.persisted_anchors,3)
            self.assertEqual(len(snapshot.anchors),1)
            archive=model.session_archive()
            self.assertEqual(len(archive.anchors),3)
            self.assertEqual(archive.anchor_failures,0)
            self.assertEqual(archive.anchors[0].packet.lower_ms,0x100000010)
            self.assertEqual(archive.anchors[-1].packet.error,1)
            path=snapshot.session_path;model.close()
            reopened=load_session(path)
            self.assertEqual(len(reopened.anchors),3)
            self.assertIsNotNone(reopened.ended_at)
            report=Path(directory)/'report.md'
            with patch('sys.argv',['session_report.py',path,'--out',str(report)]),redirect_stdout(io.StringIO()):
                session_report.main()
            text=report.read_text(encoding='utf-8')
            self.assertIn('已保存RA记录：3',text)
            self.assertIn('无可信日期',text)
            self.assertIn('不跨boot外推',text)

    def test_RA_failure_does_not_inflate_AL_ST_ET_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            model=MonitorModel(session_root=directory)
            try:
                with patch.object(model._store,'append_anchor',side_effect=OSError('disk full')):
                    model.apply(decode_packet(line()))
                self.assertEqual(model.snapshot().anchor_failures,1)
                self.assertEqual(model.snapshot().persisted_anchors,0)
                self.assertIn('RTC锚存档失败',model.snapshot().persistence_error)
                model.apply(decode_packet(line(2)))
                archive=model.session_archive()
                self.assertEqual(archive.anchor_packets,2)
                self.assertEqual(archive.anchor_failures,1)
                self.assertEqual(archive.persistence_failures,0)
                self.assertEqual(archive.status_failures,0)
                self.assertEqual(archive.transaction_failures,0)
                path=model.snapshot().session_path
            finally:
                model.close()
            archive=load_session(path)
            self.assertEqual(archive.anchor_failures,1)
            self.assertEqual(archive.persistence_failures,0)

    def test_legacy_schema4_does_not_fabricate_RA_and_tamper_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            model=MonitorModel(session_root=directory)
            model.apply(decode_packet(line()))
            path=model.snapshot().session_path;model.close()
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('UPDATE rtc_anchor_history SET canonical_ra=?',('RA,'+'00'*64,))
            with self.assertRaises(ValueError):
                load_session(path)
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('UPDATE session SET schema_version=4')
                db.execute('DROP TABLE rtc_anchor_history')
            self.assertEqual(load_session(path).anchors,())


if __name__=='__main__':
    unittest.main()
