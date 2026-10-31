"""RTC1 board-capture gate at the real serial framing seam; no hardware."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import zlib

import capture_main_persistent
from .main_persistent_validation import MainPersistentValidation
from .test_main_persistent_validation import status, transaction


def anchor(boot=12, seq=1, lower=100, error=0):
    raw = (b'RA\x01\x01\x00\x40' + bytes((int(error == 0), error)) +
           struct.pack('!IIIQQ', 1, boot, seq, lower, lower+10) +
           bytes.fromhex('000035201820021026') + bytes(15))
    raw += zlib.crc32(raw).to_bytes(4, 'big')
    return b'RA,' + raw.hex().upper().encode('ascii') + b'\n'


def identity(boot=12):
    return f'EI,00000001,{boot:08X},00000001,0000000000000001,001\n'.encode('ascii')


class RTCMainCaptureTests(unittest.TestCase):
    def test_new_RA_epoch_ignores_old_traffic_without_guessing_boot(self):
        audit = MainPersistentValidation(min_rtc_anchors=3)
        for line in (status(7), transaction(7), b'partial-old-line\n'):
            audit.accept(line)
        self.assertIsNone(audit.boot)
        for line in (anchor(), status(12), transaction(12), identity(),
                     anchor(seq=2, lower=1100), anchor(seq=3, lower=2100)):
            audit.accept(line)
        self.assertTrue(audit.summary()['verified'])
        self.assertEqual(audit.boot, 12)
        self.assertEqual(audit.invalid_count, 0)
        self.assertEqual(audit.rtc_summary()['ignored_lines_before_first_RA'], 3)

    def test_RTC_failure_mismatch_gap_and_nonadvancing_bracket_rejected(self):
        for last in (anchor(error=1), anchor(boot=13, seq=2, lower=1100),
                     anchor(seq=3, lower=1100), anchor(seq=2, lower=105)):
            audit = MainPersistentValidation(min_rtc_anchors=2)
            for line in (anchor(), status(12), transaction(12), identity(), last):
                audit.accept(line)
            self.assertFalse(audit.summary()['verified'])
            self.assertTrue(audit.reasons)
        audit = MainPersistentValidation(min_rtc_anchors=2)
        for line in (anchor(), status(12), transaction(12), identity(), b'RA,broken\n'):
            audit.accept(line)
        self.assertFalse(audit.summary()['verified'])
        self.assertEqual(audit.invalid_count, 1)

    def test_serial_waits_for_periodic_RA_after_ET_and_replays_identically(self):
        payload = (status(7) + transaction(7) + anchor() + status(12) + transaction(12) + identity() +
                   anchor(seq=2, lower=1100) + anchor(seq=3, lower=2100) + b'ST,prefix')

        class Link:
            def __init__(self): self.raw = payload
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size):
                block, self.raw = self.raw[:size], self.raw[size:]
                return block

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'logs').mkdir()
            stdout = io.StringIO()
            with patch.object(capture_main_persistent, '__file__', str(root/'capture_main_persistent.py')), \
                    patch.dict(sys.modules, {'serial': types.SimpleNamespace(Serial=lambda *a, **k: Link())}), \
                    patch.object(sys, 'argv', ['capture_main_persistent.py', '--port', 'FAKE', '--require-rtc', '3', '--cold-boot']), \
                    redirect_stdout(stdout):
                self.assertEqual(capture_main_persistent.main(), 0)
            raw = next((root/'logs').glob('*.raw'))
            self.assertEqual(raw.read_bytes(), payload)
            report = json.loads(raw.with_suffix('.json').read_text())
            self.assertEqual(report['boot'], 12)
            self.assertIsNone(report['previous_boot'])
            self.assertEqual(report['rtc']['anchor_count'], 3)
            self.assertEqual(report['trailing_partial_bytes'], 9)
            self.assertIn('MAIN RTC IDENTITY VALIDATED; boot=12', stdout.getvalue())
            self.assertIn('Do NOT Program Device or press RESET.', stdout.getvalue())
            self.assertNotIn('Program RTC1 main bit now.', stdout.getvalue())
            with patch.object(sys, 'argv', ['capture_main_persistent.py', '--input', str(raw), '--require-rtc', '3']), \
                    redirect_stdout(io.StringIO()):
                self.assertEqual(capture_main_persistent.main(), 0)


if __name__ == '__main__': unittest.main()
