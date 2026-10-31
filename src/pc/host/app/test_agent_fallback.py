"""Bounded, consented fallback using synthetic tool receipts and images."""
from dataclasses import replace
import io
import json
import time
import urllib.error
from unittest.mock import patch

from .agent_controller import (AgentController, CompletionRoute, ModelConfig,
                               ModelRequestError, probe_model, request_completion)
from .agent_settings import ZHIPU_BASE, load_agent_settings, save_agent_settings
from .agent_tools import ToolError
from .agent_vision import review_images
from .test_agent import AgentFixture
from .test_agent_vision import observation


class AgentFallbackTests(AgentFixture):
    def config(self, **kwargs):
        return replace(ModelConfig(ZHIPU_BASE, 'glm-4.7-flash', 'synthetic-route-key',
                                   vision_model='glm-4.6v-flash', allow_paid_fallback=True), **kwargs)

    def busy(self):
        return ModelRequestError('busy', retryable=True, reason='busy_1305')

    def test_busy_chain_is_bounded_and_keeps_success_for_next_round(self):
        calls = []
        def transport(config, payload):
            calls.append((config.model, payload['model']))
            if config.model != 'glm-5.3-flashx':
                raise self.busy()
            return dict(content='ok')
        route = CompletionRoute(self.config(), transport)
        for _ in range(2):
            route.completion(self.config(), {})
        self.assertEqual([x[0] for x in calls], ['glm-4.7-flash', 'glm-5.3-flash', 'glm-5.3-flashx', 'glm-5.3-flashx'])
        self.assertTrue(all(a == b for a, b in calls))
        self.assertEqual(route.metadata()['actual_model'], 'glm-5.3-flashx')
        self.assertIn('服务器繁忙', route.description())

    def test_opt_out_other_provider_or_nonfree_model_never_get_paid_route(self):
        for config in (self.config(allow_paid_fallback=False),
                       self.config(endpoint='https://other.invalid/v1'),
                       self.config(endpoint=ZHIPU_BASE + '/unexpected'),
                       self.config(model='other-model')):
            calls = []
            def transport(c, p):
                calls.append(c.model)
                raise self.busy()
            with self.assertRaises(ModelRequestError):
                CompletionRoute(config, transport).completion(config, {})
            self.assertEqual(calls, [config.model])

    def test_all_busy_stops_after_three_candidates(self):
        route = CompletionRoute(self.config(), lambda *_: (_ for _ in ()).throw(self.busy()))
        with self.assertRaises(ModelRequestError):
            route.completion(self.config(), {})
        self.assertEqual(len(route.attempts), 3)
        self.assertEqual(route.metadata()['actual_model'], '')

    def test_no_retry_on_ordinary_tool_error_or_malformed_success(self):
        route = CompletionRoute(self.config(), lambda *_: (_ for _ in ()).throw(ToolError('bad schema')))
        with self.assertRaises(ToolError):
            route.completion(self.config(), {})
        self.assertEqual(len(route.attempts), 1)
        reply = AgentController(self.tools(), transport=lambda *_: dict(content='no tool')).ask(
            '查询状态', mode='llm', config=self.config())
        self.assertTrue(reply.error)
        self.assertEqual(len(reply.model_route['attempts']), 1)

    def test_http_categories_override_status_and_never_echo_key(self):
        for status, code, retryable in ((429, '1305', True), (503, '', True), (401, '', False),
                                        (403, '', False), (400, '', False), (429, '1113', False),
                                        (500, '1210', False), (429, '1311', False),
                                        (429, '1316', False), (429, '9999', False), (403, '1305', False)):
            body = json.dumps(dict(error=dict(code=code, message=self.config().api_key))).encode()
            error = urllib.error.HTTPError(self.config().url(), status, 'error', {}, io.BytesIO(body))
            with patch('app.agent_controller.urllib.request.build_opener') as factory:
                factory.return_value.open.side_effect = error
                with self.assertRaises(ModelRequestError) as caught:
                    request_completion(self.config(), {})
            self.assertEqual(caught.exception.retryable, retryable, (status, code))
            self.assertNotIn(self.config().api_key, str(caught.exception))

    def test_network_retries_but_invalid_json_does_not(self):
        for failure, expected in ((TimeoutError(), True), (urllib.error.URLError('offline'), True)):
            with patch('app.agent_controller.urllib.request.build_opener') as factory:
                factory.return_value.open.side_effect = failure
                with self.assertRaises(ModelRequestError) as caught:
                    request_completion(self.config(), {})
            self.assertEqual(caught.exception.retryable, expected)
        with patch('app.agent_controller.urllib.request.build_opener') as factory:
            factory.return_value.open.return_value = io.BytesIO(b'not json')
            with self.assertRaises(ModelRequestError) as caught:
                request_completion(self.config(), {})
        self.assertFalse(caught.exception.retryable)

    def test_cancellation_and_deadline_prevent_paid_call(self):
        for expired in (False, True):
            stopped = [False]
            def check():
                if stopped[0]:
                    raise ToolError('cancelled')
            route = None
            def transport(*_):
                if expired:
                    route.deadline = time.monotonic() - 1
                else:
                    stopped[0] = True
                raise self.busy()
            route = CompletionRoute(self.config(), transport, check=check)
            with self.assertRaises(ToolError):
                route.completion(self.config(), {})
            self.assertEqual(len(route.attempts), 1)

    def test_tool_result_and_reasoning_survive_switch_without_rerunning_tools(self):
        payloads = []
        def transport(config, payload):
            payloads.append((config.model, json.loads(json.dumps(payload))))
            if len(payloads) == 1:
                return dict(reasoning_content='synthetic reasoning', tool_calls=[dict(id='s1',
                            function=dict(name='get_system_health', arguments='{}'))])
            if len(payloads) == 2:
                raise self.busy()
            return dict(content='历史状态不代表现在在线。')
        reply = AgentController(self.tools(), transport=transport).ask('系统状态', mode='llm', config=self.config())
        self.assertFalse(reply.error, reply.answer)
        self.assertEqual(len(reply.trace), 1)
        self.assertEqual(payloads[1][1]['messages'], payloads[2][1]['messages'])
        self.assertEqual(payloads[2][1]['messages'][-1]['role'], 'tool')
        self.assertEqual(payloads[2][1]['messages'][-2]['reasoning_content'], 'synthetic reasoning')
        self.assertEqual(reply.as_dict()['model_route']['actual_model'], 'glm-5.3-flash')
        self.assertNotIn(self.config().api_key, json.dumps(reply.as_dict()))

    def test_paid_model_thinking_and_budget_are_adapted(self):
        captured = []
        def open_request(request, **kwargs):
            captured.append((json.loads(request.data), kwargs['timeout']))
            return io.BytesIO(b'{"choices":[{"message":{"content":"ok"}}]}')
        with patch('app.agent_controller.urllib.request.build_opener') as factory:
            factory.return_value.open.side_effect = open_request
            request_completion(self.config(model='glm-5.3-flash'), dict(max_tokens=256))
            request_completion(self.config(model='glm-5.3-flashx'), dict(max_tokens=900))
            request_completion(self.config(), dict(max_tokens=256))
        for body, timeout in captured[:2]:
            self.assertEqual(body['thinking']['type'], 'enabled')
            self.assertEqual(body['max_tokens'], 4096)
            self.assertEqual(body['reasoning_effort'], 'low')
        self.assertEqual(captured[2][0]['thinking']['type'], 'disabled')
        self.assertEqual(captured[2][0]['max_tokens'], 256)

    def test_visual_fallback_preserves_image_and_reports_actual_model(self):
        self.evidence()
        payloads = []
        def transport(config, payload):
            payloads.append(payload)
            if config.model == 'glm-4.6v-flash':
                raise self.busy()
            return dict(content=json.dumps(observation()))
        reply = review_images(self.tools(), self.event.transaction.hex(), self.config(), transport=transport)
        self.assertFalse(reply.error, reply.answer)
        self.assertEqual(payloads[0]['messages'], payloads[1]['messages'])
        self.assertEqual(reply.trace[-1]['result']['model'], 'glm-5.3-flash')
        self.assertIn('glm-5.3-flash', reply.answer)
        self.assertNotIn('base64', json.dumps(reply.as_dict()))
        self.assertNotIn(self.config().api_key, json.dumps(reply.as_dict()))

    def test_paid_flag_persists_but_old_and_environment_configs_default_off(self):
        path = self.root / 'config.json'
        with patch('app.agent_settings._crypt', side_effect=lambda b, **_: b):
            save_agent_settings(self.config(), path=path)
            self.assertTrue(load_agent_settings(path, environ={}).config.allow_paid_fallback)
            self.assertFalse(load_agent_settings(path, environ={'EXAMGUARD_MODEL': 'other'}).config.allow_paid_fallback)
            body = json.loads(path.read_text(encoding='utf-8'))
            body.pop('allow_paid_fallback')
            path.write_text(json.dumps(body), encoding='utf-8')
            self.assertFalse(load_agent_settings(path, environ={}).config.allow_paid_fallback)

    def test_connection_probe_keeps_fallback_for_both_rounds(self):
        called = []
        def transport(config, payload):
            called.append(config.model)
            if len(called) == 1:
                raise self.busy()
            if len(called) == 2:
                return dict(reasoning_content='test', tool_calls=[dict(id='p1',
                            function=dict(name='get_connection_status', arguments='{}'))])
            self.assertEqual(payload['messages'][-2]['reasoning_content'], 'test')
            return dict(content='connected')
        self.assertIn('glm-5.3-flash', probe_model(self.config(), transport=transport))
        self.assertEqual(called, ['glm-4.7-flash', 'glm-5.3-flash', 'glm-5.3-flash'])
