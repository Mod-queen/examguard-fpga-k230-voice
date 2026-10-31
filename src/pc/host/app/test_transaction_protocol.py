from pathlib import Path
import sqlite3
import tempfile
import unittest
from contextlib import closing
from unittest.mock import patch

from .protocol import EventIdentityPacket, EventPacket, ProtocolError, decode_packet
from .transaction_protocol import TRANSACTION, TransactionEventPacket, encode_transaction_event
from .event_store import EventStore, load_session
from .monitor import MonitorModel


def transaction(uid=0xFFFFFFFFFFFFFFFF, boot=5):
    return TransactionEventPacket(TRANSACTION.pack(1, boot, 3, uid, 0xFEDCBA98FFFFFFFF, 1, 0, 0x3750))


class TransactionProtocolTests(unittest.TestCase):
    def test_exact_wire_identity_time_lane_and_strict_validation(self):
        packet = transaction()
        raw = encode_transaction_event(packet)
        self.assertEqual(len(raw), 68)
        self.assertEqual(decode_packet(raw), packet)
        self.assertEqual(packet.identity, (1, 5, 3, 0xFFFFFFFFFFFFFFFF))
        self.assertEqual((packet.timestamp, packet.stage_id, packet.risk_level, packet.event_code), (0xFEDCBA98FFFFFFFF, 3, 3, 0x50))
        for raw in (b'ET,' + b'0'*63, b'ET,' + b'G'*64, encode_transaction_event(packet).replace(b'ET,', b'ET,,') ):
            with self.assertRaises(ProtocolError):
                decode_packet(raw)
        for source, reserved, lane, uid in ((4, 0, 0x3750, 1), (1, 1, 0x3750, 1), (1, 0, 0xB750, 1), (1, 0, 0x6750, 1), (1, 0, 0x3750, 0)):
            with self.assertRaises(ProtocolError):
                encode_transaction_event(TransactionEventPacket(TRANSACTION.pack(1, 2, 3, uid, 4, source, reserved, lane)))

    def test_durable_full_identity_duplicates_clear_and_no_legacy_rebinding(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            model.apply(EventPacket(1, 2, 3, 0, 3, 0x50))
            model.apply(EventIdentityPacket(1, 1, 1, 7))
            for n in range(220):
                model.apply(transaction(n+1))
            model.apply(transaction())
            model.apply(transaction())
            model.apply(transaction(1, boot=6))
            snapshot = model.snapshot()
            self.assertEqual(snapshot.events[0].identity.uid, 7)
            self.assertEqual(len(snapshot.transactions), 200)
            self.assertEqual(snapshot.transaction_packets, 223)
            self.assertEqual(snapshot.persisted_transactions, 223)
            path = snapshot.session_path
            model.clear_events()
            self.assertFalse(model.snapshot().transactions)
            self.assertEqual(len(model.session_archive().transactions), 223)
            export = Path(directory) / 'transactions.csv'
            model.export_transactions_csv(export)
            self.assertEqual(len(export.read_text().splitlines()), 224)
            with self.assertRaises(ValueError):
                model.export_transactions_csv(path)
            from .review import export_report
            report = Path(directory) / 'report.md'
            export_report(report, model.snapshot(), [], [], session=model.session_archive())
            self.assertIn('18446744073709551615', report.read_text(encoding='utf-8'))
            self.assertIn('已保存ET接收记录：223', report.read_text(encoding='utf-8'))
            model.close()
            stored = load_session(path)
            self.assertEqual(stored.transactions[-3].packet, transaction())
            self.assertEqual(stored.transactions[-2].packet, transaction())
            self.assertEqual(stored.transactions[-1].packet.identity, (1, 6, 3, 1))
            self.assertEqual(len(stored.events), 1)

    def test_transaction_disk_error_visible_does_not_stop_live_or_fake_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            try:
                with patch.object(EventStore, 'append_transaction', side_effect=sqlite3.OperationalError('disk full')):
                    model.apply(transaction())
                snapshot = model.snapshot()
                self.assertEqual(snapshot.persisted_transactions, 0)
                self.assertEqual(len(snapshot.transactions), 1)
                self.assertIn('disk full', snapshot.persistence_error)
                self.assertFalse(model.session_archive().transactions)
                self.assertEqual(model.session_archive().transaction_failures, 1)
            finally:
                model.close()
            recovered = load_session(snapshot.session_path)
            self.assertEqual(recovered.transaction_failures, 1)
            self.assertEqual(recovered.transaction_packets, 1)
            self.assertEqual(recovered.persistence_failures, 0)  # no fabricated AL gap

    def test_legacy_schema_without_optional_transaction_table_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory)
            path = model.snapshot().session_path
            model.close()
            with closing(sqlite3.connect(path)) as db, db:
                db.execute('DROP TABLE transaction_events')
                db.execute('UPDATE session SET schema_version=2')
            self.assertFalse(load_session(path).transactions)


if __name__ == '__main__':
    unittest.main()
