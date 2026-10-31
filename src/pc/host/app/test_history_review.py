"""End-to-end persisted EG/HR -> review/browser/report, no physical hardware."""
from pathlib import Path
import tempfile
import tkinter as tk
import unittest
import gc
import time
from unittest.mock import patch

from .evidence_v2 import decode_window_packet
from .evidence_v2_receiver import EvidenceV2Receiver
from .history_result import encode_history_result, FLAG_OK, FLAG_COVERAGE_OK, FLAG_GAP_UNKNOWN
from .history_result_receiver import HistoryResultReceiver
from .monitor import MonitorModel
from .replay import EvidenceBrowser
from .review import load_evidence_review, history_details, transaction_windows, export_report
from .test_evidence_v2 import wire
from .test_evidence_v2_receiver import result_wire
from .transaction_protocol import TransactionEventPacket


def save_hr(root, **overrides):
    fields = dict(transaction=decode_window_packet(wire()).transaction, window=0, token=1,
                  code=0, frames=1, gap_count=0, lower_ms=100, upper_ms=300,
                  flags=FLAG_OK | FLAG_COVERAGE_OK)
    fields.update(overrides)
    return HistoryResultReceiver(root).ingest(encode_history_result(**fields))


def save_pixels(root, complete=True):
    r = EvidenceV2Receiver(root)
    r.ingest(wire() if complete else wire(flags=0, payload=b'\x12\x34'))
    r.ingest(result_wire())
    r.flush(force=True)


class HistoryReviewTests(unittest.TestCase):
    def test_checkpoint_without_EG_result_remains_waiting_even_with_HR(self):
        with tempfile.TemporaryDirectory() as d:
            receiver = EvidenceV2Receiver(d)
            receiver.ingest(wire());receiver.flush(force=True)
            save_hr(d)
            windows, errors = load_evidence_review(d)
            self.assertFalse(errors)
            self.assertFalse(windows[0]['complete'])
            self.assertIsNone(windows[0]['expected'])
            self.assertEqual(windows[0]['history_verdict'], 'partial')

    def test_late_HR_upgrade_and_gap_not_washed_out_by_complete_pixels(self):
        with tempfile.TemporaryDirectory() as d:
            save_pixels(d)
            windows, errors = load_evidence_review(d)
            self.assertFalse(errors)
            self.assertEqual(windows[0]['history_verdict'], 'awaiting_result')
            save_hr(d, gap_count=2, flags=FLAG_OK | FLAG_GAP_UNKNOWN,
                    gap_first_meta=(1).to_bytes(4, 'big')+(110).to_bytes(8, 'big'),
                    gap_last_meta=(2).to_bytes(4, 'big')+(210).to_bytes(8, 'big'),
                    gap_first_reason=0x83, gap_last_reason=0x84)
            windows, errors = load_evidence_review(d)
            self.assertFalse(errors)
            self.assertTrue(windows[0]['complete'])
            self.assertEqual(windows[0]['history_verdict'], 'degraded')
            self.assertIn('gap=2 unknown=1', history_details(windows[0]))
            self.assertIn('110/210ms', history_details(windows[0]))
            self.assertIn('0x83/0x84', history_details(windows[0]))

    def test_partial_pixels_stay_partial_despite_clean_HR(self):
        with tempfile.TemporaryDirectory() as d:
            save_pixels(d, False);save_hr(d)
            windows, errors = load_evidence_review(d)
            self.assertFalse(errors)
            self.assertEqual(windows[0]['history_verdict'], 'partial')
            self.assertIn('索引=0', history_details(windows[0]))

    def test_result_only_exact_ET_and_report_without_preview(self):
        with tempfile.TemporaryDirectory() as d:
            save_hr(d)
            windows, errors = load_evidence_review(d)
            p = TransactionEventPacket(decode_window_packet(wire()).transaction)
            matches, text = transaction_windows(p, windows)
            self.assertEqual(matches, windows)
            self.assertIn('仅HR', text)
            self.assertEqual(windows[0]['frames'], [])
            model = MonitorModel();model.apply(p)
            report = Path(d)/'report.md'
            export_report(report, model.snapshot(), windows, errors)
            text = report.read_text(encoding='utf-8')
            self.assertIn('仅HR/等待像素', text)
            self.assertIn('gap=0 unknown=0', text)

    def test_corrupt_HR_never_complete(self):
        with tempfile.TemporaryDirectory() as d:
            save_pixels(d);manifest = save_hr(d)
            raw = manifest.parent/'raw.hr'
            data = raw.read_bytes();raw.write_bytes(data[:-1]+bytes([data[-1]^1]))
            windows, errors = load_evidence_review(d)
            self.assertEqual(len(errors), 1)
            self.assertEqual(windows[0]['history_verdict'], 'invalid')
            self.assertIn('读取异常', history_details(windows[0]))

    def test_bad_latest_EG_does_not_hide_failure_behind_clean_HR(self):
        with tempfile.TemporaryDirectory() as d:
            save_pixels(d);save_hr(d)
            manifest = next(Path(d).glob('egv2_*/revision_*/manifest.json'))
            (manifest.parent/'frame_000.ppm').write_bytes(b'bad preview')
            windows, errors = load_evidence_review(d)
            self.assertTrue(errors)
            self.assertEqual(windows[0]['history_verdict'], 'invalid')
            self.assertEqual(windows[0]['frames'], [])

    def test_failed_result_only_and_corrupt_result_only_remain_visible(self):
        with tempfile.TemporaryDirectory() as d:
            manifest = save_hr(d, code=4, flags=0)
            windows, errors = load_evidence_review(d)
            self.assertFalse(errors)
            self.assertEqual(windows[0]['history_verdict'], 'failed')
            (manifest.parent/'raw.hr').write_bytes(b'broken')
            windows, errors = load_evidence_review(d)
            self.assertTrue(errors)
            self.assertEqual(len(windows), 1)
            self.assertEqual(windows[0]['history_verdict'], 'invalid')

    def test_browser_late_HR_and_real_Tk_preview_report(self):
        with tempfile.TemporaryDirectory() as d:
            root = tk.Tk();root.withdraw()
            try:
                model = MonitorModel()
                p = TransactionEventPacket(decode_window_packet(wire()).transaction)
                model.apply(p)
                browser = EvidenceBrowser(root, model);browser.root = Path(d)
                save_pixels(d);browser.find_event(p)
                from .test_replay_tasks import pump
                pump(root, lambda: not browser.scan_task.active and browser._scan_poll is None)
                self.assertIsNotNone(browser.image)
                self.assertIn('等待HR', browser.history_info.get())
                save_hr(d);browser.refresh()
                pump(root, lambda: not browser.scan_task.active and browser._scan_poll is None)
                self.assertIn('联合完整', browser.history_info.get())
                self.assertIn('code=0', browser.tree.item('0', 'values')[-1])
                report = Path(d)/'report.md'
                export_report(report, model.snapshot(), browser.windows, browser.errors)
                self.assertIn('联合完整 (complete)', report.read_text(encoding='utf-8'))
                package = Path(d)/'case.zip'
                with patch('app.replay.filedialog.asksaveasfilename', return_value=str(package)):
                    browser.package()
                deadline = time.monotonic() + 10
                while browser.file_task.active and time.monotonic() < deadline:
                    root.update();time.sleep(.01)
                self.assertFalse(browser.file_task.active)
                self.assertTrue(package.is_file())
                self.assertIn('已保存并校验', browser.info.get())
                raw = next((Path(d)/'history_results').rglob('raw.hr'))
                raw.write_bytes(b'changed after refresh')
                browser.show()
                self.assertIn('证据校验失败', browser.history_info.get())
                browser.pause()
            finally:
                root.update_idletasks()
                root.destroy()
                del browser
                gc.collect()  # release Tk variables on the owning main thread


if __name__ == '__main__':
    unittest.main()
