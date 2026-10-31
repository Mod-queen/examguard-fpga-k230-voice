"""JoyCode workflow integration; JoyCode owns its own conversation UI."""
import json
from pathlib import Path
import tkinter as tk
from tkinter import ttk
from tkinter.scrolledtext import ScrolledText

from .agent_joycode import SourcePublisher, joycode_mcp_config, launch_joycode, source_signature
from .agent_tools import AgentTools
from .background_task import BackgroundTask
from .panel_viewport import PanelViewport


class JoyCodePanel(ttk.Frame):
    def __init__(self, parent, *, registry_path, agent_panel, open_evidence, choose_evidence, return_to_agent=None):
        super().__init__(parent, padding=14)
        self.viewport=PanelViewport(self)
        content=self.viewport.content
        self.agent_panel = agent_panel
        self.open_evidence = open_evidence
        self.choose_evidence = choose_evidence
        self.return_to_agent = return_to_agent
        self.publisher = SourcePublisher(registry_path)
        self.task = BackgroundTask()
        self._closed = False
        self._job = None
        self.bind('<Destroy>', self._destroyed, add='+')
        ttk.Label(content, text='JoyCode 与监考台共享选定会话和证据目录（专业智能体）', font=('Microsoft YaHei UI', 12, 'bold')).pack(anchor='w')
        ttk.Label(content, text='对话在 JoyCode 内完成；本页提供数据联动和图像回放。\n'
                  '（可使用你自行训练或配置的智能体，结合 Skills、Rule、Prompt 和 MCP 定制专业复核流程。）', wraplength=750).pack(anchor='w', pady=6)
        actions = ttk.Frame(content)
        actions.pack(fill='x', pady=5)
        ttk.Button(actions, text='打开 JoyCode', command=self.open_joycode).pack(side='left')
        ttk.Button(actions, text='复制 MCP 配置', command=self.copy_config).pack(side='left', padx=6)
        ttk.Button(actions, text='刷新联动', command=lambda: self.sync(force=True)).pack(side='left')
        ttk.Button(actions, text='（Skills / Rule / Prompt）', command=self.show_configuration).pack(side='left', padx=6)
        self.daily_button = ttk.Button(actions, text='（转到 Agent 日常复核）', command=self.go_daily)
        self.daily_button.pack(side='left')
        self.source_text = tk.StringVar()
        ttk.Label(content, textvariable=self.source_text, wraplength=700).pack(fill='x', pady=6)
        self.path_text = tk.StringVar()
        ttk.Entry(content, textvariable=self.path_text, state='readonly').pack(fill='x')
        self.evidence_text = tk.StringVar()
        ttk.Label(content, textvariable=self.evidence_text, wraplength=700).pack(fill='x', pady=6)
        sources = ttk.Frame(content)
        sources.pack(fill='x')
        ttk.Button(sources, text='使用当前会话', command=self.use_current).pack(side='left')
        ttk.Button(sources, text='选择历史存档', command=self.choose_archive).pack(side='left', padx=6)
        ttk.Button(sources, text='选择证据目录', command=self.choose_root).pack(side='left')
        ttk.Label(content, text='首次使用：复制配置 → 在 JoyCode 中替换 examguard 的 MCP 配置 → 重连一次。\n'
                  '之后切换会话会自动联动。切换后请重新提问，先查询事件，再查看证据。\n'
                  '“联动就绪”只表示数据源可供查询，不表示大模型已连接或板卡在线。',
                  wraplength=750).pack(fill='x', pady=8)
        transfer = ttk.LabelFrame(content, text='（与 Agent 助手交接：沿用同一会话和事件）', padding=6)
        transfer.pack(fill='x', pady=(0, 6))
        self.handoff_text = tk.StringVar(value='（可从 Agent 助手带入问题和完整事件引用，再复制到 JoyCode 提问。）')
        ttk.Label(transfer, textvariable=self.handoff_text, wraplength=750).pack(fill='x')
        self._handoff_question = ''
        self._handoff_signature = None
        self.handoff_button = ttk.Button(transfer, text='（复制专业复核问题）', command=self.copy_handoff)
        self.handoff_button.pack(anchor='w', pady=(4, 0))
        box = ttk.LabelFrame(content, text='从 JoyCode 回到上位机查看原始证据', padding=8)
        box.pack(fill='x')
        ttk.Label(box, text='粘贴 JoyCode 返回的完整 event_ref：').pack(anchor='w')
        self.event_ref = tk.StringVar()
        ttk.Entry(box, textvariable=self.event_ref).pack(fill='x', pady=5)
        self.review_button = ttk.Button(box, text='打开事件图像回放', command=self.review)
        self.review_button.pack(anchor='w')
        self.state_text = tk.StringVar(value='正在关联上位机数据…')
        ttk.Label(content, textvariable=self.state_text, wraplength=700).pack(fill='x', pady=10)
        self.sync(force=True)
        self._job = self.after(1000, self._tick)

    def receive_handoff(self, question, reference, signature):
        if signature != source_signature(self.agent_panel._source()):
            self.state_text.set('（会话或证据目录已切换，请从 Agent 重新转交）')
            return False
        if reference and (len(reference)!=64 or any(c not in '0123456789abcdefABCDEF' for c in reference)):
            self.state_text.set('（事件引用不完整，未转交）')
            return False
        self.event_ref.set(reference.upper())
        self._handoff_question = str(question)[:2000]
        self._handoff_signature = signature
        preview = self._handoff_question[:140]
        self.handoff_text.set('（来自 Agent：'+preview+('…' if len(self._handoff_question)>140 else '')+'）'+
                              ('\n（event_ref：'+reference.upper()+'）' if reference else ''))
        self.sync(force=True)
        self.state_text.set('（问题已带入；点击复制专业复核问题，再到 JoyCode 粘贴。不会自动发送。）')
        return True

    def copy_handoff(self):
        if self._handoff_signature is not None and self._handoff_signature != source_signature(self.agent_panel._source()):
            self.state_text.set('（会话或证据目录已切换，请从 Agent 重新转交）')
            return False
        if not self.sync(force=True):
            return False
        text = self._handoff_question or '请复核当前选定会话的最近疑似事件与证据状态。'
        reference = self.event_ref.get().strip()
        if reference:
            if len(reference)!=64 or any(c not in '0123456789abcdefABCDEF' for c in reference):
                self.state_text.set('（请先核对完整 event_ref）')
                return False
            text += '\n（请核对完整 event_ref：'+reference.upper()+'）'
        text += '\n（请先用 examguard 查询当前选定会话，再核对事件类型、证据状态和可查看图像；不要把 UID 当作事件类型，不凭缺图推断丢包或判定违规。）'
        self.clipboard_clear()
        self.clipboard_append(text)
        self.state_text.set('（已复制问题与事件引用，请到 JoyCode 粘贴；不会自动发送图片或模型配置。）')
        return True

    def go_daily(self):
        if self.return_to_agent is not None:
            self.return_to_agent(self.event_ref.get().strip())
        else:
            self.agent_panel.prepare_daily_review(self.event_ref.get().strip())

    def show_configuration(self):
        root = Path(__file__).resolve().parents[2]
        sources = [('Skills', root/'skill/examguard-review/SKILL.md'),
                   ('Rule', root/'docs/agent_upgrade_20261030/agent_rule.md'),
                   ('Prompt', root/'docs/agent_upgrade_20261030/agent_prompt.txt')]
        dialog = tk.Toplevel(self)
        dialog.title('（专业智能体配置：Skills / Rule / Prompt）')
        dialog.geometry('840x580')
        ttk.Label(dialog, text='（这是本工程的现有配置参考；可在 JoyCode 中修改成自己的复核流程。匹配规则沿用 *，仅用于此助手。）', wraplength=800).pack(fill='x', padx=12, pady=10)
        tabs = ttk.Notebook(dialog)
        tabs.pack(fill='both', expand=True, padx=12)
        content = {}
        for name,path in sources:
            frame = ttk.Frame(tabs)
            tabs.add(frame,text='（'+name+'）')
            try:text=path.read_text(encoding='utf-8')
            except OSError:text='（配置文件不可读，请检查本地工程目录。）'
            area=ScrolledText(frame,wrap='word',font=('Microsoft YaHei UI',10))
            area.pack(fill='both',expand=True)
            area.insert('1.0',text);area.configure(state='disabled')
            content[str(frame)]=text
        def copy():
            self.clipboard_clear();self.clipboard_append(content[tabs.select()])
            self.state_text.set('（已复制所选配置，请到 JoyCode 对应配置项粘贴。）')
        ttk.Button(dialog,text='（复制当前配置）',command=copy).pack(pady=10)
        self.configuration_dialog = dialog

    def sync(self, *, force=False):
        if self._closed:
            return False
        try:
            source = self.agent_panel._source()
            self.publisher.publish(source, force=force)
            self.path_text.set(str(source.session_path))
            self.evidence_text.set('证据目录：' + str(source.evidence_root))
            self.source_text.set('已联动：' + ('当前采集会话' if source.snapshot is not None else '指定历史存档') +
                                 '；不以此证明设备在线')
            if force:
                self.state_text.set('数据联动就绪。首次更改 MCP 配置后，请在 JoyCode 中重连。')
            return True
        except (OSError, ValueError):
            self.publisher.close()
            self.source_text.set('联动未就绪；不会回退到旧存档')
            self.state_text.set('请检查所选存档及本机目录权限，然后刷新联动。')
            return False

    def _tick(self):
        self._job = None
        if self._closed:
            return
        self.sync()
        result = self.task.poll()
        if result is not None:
            self.review_button.configure(state='normal')
            okay, value = result
            if okay:
                packet, source, signature = value
                if signature != source_signature(self.agent_panel._source()):
                    self.state_text.set('查询期间已切换数据源，请重新打开该事件。')
                else:
                    self.open_evidence(packet, source.evidence_root)
                    self.state_text.set('已跳转图像回放；是否存在可查看图像，以回放页校验结果为准。')
            else:
                self.state_text.set('所选会话中未能确认该事件，请核对完整 event_ref 和会话。')
        self._job = self.after(1000, self._tick)

    def use_current(self):
        self.agent_panel.use_live()
        self.sync(force=True)

    def choose_archive(self):
        self.agent_panel.choose_archive()
        self.sync(force=True)

    def choose_root(self):
        self.choose_evidence()
        self.sync(force=True)

    def copy_config(self):
        if not self.sync(force=True):
            return
        text = json.dumps(joycode_mcp_config(self.publisher.path), ensure_ascii=False, indent=2)
        self.clipboard_clear()
        self.clipboard_append(text)
        self.state_text.set('已复制 MCP 配置。请替换 JoyCode 中的 examguard 配置并重连一次。')

    def open_joycode(self):
        if not self.sync(force=True):
            return
        try:
            launch_joycode()
            self.state_text.set('已请求打开 JoyCode，请选择“智察考场·证据复核助手”对话。')
        except OSError:
            self.state_text.set('未能启动快捷方式，请手动打开 JoyCode；数据联动仍可用。')

    def review(self):
        if self.task.active:
            return
        reference = self.event_ref.get().strip()
        if len(reference) != 64 or any(c not in '0123456789abcdefABCDEF' for c in reference):
            self.state_text.set('请粘贴完整的64位 event_ref；UID不能替代完整事件引用。')
            return
        source = self.agent_panel._source()
        signature = source_signature(source)
        def resolve():
            packet = AgentTools(source).resolve_event(reference)
            return packet, source, signature
        self.task.start(resolve)
        self.review_button.configure(state='disabled')
        self.state_text.set('正在核对事件与所选会话…')

    def close(self):
        if self._closed:
            return
        self._closed = True
        if self._job is not None:
            self.after_cancel(self._job)
            self._job = None
        self.publisher.close()

    def _destroyed(self, event):
        if event.widget is self:
            self.close()
