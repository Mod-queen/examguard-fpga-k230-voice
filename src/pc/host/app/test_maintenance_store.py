from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import zipfile

from .event_store import load_session
from .monitor import MonitorModel
from .protocol import decode_packet
from .test_maintenance_protocol import result_line
from .review import export_report
from .evidence_package import export_evidence_package, verify_evidence_package


class MaintenanceStoreTests(unittest.TestCase):
    def test_duplicates_full_history_report_and_active_database_package(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);images=root/'images';images.mkdir()
            model=MonitorModel(session_root=root/'sessions',max_events=1)
            try:
                for line in (result_line(),result_line(),result_line(error=4,**{'25':3,'27':2})):
                    model.apply(decode_packet(line))
                model.clear_events();snapshot=model.snapshot();archive=model.session_archive()
                self.assertEqual((snapshot.maintenance_packets,snapshot.persisted_maintenance), (3,3))
                self.assertEqual(len(archive.maintenance),3)
                self.assertEqual(archive.maintenance[0].packet.raw,archive.maintenance[1].packet.raw)
                report=root/'report.md';export_report(report,snapshot,[],[],session=archive)
                self.assertIn('已保存MR记录：3',report.read_text(encoding='utf-8'))
                package=root/'case.zip';export_evidence_package(images,package,session_path=snapshot.session_path)
                self.assertTrue(verify_evidence_package(package)['session'])
                with zipfile.ZipFile(package) as z:self.assertIn('recovery=2',z.read('report.md').decode())
                path=snapshot.session_path
            finally:model.close()
            archive=load_session(path);self.assertEqual(len(archive.maintenance),3)
            with closing(sqlite3.connect(path)) as db,db:db.execute("UPDATE maintenance_history SET canonical_mr='MR,bad' WHERE receipt_id=1")
            with self.assertRaises(ValueError):load_session(path)

    def test_failure_accounting_separate_and_old_schema_does_not_invent_MR(self):
        with tempfile.TemporaryDirectory() as directory:
            model=MonitorModel(session_root=directory)
            try:
                with patch.object(model._store,'append_maintenance',side_effect=OSError('disk full')):
                    model.apply(decode_packet(result_line()))
                model.apply(decode_packet(result_line(token=11)))
                archive=model.session_archive();path=archive.session_path
                self.assertEqual((archive.maintenance_packets,archive.maintenance_failures,archive.persistence_failures),(2,1,0))
                self.assertIn('维护回执存档失败',model.snapshot().persistence_error)
            finally:model.close()
            with closing(sqlite3.connect(path)) as db,db:
                db.execute('UPDATE session SET schema_version=5');db.execute('DROP TABLE maintenance_history')
            self.assertEqual(load_session(path).maintenance,())
