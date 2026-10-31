from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from .protocol import decode_packet,ProtocolError
from .monitor import MonitorModel
from .event_store import load_session
from .ddr_capacity import decode_capacity


def bm_line(valid=1):
    raw=b'BM\1\1\0\x40'+bytes((2|valid,0x85))+struct.pack('!IIIIQ',1,18,1,6,1000)+struct.pack('!4HII',0x9770,0x5550,0x9990,0x9990,1,10)+bytes(12)
    return b'BM,'+(raw+zlib.crc32(raw).to_bytes(4,'big')).hex().encode()


class BoardMonitorTests(unittest.TestCase):
    def test_strict_decoder_onchip_conversion_persistence_no_stale_health(self):
        packet=decode_packet(bm_line());self.assertIn('VCCINT/AUX/BRAM',packet.text())
        self.assertAlmostEqual(packet.adc[1]*3/65536,1.0,places=3)
        self.assertIn('未知/陈旧',decode_packet(bm_line(0)).text())
        with self.assertRaises(ProtocolError):decode_packet(bm_line()[:-1])
        with tempfile.TemporaryDirectory() as d:
            model=MonitorModel(session_root=d)
            model.apply(packet);model.apply(decode_packet(bm_line(0)));path=model.snapshot().session_path;model.close()
            archive=load_session(path);self.assertEqual(len(archive.board_monitors),2)

    def test_DC_coverage_crc_and_failure_not_passing(self):
        raw=b'DC\1\1\0\x60'+bytes(2)+struct.pack('!6I',268435456,2,2,0,134217728,134217728)+bytes(16)+struct.pack('!8I',1,2,3,4,5,6,7,8)+bytes(12)
        line=lambda raw:b'DC,'+(raw+zlib.crc32(raw).to_bytes(4,'big')).hex().encode()
        self.assertTrue(decode_capacity(line(raw))['passed'])
        self.assertEqual(decode_capacity(line(raw))['write_cycles'],(4,3,2,1))
        altered=bytearray(raw);altered[6]=1
        self.assertFalse(decode_capacity(line(altered))['passed'])
        altered[28]=0
        with self.assertRaises(ValueError):decode_capacity(line(altered))
