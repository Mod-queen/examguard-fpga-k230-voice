import unittest

from .exam_timer import ExamTimer
from .protocol import StatusPacket, ProtocolError, decode_packet, encode_status


def status(stage, remaining=None, duration=None):
    return StatusPacket(1, stage, 0, 0, 500000, 0, remaining_s=remaining, exam_duration_s=duration)


class ExamTimerTests(unittest.TestCase):
    def test_wait_s3_live_count_submit_timeout_reset_and_reconnect(self):
        timer = ExamTimer()
        self.assertEqual(timer.view(0).remaining, '45:00')
        for stage in (0, 1, 2):
            timer.apply(status(stage, 0, 2700), 10)
            self.assertEqual(timer.view(11).remaining, '45:00')
            self.assertIn('S3', timer.view(11).message)
        timer.apply(status(3, 2700, 2700), 12)
        self.assertEqual(timer.view(13).remaining, '45:00')
        timer.apply(status(3, 2699, 2700), 13)
        self.assertEqual(timer.view(14).remaining, '44:59')
        self.assertEqual(timer.view(14).elapsed, '00:01')
        # PC time never advances countdown; a missed packet/USB disconnect
        # cannot pretend that the FPGA is still running.
        self.assertEqual(timer.view(100).remaining, '44:59')
        self.assertIn('停更', timer.view(100).message)
        timer.apply(status(3, 2650, 2700), 101)
        self.assertEqual(timer.view(101).remaining, '44:10')
        timer.apply(status(4, 2650, 2700), 102)
        self.assertIn('冻结', timer.view(102).message)
        timer.apply(status(4, 0, 2700), 103)
        self.assertEqual(timer.view(103).remaining, '00:00')
        timer.apply(status(1, 0, 2700), 104)
        self.assertEqual(timer.view(104).remaining, '45:00')

    def test_legacy_does_not_invent_uptime_timer_and_late_join_uses_board(self):
        timer = ExamTimer()
        timer.apply(status(3), 1)
        self.assertEqual(timer.view(1).remaining, '--:--')
        timer.apply(status(3, 1801, 2700), 2)
        self.assertEqual(timer.view(2).remaining, '30:01')
        self.assertEqual(timer.view(2).elapsed, '14:59')

    def test_timer_protocol_roundtrip_and_reject_partial_or_invalid_time(self):
        packet = status(3, 2699, 2700)
        self.assertEqual(decode_packet(encode_status(packet)), packet)
        self.assertIsNone(decode_packet('ST,1,3,0,0,10,0,0,0,0,0').remaining_s)
        for raw in ('ST,1,3,0,0,10,0,0,0,0,0,2699',
                    'ST,1,3,0,0,10,0,0,0,0,0,2701,2700',
                    'ST,1,3,0,0,10,0,0,0,0,0,0,0'):
            with self.subTest(raw=raw), self.assertRaises(ProtocolError):
                decode_packet(raw)
