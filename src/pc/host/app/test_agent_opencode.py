"""Free backend regressions use local fixtures; never spend provider credits."""
import json
import subprocess
import sys
import textwrap
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from .agent_controller import AgentController, ModelConfig
from .agent_mcp import ReviewMCP
from .agent_opencode import FREE_MODELS, ask_free, child_config, collect_reply, known_error
from .agent_settings import load_agent_settings, save_agent_settings
from .agent_tools import ToolError
from .agent_web import AgentWebService
from .test_agent import AgentFixture


class FreeBackendTests(AgentFixture):
    def test_child_has_only_review_mcp_and_no_key_in_command_or_config(self):
        with tempfile.TemporaryDirectory() as directory:
            env, audit = child_config(Path(directory), self.source(), FREE_MODELS[0], 'synthetic-free-key')
            config = json.loads(env['OPENCODE_CONFIG_CONTENT'])
            self.assertEqual(config['permission'], {'*': 'deny', 'examguard_*': 'allow'})
            self.assertEqual(config['small_model'], FREE_MODELS[0])
            self.assertEqual(config['share'], 'disabled')
            self.assertNotIn('synthetic-free-key', env['OPENCODE_CONFIG_CONTENT'])
            self.assertEqual(env['EXAMGUARD_FREE_KEY'], 'synthetic-free-key')
            self.assertEqual(list(config['mcp']), ['examguard'])
            self.assertEqual(config['mcp']['examguard']['command'][-1], '6')
            self.assertTrue(audit.exists())

    def test_paid_model_is_refused_before_client_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ToolError):
                child_config(Path(directory), self.source(), 'opencode/paid-model', '')

    def test_mcp_audit_records_actual_data_and_enforces_call_limit(self):
        records = []
        server = ReviewMCP(self.source(snapshot=False), audit=records.append, max_calls=1)
        server.handle(dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-06-18')))
        result = server.handle(dict(jsonrpc='2.0', id=2, method='tools/call',
                                    params=dict(name='get_system_health', arguments={})))
        self.assertFalse(result['result']['isError'])
        self.assertEqual(records[0]['name'], 'get_system_health')
        self.assertFalse(records[0]['result']['live_session'])
        result = server.handle(dict(jsonrpc='2.0', id=3, method='tools/call',
                                    params=dict(name='get_system_health', arguments={})))
        self.assertTrue(result['result']['isError'])
        self.assertEqual(len(records), 1)

    def test_text_alone_is_never_a_successful_review(self):
        text = json.dumps(dict(type='text', part=dict(text='已确认没有异常')))
        with self.assertRaises(ToolError):
            collect_reply(text, [], '')

    def test_real_receipt_and_answer_are_joined_and_key_redacted(self):
        trace = [dict(name='get_system_health', arguments={}, result=self.tools().get_system_health())]
        text = json.dumps(dict(type='text', part=dict(text='需要人工复核。synthetic-free-key')))
        reply = collect_reply(text, trace, 'synthetic-free-key')
        self.assertEqual(reply.mode, 'OpenCode免费模型工具调用')
        self.assertNotIn('synthetic-free-key', json.dumps(reply.as_dict()))
        self.assertIn('系统', reply.verified)

    def test_quota_region_and_server_errors_cannot_be_successful(self):
        for detail, expected in (('Free usage limit reached', '额度'),
                                 ('This model is not available in your country', '地区'),
                                 ('Unexpected server error', '暂时出错')):
            self.assertIn(expected, known_error(detail))
            text = json.dumps(dict(type='error', error=dict(message=detail)))
            with self.assertRaises(ToolError):
                collect_reply(text, [], '')

    def test_controller_does_not_fall_back_to_paid_api(self):
        config = ModelConfig('', FREE_MODELS[0], '')
        with patch('app.agent_opencode.ask_free', side_effect=ToolError('免费额度不足')):
            reply = AgentController(self.tools()).ask('系统健康', mode='opencode', config=config)
        self.assertTrue(reply.error)
        self.assertIn('免费额度', reply.answer)
        self.assertEqual(reply.trace, [])

    def test_free_settings_without_key_restore_without_dpapi(self):
        path = self.root / 'free_settings.json'
        config = ModelConfig('', FREE_MODELS[0], '')
        save_agent_settings(config, mode='opencode', path=path)
        restored = load_agent_settings(path, environ={})
        self.assertEqual(restored.mode, 'opencode')
        self.assertEqual(restored.config.model, FREE_MODELS[0])
        self.assertEqual(restored.config.api_key, '')

    def test_web_can_select_free_mode_without_api_endpoint(self):
        web = AgentWebService(self.source, password='test-password', mode='opencode',
                              config=ModelConfig('', FREE_MODELS[0], ''))
        self.assertEqual(web.mode, 'opencode')
        web.server.server_close()

    def test_native_backend_reads_real_mcp_audit_without_any_cloud_request(self):
        stub = self.root / 'fake_client.py'
        stub.write_text(textwrap.dedent('''
            import json, os, subprocess
            config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])
            messages = [dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-06-18')),
                        dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='get_system_health', arguments={}))]
            result = subprocess.run(config['mcp']['examguard']['command'], input=''.join(json.dumps(x)+'\\n' for x in messages),
                                    capture_output=True, text=True, encoding='utf-8', check=True)
            responses = [json.loads(x) for x in result.stdout.splitlines()]
            assert not responses[1]['result']['isError']
            print(json.dumps(dict(type='text', part=dict(text='已查询指定存档；需要人工复核。'))))
        '''), encoding='utf-8')
        real_popen = subprocess.Popen
        def fake_client(command, **kwargs):
            return real_popen([sys.executable, str(stub)], **kwargs)
        with patch('app.agent_opencode.client_path', return_value='fake-client'), \
             patch('app.agent_opencode.subprocess.Popen', side_effect=fake_client):
            reply = ask_free('系统健康', self.source(snapshot=False), ModelConfig('', FREE_MODELS[0], ''),
                             cancelled=self.tools().cancelled)
        self.assertFalse(reply.error)
        self.assertEqual(reply.trace[0]['name'], 'get_system_health')
        self.assertFalse(reply.trace[0]['result']['live_session'])
