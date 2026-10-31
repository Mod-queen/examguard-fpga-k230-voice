"""K230 original-source viewer. Overlay is display-only, not burned into evidence."""
from pathlib import Path
import json
import sqlite3
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

from .exam_events import format_event
from .k230_evidence import load_captures, bind_manual, export_source_report, ppm_pixels, verify_assets


class K230EvidenceBrowser(ttk.Frame):
    def __init__(self, parent, model, show_ov5640=None):
        super().__init__(parent, padding=10)
        self.model = model
        self.show_ov5640 = show_ov5640
        self.root = Path(__file__).resolve().parents[1] / 'k230_evidence'
        self.records = []
        self.current = None
        self.image = None
        bar = ttk.Frame(self)
        bar.pack(fill='x')
        for label, action in [('选择K230目录', self.choose), ('刷新并校验', self.refresh),
                              ('人工关联FPGA事件', self.link), ('查看关联OV5640', self.open_ov5640),
                              ('导出识别证据报告', self.report)]:
            ttk.Button(bar, text=label, command=action).pack(side='left', padx=3)
        self.info = tk.StringVar()
        ttk.Label(self, textvariable=self.info, wraplength=900).pack(fill='x')
        ttk.Label(self, text='K230独立时钟；不按时间自动绑定。候选帧不代表FPGA已接受事件；人工关联不是协议确证。',
                  wraplength=900).pack(fill='x')
        self.tree = ttk.Treeview(self, columns=('id', 'trigger', 'time', 'source'), show='headings', height=5)
        for col, text in [('id', '识别帧ID'), ('trigger', '候选'), ('time', 'K230运行内 ms'), ('source', '依据来源')]:
            self.tree.heading(col, text=text)
        self.tree.pack(fill='x')
        self.tree.bind('<<TreeviewSelect>>', self.select)
        self.asset = tk.StringVar(value='inference.rgb')
        choices = ttk.Combobox(self, textvariable=self.asset, values=['inference.rgb', 'color.rgb'], state='readonly')
        choices.pack(anchor='w')
        choices.bind('<<ComboboxSelected>>', lambda _e: self.show())
        self.canvas = tk.Canvas(self, width=640, height=480, background='#101820')
        self.canvas.pack(fill='both', expand=True)
        self.detail = tk.StringVar()
        ttk.Label(self, textvariable=self.detail, wraplength=900).pack(fill='x')
        self.refresh()

    def choose(self):
        path = filedialog.askdirectory(initialdir=self.root)
        if path:
            self.root = Path(path)
            self.refresh()

    def refresh(self):
        self.current = None
        self.canvas.delete('all')
        self.records, errors = load_captures(self.root)
        self.tree.delete(*self.tree.get_children())
        for i, record in enumerate(self.records):
            m = record['manifest']
            self.tree.insert('', 'end', iid=str(i), values=(m['capture_id'], ','.join(m['triggers']),
                m['captured_ms'], (m.get('observation') or {}).get('source', 'gaze')))
        self.info.set(f'{self.root} | SHA256通过 {len(self.records)}条 | 异常 {len(errors)}条' +
                      (' | '+errors[0] if errors else ''))
        self.detail.set('选择识别帧。原图保留完整分辨率；彩色框仅在查看器叠加。')

    def select(self, _event=None):
        selection = self.tree.selection()
        if selection:
            self.current = self.records[int(selection[0])]
            self.show()

    def show(self):
        self.canvas.delete('all')
        if self.current is None:
            return
        m = self.current['manifest']
        asset = next((a for a in m['assets'] if a['file'] == self.asset.get()), None)
        if asset is None:
            self.detail.set('该条没有颜色辅助图；不可用推理帧冒充颜色采样帧。')
            return
        try:
            verify_assets(self.current['path'], m)
            # Derive display from reverified raw bytes, not an editable cached PPM.
            pixels = (self.current['path'] / asset['file']).read_bytes()
            image = tk.PhotoImage(master=self, data=ppm_pixels(pixels, asset), format='PPM')
            scale = max(1, (image.width()+639)//640, (image.height()+479)//480)
            self.image = image.subsample(scale, scale)
            self.canvas.create_image(0, 0, anchor='nw', image=self.image)
            obs = m.get('observation') or {}
            boxes = []
            if asset['role'] == 'inference_source':
                coordinate_size = m.get('settings', {}).get('box_coordinate_size', [asset['width'], asset['height']])
                for det in m.get('raw_detections', []):
                    boxes.append((det['box'], '#60a5fa', f"{det['label']} {det['raw_score']:.3f}"))
                if obs.get('fresh') and obs.get('source') != 'purple_color':
                    boxes.append((obs['box'], '#f87171', str(obs.get('source'))))
                for box in (m.get('gaze') or {}).get('boxes', []):
                    boxes.append((box, '#fbbf24', 'gaze sample'))
            else:
                coordinate_size = [asset['width'], asset['height']]
                colors = m.get('color') or {}
                boxes.extend((b, '#c084fc', 'purple colour') for b in colors.get('purple', []))
                boxes.extend((b, '#38bdf8', 'blue colour') for b in colors.get('blue', []))
            sx = asset['width']/coordinate_size[0]/scale
            sy = asset['height']/coordinate_size[1]/scale
            for (x, y, w, h), color, label in boxes:
                self.canvas.create_rectangle(x*sx, y*sy, (x+w)*sx, (y+h)*sy, outline=color, width=2)
                self.canvas.create_text(x*sx+2, max(0, y*sy-12), text=label, fill=color, anchor='nw')
            link = self.current['path'] / 'manual_link.json'
            linked = '未关联FPGA事件'
            if link.exists():
                data = json.loads(link.read_text(encoding='utf-8'))
                linked = f"人工关联：采集会话 {data['host_session_id']} / 接收#{data['receipt_id']}（非协议确认）"
            self.detail.set(f"帧{m['frame_id']} | {asset['role']} {asset['width']}×{asset['height']} | "
                f"原始模型分数={obs.get('raw_score')} 策略分数={obs.get('policy_score')} | {linked}")
        except (OSError, ValueError, KeyError, tk.TclError) as exc:
            self.detail.set('图像查看失败：'+str(exc))

    def link(self):
        if self.current is None:
            messagebox.showinfo('人工关联', '先选择一条K230识别帧。')
            return
        try:
            session = self.model.session_archive()
            if session is None:
                raise ValueError('当前未启用采集会话存档')
        except (OSError, ValueError, sqlite3.Error) as exc:
            messagebox.showerror('无法关联', str(exc))
            return
        dialog = tk.Toplevel(self)
        dialog.title('人工核对后选择FPGA AL记录（非精确ID绑定）')
        tree = ttk.Treeview(dialog, columns=('id', 'utc', 'ms', 'code'), show='headings', height=12)
        for col, text in [('id', '接收序号'), ('utc', 'PC接收 UTC'), ('ms', 'FPGA时间 ms'), ('code', '事件')]:
            tree.heading(col, text=text)
        tree.pack(fill='both', expand=True)
        for i, entry in enumerate(session.events):
            tree.insert('', 'end', iid=str(i), values=(entry.receipt_id, entry.received_at,
                                                     entry.packet.timestamp, format_event(entry.packet.event_code)))
        record = self.current

        def confirm():
            selected = tree.selection()
            if not selected:
                return
            try:
                bind_manual(record['path'], session.events[int(selected[0])], session.host_session_id)
            except (OSError, ValueError) as exc:
                messagebox.showerror('关联失败', str(exc), parent=dialog)
                return
            dialog.destroy()
            self.show()

        ttk.Label(dialog, text='请结合实际动作与OV5640回放人工核对；K230时间不能直接与FPGA时间比较。').pack()
        ttk.Button(dialog, text='确认人工关联', command=confirm).pack()

    def report(self):
        path = filedialog.asksaveasfilename(defaultextension='.md', initialfile='K230识别证据.md')
        if path:
            try:
                export_source_report(path, self.root)
            except (OSError, ValueError) as exc:
                messagebox.showerror('导出失败', str(exc))
            else:
                self.info.set('报告已保存：'+path)

    def open_ov5640(self):
        if self.current is None or self.show_ov5640 is None:
            return
        try:
            link = json.loads((self.current['path'] / 'manual_link.json').read_text(encoding='utf-8'))
            session = self.model.session_archive()
            if session is None or link['host_session_id'] != session.host_session_id:
                raise ValueError('关联属于其他采集会话；请打开对应会话报告，不跨场强行定位')
            entry = next(e for e in session.events if e.receipt_id == link['receipt_id'])
            self.show_ov5640(entry.packet, getattr(entry, "identity", None))
        except (OSError, ValueError, KeyError, StopIteration, sqlite3.Error) as exc:
            messagebox.showerror('无法定位过程画面', str(exc))
