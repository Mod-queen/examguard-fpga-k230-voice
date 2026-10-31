import gc
from dataclasses import replace
import json
from pathlib import Path
import struct
import tempfile
import tkinter as tk
import unittest
from unittest.mock import patch
import zlib

from .event_store import load_session
from .monitor import MonitorModel
from .protocol import decode_packet, ProtocolError
from .voice_protocol import decode_voice_command, encode_voice_command
from .voice_panel import VoicePanel
from .voice_roster import load_voice_roster
from .review import export_report
from .evidence_package import export_evidence_package, verify_evidence_package


def status_line(seq=1, ticket=1, flags=19, boot=42, token=0, result=0, tag=5):
    raw = bytearray(96)
    raw[:8] = b'VI\1\0\0\x60' + bytes([flags, 2])
    struct.pack_into('!IIIIIQIIQ', raw, 8, 1, boot, 0, seq, 9, tag, ticket, 1, 1234)
    raw[52:56] = bytes([1, 5, 4, 0])
    struct.pack_into('!I', raw, 56, token)
    raw[60:62] = bytes([2 if token else 0, result])
    raw[-4:] = zlib.crc32(raw[:-4]).to_bytes(4, 'big')
    return b'VI,' + raw.hex().encode() + b'\n'


class VoiceInteractionTests(unittest.TestCase):
    def test_minimized_reboot_configures_and_uploads_without_claiming_pc_presentation(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'roster.json'
            path.write_text(json.dumps({'schema':1,'candidates':[{'face_id':1,'name':'彭于晏',
                'exam_number':'6024202258','info_tag':'0000000000000009'}]}),encoding='utf-8')
            root=tk.Tk();root.withdraw();model=MonitorModel()
            panel=VoicePanel(root,model,'127.0.0.1',5006,roster_path=path)
            try:
                with patch('app.voice_panel.socket.socket') as sock:
                    send=sock.return_value.__enter__.return_value.sendto
                    for boot in (53,54,55):
                        p=replace(decode_packet(status_line(flags=1,ticket=0,tag=1,boot=boot)),
                                  round_id=2,info_state=0,exam_state=0)
                        model.apply(p);panel.poll();root.update_idletasks()
                        self.assertEqual(decode_voice_command(send.call_args.args[0])[0],3)
                        bound=replace(p,sequence=2,round_id=3,info_tag=9)
                        model.apply(bound);panel.poll();root.update_idletasks()
                        self.assertEqual(decode_voice_command(send.call_args.args[0])[0],5)
                        # Upload acceptance is NOT HDMI frame application. A
                        # hidden PC must not invent a visible presentation.
                        accepted=replace(bound,sequence=3,command_token=panel.display_sent[bound.binding],
                                         command_op=5,command_result=1)
                        count=send.call_count
                        model.apply(accepted);panel.poll();root.update_idletasks()
                        self.assertEqual(send.call_count,count)
                        applied=replace(accepted,sequence=4,flags=accepted.flags|64)
                        model.apply(applied);panel.poll();root.update_idletasks()
                        self.assertEqual(decode_voice_command(send.call_args.args[0])[0],1)
                        self.assertFalse(root.winfo_viewable())
            finally:
                model.close();root.destroy();del panel;gc.collect()

    def test_initial_real_board_state_auto_configures_once_then_presents(self):
        # Real boot50 initial state: tag1, info0, prep0, face1. No explicit
        # Apply click should be required for an already configured local roster.
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'roster.json'
            path.write_text(json.dumps({'schema':1,'candidates':[{'face_id':1,'name':'彭于晏',
                'exam_number':'6024202258','info_tag':'0000000000000009'}]}),encoding='utf-8')
            root=tk.Tk();model=MonitorModel()
            panel=VoicePanel(root,model,'127.0.0.1',5006,roster_path=path);panel.pack();root.update()
            try:
                p=replace(decode_packet(status_line(flags=1,ticket=0,tag=1)), info_state=0,exam_state=0)
                with patch('app.voice_panel.socket.socket') as sock:
                    model.apply(p);panel.poll();root.update_idletasks()
                    send=sock.return_value.__enter__.return_value.sendto
                    self.assertEqual(decode_voice_command(send.call_args.args[0])[0],3)
                    panel.poll();root.update_idletasks();self.assertEqual(send.call_count,1)
                    bound=replace(p,sequence=2,round_id=p.round_id+1,info_tag=9)
                    model.apply(bound);panel.poll();root.update_idletasks()
                    self.assertEqual(decode_voice_command(send.call_args.args[0])[0],5)
                    accepted=replace(bound,sequence=3,command_token=panel.display_sent[bound.binding],command_op=5,command_result=1)
                    model.apply(accepted);panel.poll();root.update_idletasks()
                    self.assertEqual(decode_voice_command(send.call_args.args[0])[0],1)
                    self.assertIn('6024202258',panel.candidate_text.get())
            finally:
                model.close();root.destroy();del panel;gc.collect()
    def test_new_configuration_and_heartbeat_protocol(self):
        p = decode_packet(status_line(flags=0, ticket=0))
        config = encode_voice_command(3, 20, replace(p, info_tag=99))
        self.assertEqual(decode_voice_command(config), (3, 20, 1, 42, 9, 99, 0, 1))
        self.assertEqual(decode_voice_command(encode_voice_command(4, 21, p)), (4, 21, 1, 42, 9, 5, 0, 1))
        from .candidate_display import encode_display
        line=encode_voice_command(5,22,p,encode_display('彭于晏','6024202258'))
        raw=bytes.fromhex(line.decode().strip().split(',')[1])
        self.assertEqual(raw[40:56],b'\x85\x86\x87   6024202258')
        self.assertEqual(decode_voice_command(line)[0],5)
        applied=bytearray(p.raw);applied[6]|=64
        applied[-4:]=zlib.crc32(applied[:-4]).to_bytes(4,'big')
        self.assertEqual(decode_packet(b'VI,'+applied.hex().encode()).flags & 64,64)

    def test_heartbeat_bootstraps_without_presentation_and_configuration_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'roster.json'
            path.write_text(json.dumps({'schema': 1, 'candidates': [
                {'face_id': 1, 'name': '测试考生', 'exam_number': 'TEST02', 'info_tag': '0000000000000009'}]}), encoding='utf-8')
            root = tk.Tk();root.withdraw();model = MonitorModel()
            panel = VoicePanel(root, model, '127.0.0.1', 5006, roster_path=path)
            try:
                model.apply(decode_packet(status_line(flags=0, ticket=0)))
                panel.last_heartbeat = 0
                with patch('app.voice_panel.socket.socket') as sock:
                    panel.poll()
                    send = sock.return_value.__enter__.return_value.sendto
                    send.assert_called_once()
                    self.assertEqual(decode_voice_command(send.call_args.args[0])[0], 4)
                self.assertFalse(panel.presentation_sent)
                with patch('app.voice_panel.socket.socket') as sock:
                    panel.configure_information()
                    send = sock.return_value.__enter__.return_value.sendto
                    send.assert_called_once()
                    command = decode_voice_command(send.call_args.args[0])
                    self.assertEqual((command[0], command[5]), (3, 9))
                self.assertFalse(panel.presentation_sent)
            finally:
                model.close();root.destroy();del panel;gc.collect()

    def test_dashboard_routes_voice_to_nonmodal_tab_without_duplicate_popup(self):
        from .test_dashboard_session import DashboardSessionTests
        with tempfile.TemporaryDirectory() as directory:
            app = DashboardSessionTests().create(directory)
            try:
                app._packet_queue.put(decode_packet(status_line()))
                app._poll_packets()
                self.assertEqual(app._tabs.select(), str(app._voice_panel))
                app._tabs.select(0)
                app._packet_queue.put(decode_packet(status_line(seq=2)))
                app._poll_packets()
                self.assertNotEqual(app._tabs.select(), str(app._voice_panel))
                app._packet_queue.put(decode_packet(status_line(seq=3, ticket=2)))
                app._poll_packets()
                self.assertEqual(app._tabs.select(), str(app._voice_panel))
            finally:
                app._close();del app;gc.collect()

    def test_roster_visible_presentation_only_matching_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'roster.json'
            path.write_text(json.dumps({'schema': 1, 'candidates': [
                {'face_id': 1, 'name': '彭于晏', 'exam_number': '6024202258', 'info_tag': '0000000000000005'}]}), encoding='utf-8')
            self.assertEqual(load_voice_roster(path)[1], ('彭于晏', '6024202258', 5))
            root = tk.Tk();model = MonitorModel()
            panel = VoicePanel(root, model, '127.0.0.1', 5006, roster_path=path)
            panel.pack();root.update()
            try:
                model.apply(decode_packet(status_line(flags=3)))
                with patch('app.voice_panel.socket.socket') as sock:
                    panel.poll();root.update_idletasks()
                    send = sock.return_value.__enter__.return_value.sendto
                    send.assert_called_once()
                    self.assertEqual(decode_voice_command(send.call_args.args[0])[0], 5)
                    current=panel.current
                    model.apply(replace(current,sequence=current.sequence+1,
                        command_token=panel.display_sent[current.binding],command_op=5,command_result=1))
                    panel.poll();root.update_idletasks()
                    self.assertEqual(decode_voice_command(send.call_args.args[0])[0],1)
                    panel.present_information();self.assertEqual(send.call_count,2)
                self.assertIn('6024202258', panel.candidate_text.get())
                panel.presentation_sent.clear();root.withdraw()
                with patch('app.voice_panel.socket.socket') as sock:
                    panel.present_information();sock.assert_not_called()
                path.write_text('{"schema":1,"candidates":[]}', encoding='utf-8')
                panel.reload_roster();self.assertEqual(panel.roster, {})
            finally:
                model.close();root.update_idletasks();root.destroy();del panel;gc.collect()

    def test_crc_reserved_and_command_binding(self):
        p = decode_packet(status_line())
        self.assertEqual(p.binding, (1, 42, 9, 5))
        command = encode_voice_command(2, 7, p)
        self.assertEqual(decode_voice_command(command), (2, 7, 1, 42, 9, 5, 1, 1))
        for offset in (6, 20, 60, 95):
            raw = bytearray(p.raw);raw[offset] ^= 128
            with self.assertRaises(ProtocolError):
                decode_packet(b'VI,' + raw.hex().encode())
        raw = bytearray(p.raw);raw[70] = 1
        raw[-4:] = zlib.crc32(raw[:-4]).to_bytes(4, 'big')
        with self.assertRaises(ProtocolError):
            decode_packet(b'VI,' + raw.hex().encode())
        with self.assertRaises(ProtocolError):
            encode_voice_command(2, 8, decode_packet(status_line(flags=3)))

    def test_full_journal_reopen_and_independent_failure_counter(self):
        with tempfile.TemporaryDirectory() as directory:
            model = MonitorModel(session_root=directory, max_events=1)
            try:
                for seq in range(1, 4):
                    model.apply(decode_packet(status_line(seq=seq)))
                path = Path(model.snapshot().session_path)
                model.clear_events()
                self.assertEqual(len(model.snapshot().voice), 1)
                self.assertEqual(len(model.session_archive().voice), 3)
                with patch.object(model._store, 'append_voice', side_effect=OSError('disk full')):
                    model.apply(decode_packet(status_line(seq=4)))
                self.assertEqual(model.snapshot().voice_failures, 1)
            finally:
                model.close()
            archive = load_session(path)
            self.assertEqual((len(archive.voice), archive.voice_packets, archive.voice_failures), (3, 4, 1))
            self.assertEqual(archive.persistence_failures, 0)
            self.assertEqual(archive.voice[-1].packet.sequence, 3)

    def test_voice_report_and_live_database_package_preserve_raw(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory);images = root/'images';images.mkdir()
            model = MonitorModel(session_root=root/'sessions')
            try:
                packet = decode_packet(status_line())
                model.apply(packet);model.apply(packet)
                report = root/'report.md'
                export_report(report, model.snapshot(), [], [], session=model.session_archive())
                self.assertIn('保存VI状态：2', report.read_text(encoding='utf-8'))
                package = root/'case.zip'
                export_evidence_package(images, package, session_path=model.snapshot().session_path)
                self.assertTrue(verify_evidence_package(package)['session'])
                self.assertEqual(model.session_archive().voice[0].packet.raw, packet.raw)
            finally:
                model.close()

    def test_tk_exact_handling_stale_duplicate_and_timeout(self):
        root = tk.Tk();root.withdraw()
        model = MonitorModel()
        panel = VoicePanel(root, model, '127.0.0.1', 5006)
        try:
            panel.poll()
            self.assertIn('disabled', panel.button.state())
            model.apply(decode_packet(status_line()))
            panel.poll()
            panel.next_token = 10
            with patch('app.voice_panel.socket.socket') as sock:
                panel.handle_help();panel.handle_help()
                send = sock.return_value.__enter__.return_value.sendto
                send.assert_called_once()
                self.assertEqual(decode_voice_command(send.call_args.args[0])[1], 10)
            self.assertIsNotNone(panel.pending)
            self.assertIn('待老师处理', panel.help_text.get())
            model.apply(decode_packet(status_line(seq=2, token=9, result=1)))
            panel.poll();self.assertIsNotNone(panel.pending)
            model.apply(decode_packet(status_line(seq=3, flags=19, token=10, result=1)))
            panel.poll();self.assertIsNotNone(panel.pending)
            model.apply(decode_packet(status_line(seq=4, flags=3, token=10, result=1)))
            panel.poll();self.assertIsNone(panel.pending)
            self.assertIn('处理完成', panel.result.get())
            received_at = panel.received_at
            model.apply(decode_packet(status_line(seq=2)))
            panel.poll();self.assertEqual(panel.received_at, received_at)
            model.apply(decode_packet(status_line(seq=99, boot=41)))
            panel.poll();self.assertEqual(panel.current.boot, 42)
            model.apply(decode_packet(status_line(seq=5, ticket=2)))
            panel.poll()
            with patch('app.voice_panel.socket.socket'):
                panel.handle_help()
            panel.pending = (*panel.pending[:3], 0)
            panel.poll();self.assertIsNone(panel.pending)
            self.assertIn('结果未知', panel.result.get())
            panel.received_at = 0
            with patch('app.voice_panel.socket.socket') as sock:
                panel.handle_help();sock.assert_not_called()
            panel.destroy();self.assertIsNone(panel._poll_job)
        finally:
            model.close();root.update_idletasks();root.destroy();del panel;gc.collect()


if __name__ == '__main__':
    unittest.main()
