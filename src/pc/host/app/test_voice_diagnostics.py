import unittest
import struct
from pathlib import Path
from .voice_protocol import _line
from .voice_diagnostics import decode_voice_diagnostics
from .protocol import ProtocolError


class VoiceDiagnosticTests(unittest.TestCase):
    def test_crc_reserved_and_pre_auth_record(self):
        raw = bytearray(96)
        raw[:8] = b'VD\1\0\0\x60\x13\x01'
        struct.pack_into('!IIIQ', raw, 8, 1, 80, 1, 1000)
        raw[56:58] = b'\xff\xff'
        raw[64] = 255
        raw[68:70] = b'\xd0\xe0'
        valid = _line(raw)
        packet = decode_voice_diagnostics(valid)
        self.assertEqual((packet.stage, packet.boot, packet.startup_error), (1, 80, 255))
        self.assertEqual(packet.raw[52], 0)  # not a synthetic VI face id
        damaged = bytearray(valid);damaged[20] = ord('A') if damaged[20] != ord('A') else ord('B')
        with self.assertRaises(ProtocolError):decode_voice_diagnostics(bytes(damaged))
        for index in (67, 78):
            changed=bytearray(packet.raw);changed[index]=1
            with self.assertRaises(ProtocolError):decode_voice_diagnostics(_line(changed))

    def test_real_wire_simulation_trace(self):
        root=Path(__file__).resolve().parents[2]
        trace=root/'verification_out/voice_busdiag_sim_20261028/voice_diagnostic_trace.txt'
        packets=[decode_voice_diagnostics(line) for line in trace.read_bytes().splitlines()]
        self.assertGreaterEqual(len(packets),5)
        self.assertTrue(all(p.stage==1 for p in packets))
        self.assertTrue(any(p.startup_error==0 and p.startup_responses==1 and p.poll_ok>=1 for p in packets))
        self.assertTrue(any(p.startup_error==1 and p.startup_stage==1 and p.startup_byte==0x68 and p.nacks>=1 for p in packets))
        self.assertTrue(any(p.startup_error==2 and p.startup_stage==0 and p.timeouts>=1 for p in packets))
        self.assertEqual(packets[-1].last_poll_error,0)
        self.assertGreaterEqual(packets[-1].poll_ok,2)
        self.assertEqual(packets[-1].startup_requests,3)
        self.assertEqual(packets[-1].startup_responses,3)
        self.assertEqual([p.sequence for p in packets],list(range(1,len(packets)+1)))
