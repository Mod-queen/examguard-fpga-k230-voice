"""Visible worker status/configuration and useful logs in the dashboard."""
import os
import queue
import tkinter as tk
from tkinter import ttk, messagebox

from .services import save_config


class ServicePanel(ttk.Frame):
    def __init__(self, parent, services, config_path):
        super().__init__(parent, padding=12)
        self.services = services
        self.config_path = config_path
        ttk.Label(self, text='一键启动：监考台 + FPGA串口桥 + OV5640图像接收 + K230识别运行',
                  wraplength=850).pack(anchor='w')
        ttk.Label(self, text='K230先检查识别流，已运行则只接续监听；未检测到才启动。none表示当前无目标，识别模式不上传K230原图。',
                  wraplength=850).pack(anchor='w')
        self.values = {}
        for key, title in [('fpga', 'FPGA串口'), ('images', 'OV5640图像'), ('k230', 'K230识别')]:
            variable = tk.StringVar(value=title+'：等待启动')
            self.values[key] = (title, variable)
            ttk.Label(self, textvariable=variable, wraplength=850).pack(fill='x', pady=5)
        form = ttk.Frame(self)
        form.pack(fill='x')
        self.ports = {}
        for key, title in [('fpga_port', 'FPGA串口'), ('k230_port', 'K230串口')]:
            ttk.Label(form, text=title).pack(side='left', padx=4)
            variable = tk.StringVar(value=services.config[key])
            self.ports[key] = variable
            ttk.Entry(form, textvariable=variable, width=12).pack(side='left')
        ttk.Button(form, text='保存端口（下次启动生效）', command=self.save).pack(side='left', padx=8)
        buttons = ttk.Frame(self)
        buttons.pack(fill='x', pady=8)
        ttk.Button(buttons, text='启动缺失服务', command=self.start_missing).pack(side='left')
        ttk.Button(buttons, text='打开本次日志目录', command=self.open_logs).pack(side='left', padx=8)
        ttk.Label(self, text='日常无需deploy。更新板端程序才部署；CanMV IDE与K230接收器独占串口。\n'
                  '关闭监考台会统一停止本次采集；旧证据和会话存档保留。缺设备接好后可启动缺失服务。',
                  wraplength=850).pack(anchor='w')
        self.text = tk.Text(self, height=18, wrap='word', state='disabled')
        self.text.pack(fill='both', expand=True, pady=8)
        self.after(200, self.poll)

    def poll(self):
        for _ in range(200):
            try:
                kind, name, text = self.services.events.get_nowait()
            except queue.Empty:
                break
            if kind == 'status':
                title, variable = self.values[name]
                variable.set(title+'：'+text)
            else:
                self.text.configure(state='normal')
                self.text.insert('end', f'[{name}] {text}\n')
                if int(self.text.index('end-1c').split('.')[0]) > 300:
                    self.text.delete('1.0', '101.0')
                self.text.see('end')
                self.text.configure(state='disabled')
        self.after(200, self.poll)

    def save(self):
        try:
            save_config(self.config_path, {**self.services.config,
                **{key: variable.get() for key, variable in self.ports.items()}})
        except (OSError, ValueError) as exc:
            messagebox.showerror('配置错误', str(exc), parent=self)
        else:
            messagebox.showinfo('端口已保存', '关闭并重新一键启动后生效。', parent=self)

    def start_missing(self):
        try:
            self.services.start_missing()
        except (OSError, ValueError) as exc:
            messagebox.showerror('启动失败', str(exc), parent=self)

    def open_logs(self):
        if self.services.log_dir is not None:
            os.startfile(self.services.log_dir)
