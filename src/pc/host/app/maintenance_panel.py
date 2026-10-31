"""Tk control surface using the existing local UART downlink bridge."""
from datetime import datetime, timezone
import json
from pathlib import Path
import socket
import time
import tkinter as tk
from tkinter import ttk

from .maintenance_protocol import encode_command, rtc_payload
from .persistent_config import PersistentConfig, decode_config


class MaintenancePanel(ttk.Frame):
    def __init__(self, parent, model, downlink_port):
        super().__init__(parent, padding=12)
        self.model, self.downlink_port = model, downlink_port
        self.seat = tk.StringVar(value='1')
        self.duration = tk.StringVar(value='2700')
        self.mute = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value='读取/保存仅在非考试维护状态；RTC校时来源：电脑时间，北京时间UTC+8。')
        self.pending = None
        self.next_id = int(time.time())
        self.last_board = None
        self._seen_result = None
        self.audit_path = None
        self.log_error = None
        self._board_received_at = None
        self._board_receipt = None
        self.board_info=tk.StringVar(value='板级监测：未上报（需要监测候选）')
        for row, (label, variable) in enumerate((('考位号（独立于device）', self.seat), ('考试时长/秒（60–7200）', self.duration))):
            ttk.Label(self, text=label).grid(row=row, column=0, sticky='w', pady=4)
            ttk.Entry(self, textvariable=variable).grid(row=row, column=1, sticky='ew')
        ttk.Checkbutton(self, text='默认静音', variable=self.mute).grid(row=2, column=0, sticky='w')
        buttons=ttk.Frame(self);buttons.grid(row=3, column=0, columnspan=2, sticky='w', pady=8)
        self.buttons=[]
        for text, operation in (('读取板上配置', 0), ('保存配置（UTC+8）', 1), ('用电脑北京时间校时', 2)):
            button=ttk.Button(buttons, text=text, command=lambda op=operation:self.send(op))
            button.pack(side='left', padx=3);self.buttons.append(button)
        ttk.Label(self, textvariable=self.status, wraplength=850).grid(row=4, column=0, columnspan=2, sticky='w')
        ttk.Label(self, text='校时不改考试单调计时/UID，也不回填历史RA的时区。超时不自动重发；先读取核对媒体。',
                  wraplength=850).grid(row=5, column=0, columnspan=2, sticky='w', pady=8)
        ttk.Label(self,textvariable=self.board_info,wraplength=850).grid(row=6,column=0,columnspan=2,sticky='w')
        self._poll_job=self.after(100,self.poll)
        self.bind('<Destroy>',self._destroy,add='+')

    def _log(self, value):
        if self.audit_path is None:
            parent=Path(__file__).resolve().parents[1]/'logs'
            if not parent.is_dir():
                raise OSError('host/logs missing')
            self.audit_path=parent/('maintenance_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.jsonl')
            with self.audit_path.open('x',encoding='utf-8'):
                pass
        with self.audit_path.open('a',encoding='utf-8') as target:
            target.write(json.dumps(dict(utc=datetime.now(timezone.utc).isoformat(),**value),ensure_ascii=False)+'\n')

    def send(self, operation):
        if self.pending is not None:
            return
        snapshot=self.model.snapshot()
        status=snapshot.latest_status
        health=status.evidence_health if status else None
        identity=health.identity[:2] if health else None
        if identity is None or not all(identity) or status.state_id in (3,4):
            self.status.set('未发送：需要当前板上身份，且不能在考试中操作。');return
        if identity!=self.last_board:
            self.last_board=identity
            self.next_id=max(self.next_id,int(time.time()))
        last=snapshot.latest_maintenance
        if last and (last.device,last.boot)==identity:
            self.next_id=max(self.next_id,last.request_id+1)
        try:
            payload=bytes(32)
            if operation==1:
                payload=PersistentConfig(int(self.seat.get()),int(self.duration.get()),480,self.mute.get()).encode()
            elif operation==2:
                payload=rtc_payload()
            command=encode_command(operation,self.next_id,*identity,payload)
            self._log({'direction':'request','raw':command.decode().strip(),'source':'PC current time UTC+8' if operation==2 else 'operator configuration'})
            with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
                sock.sendto(command,('127.0.0.1',self.downlink_port))
        except (ValueError,OSError) as exc:
            self.status.set(f'发送失败：{exc}');return
        self.pending=(self.next_id,operation,identity,time.monotonic())
        self.next_id+=1
        for button in self.buttons:button.state(['disabled'])
        self.status.set(f'已发请求#{self.pending[0]}，等待板上操作回执；此状态不代表成功。')

    def poll(self):
        if self._poll_job is not None:
            self.after_cancel(self._poll_job)
        self._poll_job=None
        snapshot=self.model.snapshot();result=snapshot.latest_maintenance
        if snapshot.board_monitors:
            entry=snapshot.board_monitors[-1]
            if self._board_receipt!=entry.receipt_id:
                self._board_receipt=entry.receipt_id;self._board_received_at=time.monotonic()
            text=entry.packet.text()
            if time.monotonic()-self._board_received_at>3:text+='（接收停更）'
            health=snapshot.latest_status.evidence_health if snapshot.latest_status else None
            if health and health.identity[:2]!=(entry.packet.device,entry.packet.boot):text+='（旧boot）'
            self.board_info.set(text)
        if result and result.raw!=self._seen_result:
            self._seen_result=result.raw
            try:self._log({'direction':'response','raw':'MR,'+result.raw.hex().upper()})
            except OSError as exc:self.log_error=str(exc)
        if self.pending:
            token,operation,identity,started=self.pending
            if result and (result.request_id,result.operation,(result.device,result.boot))==(token,operation,identity):
                self.status.set(result.text()+(f' | 日志写入失败：{self.log_error}' if self.log_error else f' | 日志：{self.audit_path}'))
                if result.error==0 and result.config_known:
                    profile=decode_config(result.config_raw)
                    self.seat.set(str(profile.seat_id));self.duration.set(str(profile.exam_duration_s));self.mute.set(profile.mute)
                self.pending=None
            elif time.monotonic()-started>15:
                self.status.set('未收到回执：操作结果未知，不自动重发。恢复连接后先读取配置/RTC核对；旧RTC1不支持维护命令。')
                self.pending=None
            if self.pending is None:
                for button in self.buttons:button.state(['!disabled'])
        self._poll_job=self.after(100,self.poll)

    def _destroy(self,event):
        if event.widget is self and self._poll_job is not None:
            self.after_cancel(self._poll_job);self._poll_job=None
