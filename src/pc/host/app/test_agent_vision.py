"""Dual-model review regressions on synthetic evidence only, with no cloud calls."""
from dataclasses import replace
import hashlib
import io
import json
from pathlib import Path
import time
import tkinter as tk
import urllib.error
from unittest.mock import patch

from .agent_controller import ModelConfig, ModelRequestError, request_completion
from .agent_settings import ZHIPU_BASE, ZHIPU_TEXT_MODEL, ZHIPU_VISION_MODEL, load_agent_settings, save_agent_settings
from .agent_vision import probe_vision, review_images
from .test_agent import AgentFixture
from .agent_tools import ToolError


def observation():
    return dict(observation='低分辨率测试图片，无法确定手机。', phone='uncertain',
                purple_book='not_visible', head_direction='uncertain', limitations='单帧无法判断动作持续时间。')


class AgentVisionTests(AgentFixture):
    def config(self):
        return ModelConfig(ZHIPU_BASE, ZHIPU_TEXT_MODEL, 'synthetic-zhipu-key', vision_model=ZHIPU_VISION_MODEL)

    def test_visual_request_sends_verified_png_bytes_and_keeps_text_model(self):
        self.evidence()
        config, payloads = self.config(), []
        def transport(used, payload):
            payloads.append((used, payload))
            return dict(content=json.dumps(observation(), ensure_ascii=False))
        reply = review_images(self.tools(), self.event.transaction.hex(), config, transport=transport)
        self.assertFalse(reply.error, reply.answer)
        self.assertEqual(config.model, ZHIPU_TEXT_MODEL)
        self.assertEqual(payloads[0][0].model, ZHIPU_VISION_MODEL)
        images = [v for v in payloads[0][1]['messages'][1]['content'] if v['type'] == 'image_url']
        self.assertEqual(len(images), 1)
        self.assertTrue(images[0]['image_url']['url'].startswith('data:image/png;base64,'))
        self.assertNotIn(str(self.root), json.dumps(payloads[0][1]))
        self.assertNotIn('base64', json.dumps(reply.as_dict()))
        self.assertEqual(reply.trace[-1]['result']['frames_sent'], 1)
        self.assertTrue(reply.trace[-1]['result']['response_received'])

    def test_no_images_or_invalid_evidence_never_calls_model(self):
        def forbidden(*_):
            self.fail('empty evidence must not be sent')
        reply = review_images(self.tools(), self.event.transaction.hex(), self.config(), transport=forbidden)
        self.assertTrue(reply.error)
        self.assertIn('没有可发送', reply.answer)
        self.evidence()
        images = self.tools().get_image_path(self.event.transaction.hex())['images']
        Path(images[0]['path']).write_bytes(b'changed')
        reply = review_images(self.tools(), self.event.transaction.hex(), self.config(), transport=forbidden)
        self.assertTrue(reply.error)

    def test_modified_after_tool_verification_is_rejected(self):
        self.evidence()
        tools = self.tools()
        images = tools.get_image_path(self.event.transaction.hex())
        path = Path(images['images'][0]['path'])
        path.write_bytes(path.read_bytes() + b'changed')
        reply = review_images(tools, self.event.transaction.hex(), self.config(),
                              transport=lambda *_: self.fail('changed image must not be sent'))
        self.assertTrue(reply.error)
        self.assertIn('已变更', reply.answer)

    def test_maximum_three_frames_and_no_paths_in_cloud_payload(self):
        self.evidence()
        tools = self.tools()
        real_call = tools.call
        data = tools.get_image_path(self.event.transaction.hex())
        frames = [dict(data['images'][0], frame_index=i) for i in range(20)]
        def call(name, arguments):
            return dict(data, images=frames) if name == 'get_image_path' else real_call(name, arguments)
        with patch.object(tools, 'call', side_effect=call):
            reply = review_images(tools, self.event.transaction.hex(), self.config(),
                                  transport=lambda *_: dict(content=json.dumps(observation())))
        self.assertFalse(reply.error)
        self.assertEqual([f['frame_index'] for f in reply.trace[-1]['result']['frames']], [0, 10, 19])

    def test_cancellation_and_malformed_reply_are_explicit_failures(self):
        self.evidence()
        tools = self.tools()
        tools.cancelled.set()
        reply = review_images(tools, self.event.transaction.hex(), self.config(),
                              transport=lambda *_: self.fail('cancelled request'))
        self.assertTrue(reply.error)
        for content in ('cheating confirmed', '[]', json.dumps(dict(observation(), phone='cheating'))):
            reply = review_images(self.tools(), self.event.transaction.hex(), self.config(),
                                  transport=lambda *_: dict(content=content))
            self.assertTrue(reply.error)
            self.assertIn('约定', reply.answer)

    def test_visual_probe_uses_only_a_synthetic_image(self):
        calls = []
        self.assertIn('测试图', probe_vision(self.config(), transport=lambda c, p: calls.append(p) or dict(content='绿色')))
        self.assertNotIn(str(self.root), json.dumps(calls))
        self.assertNotIn(self.event.transaction.hex(), json.dumps(calls))

    def test_zhipu_http_uses_documented_auto_tools_and_disables_thinking(self):
        captured = []
        class Response(io.BytesIO):
            pass
        def open_request(request, **kwargs):
            captured.append(json.loads(request.data))
            return Response(b'{"choices":[{"message":{"content":"ok"}}]}')
        with patch('app.agent_controller.urllib.request.build_opener') as factory:
            factory.return_value.open.side_effect = open_request
            request_completion(self.config(), dict(tool_choice='required', tools=[{'synthetic': True}]))
            request_completion(self.config(), dict(tool_choice='none', tools=[{'synthetic': True}]))
        self.assertEqual(captured[0]['tool_choice'], 'auto')
        self.assertEqual(captured[0]['thinking'], dict(type='disabled'))
        self.assertNotIn('tools', captured[1])

    def test_dual_configuration_roundtrip_and_old_config_compatibility(self):
        path = self.root / 'private' / 'config.json'
        with patch('app.agent_settings._crypt', side_effect=lambda b, **_: b):
            save_agent_settings(self.config(), path=path)
            saved = load_agent_settings(path, environ={})
            self.assertEqual(saved.config.vision_model, ZHIPU_VISION_MODEL)
            body = json.loads(path.read_text(encoding='utf-8'))
            body.pop('vision_model')
            path.write_text(json.dumps(body), encoding='utf-8')
            self.assertEqual(load_agent_settings(path, environ={}).config.vision_model, '')

    def test_service_busy_is_distinct_from_bad_key_and_does_not_echo_provider_text(self):
        key = self.config().api_key
        body = json.dumps(dict(error=dict(code='1305', message='busy ' + key))).encode()
        error = urllib.error.HTTPError(self.config().url(), 429, 'busy', {}, io.BytesIO(body))
        with patch('app.agent_controller.urllib.request.build_opener') as factory:
            factory.return_value.open.side_effect = error
            with self.assertRaises(ToolError) as caught:
                request_completion(self.config(), {})
        self.assertIn('1305', str(caught.exception))
        self.assertNotIn(key, str(caught.exception))


class AgentDualPanelTests(AgentFixture):
    def test_query_select_visual_review_and_export_preserve_event_and_text_model(self):
        from .agent_panel import AgentPanel
        self.evidence()
        root = tk.Tk()
        root.withdraw()
        panel = AgentPanel(root, self.model, evidence_root=lambda: self.root / 'evidence',
                           open_evidence=lambda *_: None, settings_path=self.root / 'config.json')
        def pump():
            deadline = time.monotonic() + 8
            while panel.busy and time.monotonic() < deadline:
                root.update()
                time.sleep(.01)
            self.assertFalse(panel.busy)
        try:
            panel.send('最近30分钟手机证据')
            pump()
            self.assertEqual(len(panel.cards), 1)
            panel.use_zhipu()
            panel.api_key.set('synthetic-ui-key')
            panel.allow_paid_fallback.set(True)
            def visual(tools, reference, config):
                def transport(used, payload):
                    if used.model == ZHIPU_VISION_MODEL:
                        raise ModelRequestError('busy', retryable=True, reason='busy_1305')
                    return dict(content=json.dumps(observation(), ensure_ascii=False))
                return review_images(tools, reference, config, transport=transport)
            with patch('app.agent_panel.review_images', side_effect=visual):
                panel.review_selected_images()
                pump()
            self.assertEqual(panel.state_text.get(), 'AI看图辅助复核')
            self.assertEqual(len(panel.cards), 1)
            self.assertEqual(panel._config().model, ZHIPU_TEXT_MODEL)
            self.assertEqual(panel.last_record['trace'][-1]['result']['frames_sent'], 1)
            self.assertEqual(panel.last_record['model_route']['actual_model'], 'glm-5.3-flash')
            self.assertIn('服务器繁忙', panel.output.get('1.0', 'end'))
            self.assertTrue(panel._config().allow_paid_fallback)
            self.assertNotIn('base64', json.dumps(panel.last_record))
            self.assertNotIn('synthetic-ui-key', json.dumps(panel.last_record))
        finally:
            panel.close()
            root.update_idletasks()
            root.destroy()
