import json
import tempfile
import unittest
from pathlib import Path

from .image_store import ImageEvidenceFrame, write_image_evidence
from .monitor import MonitorModel
from .protocol import decode_packet
from .review import load_windows, export_report, candidate_windows, exact_window


class ReviewTests(unittest.TestCase):
    def test_health_flag_formatting(self):
        from .exam_events import format_health
        self.assertEqual(format_health(0), "正常 (0x00)")
        self.assertIn("相机停帧", format_health(0x01))
        self.assertIn("证据溢出", format_health(0x09))
        self.assertIn("未知位0x80", format_health(0x80))
        self.assertIn("持久身份等待", format_health(0x10))
        self.assertIn("事务准入关闭", format_health(0x20))

    def test_candidates_require_time_and_frame_and_never_choose_ambiguity(self):
        packet = decode_packet(b'AL,0000000060,0000001000,3,0,1,100\n')
        window = dict(path=Path('event_1'), frames=[
            dict(timestamp_ms=990, frame_id=59), dict(timestamp_ms=1010, frame_id=61)])
        self.assertEqual(candidate_windows(packet, [window]), [window])
        duplicate = dict(window, path=Path('event_1_2'))
        self.assertEqual(len(candidate_windows(packet, [window, duplicate])), 2)
        wrong_frame = dict(window, frames=[dict(timestamp_ms=990, frame_id=100),
                                          dict(timestamp_ms=1010, frame_id=102)])
        self.assertEqual(candidate_windows(packet, [wrong_frame]), [])
        rollback = dict(window, frames=list(reversed(window['frames'])))
        self.assertEqual(candidate_windows(packet, [rollback]), [])
        self.assertEqual(candidate_windows(packet, [dict(window, frames=[])]), [])

    def test_exact_window_binds_by_sequence_and_falls_back_when_absent(self):
        a = dict(path=Path('event_0007'), seq=7, frames=[])
        b = dict(path=Path('event_0008'), seq=8, frames=[])
        self.assertEqual(exact_window(7, [a, b]), [a])
        self.assertEqual(exact_window(9, [a, b]), [])
        self.assertEqual(exact_window(None, [a, b]), [])  # v1/v2.0 has no seq

    def test_complete_missing_file_and_report_scope(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = write_image_evidence(tmp, event_seq=1, expected_count=1,
                width=1, height=1, frames=[ImageEvidenceFrame(1, 0, 60, 1000, 0, 1, 1, b'\x20')])
            windows, errors = load_windows(tmp)
            self.assertFalse(errors)
            self.assertTrue(windows[0]['complete'])
            model = MonitorModel()
            model.apply(decode_packet(b'AL,0000000060,0000001000,3,0,1,100\n'))
            report = Path(tmp) / 'report.md'
            export_report(report, model.snapshot(), windows, errors)
            text = report.read_text(encoding='utf-8')
            self.assertIn('0x64', text)
            self.assertIn('未自动绑定告警', text)
            self.assertIn(str(directory.resolve()), text)
            (directory / 'frame_000.pgm').unlink()
            windows, _ = load_windows(tmp)
            self.assertFalse(windows[0]['complete'])

    def test_invalid_manifest_does_not_hide_good_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = write_image_evidence(tmp, event_seq=1, expected_count=1,
                width=1, height=1, frames=[])
            bad = Path(tmp) / 'event_0002'
            bad.mkdir()
            (bad / 'manifest.json').write_text('{')
            windows, errors = load_windows(tmp)
            self.assertEqual(len(windows), 1)
            self.assertFalse(windows[0]['complete'])
            self.assertEqual(len(errors), 1)
            manifest = directory / 'manifest.json'
            data = json.loads(manifest.read_text())
            data['frames'] = [dict(index=0, file='../outside.ppm', timestamp_ms=0)]
            manifest.write_text(json.dumps(data))
            windows, errors = load_windows(tmp)
            self.assertFalse(windows)
            self.assertEqual(len(errors), 2)
