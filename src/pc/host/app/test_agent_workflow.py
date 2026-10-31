"""Real local login/credential persistence and two-way handoff on synthetic data."""
import http.cookiejar
import json
import os
import time
import tkinter as tk
import urllib.error
import urllib.request
from unittest.mock import patch

from .agent_panel import AgentPanel
from .agent_web_settings import generate_password,load_web_password,save_web_password
from .agent_joycode import source_signature
from .joycode_panel import JoyCodePanel
from .test_agent import AgentFixture

class DailyProfessionalWorkflowTests(AgentFixture):
    def setUp(self):
        super().setUp()
        self.window=tk.Tk();self.window.withdraw()
        self.agent=AgentPanel(self.window,self.model,evidence_root=lambda:self.root/'evidence',
                              open_evidence=lambda *_:None,settings_path=self.root/'agent.json')
        self.joy=JoyCodePanel(self.window,registry_path=self.root/'private/source.json',
                             agent_panel=self.agent,open_evidence=lambda *_:None,choose_evidence=lambda:None,
                             return_to_agent=self.agent.prepare_daily_review)
        self.agent.professional_handoff=self.joy.receive_handoff

    def tearDown(self):
        self.joy.close();self.agent.close()
        self.window.update_idletasks();self.window.destroy()
        super().tearDown()

    def request(self,url,path,body=None,client=None):
        request=urllib.request.Request(url.rstrip('/')+path,
                    data=json.dumps(body).encode('utf-8') if body is not None else None,
                    headers={'Content-Type':'application/json'} if body is not None else {})
        opener=client or urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:reply=opener.open(request,timeout=5)
        except urllib.error.HTTPError as exc:reply=exc
        with reply:return reply.status,reply.read()

    def test_daily_selected_event_roundtrip_and_stale_source_rejected(self):
        self.evidence()
        self.agent.send('最近30分钟手机事件证据')
        deadline=time.monotonic()+5
        while self.agent.busy and time.monotonic()<deadline:
            self.window.update();time.sleep(.01)
        self.assertFalse(self.agent.busy)
        self.agent.handoff_professional()
        self.assertEqual(self.joy.event_ref.get(),self.event.transaction.hex().upper())
        self.assertTrue(self.joy.copy_handoff())
        copied=self.window.clipboard_get()
        self.assertIn(self.event.transaction.hex().upper(),copied)
        self.assertIn('最近30分钟手机事件证据',copied)
        self.assertIn('不要把 UID 当作事件类型',copied)
        self.assertNotIn(str(self.root),copied)
        self.joy.go_daily()
        self.assertIn(self.event.transaction.hex().upper(),self.agent.question.get())
        self.assertFalse(self.agent.busy)  # A transfer never silently queries a model.
        self.agent.archive_path=self.source().session_path
        self.assertFalse(self.joy.copy_handoff())
        self.assertIn('重新转交',self.joy.state_text.get())

    def test_configuration_reference_is_readonly_and_invalid_reference_not_handed_over(self):
        self.assertFalse(self.joy.receive_handoff('q','102',source_signature(self.agent._source())))
        self.joy.show_configuration()
        dialog=self.joy.configuration_dialog
        labels=[]
        def visit(widget):
            if widget.winfo_class()=='TNotebook':
                labels.extend(widget.tab(tab,'text') for tab in widget.tabs())
            for child in widget.winfo_children():visit(child)
        visit(dialog)
        self.assertEqual(labels,['（Skills）','（Rule）','（Prompt）'])
        dialog.destroy()

    def test_real_generated_password_login_change_and_restart(self):
        if os.name!='nt':self.skipTest('Windows DPAPI')
        self.agent.mode.set('local')
        self.assertTrue(self.agent.toggle_web())
        password=self.agent.web_password.get()
        self.assertGreaterEqual(len(password),8)
        path=self.agent.web_settings_path
        self.assertTrue(path.exists())
        self.assertNotIn(password,path.read_text(encoding='utf-8'))
        self.assertEqual(load_web_password(path),password)
        old=self.agent.web_service
        jar=http.cookiejar.CookieJar()
        client=urllib.request.build_opener(urllib.request.ProxyHandler({}),urllib.request.HTTPCookieProcessor(jar))
        self.assertEqual(self.request(old.url,'/api/session',client=client)[0],401)
        self.assertEqual(self.request(old.url,'/api/login',dict(username='judge',password=password),client=client)[0],200)
        self.assertEqual(self.request(old.url,'/api/session',client=client)[0],200)
        new_password=generate_password()
        self.agent.web_password.set(new_password)
        self.assertTrue(self.agent.apply_web_password())
        self.assertTrue(old.cancelled.is_set())
        current=self.agent.web_service
        self.assertEqual(self.request(current.url,'/api/session',client=client)[0],401)
        self.assertEqual(self.request(current.url,'/api/login',dict(username='judge',password=password))[0],401)
        self.assertEqual(self.request(current.url,'/api/login',dict(username='judge',password=new_password))[0],200)
        self.agent.copy_web_address()
        self.assertEqual(self.window.clipboard_get(),current.url)
        with patch('webbrowser.open',return_value=True) as opened:
            self.agent.open_web()
            opened.assert_called_once_with(current.url)
        self.agent.toggle_web()
        self.assertIsNone(self.agent.web_service)
        self.agent.close()
        replacement=AgentPanel(self.window,self.model,evidence_root=lambda:self.root/'evidence',
                             open_evidence=lambda *_:None,settings_path=self.root/'agent.json')
        try:self.assertEqual(replacement.web_password.get(),new_password)
        finally:replacement.close()

    def test_invalid_password_or_encryption_failure_never_starts_a_server(self):
        self.agent.web_password.set('short')
        self.assertFalse(self.agent.toggle_web())
        self.assertIsNone(self.agent.web_service)
        self.agent.web_password.set('synthetic-password-123')
        with patch('app.agent_web_settings._crypt',side_effect=ValueError('failed')):
            self.assertFalse(self.agent.toggle_web())
        self.assertIsNone(self.agent.web_service)
        self.assertFalse(self.agent.web_settings_path.exists())

    def test_corrupt_password_file_and_length_limits(self):
        path=self.root/'password.json'
        self.assertEqual(load_web_password(path),'')
        for contents in ('{broken',json.dumps({'version':1,'protection':'plaintext'}),
                         json.dumps({'version':1,'protection':'windows-dpapi-current-user','password_protected':'bad'})):
            path.write_text(contents,encoding='utf-8')
            self.assertEqual(load_web_password(path),'')
        for password in ('short','x'*129,None):
            with self.assertRaises(ValueError):save_web_password(password,path)

if __name__=='__main__':
    import unittest
    unittest.main()
