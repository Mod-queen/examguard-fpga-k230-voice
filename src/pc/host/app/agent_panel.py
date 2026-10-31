"""Tk Agent interface. Disk/network work stays off the Tk thread."""
from pathlib import Path
import json
import math
import queue
import threading
import tkinter as tk
from tkinter import filedialog, ttk
from tkinter.scrolledtext import ScrolledText

from .agent_controller import AgentController, ModelConfig, probe_model
from .agent_tools import AgentSource, AgentTools
from .agent_report import build_review_record, serialize_review_record, utc_now
from .agent_settings import (OPENCODE_GO_MODELS, load_agent_settings,
                             save_agent_settings, clear_agent_settings,
                             ZHIPU_BASE, ZHIPU_TEXT_MODEL, ZHIPU_VISION_MODEL)
from .agent_opencode import FREE_MODELS, probe_free
from .agent_vision import probe_vision, review_images
from .transaction_protocol import decode_transaction_event
from .agent_web_settings import generate_password, load_web_password, save_web_password, validate_password
from .panel_viewport import PanelViewport


class AgentPanel(ttk.Frame):
    def __init__(self, parent, model, *, evidence_root, open_evidence, settings_path=None, web_settings_path=None):
        super().__init__(parent, padding=10)
        self.viewport=PanelViewport(self)
        content=self.viewport.content
        self.model = model
        self.evidence_root = evidence_root  # Tk-thread callback; never read it from worker.
        self.open_evidence = open_evidence
        self.archive_path = None
        self.history = []
        self.last_record = None
        self.cards = {}
        self._queue = queue.Queue()
        self._cancel = threading.Event()
        self._closed = self.busy = False
        self._poll_job = None
        self.web_service = None
        self.professional_handoff = None
        self.web_settings_path = (web_settings_path if web_settings_path is not None else
                                  Path(settings_path).with_name('agent_web_password.json') if settings_path else None)
        self.settings_path = settings_path
        self._connection_busy = False
        self._connection_poll = None
        self._connection_queue = queue.Queue()
        saved = load_agent_settings(settings_path)
        self._conversation_id = saved.config.session_id
        self.bind('<Destroy>', self._destroyed, add='+')
        self.mode = tk.StringVar(value=saved.mode)
        self.endpoint = tk.StringVar(value=saved.config.endpoint)
        self.model_name = tk.StringVar(value=saved.config.model)
        self.vision_model_name = tk.StringVar(value=saved.config.vision_model)
        self.allow_paid_fallback = tk.BooleanVar(value=saved.config.allow_paid_fallback)
        self.api_key = tk.StringVar(value=saved.config.api_key)
        self.source_text = tk.StringVar(value='数据：当前采集会话；时间按PC接收时间查询')
        self.state_text = tk.StringVar(value=saved.message)

        role_bar = ttk.Frame(content)
        role_bar.pack(fill='x', pady=(0, 4))
        ttk.Label(role_bar, text='（日常：快速查报警、看证据、问系统状态）').pack(side='left')
        self.professional_button = ttk.Button(role_bar, text='（转到 JoyCode 专业复核）', command=self.handoff_professional)
        self.professional_button.pack(side='right')

        bar = ttk.Frame(content)
        bar.pack(fill='x')
        ttk.Radiobutton(bar, text='本地工具演示', variable=self.mode, value='local', command=self._mode_changed).pack(side='left')
        ttk.Radiobutton(bar, text='OpenCode免费模型', variable=self.mode, value='opencode', command=self._mode_changed).pack(side='left')
        ttk.Radiobutton(bar, text='大模型API', variable=self.mode, value='llm', command=self._mode_changed).pack(side='left')
        ttk.Button(bar, text='选择历史存档', command=self.choose_archive).pack(side='right')
        ttk.Button(bar, text='当前会话', command=self.use_live).pack(side='right', padx=4)
        ttk.Label(content, textvariable=self.source_text, wraplength=900).pack(fill='x', pady=(3, 6))

        config = ttk.LabelFrame(content, text='模型接入 · 智谱双模型：文本查询 + 点击看图', padding=6)
        config.pack(fill='x')
        config.columnconfigure(1, weight=1)
        config.columnconfigure(3, weight=1)
        ttk.Label(config, text='API地址').grid(row=0, column=0, sticky='w')
        ttk.Entry(config, textvariable=self.endpoint).grid(row=0, column=1, columnspan=3, sticky='ew', padx=5)
        ttk.Label(config, text='模型名').grid(row=1, column=0, sticky='w')
        ttk.Combobox(config, textvariable=self.model_name, values=(ZHIPU_TEXT_MODEL,) + FREE_MODELS + OPENCODE_GO_MODELS + ('glm-5.3-flashx',), width=22).grid(row=1, column=1, sticky='ew', padx=5, pady=4)
        ttk.Label(config, text='API密钥').grid(row=1, column=2, sticky='w')
        ttk.Entry(config, textvariable=self.api_key, show='*', width=24).grid(row=1, column=3, sticky='ew', padx=5)
        actions = ttk.Frame(config)
        ttk.Label(config, text='视觉模型').grid(row=2, column=0, sticky='w')
        ttk.Combobox(config, textvariable=self.vision_model_name,
                     values=(ZHIPU_VISION_MODEL, 'glm-5.3-flash', 'glm-5.3-flashx')).grid(row=2, column=1, sticky='ew', padx=5)
        ttk.Button(config, text='使用智谱免费双模型', command=self.use_zhipu).grid(row=2, column=2, columnspan=2, sticky='w', padx=5)
        actions.grid(row=3, column=0, columnspan=4, sticky='w', pady=(5, 0))
        self.connect_button = ttk.Button(actions, text='保存并连接', command=self.save_and_connect)
        self.connect_button.pack(side='left')
        self.test_button = ttk.Button(actions, text='仅测试连接', command=self.test_connection)
        self.test_button.pack(side='left', padx=5)
        ttk.Button(actions, text='清除已保存密钥', command=self.forget_key).pack(side='left')
        self.fallback_checkbox = ttk.Checkbutton(actions, text='免费繁忙时用收费备用：5.3-Flash → FlashX',
                                                variable=self.allow_paid_fallback)
        self.fallback_checkbox.pack(side='left', padx=8)
        ttk.Label(content, textvariable=self.state_text).pack(fill='x', pady=5)

        panes = ttk.Panedwindow(content, orient='horizontal')
        panes.pack(fill='both', expand=True)
        conversation = ttk.Frame(panes)
        evidence = ttk.Frame(panes)
        panes.add(conversation, weight=3)
        panes.add(evidence, weight=2)
        self.output = ScrolledText(conversation, height=6, width=45, wrap='word', state='disabled',
                                  bg='#0f1921', fg='#e6edf3', insertbackground='white', font=('Microsoft YaHei UI', 10))
        self.output.pack(fill='both', expand=True)
        self._append('助手', '可查询手机、资料、扭头报警、证据和系统状态。' +
                     ('已读取模型配置，连接状态需测试。' if saved.mode in ('llm', 'opencode') else '当前为本地工具演示，可选择免费模型或兼容API。') +
                     '识别结果需要老师看图复核。')
        quick = ttk.Frame(conversation)
        quick.pack(fill='x', pady=4)
        for label, text in (('手机报警', '最近30分钟有没有手机报警？'), ('最近事件', '最近30分钟事件和证据'), ('系统健康', '系统健康和温度怎么样？')):
            ttk.Button(quick, text=label, command=lambda q=text: self.send(q)).pack(side='left', padx=2)
        entry_bar = ttk.Frame(conversation)
        entry_bar.pack(fill='x')
        self.question = tk.StringVar()
        self.entry = ttk.Entry(entry_bar, textvariable=self.question)
        self.entry.pack(side='left', fill='x', expand=True)
        self.entry.bind('<Return>', lambda _event: self.send())
        self.send_button = ttk.Button(entry_bar, text='发送', command=self.send)
        self.send_button.pack(side='left', padx=4)
        self.cancel_button = ttk.Button(entry_bar, text='取消', command=self.cancel, state='disabled')
        self.cancel_button.pack(side='left')
        self.export_button = ttk.Button(conversation, text='导出本次复核记录', command=self.export_review, state='disabled')
        self.export_button.pack(anchor='w', pady=4)

        ttk.Label(evidence, text='工具核验记录 · 以原始证据为准').pack(anchor='w')
        self.event_tree = ttk.Treeview(evidence, columns=('event', 'uid'), show='headings', height=3, selectmode='browse')
        self.event_tree.heading('event', text='疑似事件')
        self.event_tree.heading('uid', text='UID')
        self.event_tree.column('event', width=120)
        self.event_tree.column('uid', width=120)
        self.event_tree.pack(fill='x', pady=5)
        self.event_tree.bind('<<TreeviewSelect>>', self._select_card)
        self.event_tree.bind('<Double-1>', lambda _e: self.show_evidence())
        ttk.Button(evidence, text='打开该事件的图像回放', command=self.show_evidence).pack(fill='x')
        self.vision_button = ttk.Button(evidence, text='AI 看图复核（最多发送3帧）', command=self.review_selected_images)
        self.vision_button.pack(fill='x', pady=(4, 0))
        self.preview = ttk.Label(evidence, text='查询后选择事件查看图像', anchor='center')
        self.preview.pack(fill='x', pady=5)
        self.details = ScrolledText(evidence, height=4, width=32, wrap='word', state='disabled', font=('Microsoft YaHei UI', 9))
        self.details.pack(fill='both', expand=True)

        web = ttk.Frame(content)
        web.pack(fill='x', side='bottom', before=panes, pady=(7, 0))
        web.columnconfigure(1, weight=1)
        password_bar = ttk.Frame(web)
        password_bar.grid(row=0, column=0, columnspan=2, sticky='ew')
        ttk.Label(password_bar, text='网页访问密码').pack(side='left')
        restored_password = load_web_password(self.web_settings_path)
        self.web_password = tk.StringVar(value=restored_password)
        self.web_password_entry = ttk.Entry(password_bar, textvariable=self.web_password, show='*', width=18)
        self.web_password_entry.pack(side='left', padx=4)
        self.web_show_password = tk.BooleanVar(value=False)
        ttk.Checkbutton(password_bar, text='（显示）', variable=self.web_show_password,
                        command=lambda: self.web_password_entry.configure(show='' if self.web_show_password.get() else '*')).pack(side='left')
        ttk.Button(password_bar, text='（生成密码）', command=self.generate_web_password).pack(side='left', padx=4)
        ttk.Button(password_bar, text='（保存并应用密码）', command=self.apply_web_password).pack(side='left')
        actions = ttk.Frame(web)
        actions.grid(row=1, column=0, sticky='w', pady=(4, 0))
        self.web_button = ttk.Button(actions, text='启动本机评审网页', command=self.toggle_web)
        self.web_button.pack(side='left')
        self.web_address = tk.StringVar(value='未启动；公开链接需要另行部署')
        ttk.Button(actions, text='（打开网页）', command=self.open_web).pack(side='left', padx=3)
        ttk.Button(actions, text='（复制地址）', command=self.copy_web_address).pack(side='left')
        ttk.Entry(web, textvariable=self.web_address, state='readonly').grid(row=1, column=1, sticky='ew', padx=5, pady=(4, 0))
        self.web_status = tk.StringVar(value='（账号 judge；密码已加密保存）' if restored_password else
                                           '（账号 judge；首次启动可自动生成并加密保存密码）')
        ttk.Label(web, textvariable=self.web_status).grid(row=2, column=0, columnspan=2, sticky='w', pady=(3, 0))

    def handoff_professional(self):
        if self.busy or self._connection_busy:
            self.state_text.set('（请等待当前查询完成后再转交专业复核）')
            return
        if self.professional_handoff is None:
            self.state_text.set('（请在完整监考台中打开 JoyCode 联动）')
            return
        from .agent_joycode import source_signature
        source = self._source()
        card = self._selected_card()
        if card and source_signature(card['source']) != source_signature(source):
            self.state_text.set('（该事件属于先前数据源，请重新查询后再转交）')
            return
        question = self.question.get().strip() or next((m['content'] for m in reversed(self.history) if m['role']=='user'), '请复核最近的疑似报警及证据状态。')
        reference = card['event']['event_ref'] if card else ''
        self.professional_handoff(question, reference, source_signature(source))

    def prepare_daily_review(self, reference=''):
        if reference and (len(reference)!=64 or any(c not in '0123456789abcdefABCDEF' for c in reference)):
            self.state_text.set('（请先核对完整 event_ref）')
            return False
        if reference:
            self.question.set('请核对 event_ref 为 '+reference.upper()+' 的事件，查询证据状态和可查看图像。')
        self.state_text.set('（已从 JoyCode 返回日常复核；沿用当前会话，点击发送后查询）')
        self.entry.focus_set()
        return True

    def _mode_changed(self):
        if self.mode.get() == 'opencode':
            if self.model_name.get() not in FREE_MODELS:
                self.model_name.set(FREE_MODELS[0])
            self.state_text.set('OpenCode免费模式 · 有额度及地区限制，待实际连接验证；不自动切付费模型')
            return
        if self.mode.get() == 'llm' and self.model_name.get() in FREE_MODELS:
            self.model_name.set(OPENCODE_GO_MODELS[0])
        self.state_text.set('本地工具演示 · 尚未接入大模型' if self.mode.get() == 'local' else '大模型模式 · 待发送查询验证连接')

    def _config(self):
        return ModelConfig(self.endpoint.get(), self.model_name.get(), self.api_key.get(), self._conversation_id,
                           self.vision_model_name.get(), self.allow_paid_fallback.get())

    def use_zhipu(self):
        if self.busy or self._connection_busy or self.web_service:
            self.state_text.set('请先等待查询结束并停止网页，再切换模型')
            return
        if self.endpoint.get().rstrip('/') != ZHIPU_BASE:
            self.api_key.set('')  # Never send the prior provider's key to Zhipu.
        self.endpoint.set(ZHIPU_BASE)
        self.model_name.set(ZHIPU_TEXT_MODEL)
        self.vision_model_name.set(ZHIPU_VISION_MODEL)
        self.mode.set('llm')
        self.history.clear()
        self.state_text.set('已选择智谱免费双模型。填写智谱密钥后保存；普通提问不发图，看图需选中事件后点击按钮。')

    def save_and_connect(self):
        if self.busy or self._connection_busy or self.web_service:
            self.state_text.set('请先等待查询结束并停止评审网页，再保存模型配置')
            return
        try:
            mode = 'opencode' if self.mode.get() == 'opencode' else 'llm'
            save_agent_settings(self._config(), mode=mode, path=self.settings_path)
        except (OSError, ValueError):
            self.state_text.set('保存失败，请检查API地址、模型名、密钥和本机目录权限')
            return
        self.mode.set(mode)
        self.test_connection()

    def forget_key(self):
        if self.busy or self._connection_busy or self.web_service:
            self.state_text.set('请先等待查询结束并停止评审网页，再清除配置')
            return
        try:
            clear_agent_settings(self.settings_path)
        except OSError:
            self.state_text.set('删除本机配置失败，请检查目录权限')
            return
        self.api_key.set('')
        self.mode.set('local')
        self.state_text.set('已清除本机保存的密钥；当前为本地工具演示')

    def test_connection(self):
        if self.busy or self._connection_busy or self._closed:
            return
        config = self._config()
        free_mode = self.mode.get() == 'opencode'
        try:
            if free_mode:
                if config.model not in FREE_MODELS:
                    raise ValueError('model')
            else:
                config.url()
        except ValueError:
            self.state_text.set('请先填写有效API地址、模型名和密钥')
            return
        self._connection_busy = True
        self.connect_button.configure(state='disabled')
        self.test_button.configure(state='disabled')
        self.send_button.configure(state='disabled')
        self.state_text.set('正在测试模型工具调用；本次不发送监考数据或图片…')
        def work():
            try:
                if free_mode:
                    message = probe_free(config)
                elif config.vision_model:
                    results = []
                    for label, probe in (('文本', probe_model), ('视觉', probe_vision)):
                        try:
                            results.append(label + '：' + probe(config))
                        except (ValueError, OSError) as exc:
                            results.append(label + '未通过：' + str(exc))
                    message = '\n'.join(results)
                else:
                    message = probe_model(config)
            except ValueError as exc:
                message = str(exc)
            except Exception:
                message = '连接测试未完成，请检查服务地址、订阅额度和模型支持'
            self._connection_queue.put(message.replace(config.api_key, '[密钥已隐藏]') if config.api_key else message)
        threading.Thread(target=work, name='examguard-model-check', daemon=True).start()
        self._connection_poll = self.after(60, self._poll_connection)

    def _poll_connection(self):
        self._connection_poll = None
        if self._closed:
            return
        try:
            message = self._connection_queue.get_nowait()
        except queue.Empty:
            self._connection_poll = self.after(60, self._poll_connection)
            return
        self._connection_busy = False
        self.connect_button.configure(state='normal')
        self.test_button.configure(state='normal')
        self.send_button.configure(state='normal')
        self.state_text.set(message)
        self._append('连接测试', message)

    def _append(self, who, text):
        self.output.configure(state='normal')
        self.output.insert('end', f'{who}\n{text}\n\n')
        self.output.see('end')
        self.output.configure(state='disabled')

    def choose_archive(self):
        if self.busy or self.web_service:
            self.state_text.set('请先等待查询完成并停止网页服务，再切换数据源')
            return
        path = filedialog.askopenfilename(title='选择本工程会话存档', filetypes=[('SQLite会话', '*.sqlite3')])
        if path:
            self.archive_path = Path(path)
            self.source_text.set(f'历史存档：{self.archive_path.name}；不是当前在线状态')
            self.history.clear()
            from uuid import uuid4
            self._conversation_id = uuid4().hex
            self.last_record = None
            self.export_button.configure(state='disabled')
            self._clear_cards()

    def use_live(self):
        if self.busy or self.web_service:
            self.state_text.set('请先等待查询完成并停止网页服务，再切换数据源')
            return
        self.archive_path = None
        from uuid import uuid4
        self._conversation_id = uuid4().hex
        self.history.clear()
        self.last_record = None
        self.export_button.configure(state='disabled')
        self._clear_cards()
        self.source_text.set('数据：当前采集会话；时间按PC接收时间查询')

    def _source(self):
        root = Path(self.evidence_root()).resolve()
        if self.archive_path:
            return AgentSource(self.archive_path, root, label='指定历史存档')
        snapshot = self.model.snapshot()
        return AgentSource(Path(snapshot.session_path) if snapshot.session_path else None, root, snapshot)

    def send(self, question=None):
        if self.busy or self._connection_busy or self._closed:
            return
        text = question if question is not None else self.question.get()
        if not text.strip():
            return
        if len(text) > 2000:
            self.state_text.set('问题最多2000字')
            return
        source = self._source()
        config = self._config()
        mode, history = self.mode.get(), list(self.history)
        queried_at = utc_now()
        self.last_record = None
        self.export_button.configure(state='disabled')
        self._append('老师', text)
        self.question.set('')
        self.busy = True
        self.send_button.configure(state='disabled')
        self.cancel_button.configure(state='normal')
        self.state_text.set('正在查询，监测与图像接收继续运行…')
        self._cancel = threading.Event()
        cancel = self._cancel
        def work():
            try:
                result = AgentController(AgentTools(source, cancelled=cancel)).ask(text, mode=mode, config=config, history=history)
                record = build_review_record(text, result, source, queried_at, secrets=(config.api_key,))
                self._queue.put((result, source, text, None, record))
            except Exception:
                self._queue.put((None, source, text, '查询未完成；请检查所选存档或模型配置', None))
        threading.Thread(target=work, name='examguard-agent', daemon=True).start()
        self._poll_job = self.after(60, self._poll)

    def cancel(self):
        self._cancel.set()
        self.state_text.set('已请求取消；网络请求最多等待当前超时结束')

    def _poll(self):
        self._poll_job = None
        if self._closed:
            return
        try:
            reply, source, question, error, record = self._queue.get_nowait()
        except queue.Empty:
            self._poll_job = self.after(60, self._poll)
            return
        self.busy = False
        self.send_button.configure(state='normal')
        self.cancel_button.configure(state='disabled')
        if self._cancel.is_set():
            self.state_text.set('本次查询已取消')
            return
        if error:
            self.state_text.set(error)
            self._append('助手', error)
            return
        self.state_text.set(reply.mode)
        self.last_record = record
        self.export_button.configure(state='normal')
        prefix = '模型说明（请以核验记录为准）' if reply.mode in ('大模型工具调用', 'OpenCode免费模型工具调用', 'AI看图辅助复核') else reply.mode
        self._append(prefix, reply.answer + '\n\n核验记录：\n' + reply.verified)
        self.history.extend([dict(role='user', content=question), dict(role='assistant', content=reply.answer)])
        self.history = self.history[-8:]
        self.details.configure(state='normal')
        self.details.delete('1.0', 'end')
        self.details.insert('end', json.dumps(dict(tool_trace=reply.trace, model_route=reply.model_route), ensure_ascii=False, indent=2))
        self.details.configure(state='disabled')
        self._clear_cards()
        events, images = {}, {}
        for call in reply.trace:
            data = call['result']
            if call['name'] == 'get_recent_events':
                events.update({e['event_ref']: e for e in data.get('events', [])})
            elif call['name'] == 'get_image_path' and 'event_ref' in data:
                images[data['event_ref']] = data.get('images', [])
                events.setdefault(data['event_ref'], dict(event_ref=data['event_ref'], event=data['event'],
                                                          event_uid=data['event_uid']))
        for ref, event in events.items():
            iid = f'agent_{len(self.cards)}'
            self.cards[iid] = dict(event=event, source=source, images=images.get(ref, []))
            self.event_tree.insert('', 'end', iid=iid, values=(event['event'], event['event_uid']))
        if self.cards:
            self.event_tree.selection_set(next(iter(self.cards)))

    def _clear_cards(self):
        for item in self.event_tree.get_children():
            self.event_tree.delete(item)
        self.cards.clear()
        self.preview.configure(image='', text='选择事件查看现有图像')
        self._image = None

    def _selected_card(self):
        selected = self.event_tree.selection()
        return self.cards.get(selected[0]) if selected else None

    def _select_card(self, _event=None):
        card = self._selected_card()
        if not card:
            return
        if not card['images']:
            self.preview.configure(image='', text='尚无已校验缩略图；可打开回放查看关联状态')
            self._image = None
            return
        try:
            path = Path(card['images'][0]['path'])
            if path.stat().st_size > 16 * 1024 * 1024:
                raise ValueError('preview too big')
            original = tk.PhotoImage(file=str(path))
            ratio = max(1, math.ceil(original.width() / 240), math.ceil(original.height() / 110))
            self._image = original.subsample(ratio)
            self.preview.configure(image=self._image, text='')
        except (OSError, ValueError, tk.TclError):
            self.preview.configure(image='', text='缩略图不可用，请打开回放重新校验')

    def show_evidence(self):
        card = self._selected_card()
        if card:
            self.open_evidence(decode_transaction_event(card['event']['event_ref']), card['source'].evidence_root)

    def review_selected_images(self):
        if self.busy or self._connection_busy or self._closed:
            return
        card = self._selected_card()
        if not card:
            self.state_text.set('请先查询事件，并选中一条有图片的事件')
            return
        config = self._config()
        try:
            if self.mode.get() != 'llm' or not config.vision_model.strip():
                raise ValueError('vision not configured')
            config.url()
        except ValueError:
            self.state_text.set('请先选择智谱免费双模型、填写智谱密钥并保存连接')
            return
        source = card['source']
        reference = card['event']['event_ref']
        text = '请辅助查看该事件的抽样图片：' + reference
        queried_at = utc_now()
        self.busy = True
        self.last_record = None
        self.export_button.configure(state='disabled')
        self.send_button.configure(state='disabled')
        self.cancel_button.configure(state='normal')
        self.state_text.set('正在校验图片；最多发送3帧至所填模型平台，原图保留在本机…')
        self._append('老师', text)
        self._cancel = threading.Event()
        cancel = self._cancel
        def work():
            try:
                result = review_images(AgentTools(source, cancelled=cancel), reference, config)
                record = build_review_record(text, result, source, queried_at, secrets=(config.api_key,))
                self._queue.put((result, source, text, None, record))
            except Exception:
                self._queue.put((None, source, text, '看图复核未完成，请查看原始图像', None))
        threading.Thread(target=work, name='examguard-vision', daemon=True).start()
        self._poll_job = self.after(60, self._poll)

    def export_review(self):
        if not self.last_record:
            return
        filename = filedialog.asksaveasfilename(title='保存本次复核记录', defaultextension='.json',
                    initialfile='examguard_review_' + self.last_record['queried_at_utc'].replace(':', '').replace('+', '_') + '.json',
                    filetypes=[('复核记录 JSON', '*.json')])
        if not filename:
            return
        try:
            with open(filename, 'x', encoding='utf-8') as stream:
                stream.write(serialize_review_record(self.last_record))
            self.state_text.set('复核记录已导出，可用文本编辑器查看')
        except FileExistsError:
            self.state_text.set('该文件已存在，请另选文件名保存')
        except OSError:
            self.state_text.set('导出失败，请检查保存位置')

    def generate_web_password(self):
        self.web_password.set(generate_password())
        self.web_status.set('（已生成新密码；点击保存并应用，或启动网页后生效）')

    def apply_web_password(self):
        try:
            validate_password(self.web_password.get())
            save_web_password(self.web_password.get(), self.web_settings_path)
        except (OSError, ValueError):
            self.web_status.set('（保存失败；密码须为8到128位，请检查本机目录权限）')
            return False
        if self.web_service:
            self._stop_web()
            if not self._start_web():
                return False
            self.web_status.set('（新密码已保存并生效；旧登录已失效，请使用新地址重新登录）')
        else:
            self.web_status.set('（密码已在本机加密保存；启动网页后生效，账号 judge）')
        return True

    def _stop_web(self):
        if self.web_service:
            self.web_service.close()
            self.web_service = None
        self.web_button.configure(text='启动本机评审网页')
        self.web_address.set('已停止；公开链接需要另行部署')

    def toggle_web(self):
        if self.web_service:
            self._stop_web()
            self.web_status.set('（网页已停止；下次启动沿用已保存密码）')
            return
        if not self.web_password.get():
            self.generate_web_password()
        try:
            validate_password(self.web_password.get())
            save_web_password(self.web_password.get(), self.web_settings_path)
        except (OSError, ValueError):
            self.state_text.set('请设置至少8位网页访问密码，登录账号为judge')
            self.web_status.set('（密码未保存；需要8到128位，请检查本机目录权限）')
            return False
        return self._start_web()

    def _start_web(self):
        from .agent_web import AgentWebService
        source = self._source()
        # Fix selected paths at start. Only the thread-safe model snapshot is refreshed.
        model = self.model
        def source_factory():
            if source.snapshot is None:
                return source
            from dataclasses import replace
            return replace(source, snapshot=model.snapshot())
        try:
            service = AgentWebService(source_factory, password=self.web_password.get(),
                    mode=self.mode.get(), config=self._config())
            try:
                service.start()
            except BaseException:
                service.close()
                raise
            self.web_service = service
        except (OSError, ValueError):
            self.state_text.set('网页启动失败，请检查配置')
            return False
        self.web_button.configure(text='停止评审网页')
        self.web_address.set(self.web_service.url + '  账号judge；仅本机')
        self.web_status.set('（网页已启动；账号 judge，密码可点显示查看；停止网页后登录失效）')
        return True

    def open_web(self):
        if not self.web_service:
            if not self.toggle_web():
                return
        import webbrowser
        try:
            opened = webbrowser.open(self.web_service.url)
        except OSError:
            opened = False
        self.web_status.set('（已请求打开浏览器，使用账号 judge 和上方密码登录）' if opened else
                            '（未能打开浏览器，请复制地址后手动打开）')

    def copy_web_address(self):
        if not self.web_service:
            self.web_status.set('（请先启动本机评审网页）')
            return
        self.clipboard_clear()
        self.clipboard_append(self.web_service.url)
        self.web_status.set('（已复制网页地址；账号 judge，密码请通过上方输入框查看）')

    def close(self):
        if self._closed:
            return
        self._closed = True
        self._cancel.set()
        if self._poll_job:
            self.after_cancel(self._poll_job)
            self._poll_job = None
        if self._connection_poll:
            self.after_cancel(self._connection_poll)
            self._connection_poll = None
        if self.web_service:
            self.web_service.close()
            self.web_service = None
        self.api_key.set('')
        self.web_password.set('')

    def _destroyed(self, event):
        if event.widget is self:
            self.close()
