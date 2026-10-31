import gc
from pathlib import Path
import tempfile
import tkinter as tk
import unittest
from unittest.mock import patch

from .evidence_health import EvidenceHealth
from .maintenance_panel import MaintenancePanel
from .monitor import MonitorModel
from .protocol import StatusPacket, decode_packet
from .test_maintenance_protocol import result_line


class MaintenancePanelTests(unittest.TestCase):
    def test_send_uses_existing_bridge_then_only_matching_receipt_completes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=tk.Tk();root.withdraw();model=MonitorModel()
            panel=MaintenancePanel(root,model,5006)
            panel.audit_path=Path(directory)/'maintenance.jsonl'
            words=[0]*32;words[:4]=[0x01000000,1,18,0]
            status=StatusPacket(1,1,0,0,5,0,remaining_s=2700,exam_duration_s=2700,
                                evidence_health=EvidenceHealth(tuple(words)))
            try:
                panel.send(0);self.assertIn('未发送',panel.status.get())
                model.apply(status)
                panel.next_id=10;panel.last_board=(1,18)
                with patch('app.maintenance_panel.socket.socket') as sock:
                    panel.send(0);panel.send(1)
                    sock.return_value.__enter__.return_value.sendto.assert_called_once()
                    command,address=sock.return_value.__enter__.return_value.sendto.call_args.args
                    self.assertEqual(address,('127.0.0.1',5006))
                    self.assertTrue(command.startswith(b'MC,'))
                model.apply(decode_packet(result_line(operation=0,token=9)))
                panel.poll();self.assertIsNotNone(panel.pending)
                model.apply(decode_packet(result_line(operation=0,token=10)))
                panel.poll();self.assertIsNone(panel.pending)
                self.assertIn('成功',panel.status.get())
                self.assertIn('response',panel.audit_path.read_text(encoding='utf-8'))
                # Real board rejects exam writes; GUI must avoid even sending.
                status.state_id=3;model.apply(status)
                with patch('app.maintenance_panel.socket.socket') as sock:
                    panel.send(2);sock.assert_not_called()
            finally:
                root.update_idletasks();root.destroy();del panel;gc.collect()

    def test_timeout_not_auto_retried_and_destroy_cancels_poll(self):
        root=tk.Tk();root.withdraw();model=MonitorModel();panel=MaintenancePanel(root,model,5006)
        try:
            panel.pending=(1,0,(1,18),0)
            with patch('app.maintenance_panel.socket.socket') as sock:
                panel.poll();sock.assert_not_called()
            self.assertIsNone(panel.pending);self.assertIn('结果未知',panel.status.get())
            panel.destroy();self.assertIsNone(panel._poll_job)
        finally:
            root.update_idletasks();root.destroy();del panel;gc.collect()
