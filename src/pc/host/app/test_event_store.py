"""Persistence integration: trim/clear, restart, duplicate AL, failures, crash."""
import csv
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from .event_store import EventLogEntry, EventStore, load_session
from .monitor import MonitorModel
from .protocol import EventIdentityPacket, EventPacket, StatusPacket
from .review import export_report

HOST = Path(__file__).resolve().parents[1]


def alarm(number=1, timestamp=None):
    return EventPacket(number, number if timestamp is None else timestamp, 3, 0, 3, 0x50)


class PersistenceTests(unittest.TestCase):
    def test_v2_identity_persists_attaches_and_reloads(self):
        with tempfile.TemporaryDirectory() as directory:
            store = EventStore(directory)
            store.append(EventLogEntry("t0", alarm(1), 1))
            store.attach_identity(1, EventIdentityPacket(1, 2, 3, 0x1F2E3D4C5B6A7988))
            store.close(received_al=1, failed_al=0, last_error=None)
            archive = load_session(store.path)
            self.assertEqual(archive.events[0].identity,
                             EventIdentityPacket(1, 2, 3, 0x1F2E3D4C5B6A7988))

    def test_monitor_attaches_ei_to_previous_al_only(self):
        model = MonitorModel()
        model.apply(alarm(7))
        model.apply(EventIdentityPacket(1, 2, 3, 55))
        model.apply(alarm(8))
        snapshot = model.snapshot()
        self.assertEqual(snapshot.events[0].identity, EventIdentityPacket(1, 2, 3, 55))
        self.assertIsNone(snapshot.events[1].identity)
        self.assertEqual(snapshot.latest_identity, EventIdentityPacket(1, 2, 3, 55))

    def test_report_shows_uid_or_v1_placeholder(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            try:
                model.apply(alarm(1))
                model.apply(EventIdentityPacket(1, 2, 3, 77))
                model.apply(alarm(2))
                report = Path(directory)/"r.md"
                export_report(report, model.snapshot(), [], [], session=model.session_archive())
                text = report.read_text(encoding="utf-8")
                self.assertIn("| 77 | 1/2/3 |", text)
                self.assertIn("未收到EI", text)
            finally:
                model.close()

    def test_more_than_200_clear_and_full_csv_report_survive_restart(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory, session_metadata={"board_protocol": "v1"})
            try:
                for number in range(1, 251):
                    model.apply(alarm(number))
                snapshot = model.snapshot()
                self.assertEqual(len(snapshot.events), 200)
                self.assertEqual(snapshot.persisted_events, 250)
                model.clear_events()
                self.assertEqual(model.snapshot().events, ())
                csv_path = Path(directory)/"events.csv"
                model.export_events_csv(csv_path)
                with csv_path.open(encoding="utf-8", newline="") as stream:
                    rows = list(csv.DictReader(stream))
                self.assertEqual(len(rows), 250)
                self.assertEqual(rows[0]["receipt_id"], "1")
                self.assertEqual(rows[-1]["receipt_id"], "250")
                archive = model.session_archive()
                report = Path(directory)/"report.md"
                export_report(report, model.snapshot(), [], [], session=archive)
                text = report.read_text(encoding="utf-8")
                self.assertIn("已落盘：250", text)
                self.assertIn("采集会话不是FPGA", text)
                self.assertIn("| 250 |", text)
                self.assertIn("未自动绑定告警", text)
                path = snapshot.session_path
            finally:
                model.close()
            reopened = load_session(path)
            self.assertIsNotNone(reopened.ended_at)
            self.assertEqual(len(reopened.events), 250)
            self.assertEqual(reopened.events[0].packet, alarm(1))

    def test_each_launch_is_separate_and_identical_packets_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            one, two = MonitorModel(session_root=directory), MonitorModel(session_root=directory)
            try:
                one.apply(alarm())
                one.apply(alarm())
                one.apply(alarm(0, 0))  # rollback is preserved, not guessed as a new exam
                two.apply(alarm())
                self.assertNotEqual(one.snapshot().host_session_id, two.snapshot().host_session_id)
                self.assertEqual(len(one.session_archive().events), 3)
                self.assertEqual(len(two.session_archive().events), 1)
                self.assertEqual([e.receipt_id for e in one.session_archive().events], [1, 2, 3])
            finally:
                one.close()
                two.close()

    def test_uint64_timestamp_and_no_status_synthesized_alarm(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            try:
                model.apply(StatusPacket(1, 3, 3, 0, 10, 0x50))
                model.apply(alarm(timestamp=2**64-1))
                archive = model.session_archive()
                self.assertEqual(len(archive.events), 1)
                self.assertEqual(archive.events[0].packet.timestamp, 2**64-1)
            finally:
                model.close()

    def test_write_failure_visible_memory_continues_gap_not_hidden(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            try:
                model.apply(alarm(1))
                with patch.object(EventStore, "append", side_effect=sqlite3.OperationalError("disk full")):
                    model.apply(alarm(2))
                model.apply(alarm(3))
                snapshot = model.snapshot()
                self.assertEqual(len(snapshot.events), 3)
                self.assertEqual(snapshot.persisted_events, 2)
                self.assertEqual(snapshot.persistence_failures, 1)
                self.assertIn("disk full", snapshot.persistence_error)
                self.assertEqual([e.receipt_id for e in model.session_archive().events], [1, 3])
                path = snapshot.session_path
            finally:
                model.close()
            self.assertEqual(load_session(path).persistence_failures, 1)

    def test_initialization_failure_and_read_failure_are_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            bad_root = Path(directory)/"not_a_directory"
            bad_root.write_text("existing file", encoding="utf-8")
            model = MonitorModel(session_root=bad_root)
            model.apply(alarm())
            self.assertIsNone(model.session_archive())
            self.assertIn("初始化失败", model.snapshot().persistence_error)
            self.assertEqual(model.snapshot().persistence_failures, 1)
            with self.assertRaises(OSError):
                model.export_events_csv(Path(directory)/"should_not_claim_full_session.csv")
            model.close()
            model = MonitorModel(session_root=directory)
            try:
                with patch.object(EventStore, "read", side_effect=sqlite3.DatabaseError("corrupt")):
                    with self.assertRaises(sqlite3.DatabaseError):
                        model.session_archive()
            finally:
                model.close()

    def test_committed_events_recover_after_process_exit_without_close(self):
        with tempfile.TemporaryDirectory() as directory:
            code = ("import os,sys\nfrom app.monitor import MonitorModel\n"
                    "from app.protocol import EventPacket\n"
                    "m=MonitorModel(session_root=sys.argv[1])\n"
                    "m.apply(EventPacket(1,2,3,0,3,80))\n"
                    "os._exit(0)\n")
            subprocess.run([sys.executable, "-B", "-c", code, directory], cwd=HOST,
                           check=True, timeout=15)
            files = list(Path(directory).glob("*.sqlite3"))
            self.assertEqual(len(files), 1)
            archive = load_session(files[0])
            self.assertEqual(len(archive.events), 1)
            self.assertIsNone(archive.ended_at)

    def test_offline_cli_and_no_overwrite_of_database(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            model.apply(alarm())
            path = model.snapshot().session_path
            try:
                with self.assertRaises(ValueError):
                    model.export_events_csv(path)
                with self.assertRaises(ValueError):
                    model.export_evidence_csv(path)
                with self.assertRaises(ValueError):
                    export_report(path, model.snapshot(), [], [], session=model.session_archive())
            finally:
                model.close()
            report = Path(directory)/"offline.md"
            subprocess.run([sys.executable, "-B", str(HOST/"session_report.py"), path,
                            "--out", str(report)], cwd=HOST, check=True, timeout=15,
                           capture_output=True)
            self.assertIn("已落盘：1", report.read_text(encoding="utf-8"))
            with self.assertRaises(FileNotFoundError):
                load_session(Path(directory)/"missing.sqlite3")
            self.assertFalse((Path(directory)/"missing.sqlite3").exists())


if __name__ == "__main__":
    unittest.main()
