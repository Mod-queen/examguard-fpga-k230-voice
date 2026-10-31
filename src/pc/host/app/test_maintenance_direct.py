from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from .protocol import StatusPacket, encode_status
from .evidence_health import EvidenceHealth
from .test_maintenance_protocol import result_line
from maintenance import execute


class Link:
    def __init__(self,stage=1):
        words=[0]*32;words[:4]=[0x01000000,1,18,0]
        self.status=encode_status(StatusPacket(1,stage,0,0,5,0,remaining_s=2700,exam_duration_s=2700,
                                              evidence_health=EvidenceHealth(tuple(words))))
        self.sent=[];self.initial=True;self.response=None
    def readline(self):
        if self.initial:self.initial=False;return self.status
        if self.response:
            response=self.response;self.response=None;return response
        return b''
    def write(self,data):
        self.sent.append(data)
        raw=bytes.fromhex(data[3:].decode())
        self.response=result_line(operation=raw[6],token=int.from_bytes(raw[8:12],'big'))
        return len(data)
    def flush(self):pass


class DirectMaintenanceTests(unittest.TestCase):
    def test_identity_discovery_single_send_exact_reply_and_raw_retention(self):
        with tempfile.TemporaryDirectory() as d:
            link=Link();path=Path(d)/'capture.raw'
            result=execute(link,0,bytes(32),path)
            self.assertEqual(result.error,0);self.assertEqual(len(link.sent),1)
            self.assertTrue(path.with_suffix('.request').is_file())
            self.assertIn(b'MR,',path.read_bytes())
            link=Link(stage=3)
            with self.assertRaises(ValueError):execute(link,0,bytes(32),Path(d)/'exam.raw')
            self.assertFalse(link.sent)
