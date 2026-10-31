"""Real Tk event loop and live SQLite stay usable during a gated archive copy."""
import gc
from pathlib import Path
import tempfile
import threading
import time
import tkinter as tk
import unittest
from unittest.mock import patch

from .evidence_package import _copy_file, verify_evidence_package
from .monitor import MonitorModel
from .protocol import EventPacket
from .replay import EvidenceBrowser
from .event_store import load_session
from .test_history_review import save_pixels, save_hr


def pump(root, condition, seconds=10):
    deadline = time.monotonic() + seconds
    while not condition() and time.monotonic() < deadline:
        root.update()
        time.sleep(.005)
    if not condition():
        raise AssertionError('Timed out waiting for background task')


class ReplayTaskTests(unittest.TestCase):
    def test_scan_is_background_coalesced_and_old_directory_never_published(self):
        with tempfile.TemporaryDirectory() as directory:
            root=tk.Tk();root.withdraw();model=MonitorModel()
            browser=EvidenceBrowser(root,model,root=Path(directory)/'empty')
            pump(root,lambda:not browser.scan_task.active and browser._scan_poll is None)
            first=Path(directory)/'first';second=Path(directory)/'second'
            save_pixels(first);save_hr(first);save_pixels(second,False);save_hr(second)
            entered,release=threading.Event(),threading.Event();owner=threading.get_ident();threads=[]
            from .review import load_evidence_review
            def scan(path, **kwargs):
                threads.append(threading.get_ident())
                if path==first:
                    entered.set()
                    if not release.wait(10):raise TimeoutError('scan gate')
                return load_evidence_review(path, **kwargs)
            try:
                with patch('app.replay.load_evidence_review',side_effect=scan):
                    browser.root=first;browser.refresh();pump(root,entered.is_set)
                    beats=[];root.after(0,lambda:beats.append(1));pump(root,lambda:bool(beats))
                    browser.root=second;browser.refresh();browser.refresh();release.set()
                    pump(root,lambda:not browser.scan_task.active and browser._scan_poll is None)
                self.assertTrue(all(t!=owner for t in threads));self.assertEqual(len(threads),2)
                self.assertIn(str(second),browser.info.get());self.assertEqual(browser.windows[0]['history_verdict'],'partial')
            finally:
                release.set();pump(root,lambda:not browser.scan_task.active and browser._scan_poll is None)
                root.destroy();del browser;gc.collect()

    def test_report_reads_independent_connection_without_live_model_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = tk.Tk();root.withdraw()
            model = MonitorModel(session_root=Path(directory)/'sessions')
            browser = EvidenceBrowser(root, model)
            browser.root = Path(directory)
            report = Path(directory)/'report.md'
            entered, release = threading.Event(), threading.Event()

            def read_session(path):
                entered.set()
                if not release.wait(10):
                    raise TimeoutError('test read gate')
                return load_session(path)

            try:
                with patch('app.replay.load_session', side_effect=read_session), patch.object(
                        model, 'session_archive', side_effect=AssertionError('UI must not read live store')), patch(
                        'app.replay.filedialog.asksaveasfilename', return_value=str(report)):
                    browser.report()
                    pump(root, entered.is_set)
                    model.apply(EventPacket(1, 100, 3, 0, 3, 0x50))
                    self.assertEqual(model.snapshot().persisted_events, 1)
                    release.set()
                    pump(root, lambda: not browser.file_task.active)
                self.assertIn('已落盘：1', report.read_text(encoding='utf-8'))
                self.assertIn('报告已保存', browser.task_info.get())
            finally:
                release.set()
                pump(root, lambda: not browser.file_task.active)
                model.close();root.destroy();del browser;gc.collect()

    def test_export_does_not_block_Tk_live_receipts_or_duplicate_tasks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = tk.Tk();root.withdraw()
            model = MonitorModel(session_root=Path(directory)/'sessions')
            browser = EvidenceBrowser(root, model)
            evidence = Path(directory)/'images';save_pixels(evidence, False);save_hr(evidence)
            browser.root = evidence
            package = Path(directory)/'case.zip'
            entered, release = threading.Event(), threading.Event()
            owner = threading.get_ident()
            threads = []

            def slow_copy(source, destination):
                threads.append(threading.get_ident())
                entered.set()
                if not release.wait(10):
                    raise TimeoutError('test copy gate')
                _copy_file(source, destination)

            try:
                with patch('app.evidence_package._copy_file', side_effect=slow_copy), patch(
                        'app.replay.filedialog.asksaveasfilename', return_value=str(package)) as dialog:
                    browser.package()
                    pump(root, entered.is_set)
                    beats = []
                    root.after(0, lambda: beats.append(True))
                    pump(root, lambda: bool(beats))
                    model.apply(EventPacket(1, 100, 3, 0, 3, 0x50))
                    self.assertEqual(model.snapshot().persisted_events, 1)
                    browser.package();browser.report();browser.capacity()
                    self.assertEqual(dialog.call_count, 1)
                    self.assertTrue(browser.file_task.active)
                    self.assertTrue(all(b.instate(['disabled']) for b in browser._file_buttons))
                    # Changing the displayed directory never retargets an active job.
                    browser.root = Path(directory)/'different'
                    release.set()
                    pump(root, lambda: not browser.file_task.active)
                self.assertTrue(all(t != owner for t in threads))
                self.assertEqual(verify_evidence_package(package)['evidence']['counts'], {'partial': 1})
                self.assertIn(str(evidence), browser.task_info.get())
                self.assertTrue(all(not b.instate(['disabled']) for b in browser._file_buttons))
                model.apply(EventPacket(2, 200, 3, 0, 2, 0x60))
                self.assertEqual(model.snapshot().persisted_events, 2)
            finally:
                release.set()
                pump(root, lambda: not browser.file_task.active)
                model.close();root.destroy()
                del browser;gc.collect()

    def test_corrupt_export_failure_visible_then_capacity_can_run(self):
        with tempfile.TemporaryDirectory() as directory:
            root = tk.Tk();root.withdraw()
            browser = EvidenceBrowser(root, MonitorModel())
            evidence = Path(directory)/'images';save_pixels(evidence);save_hr(evidence)
            browser.root = evidence
            packets = next(evidence.glob('egv2_*/revision_*/packets.bin'))
            packets.write_bytes(b'broken')
            package = Path(directory)/'bad.zip'
            try:
                with patch('app.replay.messagebox.showerror') as error, patch(
                        'app.replay.filedialog.asksaveasfilename', return_value=str(package)):
                    browser.package()
                    pump(root, lambda: not browser.file_task.active)
                    error.assert_called_once()
                self.assertIn('失败', browser.task_info.get())
                self.assertFalse(package.exists())
                browser.capacity()
                pump(root, lambda: not browser.file_task.active)
                self.assertIn('不自动删除', browser.task_info.get())
                self.assertIn('磁盘余量', browser.task_info.get())
                self.assertEqual(packets.read_bytes(), b'broken')
            finally:
                root.destroy();del browser;gc.collect()

    def test_destroyed_widget_has_no_worker_Tk_callback(self):
        root = tk.Tk();root.withdraw()
        browser = EvidenceBrowser(root, MonitorModel())
        task = browser.file_task
        entered, release = threading.Event(), threading.Event()

        def slow_work():
            entered.set()
            release.wait(10)
            return {'done': True}

        try:
            browser._start_file_task('容量', None, slow_work)
            pump(root, entered.is_set)
            browser.destroy()
            self.assertIsNone(browser._task_poll)
            del browser;gc.collect()
            release.set()
            result = []
            def completed():
                outcome = task.poll()
                if outcome is not None:
                    result.append(outcome)
                return bool(result)
            pump(root, completed)
            self.assertEqual(result[0], (True, {'done': True}))
        finally:
            release.set();root.destroy();gc.collect()


if __name__ == '__main__':
    unittest.main()
