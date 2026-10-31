import unittest
from contextlib import redirect_stdout
import io
from pathlib import Path
import tempfile
import types
import json
from unittest.mock import patch

import capture_main_persistent

from .evidence_health import EvidenceHealth
from .main_persistent_validation import MainPersistentValidation
from .protocol import StatusPacket, encode_status
from .transaction_protocol import TRANSACTION, TransactionEventPacket, encode_transaction_event

BOARD_ST = b'ST,0000006120,3,0,0,0000102000,000,000,000,000,000,02660,02700,020048700000000100000005000000010000000A000000000000000A0000001000000000000000000000000000018E700000000000000000000000000000000000000000000000000000000000000000000003F30000000000000000000000000000000000000000000007E6000000000000B1150000000000000000010002FE\n'


def status(boot, flags=0):
    words = [0] * 32
    words[0:4] = [0x01000000, 1, boot, 0]
    return encode_status(StatusPacket(1, 1, 0, 0, 100, 0, health_flags=flags,
                                     remaining_s=2700, exam_duration_s=2700,
                                     evidence_health=EvidenceHealth(tuple(words))))


def transaction(boot, uid=1):
    return encode_transaction_event(TransactionEventPacket(TRANSACTION.pack(1, boot, 1, uid, 101, 0, 0, 0x3064)))


class MainPersistentTests(unittest.TestCase):
    def test_live_capture_512byte_reads_preserves_partial_tail_and_writes_summary(self):
        pending = status(0, 0x10)
        ready = status(5)
        et = transaction(5)
        payload = pending + ready + et + ready[:29]

        class Link:
            def __init__(self):
                self.data = payload

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read(self, size):
                block, self.data = self.data[:size], self.data[size:]
                return block

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'logs').mkdir()
            stdout = io.StringIO()
            with patch.object(capture_main_persistent, '__file__', str(root/'capture_main_persistent.py')), \
                    patch('sys.modules', {**__import__('sys').modules, 'serial': types.SimpleNamespace(Serial=lambda *a, **k: Link())}), \
                    patch('sys.argv', ['capture_main_persistent.py', '--port', 'FAKE', '--previous-boot', '4']), \
                    redirect_stdout(stdout):
                result = capture_main_persistent.main()
            self.assertEqual(result, 0)
            saved = next((root/'logs').glob('*.raw'))
            self.assertEqual(saved.read_bytes(), payload)
            report = json.loads(saved.with_suffix('.json').read_text())
            self.assertTrue(report['verified'])
            self.assertEqual(report['status_count'], 2)
            self.assertEqual(report['trailing_partial_bytes'], 29)
            self.assertIn('MAIN BOOT READY; device=1 boot=5', stdout.getvalue())
            self.assertIn('MAIN PERSISTENT IDENTITY VALIDATED', stdout.getvalue())
            stdout = io.StringIO()
            with patch('sys.argv', ['capture_main_persistent.py', '--input', str(saved), '--previous-boot', '4']), redirect_stdout(stdout):
                self.assertEqual(capture_main_persistent.main(), 0)
            self.assertIn('"trailing_partial_bytes": 29', stdout.getvalue())

    def test_serial_partition_bytearray_matches_bytes(self):
        line, _, _ = bytearray(status(5)).partition(b'\n')
        a = MainPersistentValidation(4)
        a.accept(line)
        a.accept(transaction(5))
        self.assertTrue(a.summary()['verified'])

    def test_real_board_bad_telemetry_is_not_relaxed_for_identity(self):
        a = MainPersistentValidation(4);a.accept(BOARD_ST)
        self.assertIsNone(a.boot)
        self.assertEqual(a.invalid_count, 1)
        self.assertFalse(a.summary()['verified'])

    def test_corrected_history_statistics_with_same_board_counts(self):
        # Canonical mapping of the board's 1011 commits / 2022 gaps / 45333 UDP
        # packets. Counts are never placed in reserved state words20 or28.
        words = [0] * 32
        words[:12] = [0x02004870, 1, 5, 1, 10, 0, 10, 0x10, 0, 0, 0, 102000]
        words[23] = 1011
        words[26] = 2022
        words[29] = 45333
        words[31] = 0x010002fe
        st = encode_status(StatusPacket(6120, 3, 0, 0, 102000, 0,
                           remaining_s=2660, exam_duration_s=2700,
                           evidence_health=EvidenceHealth(tuple(words))))
        a = MainPersistentValidation(4);a.accept(bytearray(st))
        self.assertEqual(a.boot, 5)
        a.accept(transaction(5, 11))
        self.assertTrue(a.summary()['verified'])

    def test_pending_then_ready_and_same_boot_monotonic_UID(self):
        a = MainPersistentValidation(4)
        a.accept(status(0, 0x10));self.assertFalse(a.summary()['verified'])
        a.accept(status(5));a.accept(transaction(5, 1));a.accept(transaction(5, 3))
        self.assertTrue(a.summary()['verified'])  # cancelled UID2 is not a duplicate
        # UART whole-packet arbitration may deliver ET before the first ST.
        a = MainPersistentValidation(4);a.accept(transaction(5));a.accept(status(5))
        self.assertTrue(a.summary()['verified'])
        a = MainPersistentValidation(4);a.accept(transaction(4));a.accept(status(5))
        self.assertFalse(a.summary()['verified'])

    def test_failed_skipped_reset_and_cross_boot_ET_rejected(self):
        for lines in ((status(0, 0x20),), (status(6), transaction(6)),
                      (status(5), transaction(4)), (status(5), status(6), transaction(6))):
            a = MainPersistentValidation(4)
            for line in lines:
                a.accept(line)
            self.assertFalse(a.summary()['verified'])

    def test_duplicate_UID_invalid_line_and_no_ET_rejected(self):
        for extra in ((transaction(5), transaction(5)), (b'broken UART\n', transaction(5)), ()):
            a = MainPersistentValidation(4);a.accept(status(5))
            for line in extra:
                a.accept(line)
            self.assertFalse(a.summary()['verified'])


if __name__ == '__main__':
    unittest.main()
