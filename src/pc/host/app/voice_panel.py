"""Non-modal preparation/help surface. Sending is not a handling acknowledgement."""
import socket
from dataclasses import replace
from pathlib import Path
import time
import tkinter as tk
from tkinter import ttk

from .voice_protocol import encode_voice_command
from .voice_roster import load_voice_roster
from .candidate_display import encode_display


EXAM_STATES = ('等待S3', '提示排队', '提示写入中', '等待新回复', '检查准备',
               '准备完成，待开考', '等待开考状态', '考试中', '考中等待新回复',
               '准备回复超时', '交互故障', '考试已结束')
INFO_STATES = ('等待配置/信息呈现', '核对提示排队', '核对提示写入中', '等待播报结束及新回复',
               '请回复“信息正确”或“信息有误”', '信息已确认，可按S3', '信息有误，待老师处理',
               '信息回复超时，请重新核对', '信息交互故障，请重新核对')


class VoicePanel(ttk.Frame):
    def __init__(self, parent, model, downlink_host, downlink_port, roster_path=None):
        super().__init__(parent, padding=12)
        self.model = model
        self.address = (downlink_host, downlink_port)
        self.current = None
        self.receipt = 0
        self.received_at = 0
        self.pending = None
        self.last_heartbeat = time.monotonic()
        self.heartbeat_token = max(1, int(time.time()))
        self.next_token = max(1, int(time.time()))
        self.board_highwater = {}
        self.seq_highwater = {}
        self.roster_path = Path(roster_path) if roster_path else Path(__file__).resolve().parents[1]/'voice_roster.json'
        self.roster = {}
        self.roster_error = None
        self.presentation_sent = set()
        self.auto_configured = set()
        self.display_sent = {}
        self._presentation_job = None
        self.summary = tk.StringVar(value='语音交互：尚未收到VI状态（需新候选位流）')
        self.candidate_text = tk.StringVar(value='考生信息：等待名册与核验结果')
        self.help_text = tk.StringVar(value='求助状态未知')
        self.result = tk.StringVar(value='求助不暂停考试计时；“已处理”需板上回执确认。')
        ttk.Label(self, textvariable=self.summary, wraplength=800).pack(anchor='w', pady=5)
        self.candidate_label = ttk.Label(self, textvariable=self.candidate_text, wraplength=800)
        self.candidate_label.pack(anchor='w', pady=5)
        ttk.Label(self, text='语音操作：先说“小幻小幻”唤醒；核对后说“信息正确”或“信息有误”。\n'
                            '老师按S3后检查准备，再说“准备好了”；需要时说“需要帮助”。',
                  wraplength=800).pack(anchor='w', pady=5)
        ttk.Button(self, text='重新读取名册', command=self.reload_roster).pack(anchor='w')
        ttk.Button(self, text='应用当前名册 / 重新核对信息', command=self.configure_information).pack(anchor='w', pady=4)
        ttk.Label(self, textvariable=self.help_text, wraplength=800).pack(anchor='w', pady=5)
        self.button = ttk.Button(self, text='老师：该求助已处理', command=self.handle_help)
        self.button.pack(anchor='w', pady=8)
        ttk.Label(self, textvariable=self.result, wraplength=800).pack(anchor='w')
        self._poll_job = self.after(100, self.poll)
        self.bind('<Destroy>', self._destroy, add='+')
        self.reload_roster()

    def reload_roster(self):
        # Explicit operator action also permits a new, higher-token presentation
        # receipt if a previous send had no board acknowledgement. Never auto-retry.
        self.presentation_sent.clear()
        self.display_sent.clear()
        try:
            self.roster = load_voice_roster(self.roster_path)
            self.roster_error = None
        except (ValueError, OSError) as exc:
            self.roster = {}
            self.roster_error = str(exc)
        self.candidate_text.set('名册已读取，等待匹配核验记录。' if not self.roster_error else f'名册错误：{self.roster_error}')
        if self.current:
            self.show_candidate(self.current)

    def show_candidate(self, p):
        candidate = self.roster.get(p.face)
        if candidate and candidate[2] == p.info_tag:
            self.candidate_text.set(f'姓名：{candidate[0]}　考号：{candidate[1]}　考位：{p.seat}')
        else:
            self.candidate_text.set('考生信息未呈现：名册缺失或修订不匹配，请先填写并核对名册。')

    def present_information(self):
        self._presentation_job = None
        p = self.current
        candidate = self.roster.get(p.face) if p else None
        initial = p and p.stage==2 and p.info_state==0 and p.exam_state==0 and p.info_tag==1
        initial_key = (p.device,p.boot,p.round_id) if p else None
        if (initial and candidate and self.fresh() and
                initial_key not in self.auto_configured):
            self.auto_configured.add(initial_key)
            self.configure_information()
            return
        if (not self.fresh() or p.stage != 2 or candidate is None or candidate[2] != p.info_tag or
                p.binding in self.presentation_sent or self.pending):
            return
        # New candidate firmware stages the matching text on HDMI. Keep the
        # ordinary presentation acknowledgement separate from text upload.
        if p.binding not in self.display_sent:
            try:
                token=max(self.next_token,p.command_token+1)
                command=encode_voice_command(5,token,p,encode_display(candidate[0],candidate[1]))
                with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                    sock.sendto(command,self.address)
                self.next_token=token+1;self.display_sent[p.binding]=token
            except (ValueError,OSError) as exc:
                self.result.set(f'HDMI信息未发送：{exc}')
            return
        if p.command_token!=self.display_sent[p.binding] or p.command_op!=5 or p.command_result!=1:
            self.result.set('等待FPGA接收HDMI信息；需要本次显示修复版位流。')
            return
        # Configuration/text transfer must survive a minimized monitor. A
        # visible PC surface OR an explicit matching HDMI frame-applied flag
        # permits VC1; accepting VC5 alone does not claim visible presentation.
        pc_visible = self.winfo_viewable() and self.candidate_label.winfo_viewable()
        if not pc_visible and not p.flags & 64:
            self.result.set('HDMI文本已接收，等待显示帧应用回执；PC窗口可保持最小化。')
            return
        try:
            token = max(self.next_token, p.command_token+1)
            command = encode_voice_command(1, token, p)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.sendto(command, self.address)
        except (ValueError, OSError) as exc:
            self.result.set(f'呈现回执未发送：{exc}')
            return
        self.next_token = token+1
        self.presentation_sent.add(p.binding)
        self.result.set('已呈现匹配名册，呈现回执已发送；等待板上信息确认流程。')

    def fresh(self):
        if self.current is None or not self.current.flags & 1 or time.monotonic()-self.received_at > 3:
            return False
        status = self.model.snapshot().latest_status
        health = status.evidence_health if status else None
        return not health or health.identity[:2] == (self.current.device, self.current.boot)

    def send_command(self, operation, status):
        token = max(self.next_token, status.command_token+1)
        command = encode_voice_command(operation, token, status)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.sendto(command, self.address)
        self.next_token = token+1
        return token

    def configure_information(self):
        p = self.current
        candidate = self.roster.get(p.face) if p else None
        if not p or p.stage != 2 or time.monotonic()-self.received_at > 3 or not candidate:
            self.result.set('未应用：需要当前核验状态与真实姓名/考号名册。')
            return
        try:
            self.send_command(3, replace(p, info_tag=candidate[2]))
        except (ValueError, OSError) as exc:
            self.result.set(f'名册修订请求未发送：{exc}')
            return
        self.result.set('名册修订请求已发送，等待FPGA换轮次；需重新核对与回复。')

    def handle_help(self):
        p = self.current
        if self.pending or not self.fresh() or not p.help_pending:
            self.result.set('未发送：需要新鲜的待处理求助状态。')
            return
        try:
            token = max(self.next_token, p.command_token+1)
            command = encode_voice_command(2, token, p)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.sendto(command, self.address)
        except (ValueError, OSError) as exc:
            self.result.set(f'处理请求未发送：{exc}')
            return
        self.next_token = token+1
        self.pending = (token, p.binding, p.ticket, time.monotonic())
        self.result.set('处理请求已发送，等待FPGA确认；不会提前清除求助。')
        self.button.state(['disabled'])

    def poll(self):
        if self._poll_job is not None:
            self.after_cancel(self._poll_job)
        self._poll_job = None
        snapshot = self.model.snapshot()
        for entry in snapshot.voice:
            if entry.receipt_id <= self.receipt:
                continue
            self.receipt = entry.receipt_id
            p = entry.packet
            board = (p.device, p.boot)
            if p.boot < self.board_highwater.get(p.device, 0) or p.sequence <= self.seq_highwater.get(board, 0):
                continue
            self.board_highwater[p.device] = p.boot
            self.seq_highwater[board] = p.sequence
            self.current = p
            self.received_at = time.monotonic()
            self.summary.set(f'考位{p.seat}｜人脸编号{p.face}｜{INFO_STATES[p.info_state]}｜{EXAM_STATES[p.exam_state]}')
            self.show_candidate(p)
            self.help_text.set((f'{"考中" if p.flags & 32 else "准备期间"}求助 #{p.ticket}：待老师处理'
                                if p.help_pending else '当前无待处理求助') + f'（轮次{p.round_id}）')
            if self.pending:
                token, binding, ticket, _ = self.pending
                if p.binding != binding or p.ticket != ticket:
                    self.result.set('求助上下文已变化，原处理结果请查记录。')
                    self.pending = None
                elif p.command_token == token and p.command_op == 2 and p.command_result:
                    if p.command_result == 1 and p.help_pending:
                        # Endpoint acceptance can reach a snapshot one clock
                        # before the interaction controller consumes the pulse.
                        self.result.set('FPGA已接收处理请求，等待求助状态清除。')
                    else:
                        success = p.command_result == 1 and not p.help_pending
                        self.result.set('FPGA已确认：求助处理完成。' if success else f'FPGA拒绝或未完成处理，结果码{p.command_result}。')
                        self.pending = None
        if self.pending and time.monotonic()-self.pending[3] > 10:
            self.pending = None
            self.result.set('处理回执超时，结果未知；不自动重发，请核对板上状态。')
        # Heartbeat never claims presentation. It runs even on a hidden tab and
        # bootstraps flags=0 status; only advancing VI packets refresh freshness.
        if self.current and time.monotonic()-self.received_at < 3 and time.monotonic()-self.last_heartbeat >= 1:
            try:
                self.heartbeat_token = max(self.heartbeat_token+1, int(time.time()))
                heartbeat = encode_voice_command(4, self.heartbeat_token, self.current)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                    sock.sendto(heartbeat, self.address)
                self.last_heartbeat = time.monotonic()
            except (ValueError, OSError):
                pass
        available = self.fresh() and self.current.help_pending and self.pending is None
        self.button.state(['!disabled'] if available else ['disabled'])
        if self.current and not self.fresh():
            self.summary.set('语音交互状态陈旧或属于旧启动，保留最后读数，禁止处理操作。')
        if self._presentation_job is None:
            self._presentation_job = self.after_idle(self.present_information)
        self._poll_job = self.after(100, self.poll)

    def _destroy(self, event):
        if event.widget is self and self._poll_job is not None:
            self.after_cancel(self._poll_job)
            self._poll_job = None
        if event.widget is self and self._presentation_job is not None:
            self.after_cancel(self._presentation_job)
            self._presentation_job = None
        if event.widget is self:
            # Tk variables must be released here on the UI thread, rather than
            # by a later cyclic GC pass on a background export worker.
            self.summary = self.candidate_text = self.help_text = self.result = None
