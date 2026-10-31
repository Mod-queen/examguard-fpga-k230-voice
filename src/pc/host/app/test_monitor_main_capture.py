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
from .test_rtc_main_capture import anchor,identity
from .test_main_persistent_validation import status,transaction


def board(boot=18,seq=1,adc_seq=10,stamp=1000,flags=3,seat=1):
    raw=b'BM\1\1\0\x40'+bytes((flags,0))+struct.pack('!IIIIQ',1,boot,seq,seat,stamp)+struct.pack('!4HII',0x9770,0x5550,0x9990,0x5550,adc_seq,10)+bytes(12)
    return b'BM,'+(raw+zlib.crc32(raw).to_bytes(4,'big')).hex().encode()+b'\n'


def stream():
    return (status(17)+anchor(boot=17)+transaction(17)+b'old prefix\n'+board()+anchor(boot=18)+
            status(18)+transaction(18)+identity(18)+board(seq=2,adc_seq=20,stamp=2000)+
            anchor(boot=18,seq=2,lower=1100)+anchor(boot=18,seq=3,lower=2100))


class MonitorCaptureTests(unittest.TestCase):
    def test_old_RTC1_RA_excluded_until_first_BM(self):
        audit=MainPersistentValidation(min_rtc_anchors=3,min_board_records=2)
        for line in stream().splitlines():audit.accept(line)
        self.assertTrue(audit.summary()['verified']);self.assertEqual(audit.boot,18)
        self.assertEqual(audit.board_summary()['ignored_before_first_BM'],4)
        self.assertEqual(len(audit.anchors),3)

    def test_invalid_or_changed_monitor_cannot_pass(self):
        for last in (board(boot=19,seq=2,adc_seq=20,stamp=2000),board(seq=2,adc_seq=10,stamp=2000),
                     board(seq=2,adc_seq=20,stamp=2000,flags=2),board(seq=2,adc_seq=20,stamp=2000,seat=2)):
            audit=MainPersistentValidation(min_rtc_anchors=2,min_board_records=2)
            for line in (board(),anchor(boot=18),status(18),last):audit.accept(line)
            self.assertFalse(audit.summary()['verified']);self.assertTrue(audit.reasons)

    def test_serial_raw_and_offline_replay_keep_same_monitor_boundary(self):
        payload=stream()+b'ST,prefix'
        class Link:
            def __init__(self):self.raw=payload
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read(self,size):
                block,self.raw=self.raw[:size],self.raw[size:];return block
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);(root/'logs').mkdir();stdout=io.StringIO()
            with patch.object(capture_main_persistent,'__file__',str(root/'capture_main_persistent.py')),patch.dict(
                    sys.modules,{'serial':types.SimpleNamespace(Serial=lambda *a,**k:Link())}),patch.object(
                    sys,'argv',['capture_main_persistent.py','--port','FAKE','--require-rtc','3','--require-board','2']),redirect_stdout(stdout):
                self.assertEqual(capture_main_persistent.main(),0)
            raw=next((root/'logs').glob('*.raw'));report=json.loads(raw.with_suffix('.json').read_text(encoding='utf-8'))
            self.assertEqual(raw.read_bytes(),payload);self.assertEqual(report['board']['records'],2)
            self.assertIn('MAIN MONITOR IDENTITY VALIDATED; boot=18',stdout.getvalue())
            with patch.object(sys,'argv',['capture_main_persistent.py','--input',str(raw),'--require-rtc','3','--require-board','2']),redirect_stdout(io.StringIO()):
                self.assertEqual(capture_main_persistent.main(),0)
