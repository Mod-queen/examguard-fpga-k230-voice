"""Tk session integration with deterministic decoded input, no board/socket."""
from pathlib import Path
import sqlite3
import tempfile
import tkinter as tk
import unittest
import gc
from unittest.mock import patch

from .dashboard import Dashboard
from .event_store import EventStore, load_session
from .protocol import EventPacket, decode_packet


class DashboardSessionTests(unittest.TestCase):
    def tearDown(self):
        gc.collect()  # Release destroyed Tk interpreters on their owning thread.

    def test_new_click_cancels_background_full_scan_and_discards_old_result(self):
        import threading
        from .evidence_v2_receiver import EvidenceV2Receiver
        from .evidence_v2 import decode_window_packet
        from .transaction_protocol import TransactionEventPacket
        from .test_evidence_v2 import wire
        from .test_evidence_v2_receiver import result_wire
        from .review import load_evidence_review
        from .test_replay_tasks import pump
        with tempfile.TemporaryDirectory() as directory:
            app=self.create(directory)
            release=threading.Event();entered=threading.Event();cancels=[]
            try:
                browser=app._browser
                pump(app,lambda:not browser.scan_task.active and browser._scan_poll is None)
                root=Path(directory)/'images';receiver=EvidenceV2Receiver(root)
                for uid in (1,2):
                    receiver.ingest(wire(uid=uid));receiver.ingest(result_wire(uid=uid))
                def scan(path,**kwargs):
                    if kwargs.get('event') is None:
                        cancels.append(kwargs['cancelled']);entered.set()
                        if not release.wait(5):raise TimeoutError('scan not released')
                    return load_evidence_review(path,**kwargs)
                first=TransactionEventPacket(decode_window_packet(wire(uid=1)).transaction)
                last=TransactionEventPacket(decode_window_packet(wire(uid=2)).transaction)
                with patch('app.replay.load_evidence_review',side_effect=scan):
                    browser.root=root;browser.show_all();pump(app,entered.is_set)
                    browser.find_event(first);browser.find_event(last)
                    self.assertTrue(cancels[0].is_set())
                    release.set()
                    pump(app,lambda:not browser.scan_task.active and browser._scan_poll is None)
                self.assertEqual(browser.current['identity'],last.identity)
                self.assertEqual(len(browser.windows),1)
                self.assertIsNotNone(browser.image)
            finally:
                release.set();app._close()
    def test_click_verifies_only_target_archive_not_unrelated_windows(self):
        from .evidence_v2_receiver import EvidenceV2Receiver
        from .evidence_v2 import decode_window_packet
        from .transaction_protocol import TransactionEventPacket
        from .test_evidence_v2 import wire
        from .test_evidence_v2_receiver import result_wire
        from .evidence_v2_store import read_revision
        from .test_replay_tasks import pump
        with tempfile.TemporaryDirectory() as directory:
            app=self.create(directory)
            try:
                root=Path(directory)/'images'
                receiver=EvidenceV2Receiver(root)
                for uid in (7,8,9):
                    receiver.ingest(wire(uid=uid));receiver.ingest(result_wire(uid=uid))
                browser=app._browser
                pump(app,lambda:not browser.scan_task.active and browser._scan_poll is None)
                browser.root=root
                event=TransactionEventPacket(decode_window_packet(wire(uid=8)).transaction)
                # An unrelated corrupt archive must not delay/prevent the
                # selected transaction's strict raw/preview verification.
                unrelated=next(root.glob('egv2_*0007/revision_*/packets.bin'))
                unrelated.write_bytes(b'corrupt unrelated archive')
                with patch('app.review.read_revision',wraps=read_revision) as read:
                    browser.find_event(event)
                    pump(app,lambda:not browser.scan_task.active and browser._scan_poll is None)
                    self.assertIsNotNone(browser.image)
                    self.assertEqual(read.call_count,1)
                    self.assertIn('0008',str(read.call_args.args[0]))
                self.assertFalse(browser.errors)
            finally:
                app._close()

    def test_event_selection_survives_ei_refresh(self):
        from .protocol import EventIdentityPacket
        with tempfile.TemporaryDirectory() as directory:
            app=self.create(directory)
            try:
                app._packet_queue.put(EventPacket(1,100,3,0,2,0x50))
                app._poll_packets()
                row=app._event_tree.get_children()[0]
                app._event_tree.selection_set(row)
                app._packet_queue.put(EventIdentityPacket(1,50,1,9,9))
                app._poll_packets()
                self.assertEqual(len(app._event_tree.selection()),1)
                self.assertEqual(app._event_entries[app._event_tree.selection()[0]].identity.boot_id,50)
            finally:
                app._close()

    def test_legacy_alarm_offers_same_boot_new_evidence_without_uid_false_binding(self):
        from .evidence_v2_receiver import EvidenceV2Receiver
        from .test_evidence_v2 import wire
        from .test_evidence_v2_receiver import result_wire
        from .protocol import EventIdentityPacket
        from .test_replay_tasks import pump
        with tempfile.TemporaryDirectory() as directory:
            app=self.create(directory)
            try:
                app._browser.root=Path(directory)/'evidence'
                receiver=EvidenceV2Receiver(app._browser.root)
                receiver.ingest(wire());receiver.ingest(result_wire())
                from .evidence_v2 import decode_window_packet
                from .transaction_protocol import TransactionEventPacket
                et=TransactionEventPacket(decode_window_packet(wire()).transaction)
                image_packet=decode_window_packet(wire())
                alarm=EventPacket(image_packet.frame_id,image_packet.frame_time_ms,et.stage_id,0,et.risk_level,et.event_code)
                app._packet_queue.put(alarm)
                # Legacy UID deliberately NOT the ET UID.
                app._packet_queue.put(EventIdentityPacket(*et.identity[:3],999,1))
                app._poll_packets()
                row=app._event_tree.get_children()[0];app._event_tree.selection_set(row)
                app._open_event_evidence()
                pump(app,lambda:not app._browser.scan_task.active and app._browser._scan_poll is None)
                self.assertIsNotNone(app._browser.image)
                self.assertIn('候选',app._browser.match_info.get())
                self.assertNotIn('精确绑定',app._browser.match_info.get())
            finally:
                app._close()

    def test_legacy_candidates_refuse_cross_boot_and_keep_multiple_choices(self):
        from .review import legacy_transaction_candidates
        from .protocol import EventIdentityPacket
        from .transaction_protocol import TransactionEventPacket
        from .evidence_v2 import decode_window_packet
        from .test_evidence_v2 import wire
        event=TransactionEventPacket(decode_window_packet(wire(source_time=100)).transaction)
        window=dict(protocol='EGv2',transaction=event.transaction,identity=event.identity,
                    frames=[dict(timestamp_ms=100,frame_id=1)])
        alarm=EventPacket(1,100,event.stage_id,0,event.risk_level,event.event_code)
        identity=EventIdentityPacket(*event.identity[:3],99)
        self.assertEqual(legacy_transaction_candidates(alarm,identity,[window,dict(window)]),[window,window])
        identity.boot_id+=1
        self.assertFalse(legacy_transaction_candidates(alarm,identity,[window]))
    def test_RA_display_is_separate_from_event_time_and_old_boot_flagged(self):
        from .test_rtc_anchor import line
        from .evidence_health import EvidenceHealth
        from .protocol import StatusPacket
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                app._packet_queue.put(decode_packet(line()))
                app._poll_packets()
                self.assertIn('无时区', app._rtc_anchor_text.get())
                self.assertIn('不替换事件源时间', app._rtc_anchor_text.get())
                self.assertEqual(app._model.snapshot().persisted_anchors, 1)
                words = [0]*32;words[:4]=[0x01000000,1,8,0]
                app._packet_queue.put(StatusPacket(1,1,0,0,5,0,remaining_s=2700,exam_duration_s=2700,
                                                   evidence_health=EvidenceHealth(tuple(words))))
                app._poll_packets()
                self.assertIn('旧boot锚', app._rtc_anchor_text.get())
            finally:
                app._close()

    def test_transaction_received_persisted_displayed_separate_from_legacy(self):
        from .test_transaction_protocol import transaction
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                app._packet_queue.put(transaction())
                app._poll_packets()
                snapshot = app._model.snapshot()
                self.assertEqual(snapshot.persisted_transactions, 1)
                self.assertFalse(snapshot.events)
                item = app._event_tree.get_children()[0]
                self.assertIn('ET uid=', app._event_tree.item(item, 'values')[-1])
                app._event_tree.selection_set(item)
                app._open_event_evidence()
                self.assertIn('已接受事件', app._message.get())
                self.assertIn('事务ET 1', app._packet_count.get())
            finally:
                app._close()

    def test_et_before_image_refresh_exact_preview_report_and_context_conflict(self):
        from .evidence_v2_receiver import EvidenceV2Receiver
        from .evidence_v2 import decode_window_packet
        from .transaction_protocol import TransactionEventPacket
        from .test_evidence_v2 import wire
        from .test_evidence_v2_receiver import result_wire
        from .review import export_report
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                browser = app._browser
                browser.root = Path(directory)/'evidence'
                event = TransactionEventPacket(decode_window_packet(wire()).transaction)
                app._packet_queue.put(event)
                app._poll_packets()
                item = app._event_tree.get_children()[0]
                app._event_tree.selection_set(item)
                app._open_event_evidence()
                from .test_replay_tasks import pump
                pump(app, lambda: not browser.scan_task.active and browser._scan_poll is None)
                self.assertIn('尚无', browser.match_info.get())
                receiver = EvidenceV2Receiver(browser.root)
                receiver.ingest(wire())
                receiver.ingest(result_wire())
                browser.refresh()
                pump(app, lambda: not browser.scan_task.active and browser._scan_poll is None)
                self.assertIn('精确关联', browser.match_info.get())
                self.assertTrue(browser.current['complete'])
                self.assertIsNotNone(browser.image)
                self.assertEqual(browser.image.width(), 4)
                report = Path(directory)/'egreport.md'
                export_report(report, app._model.snapshot(), browser.windows, browser.errors, session=app._model.session_archive())
                self.assertIn('精确关联：complete', report.read_text(encoding='utf-8'))
                # Image first / same identity but DIFFERENT source time: never fallback.
                mismatch = TransactionEventPacket(decode_window_packet(wire(source_time=2)).transaction)
                browser.find_event(mismatch)
                pump(app, lambda: not browser.scan_task.active and browser._scan_poll is None)
                self.assertIn('冲突', browser.match_info.get())
                self.assertIsNone(browser.current)
                browser.find_event(event)
                pump(app, lambda: not browser.scan_task.active and browser._scan_poll is None)
                self.assertIsNotNone(browser.image)
                (browser.current['path']/'frame_000.ppm').write_bytes(b'tampered after list refresh')
                browser.show()
                self.assertIn('图像读取失败', browser.frame_info.get())
            finally:
                app._close()

    def test_new_evidence_health_real_packet_model_and_stale_display(self):
        from .test_evidence_health import health, status
        from .protocol import encode_status
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                app._packet_queue.put(decode_packet(encode_status(status(health(0x70 | 2)))))
                app._poll_packets()
                self.assertIn('启动身份耗尽', app._evidence_health_text.get())
                self.assertIn('UDP发送/丢弃=443/0', app._evidence_health_text.get())
                app._evidence_health_view.received_at -= 4
                app._poll_packets()
                self.assertIn('状态停更', app._evidence_health_text.get())
                self.assertIn('接受/拒绝=11/2', app._evidence_health_text.get())
                app._packet_queue.put(decode_packet('ST,1,3,0,0,10,0,0,0,0,0,2600,2700'))
                app._poll_packets()
                self.assertIn('旧协议', app._evidence_health_text.get())
            finally:
                app._close()

    def test_countdown_replaces_legacy_channels_and_k230_tab_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                self.assertFalse(hasattr(app, '_k230_browser'))
                self.assertFalse(hasattr(app, '_motion_values'))
                self.assertEqual(app._remaining_time.get(), '45:00')
                for stage, remaining, text in ((2, 0, '45:00'), (3, 2700, '45:00'),
                                                (3, 2699, '44:59'), (4, 2699, '44:59'),
                                                (4, 0, '00:00'), (1, 0, '45:00')):
                    app._packet_queue.put(decode_packet(f'ST,1,{stage},0,0,10,0,0,0,0,0,{remaining},2700'))
                    app._poll_packets()
                    self.assertEqual(app._remaining_time.get(), text)
                tabs = [app._tabs.tab(tab, 'text') for tab in app._tabs.tabs()]
                self.assertNotIn('K230识别证据', tabs)
                self.assertIn('图像回放 / 报告', tabs)
            finally:
                app._close()

    def create(self, directory):
        root = tk.Tk()
        root.withdraw()
        root.update_idletasks()
        root.destroy()
        with patch("app.dashboard.receive_packets", return_value=iter(())):
            app = Dashboard(host="127.0.0.1", port=0,
                              config_path=Path(directory)/"regions.json",
                              session_root=Path(directory)/"sessions",
                              evidence_root=Path(directory)/'evidence')
            app.withdraw()
            app.update_idletasks()  # deliver ttk theme events before destroying a test interpreter
            app._receiver_thread.join(timeout=2)
            app._stop_event.set()
            return app

    def test_burst_history_clear_report_and_close_drains_decoded_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                for n in range(1, 251):
                    app._packet_queue.put(EventPacket(n, n, 3, 0, 3, 0x50))
                app._poll_packets()
                self.assertEqual(app._model.snapshot().persisted_events, 100)
                self.assertEqual(app._packet_queue.qsize(), 150)
                app._poll_packets()
                app._poll_packets()
                self.assertEqual(len(app._event_tree.get_children()), 200)
                self.assertIn("已落盘AL 250", app._session_status.get())
                app._clear_events()
                self.assertEqual(len(app._event_tree.get_children()), 0)
                report = Path(directory)/"report.md"
                with patch("app.replay.filedialog.asksaveasfilename", return_value=str(report)):
                    app._browser.report()
                import time
                deadline = time.monotonic() + 10
                while app._browser.file_task.active and time.monotonic() < deadline:
                    app.update();time.sleep(.01)
                self.assertFalse(app._browser.file_task.active)
                self.assertIn("已落盘：250", report.read_text(encoding="utf-8"))
                path = app._model.snapshot().session_path
                app._packet_queue.put(EventPacket(251, 251, 3, 0, 2, 0x60))
            finally:
                app._close()
            self.assertEqual(len(load_session(path).events), 251)
            self.assertIsNotNone(load_session(path).ended_at)

    def test_persistence_error_stays_visible_after_status_refresh(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.create(directory)
            try:
                with patch.object(EventStore, "append", side_effect=sqlite3.OperationalError("disk full")):
                    app._packet_queue.put(EventPacket(1, 2, 3, 0, 3, 0x50))
                    app._poll_packets()
                app._refresh_session_status()
                self.assertIn("disk full", app._session_status.get())
                self.assertEqual(len(app._event_tree.get_children()), 1)
            finally:
                app._close()


if __name__ == "__main__":
    unittest.main()
