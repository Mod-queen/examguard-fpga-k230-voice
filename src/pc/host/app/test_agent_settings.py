"""Exercise persisted model setup and real DPAPI with synthetic keys only."""
import json
import io
import os
from pathlib import Path
import tempfile
import time
import tkinter as tk
import unittest
import urllib.error
from unittest.mock import patch

from .agent_controller import ModelConfig, probe_model, request_completion
from .agent_settings import (OPENCODE_GO_BASE, clear_agent_settings,
                             load_agent_settings, save_agent_settings, ZHIPU_BASE, ZHIPU_VISION_MODEL)
from .agent_tools import ToolError
from .test_agent import AgentFixture


class AgentSettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'private' / 'settings.json'
        self.config = ModelConfig(OPENCODE_GO_BASE, 'glm-5.3-flash', 'synthetic-secret-测试-123')

    def tearDown(self):
        self.tmp.cleanup()

    def test_first_run_has_zhipu_presets_but_is_not_connected(self):
        settings = load_agent_settings(self.path, environ={})
        self.assertEqual(settings.mode, 'local')
        self.assertEqual(settings.config.endpoint, ZHIPU_BASE)
        self.assertEqual(settings.config.vision_model, ZHIPU_VISION_MODEL)
        self.assertEqual(settings.config.api_key, '')
        self.assertIn('填写智谱密钥', settings.message)
        self.assertFalse(self.path.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows DPAPI')
    def test_real_dpapi_roundtrip_restart_and_clear(self):
        save_agent_settings(self.config, path=self.path)
        stored = self.path.read_text(encoding='utf-8')
        self.assertNotIn(self.config.api_key, stored)
        self.assertNotIn('synthetic-secret', stored)
        settings = load_agent_settings(self.path, environ={})
        self.assertEqual(settings.config, self.config)
        self.assertEqual(settings.mode, 'llm')
        self.assertIn('待测试', settings.message)
        clear_agent_settings(self.path)
        self.assertEqual(load_agent_settings(self.path, environ={}).mode, 'local')

    def test_failed_encryption_never_writes_plaintext(self):
        with patch('app.agent_settings._crypt', side_effect=ToolError('failed')):
            with self.assertRaises(ToolError):
                save_agent_settings(self.config, path=self.path)
        self.assertFalse(self.path.exists())

    def test_corrupt_or_wrong_user_config_falls_back_explicitly(self):
        self.path.parent.mkdir()
        for body in ('{bad', json.dumps(dict(version=1, protection='plaintext')),
                     json.dumps(dict(version=1, protection='windows-dpapi-current-user',
                                     endpoint=None, model='m', key_protected='a', mode='llm'))):
            self.path.write_text(body, encoding='utf-8')
            settings = load_agent_settings(self.path, environ={})
            self.assertEqual(settings.mode, 'local')
            self.assertEqual(settings.config.api_key, '')
            self.assertIn('无法读取', settings.message)

    @unittest.skipUnless(os.name == 'nt', 'Windows DPAPI')
    def test_environment_override_does_not_send_stored_key_to_other_endpoint(self):
        save_agent_settings(self.config, path=self.path)
        settings = load_agent_settings(self.path, environ={'EXAMGUARD_API_BASE': 'https://example.invalid/v1'})
        self.assertEqual(settings.config.api_key, '')
        self.assertEqual(settings.mode, 'local')
        settings = load_agent_settings(self.path, environ=dict(EXAMGUARD_API_BASE='https://example.invalid/v1',
                         EXAMGUARD_MODEL='m', EXAMGUARD_API_KEY='env-synthetic'))
        self.assertEqual(settings.config.api_key, 'env-synthetic')
        self.assertEqual(settings.mode, 'llm')

    def test_connection_test_requires_both_tool_call_and_final_reply(self):
        payloads = []
        def transport(config, payload):
            payloads.append(payload)
            if len(payloads) == 1:
                return dict(tool_calls=[dict(id='probe1', type='function',
                    function=dict(name='get_connection_status', arguments='{}'))])
            return dict(content='connected')
        self.assertIn('连接测试通过', probe_model(self.config, transport=transport))
        self.assertEqual(len(payloads), 2)
        self.assertEqual(payloads[1]['messages'][-1]['role'], 'tool')
        self.assertNotIn(self.config.api_key, json.dumps(payloads))
        self.assertNotIn('get_recent_events', json.dumps(payloads))

    def test_plain_text_or_malformed_response_cannot_pass_tool_probe(self):
        for message in (dict(content='connected'), dict(tool_calls=['bad']),
                        dict(tool_calls=[dict(id='1', function=dict(name='delete', arguments='{}'))])):
            with self.assertRaises(ToolError):
                probe_model(self.config, transport=lambda *_: message)

    def test_unfinished_second_round_is_not_connected(self):
        messages = iter([dict(tool_calls=[dict(id='1', function=dict(name='get_connection_status', arguments='{}'))]),
                         dict(content=None)])
        with self.assertRaises(ToolError):
            probe_model(self.config, transport=lambda *_: next(messages))

    def test_provider_permission_error_is_specific_without_echoing_secrets(self):
        body = json.dumps(dict(error=dict(message='An active OpenCode Go subscription is required. ' + self.config.api_key))).encode()
        error = urllib.error.HTTPError(self.config.url(), 403, 'Forbidden', {}, io.BytesIO(body))
        with patch('app.agent_controller.urllib.request.build_opener') as factory:
            factory.return_value.open.side_effect = error
            with self.assertRaises(ToolError) as caught:
                request_completion(self.config, {})
        self.assertIn('有效的OpenCode Go订阅', str(caught.exception))
        self.assertNotIn(self.config.api_key, str(caught.exception))


class AgentSavedPanelTests(AgentFixture):
    @unittest.skipUnless(os.name == 'nt', 'Windows DPAPI')
    def test_save_probe_restart_and_clear_through_panel(self):
        from .agent_panel import AgentPanel
        root = tk.Tk()
        root.withdraw()
        path = self.root / 'settings.json'
        panels = []
        def create():
            panel = AgentPanel(root, self.model, evidence_root=lambda: self.root / 'evidence',
                               open_evidence=lambda *_: None, settings_path=path)
            panels.append(panel)
            return panel
        try:
            panel = create()
            panel.api_key.set('synthetic-ui-key')
            with patch('app.agent_panel.probe_model', return_value='连接测试通过：模拟服务'), patch('app.agent_panel.probe_vision', return_value='视觉接口已响应：模拟测试'):
                panel.save_and_connect()
                deadline = time.monotonic() + 5
                while panel._connection_busy and time.monotonic() < deadline:
                    root.update()
                    time.sleep(.01)
            self.assertFalse(panel._connection_busy)
            self.assertIn('连接测试通过', panel.state_text.get())
            self.assertEqual(panel.mode.get(), 'llm')
            panel.close()
            restored = create()
            self.assertEqual(restored.api_key.get(), 'synthetic-ui-key')
            self.assertEqual(restored.mode.get(), 'llm')
            self.assertIn('待测试', restored.state_text.get())
            restored.forget_key()
            self.assertFalse(path.exists())
            self.assertEqual(restored.mode.get(), 'local')
            self.assertEqual(restored.api_key.get(), '')
        finally:
            for panel in panels:
                panel.close()
            root.destroy()
