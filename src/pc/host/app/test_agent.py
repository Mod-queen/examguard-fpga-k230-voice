"""Agent regressions use isolated synthetic protocol fixtures, never real capture."""
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import hashlib
import http.cookiejar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import time
import tkinter as tk
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

from .agent_controller import AgentController, ModelConfig, request_completion
from .agent_tools import AgentSource, AgentTools, ToolError
from .agent_web import AgentWebService, ppm_to_png
from .board_monitor import BoardMonitor
from .event_store import load_session
from .evidence_v2 import decode_window_packet
from .evidence_v2_receiver import EvidenceV2Receiver
from .evidence_v2_store import latest_revision
from .history_result import FLAG_COVERAGE_OK, FLAG_OK, encode_history_result
from .history_result_receiver import HistoryResultReceiver
from .monitor import MonitorModel
from .protocol import EventPacket, StatusPacket
from .test_evidence_v2 import wire
from .test_evidence_v2_receiver import result_wire
from .transaction_protocol import TransactionEventPacket, TRANSACTION


class AgentFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.model = MonitorModel(session_root=self.root / 'sessions')
        self.event = TransactionEventPacket(decode_window_packet(wire()).transaction)
        self.model.apply(self.event)

    def tearDown(self):
        self.model.close()
        self.temp.cleanup()

    def source(self, *, snapshot=True):
        current = self.model.snapshot()
        return AgentSource(Path(current.session_path), self.root / 'evidence', current if snapshot else None)

    def tools(self, **kwargs):
        return AgentTools(self.source(), **kwargs)

    def evidence(self, *, partial=False, history=True):
        receiver = EvidenceV2Receiver(self.root / 'evidence')
        receiver.ingest(wire(flags=0, payload=b'\x12\x34') if partial else wire())
        receiver.ingest(result_wire())
        receiver.flush(force=True)
        if history:
            HistoryResultReceiver(self.root / 'evidence').ingest(encode_history_result(
                transaction=self.event.transaction, window=1, token=7, code=0, frames=1,
                gap_count=0, lower_ms=100, upper_ms=300, flags=FLAG_OK | FLAG_COVERAGE_OK))


class AgentToolTests(AgentFixture):
    def test_durable_query_survives_clear_and_deduplicates_et_not_al(self):
        self.model.apply(self.event)
        self.model.apply(EventPacket(1, 2, 3, 0, 3, 0x50))
        self.model.clear_events()
        result = self.tools().get_recent_events(event_code=80)
        self.assertEqual(result['unique_transactions_in_scanned_rows'], 1)
        self.assertEqual(result['scanned_receipts'], 2)
        self.assertEqual(result['legacy_receipts_in_scanned_rows'], 1)
        item = result['events'][0]
        self.assertEqual(item['event_uid'], str(0x1234567800000001))
        self.assertEqual(item['source_time_ms'], str(0xDEADBEEFFFFFFFFF))

    def test_uid_ambiguity_and_same_identity_conflict_refuse_binding(self):
        dev, boot, session, uid, stamp, source, reserved, lane = TRANSACTION.unpack(self.event.transaction)
        other = TransactionEventPacket(TRANSACTION.pack(dev, boot + 1, session, uid, stamp, source, reserved, lane))
        self.model.apply(other)
        with self.assertRaisesRegex(ToolError, '多个事件'):
            self.tools().resolve_event(str(uid))
        self.assertEqual(self.tools().resolve_event(other.transaction.hex()).identity[1], boot + 1)
        conflict = TransactionEventPacket(TRANSACTION.pack(dev, boot, session, uid, stamp + 1, source, reserved, lane))
        self.model.apply(conflict)
        with self.assertRaisesRegex(ToolError, '冲突'):
            self.tools().resolve_event(self.event.transaction.hex())

    def test_joint_complete_requires_hr_and_images_return_actual_frames(self):
        self.evidence(history=False)
        tools = self.tools()
        ref = self.event.transaction.hex()
        self.assertEqual(tools.check_evidence_status(ref)['status'], 'awaiting_result')
        self.assertEqual(len(tools.get_image_path(ref)['images']), 1)
        self.evidence()
        self.assertEqual(self.tools().check_evidence_status(ref)['status'], 'complete')
        image = self.tools().get_image_path(ref)['images'][0]
        self.assertTrue(Path(image['path']).is_relative_to(self.root))
        self.assertTrue(ppm_to_png(Path(image['path']).read_bytes()).startswith(b'\x89PNG'))

    def test_partial_and_hr_only_do_not_become_complete(self):
        self.evidence(partial=True)
        self.assertEqual(self.tools().check_evidence_status(self.event.transaction.hex())['status'], 'partial')
        self.assertEqual(self.tools().get_image_path(self.event.transaction.hex())['images'], [])
        # Separate evidence scope with only a genuine validated HR result.
        scope = self.root / 'only_hr'
        HistoryResultReceiver(scope).ingest(encode_history_result(
            transaction=self.event.transaction, window=1, token=7, code=0, frames=1,
            gap_count=0, lower_ms=100, upper_ms=300, flags=FLAG_OK | FLAG_COVERAGE_OK))
        tools = AgentTools(replace(self.source(), evidence_root=scope))
        self.assertEqual(tools.check_evidence_status(self.event.transaction.hex())['status'], 'awaiting_pixels')

    def test_bad_latest_revision_blocks_old_complete_preview(self):
        self.evidence()
        latest = latest_revision(self.root / 'evidence', self.event.identity)
        later = latest.parent / 'revision_zzzz'
        later.mkdir()
        (later / 'manifest.json').write_text('{}', encoding='utf-8')
        tools = self.tools()
        self.assertEqual(tools.check_evidence_status(self.event.transaction.hex())['status'], 'invalid')
        self.assertEqual(tools.get_image_path(self.event.transaction.hex())['images'], [])

    def test_unknown_event_and_paths_and_arguments_are_rejected(self):
        for value in ('../../secret.ppm', '1;DROP TABLE events', '0', str(2**64)):
            with self.subTest(value=value), self.assertRaises(ToolError):
                self.tools().resolve_event(value)
        for name, args in (('shell', {}), ('get_recent_events', {'limit': True}),
                           ('get_recent_events', {'time_range': 0}), ('get_image_path', {'path': 'x'})):
            with self.subTest(name=name, args=args), self.assertRaises(ToolError):
                self.tools().call(name, args)

    def test_evidence_scope_does_not_claim_absence_outside_selected_directory(self):
        self.evidence()
        present = self.tools().check_evidence_status(self.event.transaction.hex())
        self.assertEqual(present['status'], 'complete')
        alternate = replace(self.source(snapshot=False), evidence_root=self.root / 'other_evidence', label='另一选定目录')
        missing = AgentTools(alternate)
        state = missing.check_evidence_status(self.event.transaction.hex())
        images = missing.get_image_path(self.event.transaction.hex())
        self.assertEqual(state['status'], 'not_received')
        self.assertEqual(images['images'], [])
        for result in (state, images):
            self.assertEqual(result['source'], '另一选定目录')
            self.assertEqual(result['scope'], 'selected_session_and_evidence_directory')
        self.assertEqual(self.tools().check_evidence_status(self.event.transaction.hex())['status'], 'complete')

    def test_event_uid_never_substitutes_for_event_code_in_evidence_tools(self):
        for uid, code, label in ((102, 0x50, '手机'), (80, 0x60, '扭头'), (81, 0x51, '资料'), (96, 0x66, '未知')):
            event = TransactionEventPacket(TRANSACTION.pack(77, 88, 99, uid, 100, 1, 0, 0x3000 | code))
            self.model.apply(event)
            tools = self.tools()
            queried = tools.get_recent_events()['events']
            row = next(e for e in queried if e['event_ref'] == event.transaction.hex().upper())
            for result in (row, tools.check_evidence_status(event.transaction.hex()), tools.get_image_path(event.transaction.hex())):
                with self.subTest(uid=uid, code=code):
                    self.assertEqual(result['event_uid'], str(uid))
                    self.assertEqual(result['event_code'], code)
                    self.assertEqual(result['event_code_hex'], f'0x{code:02X}')
                    self.assertIn(label, result['event'])

    def test_archive_reads_do_not_modify_database_and_time_range_is_honest(self):
        source = self.source(snapshot=False)
        self.model.close()
        before = hashlib.sha256(source.session_path.read_bytes()).hexdigest()
        result = AgentTools(source, now=datetime.now(timezone.utc) + timedelta(days=2)).get_recent_events()
        self.assertEqual(result['events'], [])
        self.assertIn('PC接收时间', result['time_basis'])
        self.assertEqual(before, hashlib.sha256(source.session_path.read_bytes()).hexdigest())

    def test_health_missing_fresh_stale_and_archive_are_distinct(self):
        self.assertEqual(self.tools().get_system_health()['status'], 'unknown')
        self.model.apply(StatusPacket(1, 3, 0, 0, 100, 0, health_flags=2))
        result = self.tools().get_system_health()
        self.assertEqual(result['status'], 'fresh')
        self.assertIn('K230无结果', result['reported_health'])
        self.assertIsNone(result['fpga_temperature_c'])
        self.assertEqual(self.tools(now=datetime.now(timezone.utc) + timedelta(seconds=10)).get_system_health()['status'], 'stale')
        self.assertEqual(AgentTools(self.source(snapshot=False)).get_system_health()['status'], 'stale')

    def test_limit_scan_is_explicit_not_full_range_count(self):
        # Commit actual unique ET rows without expensive unrelated status history.
        for n in range(501):
            self.model.apply(TransactionEventPacket(decode_window_packet(wire(uid=n+1)).transaction))
        result = self.tools().get_recent_events(limit=2)
        self.assertTrue(result['scan_truncated'])
        self.assertTrue(result['display_truncated'])
        self.assertEqual(result['scanned_receipts'], 500)
        self.assertEqual(len(result['events']), 2)


class AgentControllerTests(AgentFixture):
    def test_actual_compatible_http_roundtrip_and_redirect_refusal(self):
        payloads = []
        redirect = [False]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                payloads.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                if redirect[0]:
                    self.send_response(302)
                    self.send_header('Location', '/sink')
                    self.end_headers()
                    return
                message = (dict(tool_calls=[dict(id='tool1', type='function', function=dict(
                    name='get_recent_events', arguments='{"event_code":80}'))])
                    if len(payloads) == 1 else dict(content='已查询到疑似手机事件，请人工复核。'))
                raw = json.dumps(dict(choices=[dict(message=message)])).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        worker = threading.Thread(target=server.serve_forever, kwargs=dict(poll_interval=.05), daemon=True)
        worker.start()
        config = ModelConfig(f'http://127.0.0.1:{server.server_port}/v1', 'fixture-model', 'fixture-key')
        # Isolate loopback HTTP from the user's system proxy.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), __import__('app.agent_controller', fromlist=['_NoRedirect'])._NoRedirect)
        try:
            with patch('app.agent_controller.urllib.request.build_opener', return_value=opener):
                reply = AgentController(self.tools()).ask('手机', mode='llm', config=config)
                self.assertEqual(reply.mode, '大模型工具调用')
                self.assertFalse(reply.error)
                self.assertEqual(len(payloads), 2)
                redirect[0] = True
                with self.assertRaisesRegex(ToolError, 'HTTP 302'):
                    request_completion(config, dict(model='fixture-model', messages=[]))
                self.assertEqual(len(payloads), 3)  # No redirected credential-bearing request.
        finally:
            server.shutdown()
            server.server_close()
            worker.join(1)

    def test_local_is_explicit_and_does_not_call_api(self):
        def forbidden(*args):
            self.fail('local mode accessed LLM')
        reply = AgentController(self.tools(), transport=forbidden).ask('有没有手机报警？')
        self.assertIn('未接大模型', reply.mode)
        self.assertEqual([t['name'] for t in reply.trace], ['get_recent_events', 'check_evidence_status', 'get_image_path'])
        self.assertIn('需人工复核', reply.verified)

    def test_real_tool_loop_payload_and_key_redaction(self):
        config = ModelConfig('https://api.example.invalid/v1', 'demo', 'secret-ABC123')
        payloads = []
        def transport(config, payload):
            # Persist request value as a transport would, not the mutable messages list.
            payloads.append(json.loads(json.dumps(payload)))
            if len(payloads) == 1:
                return dict(tool_calls=[dict(id='tool1', function=dict(name='get_recent_events', arguments='{"time_range":30,"event_code":80}'))])
            return dict(content='已查询。' + config.api_key)
        reply = AgentController(self.tools(), transport=transport).ask('手机报警', mode='llm', config=config)
        self.assertFalse(reply.error)
        self.assertEqual(reply.mode, '大模型工具调用')
        self.assertEqual(payloads[0]['tool_choice'], 'required')
        self.assertTrue(any(m['role'] == 'tool' for m in payloads[1]['messages']))
        self.assertNotIn(config.api_key, json.dumps(reply.as_dict()))
        self.assertNotIn(config.api_key, repr(config))

    def test_llm_cannot_claim_completion_without_tool_or_after_error(self):
        config = ModelConfig('https://api.example.invalid/v1', 'demo', 'secret')
        reply = AgentController(self.tools(), transport=lambda *_: dict(content='没有作弊')).ask('手机', mode='llm', config=config)
        self.assertTrue(reply.error)
        self.assertIn('没有调用工具', reply.answer)
        missing = AgentController(self.tools()).ask('手机', mode='llm', config=ModelConfig())
        self.assertTrue(missing.error)
        self.assertEqual(missing.trace, [])

    def test_unknown_tools_and_malformed_calls_do_not_gain_controls(self):
        config = ModelConfig('https://api.example.invalid/v1', 'demo', 'secret')
        for response in (dict(tool_calls=[dict(id='1', function=dict(name='delete_evidence', arguments='{}'))]),
                         dict(tool_calls=['bad']), dict(tool_calls=[dict(id='1', function=dict(name='get_recent_events', arguments='{broken'))])):
            reply = AgentController(self.tools(), transport=lambda *_: response).ask('测试', mode='llm', config=config)
            self.assertTrue(reply.error)
        self.assertEqual(len(load_session(self.source().session_path).transactions), 1)

    def test_secret_echo_in_tool_arguments_is_redacted(self):
        config = ModelConfig('https://api.example.invalid/v1', 'demo', 'secret-ABC123')
        response = dict(tool_calls=[dict(id='1', function=dict(name='get_image_path', arguments=json.dumps(dict(event_ref=config.api_key))))])
        reply = AgentController(self.tools(), transport=lambda *_: response).ask('证据', mode='llm', config=config)
        self.assertNotIn(config.api_key, json.dumps(reply.as_dict()))

    def test_api_address_and_remote_plain_http_are_validated(self):
        self.assertEqual(ModelConfig('https://example.invalid/v1/', 'model', 'key').url(), 'https://example.invalid/v1/chat/completions')
        self.assertEqual(ModelConfig('http://127.0.0.1:8900/v1/chat/completions', 'm', 'k').url(), 'http://127.0.0.1:8900/v1/chat/completions')
        for url in ('http://example.invalid/v1', 'https://user:pass@example.invalid', 'https://example.invalid/?key=secret'):
            with self.assertRaises(ToolError):
                ModelConfig(url, 'model', 'key').url()


class AgentWebTests(AgentFixture):
    def setUp(self):
        super().setUp()
        self.evidence()
        self.web = AgentWebService(self.source, password='test-password-123')
        self.web.start()
        self.jar = http.cookiejar.CookieJar()
        self.client = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar))
        self.csrf = ''

    def tearDown(self):
        self.web.close()
        super().tearDown()

    def request(self, path, body=None, *, csrf=True, origin=None):
        headers = {}
        if body is not None:
            headers['Content-Type'] = 'application/json'
            if csrf:
                headers['X-CSRF-Token'] = self.csrf
        if origin:
            headers['Origin'] = origin
        request = urllib.request.Request(self.web.url.rstrip('/') + path,
            data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            response = self.client.open(request, timeout=10)
        except urllib.error.HTTPError as exc:
            response = exc
        raw = response.read()
        return response.status, raw, response.headers

    def login(self):
        status, raw, headers = self.request('/api/login', dict(username='judge', password='test-password-123'))
        self.assertEqual(status, 200)
        self.csrf = json.loads(raw)['csrf']
        self.assertIn('HttpOnly', headers['Set-Cookie'])

    def test_login_required_csrf_origin_and_logout(self):
        self.assertEqual(self.request('/api/session')[0], 401)
        self.assertEqual(self.request('/api/ask', dict(question='手机'))[0], 401)
        self.assertEqual(self.request('/api/login', dict(username='judge', password='bad'))[0], 401)
        self.login()
        self.assertEqual(self.request('/api/ask', dict(question='手机'), csrf=False)[0], 403)
        self.assertEqual(self.request('/api/ask', dict(question='手机'), origin='https://evil.invalid')[0], 403)
        self.assertEqual(json.loads(self.request('/api/session')[1])['mode'], 'local')
        self.assertEqual(self.request('/api/logout', {})[0], 200)
        self.assertEqual(self.request('/api/session')[0], 401)

    def test_query_validated_images_and_no_arbitrary_files(self):
        self.login()
        status, raw, _ = self.request('/api/ask', dict(question='最近30分钟手机事件证据'))
        result = json.loads(raw)
        self.assertEqual(status, 200)
        self.assertIn('未接大模型', result['mode'])
        self.assertNotIn(str(self.root), raw.decode('utf-8'))
        ref = self.event.transaction.hex()
        status, raw, headers = self.request(f'/api/image?event_ref={ref}&index=0')
        self.assertEqual(status, 200)
        self.assertEqual(headers['Content-Type'], 'image/png')
        self.assertTrue(raw.startswith(b'\x89PNG'))
        self.assertEqual(self.request('/api/image?path=../../secret&index=0')[0], 404)
        self.assertEqual(self.request('/../agent_controller.py')[0], 404)

    def test_login_attempts_are_limited(self):
        for _ in range(8):
            self.assertEqual(self.request('/api/login', dict(username='judge', password='bad'))[0], 401)
        self.assertEqual(self.request('/api/login', dict(username='judge', password='test-password-123'))[0], 429)

    def test_parallel_asks_cannot_clear_another_requests_busy_flag(self):
        self.login()
        entered, release = threading.Event(), threading.Event()
        original = AgentController.ask
        def held(controller, *args, **kwargs):
            entered.set()
            release.wait(5)
            return original(controller, *args, **kwargs)
        with patch('app.agent_web.AgentController.ask', held):
            worker = threading.Thread(target=lambda: self.request('/api/ask', dict(question='手机')))
            worker.start()
            self.assertTrue(entered.wait(3))
            try:
                self.assertEqual(self.request('/api/ask', dict(question='手机'))[0], 429)
                self.assertEqual(self.request('/api/ask', dict(question='手机'))[0], 429)
            finally:
                release.set()
                worker.join(5)
            self.assertFalse(worker.is_alive())


class AgentPanelTests(AgentFixture):
    def test_async_panel_evidence_navigation_and_close(self):
        from .agent_panel import AgentPanel
        self.evidence()
        root = tk.Tk()
        root.withdraw()
        opened = []
        panel = AgentPanel(root, self.model, evidence_root=lambda: self.root / 'evidence',
                           open_evidence=lambda packet, path: opened.append((packet, path)),
                           settings_path=self.root / 'agent_settings.json')
        panel.pack(fill='both', expand=True)
        try:
            panel.send('最近30分钟手机事件证据')
            deadline = time.monotonic() + 8
            while panel.busy and time.monotonic() < deadline:
                root.update()
                time.sleep(.01)
            self.assertFalse(panel.busy)
            self.assertIn('未接大模型', panel.state_text.get())
            self.assertEqual(len(panel.cards), 1)
            self.assertIsNotNone(panel.last_record)
            record_path = self.root / 'review.json'
            with patch('app.agent_panel.filedialog.asksaveasfilename', return_value=str(record_path)):
                panel.export_review()
            record = json.loads(record_path.read_text(encoding='utf-8'))
            self.assertEqual(record['question'], '最近30分钟手机事件证据')
            self.assertNotIn(str(self.root), record_path.read_text(encoding='utf-8'))
            with patch('app.agent_panel.filedialog.asksaveasfilename', return_value=str(record_path)):
                panel.export_review()
            self.assertIn('已存在', panel.state_text.get())
            root.update()
            panel.show_evidence()
            self.assertEqual(opened[0][0], self.event)
            panel.api_key.set('secret-not-persisted')
            panel.close()
            self.assertEqual(panel.api_key.get(), '')
        finally:
            panel.close()
            root.update_idletasks()
            root.destroy()


class AgentExportTests(AgentFixture):
    def test_portable_record_redacts_nested_secrets_and_keeps_evidence_reference(self):
        from .agent_controller import AgentReply
        from .agent_report import build_review_record, serialize_review_record
        reply = AgentReply('本地工具演示', '不可把密钥 secret-123 放入记录', '需人工复核',
                           [dict(name='get_image_path', result=dict(event_ref=self.event.transaction.hex(),
                                 images=[dict(path='D:/private/frame.ppm', sha256='abc')], api_key='secret-123'))])
        record = build_review_record('secret-123', reply, self.source(), '2026-10-30T03:00:00+00:00', secrets=('secret-123',))
        text = serialize_review_record(record)
        self.assertNotIn('secret-123', text)
        self.assertNotIn('D:/private', text)
        self.assertIn(self.event.transaction.hex(), text)
        self.assertIn('abc', text)
        self.assertEqual(record['queried_at_utc'], '2026-10-30T03:00:00+00:00')
        self.assertIn('path', reply.trace[0]['result']['images'][0])


class AgentMCPTests(AgentFixture):
    def mcp(self):
        from .agent_mcp import ReviewMCP
        server = ReviewMCP(self.source(snapshot=False))
        response = server.handle(dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-06-18')))
        self.assertEqual(response['result']['protocolVersion'], '2025-06-18')
        return server

    def test_mcp_lists_and_calls_only_readonly_tools(self):
        server = self.mcp()
        tools = server.handle(dict(jsonrpc='2.0', id=2, method='tools/list'))['result']['tools']
        self.assertEqual(len(tools), 4)
        self.assertTrue(all(t['annotations']['readOnlyHint'] for t in tools))
        result = server.handle(dict(jsonrpc='2.0', id=3, method='tools/call', params=dict(name='get_recent_events', arguments=dict(time_range=30))))['result']
        self.assertFalse(result['isError'])
        value = json.loads(result['content'][0]['text'])
        self.assertEqual(value['events'][0]['event_ref'], self.event.transaction.hex().upper())
        bad = server.handle(dict(jsonrpc='2.0', id=4, method='tools/call', params=dict(name='execute_sql', arguments={})))
        self.assertTrue(bad['result']['isError'])
        bad = server.handle(dict(jsonrpc='2.0', id=5, method='tools/call', params=dict(name='get_recent_events', arguments=dict(sql='DROP TABLE session'))))
        self.assertTrue(bad['result']['isError'])

    def test_mcp_stdio_framing_and_lifecycle(self):
        from io import BytesIO
        from .agent_mcp import ReviewMCP
        server = ReviewMCP(self.source())
        self.assertIn('error', server.handle(dict(jsonrpc='2.0', id=0, method='tools/list')))
        requests = [dict(jsonrpc='2.0', id=1, method='initialize', params=dict(protocolVersion='2025-06-18')),
                    dict(jsonrpc='2.0', method='notifications/initialized'), dict(jsonrpc='2.0', id=2, method='tools/list')]
        reader = BytesIO(b'\n'.join(json.dumps(r).encode() for r in requests) + b'\n{bad\n')
        writer = BytesIO()
        server.serve(reader, writer)
        results = [json.loads(line) for line in writer.getvalue().splitlines()]
        self.assertEqual(len(results), 3)
        self.assertEqual(results[1]['id'], 2)
        self.assertEqual(results[2]['error']['code'], -32700)


if __name__ == '__main__':
    unittest.main()
