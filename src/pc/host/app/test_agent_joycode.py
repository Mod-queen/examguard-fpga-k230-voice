"""Explicit live-selection bridge on synthetic sessions; no JoyCode/cloud/boards."""
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import tkinter as tk
from unittest.mock import patch

from .agent_joycode import SelectedSource, SourcePublisher, SourceSelectionError, joycode_mcp_config
from .agent_mcp import ReviewMCP
from .monitor import MonitorModel
from .test_agent import AgentFixture


class JoyCodeSourceTests(AgentFixture):
    def setUp(self):
        super().setUp()
        self.stamp = datetime.now(timezone.utc)
        self.path = self.root / 'private' / 'source.json'
        self.publisher = SourcePublisher(self.path, now=lambda: self.stamp)
        self.provider = SelectedSource(self.path, now=lambda: self.stamp)

    def tearDown(self):
        self.publisher.close()
        super().tearDown()

    def test_follows_exact_selection_and_never_claims_live_online(self):
        self.publisher.publish(self.source())
        source = self.provider.resolve('get_system_health')
        self.assertEqual(source.session_path, self.source().session_path)
        self.assertIsNone(source.snapshot)
        self.assertEqual(self.provider.context['selection_mode'], 'current')
        self.assertIn('非实时', source.label)

    def test_heartbeat_expires_and_missing_registration_never_falls_back(self):
        with self.assertRaises(SourceSelectionError):
            self.provider.resolve('get_system_health')
        self.publisher.publish(self.source())
        self.provider.resolve('get_system_health')
        self.stamp += timedelta(seconds=16)
        with self.assertRaises(SourceSelectionError):
            self.provider.resolve('get_system_health')
        self.publisher.publish(self.source())
        self.provider.resolve('get_recent_events')
        self.publisher.close()
        with self.assertRaises(SourceSelectionError):
            self.provider.resolve('get_image_path')

    def test_scope_switch_requires_new_query_before_evidence(self):
        self.publisher.publish(self.source())
        self.provider.resolve('get_recent_events')
        self.publisher.publish(replace(self.source(), evidence_root=self.root / 'other'))
        for _ in range(2):
            with self.assertRaises(SourceSelectionError):
                self.provider.resolve('get_image_path')
        self.provider.resolve('get_recent_events')
        self.assertEqual(self.provider.resolve('get_image_path').evidence_root, self.root / 'other')
        second = MonitorModel(session_root=self.root / 'new_sessions')
        try:
            self.publisher.publish(replace(self.source(), session_path=Path(second.snapshot().session_path)))
            with self.assertRaises(SourceSelectionError):
                self.provider.resolve('check_evidence_status')
        finally:
            second.close()

    def test_old_owner_close_cannot_remove_new_registration(self):
        self.publisher.publish(self.source())
        newer = SourcePublisher(self.path, now=lambda: self.stamp)
        newer.publish(self.source())
        self.publisher.close()
        self.assertTrue(self.path.is_file())
        newer.close()
        self.assertFalse(self.path.exists())

    def test_mcp_source_missing_is_actionable_and_static_source_still_works(self):
        server = ReviewMCP(None, source_provider=self.provider)
        server.handle(dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-06-18')))
        request = dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='get_system_health', arguments={}))
        self.assertTrue(server.handle(request)['result']['isError'])
        self.publisher.publish(self.source())
        result = server.handle(request)['result']
        self.assertFalse(result['isError'])
        data = json.loads(result['content'][0]['text'])
        self.assertEqual(data['selection_id'], self.publisher.selection_id)
        self.assertFalse(data['live_session'])

    def test_generated_config_runs_real_mcp_subprocess_without_writing_session(self):
        self.publisher.publish(self.source())
        spec = joycode_mcp_config(self.path)['mcpServers']['examguard']
        before = hashlib.sha256(self.source().session_path.read_bytes()).hexdigest()
        requests = [dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-06-18')),
                    dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='get_recent_events', arguments=dict(time_range=30)))]
        result = subprocess.run([spec['command'], *spec['args']], input='\n'.join(json.dumps(r) for r in requests) + '\n',
            text=True, encoding='utf-8', capture_output=True, timeout=10,
            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(json.loads(result.stdout.splitlines()[-1])['result']['content'][0]['text'])
        self.assertEqual(data['events'][0]['event_ref'], self.event.transaction.hex().upper())
        self.assertEqual(before, hashlib.sha256(self.source().session_path.read_bytes()).hexdigest())


class JoyCodePanelTests(AgentFixture):
    def test_gui_config_source_switch_event_replay_and_close(self):
        from .agent_panel import AgentPanel
        from .joycode_panel import JoyCodePanel
        root = tk.Tk()
        root.withdraw()
        opened = []
        agent = AgentPanel(root, self.model, evidence_root=lambda: self.root / 'evidence',
                           open_evidence=lambda *_: None, settings_path=self.root / 'settings.json')
        path = self.root / 'private' / 'source.json'
        panel = JoyCodePanel(root, registry_path=path, agent_panel=agent,
                            open_evidence=lambda p, r: opened.append((p, r)), choose_evidence=lambda: None)
        try:
            provider = SelectedSource(path)
            self.assertEqual(provider.resolve('get_recent_events').session_path, self.source().session_path)
            panel.copy_config()
            spec = json.loads(root.clipboard_get())['mcpServers']['examguard']
            self.assertIn('--current-session-file', spec['args'])
            agent.archive_path = self.source().session_path
            panel.sync(force=True)
            provider.resolve('get_recent_events')
            self.assertEqual(provider.context['selection_mode'], 'archive')
            panel.use_current()
            provider.resolve('get_recent_events')
            self.assertEqual(provider.context['selection_mode'], 'current')
            with patch('app.joycode_panel.launch_joycode') as launch:
                panel.open_joycode()
                launch.assert_called_once()
            panel.event_ref.set(self.event.transaction.hex())
            panel.review()
            deadline = time.monotonic() + 5
            while not opened and time.monotonic() < deadline:
                root.update()
                time.sleep(.01)
            self.assertEqual(opened[0][0], self.event)
            panel.close()
            self.assertFalse(path.exists())
        finally:
            panel.close()
            agent.close()
            root.update_idletasks()
            root.destroy()
