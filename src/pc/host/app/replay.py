"""Tk evidence browser, using native PPM/PGM support."""

import tkinter as tk
import hashlib
from dataclasses import replace
from functools import partial
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
from threading import Event

from .review import (load_evidence_review, export_report, candidate_windows, evidence_state, history_details,
                     candidate_summary, exact_window, transaction_windows, legacy_transaction_candidates)
from .transaction_protocol import TransactionEventPacket
from .history_association import read_history_record
from .background_task import BackgroundTask
from .event_store import load_session
from .evidence_capacity import scan_evidence_capacity


def _export_report(root, path, snapshot):
    """Read DB on an independent connection, without holding the live model lock."""
    windows, errors = load_evidence_review(root)
    session = load_session(snapshot.session_path) if snapshot.session_path else None
    if session:
        session = replace(session, event_packets=max(session.event_packets, snapshot.event_packets),
                          persistence_failures=max(session.persistence_failures,
                                                   snapshot.event_packets - snapshot.persisted_events),
                          persistence_error=snapshot.persistence_error or session.persistence_error,
                          transaction_packets=max(session.transaction_packets, snapshot.transaction_packets),
                          transaction_failures=max(session.transaction_failures,
                                                   snapshot.transaction_packets - snapshot.persisted_transactions),
                          status_packets=max(session.status_packets, snapshot.status_packets),
                          status_failures=max(session.status_failures, snapshot.status_failures),
                           anchor_packets=max(session.anchor_packets, snapshot.anchor_packets),
                           anchor_failures=max(session.anchor_failures, snapshot.anchor_failures),
                           maintenance_packets=max(session.maintenance_packets, snapshot.maintenance_packets),
                           maintenance_failures=max(session.maintenance_failures, snapshot.maintenance_failures),
                           board_packets=max(session.board_packets,snapshot.board_packets),
                           board_failures=max(session.board_failures,snapshot.board_failures))
    export_report(path, snapshot, windows, errors, session=session)
    return str(path)


def _export_package(root, path, session_path):
    from .evidence_package import export_evidence_package
    return export_evidence_package(root, path, session_path=session_path)


class EvidenceBrowser(ttk.Frame):
    def __init__(self, parent, model, root=None):
        super().__init__(parent, padding=10)
        self.model = model
        self.root = Path(root) if root is not None else Path(__file__).resolve().parents[1] / "evidence_out"
        self.windows = []
        self.current = None
        self.event = None
        self.identity = None
        self.index = 0
        self.job = None
        self.image = None
        self.file_task = BackgroundTask()
        self.scan_task = BackgroundTask()
        self._scan_poll = None
        self._scan_root = None
        self._scan_again = False
        self._scan_cancel = None
        self.errors = []
        self._task_poll = None
        self._task_kind = None
        self._task_path = None
        self._task_root = None
        self.bind('<Destroy>', self._destroy_browser, add='+')
        bar = ttk.Frame(self)
        bar.pack(fill="x")
        self._file_buttons = []
        for label, action in (("选择证据目录", self.choose), ("刷新", self.refresh), ("全部窗口", self.show_all),
                              ("导出监考报告", self.report), ('导出取证包', self.package),
                              ('查看容量', self.capacity)):
            button = ttk.Button(bar, text=label, command=action)
            button.pack(side="left", padx=3)
            if action in (self.report, self.package, self.capacity):
                self._file_buttons.append(button)
        self.task_info = tk.StringVar(value='报告/取证导出和容量盘点在后台执行；容量盘点不删除文件。')
        ttk.Label(self, textvariable=self.task_info, wraplength=1000).pack(fill='x')
        self.info = tk.StringVar()
        ttk.Label(self, textvariable=self.info).pack(fill="x")
        self.match_info = tk.StringVar(value="实时事件页双击事件，查找候选图像；未确认跨会话绑定")
        ttk.Label(self, textvariable=self.match_info, wraplength=700).pack(fill="x")
        self.tree = ttk.Treeview(self, columns=("window", "count", "time", "history"), show="headings", height=5)
        for col, name in (("window", "证据窗口"), ("count", "像素 / 联合状态"), ("time", "板内时间 ms"), ("history", "HR历史结果 / 缺口")):
            self.tree.heading(col, text=name)
        self.tree.column('history', width=340)
        self.tree.pack(fill="x")
        self.tree.bind("<<TreeviewSelect>>", self.select)
        self.preview = ttk.Label(self, anchor="center")
        self.preview.pack(fill="both", expand=True)
        self.frame_info = tk.StringVar(value="选择窗口查看图像；图像窗口尚未自动绑定告警")
        ttk.Label(self, textvariable=self.frame_info).pack()
        self.history_info = tk.StringVar(value='选择窗口查看HR结果与缺口；不以像素完整代替历史覆盖')
        ttk.Label(self, textvariable=self.history_info, wraplength=1000).pack(fill='x')
        controls = ttk.Frame(self)
        controls.pack()
        for label, action in (("上一帧", lambda: self.step(-1)), ("下一帧", lambda: self.step(1)),
                              ("播放（5帧/秒）", self.play), ("暂停", self.pause)):
            ttk.Button(controls, text=label, command=action).pack(side="left", padx=3)
        self.refresh()

    def choose(self):
        path = filedialog.askdirectory(initialdir=self.root)
        if path:
            self.root = Path(path)
            self.event = self.identity = None
            self.refresh()

    def show_all(self):
        self.event = self.identity = None
        self.match_info.set('全部窗口：选择一行查看；双击实时事件可优先定位对应窗口。')
        self.refresh()

    def refresh(self):
        if not self.scan_task.active and self._scan_poll is not None:
            self.after_cancel(self._scan_poll)
            self._scan_poll = None
        self.pause()
        self.current = None
        self.preview.configure(image="")
        self.windows, self.errors = [], []
        self.tree.delete(*self.tree.get_children())
        self.info.set(f'{self.root} | 正在优先核验所选事件…' if self.event is not None else
                      f'{self.root} | 后台核验最新证据，等待扫描完成…')
        self.frame_info.set('正在核验原始包CRC与图像哈希，请稍候…')
        if self.scan_task.active:
            if self._scan_cancel is not None:
                self._scan_cancel.set()
            self._scan_again = True
            return
        self._scan_root = self.root.resolve()
        self._scan_again = False
        self._scan_cancel = Event()
        if self.event is None:
            self.scan_task.start(partial(load_evidence_review, self._scan_root, cancelled=self._scan_cancel))
        else:
            self.scan_task.start(partial(load_evidence_review, self._scan_root, event=self.event,
                                         identity=self.identity, cancelled=self._scan_cancel))
        self._scan_poll = self.after(50, self._poll_scan)

    def _poll_scan(self):
        self._scan_poll = None
        outcome = self.scan_task.poll()
        if outcome is None:
            self._scan_poll = self.after(50, self._poll_scan)
            return
        if self._scan_again or self.root.resolve() != self._scan_root:
            self.refresh()
            return
        ok, result = outcome
        self.windows, self.errors = result if ok else ([], [str(result)])
        self._render_index = 0
        self._render_scan_batch()

    def _render_scan_batch(self):
        # Bounded Tk work per tick, independent of directory/file scan size.
        self._scan_poll = None
        if self.root.resolve() != self._scan_root:
            self.refresh()
            return
        stop = min(self._render_index + 100, len(self.windows))
        for i in range(self._render_index, stop):
            w = self.windows[i]
            frames = w["frames"]
            span = f"{frames[0]['timestamp_ms']}–{frames[-1]['timestamp_ms']}" if frames else "无帧"
            label = (w['protocol'] + ' ' + '/'.join(map(str, w['identity']))) if w.get('protocol') in ('EGv2', 'HR') else w['path'].name
            self.tree.insert("", "end", iid=str(i), values=(label,
                             f"{len(frames)}/{w['expected'] if w['expected'] is not None else '?'} {evidence_state(w)}", span,
                              history_details(w) if w.get('history_verdict') else '旧PGv1无HR'))
        self._render_index = stop
        if stop < len(self.windows):
            self._scan_poll = self.after(1, self._render_scan_batch)
            return
        scope='所选事件优先核验' if self.event is not None else '全部窗口'
        self.info.set(f"{self.root} | {scope} | {len(self.windows)}窗 | {len(self.errors)}项读取异常")
        self.frame_info.set("EGv2：像素原包/图像哈希复核；HR：结果CRC/哈希复核，缺口与像素完整性分列。")
        self.history_info.set('选择窗口查看HR；未收到结果、像素缺片和历史gap分别显示。')
        if self.event is not None:
            self._match_event()

    def find_event(self, packet, identity=None):
        self.event = packet
        self.identity = identity
        self.refresh()

    def _match_event(self):
        if isinstance(self.event, TransactionEventPacket):
            candidates, explanation = transaction_windows(self.event, self.windows)
            self.match_info.set(f'ET {self.event.identity}：{explanation}')
            self._highlight(candidates)
            return
        # Exact binding first: the AL's EI event_seq is the same sequence the
        # image window carries. Only fall back to time+frame candidates when no
        # EI sequence is available (v1/v2.0) or no window matches it.
        seq = getattr(self.identity, "event_seq", None)
        exact = exact_window(seq, self.windows)
        if exact:
            candidates = exact
            self.match_info.set(f"事件序号 {seq}：已精确绑定证据窗口 "
                                + ", ".join(w["path"].name for w in exact)
                                + "（序号来自EI；窗口未复验像素CRC）")
        else:
            candidates = candidate_windows(self.event, self.windows)
            reason = "无事件序号，退回时间+帧候选" if seq is None else f"序号{seq}无匹配窗口，退回时间+帧候选"
            self.match_info.set(f"事件 {self.event.timestamp} ms / 0x{self.event.event_code:02X}："
                                 + candidate_summary(candidates) + f"（{reason}）")
            if not candidates:
                candidates=legacy_transaction_candidates(self.event,self.identity,self.windows)
                self.match_info.set(f'旧AL事件：同设备/启动/会话、事件码及源时间邻近的EGv2候选 {len(candidates)} 个；'
                                    '旧AL的UID不能当ET身份，请核对画面；双击ET行可精确关联。')
        self._highlight(candidates)

    def _highlight(self, candidates):
        for i, window in enumerate(self.windows):
            self.tree.item(str(i), tags=("candidate",) if window in candidates else ())
        self.tree.tag_configure("candidate", foreground="#0284c7")
        if len(candidates) == 1:
            item = str(self.windows.index(candidates[0]))
            self.tree.selection_set(item)
            self.tree.see(item)
            self.select()

    def select(self, _event=None):
        self.pause()
        selection = self.tree.selection()
        if selection:
            self.current = self.windows[int(selection[0])]
            self.index = 0
            self.show()

    def show(self):
        if self.current:
            try:
                for record in self.current.get('history', ()):
                    if read_history_record(record.manifest_path) != record:
                        raise ValueError('HR result changed since refresh')
            except (OSError, ValueError, KeyError, TypeError) as exc:
                self.pause()
                self.preview.configure(image='')
                self.history_info.set(f'证据校验失败：{exc}')
                self.frame_info.set('HR读取失败，刷新后重新核对')
                return
            self.history_info.set(evidence_state(self.current) + '；' + history_details(self.current)
                                  if self.current.get('history_verdict') else 'PGv1无HR历史结果')
        if not self.current or not self.current["frames"]:
            self.preview.configure(image="")
            self.frame_info.set("该窗口没有可回放帧")
            return
        f = self.current["frames"][self.index]
        try:
            if self.current.get('protocol') == 'EGv2':
                # load_windows already verified raw CRC/context/frame bytes.
                # Recheck the selected preview at use without rereading every
                # frame and reassembling a 40-frame archive on each play tick.
                preview = (self.current['path']/f['file']).read_bytes()
                if hashlib.sha256(preview).hexdigest() != f['sha256']:
                    raise ValueError('EGv2 preview hash changed since refresh')
                self.image = tk.PhotoImage(master=self, data=preview, format='PPM')
            else:
                self.image = tk.PhotoImage(master=self, file=str(self.current["path"] / f["file"]))
            self.image = self.image.zoom(2, 2)
            self.preview.configure(image=self.image)
            self.frame_info.set(f"帧 {f['index']} | frame_id={f['frame_id']} | {f['timestamp_ms']} ms")
        except (tk.TclError, OSError, ValueError, KeyError, TypeError) as exc:
            self.pause()
            self.preview.configure(image="")
            self.frame_info.set(f"图像读取失败：{exc}")

    def step(self, delta):
        self.pause()
        if self.current and self.current["frames"]:
            self.index = max(0, min(self.index + delta, len(self.current["frames"]) - 1))
            self.show()

    def play(self):
        self.pause()
        if self.current and self.current["frames"]:
            self.show()
            if self.index + 1 < len(self.current["frames"]):
                self.index += 1
                self.job = self.after(200, self.play)

    def pause(self):
        if self.job is not None:
            self.after_cancel(self.job)
            self.job = None

    def report(self):
        if self.file_task.active:
            return
        path = filedialog.asksaveasfilename(defaultextension=".md", initialfile="监考报告.md")
        if path:
            self._start_file_task('报告', path, partial(_export_report, self.root.resolve(),
                                                     Path(path), self.model.snapshot()))

    def package(self):
        if self.file_task.active:
            return
        path = filedialog.asksaveasfilename(defaultextension='.zip', initialfile='ExamGuard取证包.zip')
        if path:
            self._start_file_task('取证包', path, partial(_export_package, self.root.resolve(),
                                                       Path(path), self.model.snapshot().session_path))

    def capacity(self):
        if not self.file_task.active:
            self._start_file_task('容量', None, partial(scan_evidence_capacity, self.root.resolve()))

    def _start_file_task(self, kind, path, action):
        if not self.file_task.start(action):
            return
        self._task_kind, self._task_path, self._task_root = kind, path, self.root.resolve()
        for button in self._file_buttons:
            button.state(['disabled'])
        self.task_info.set(f'{kind}后台处理中：{self._task_root}；正常关闭窗口仍会等待该文件任务结束。')
        self._task_poll = self.after(50, self._poll_file_task)

    def _poll_file_task(self):
        self._task_poll = None
        outcome = self.file_task.poll()
        if outcome is None:
            self._task_poll = self.after(50, self._poll_file_task)
            return
        for button in self._file_buttons:
            button.state(['!disabled'])
        ok, result = outcome
        if not ok:
            self.task_info.set(f'{self._task_kind}处理失败：{result}')
            messagebox.showerror(f'{self._task_kind}处理失败', result)
        elif self._task_kind == '容量':
            kinds = result['bytes_by_kind']
            mib = lambda value: f'{value / 1024**2:.1f} MiB'
            self.task_info.set(
                f'容量盘点 [{self._task_root}]：{result["total_files"]}文件 / {mib(result["total_file_bytes"])}；'
                f'最新EG {mib(kinds.get("latest_published_EG", 0))}，'
                f'旧/未发布revision {mib(kinds.get("older_or_unpublished_revision", 0))}，'
                f'pending {mib(kinds.get("unpublished_pending", 0))}；'
                f'磁盘余量 {result["disk_free_bytes"] / 1024**3:.2f} GiB，'
                f'跳过链接{len(result["skipped_links"])}。逻辑字节、非完整性核验；不自动删除。')
        else:
            if self._task_kind == '取证包':
                text = f'取证包已保存并校验：{result["files"]}文件 | {self._task_path}'
            else:
                text = f'报告已保存：{self._task_path}'
            self.task_info.set(f'{text} | 来源：{self._task_root}')
            self.info.set(text)

    def _destroy_browser(self, event):
        if event.widget is not self:
            return
        self.pause()
        if self._task_poll is not None:
            self.after_cancel(self._task_poll)
            self._task_poll = None
        if self._scan_poll is not None:
            self.after_cancel(self._scan_poll)
            self._scan_poll = None
        if self._scan_cancel is not None:
            self._scan_cancel.set()
