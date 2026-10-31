"""Small standard-library dashboard for the FPGA monitor."""

from __future__ import annotations

import queue
import socket
import sqlite3
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from .config import (
    ConfigError,
    RegionLayout,
    default_layout,
    load_layout,
    save_layout,
    validate_layout,
)
from .monitor import MonitorModel
from .replay import EvidenceBrowser
from .exam_timer import ExamTimer
from .evidence_health import EvidenceHealthView
from .transaction_protocol import TransactionEventPacket
from .voice_protocol import VoiceStatus
from .protocol import (
    ConfigAckPacket,
    EventPacket,
    EventIdentityPacket,
    EvidenceEndPacket,
    Packet,
    ProtocolError,
    RegionConfig,
    StatusPacket,
    encode_config_request,
)
from .receiver import receive_packets


from .exam_events import (
    RISK_NAMES,
    STAGE_NAMES,
    ZONE_NAMES,
    format_event,
    format_health,
)


class Dashboard(tk.Tk):
    """Tk window that receives packets without blocking the UI thread."""

    POLL_INTERVAL_MS = 100

    def __init__(
        self,
        *,
        host: str,
        port: int,
        config_path: str | Path,
        downlink_host: str = "127.0.0.1",
        downlink_port: int = 5006,
        session_root: str | Path | None = None,
        services=None,
        launch_config_path=None,
        evidence_root=None,
    ) -> None:
        super().__init__()
        self.title("ExamGuard 监考台")
        self.minsize(980, 650)
        self.configure(background="#101820")
        self.protocol("WM_DELETE_WINDOW", self._close)
        self._services = services
        self._launch_config_path = launch_config_path
        self._evidence_root = evidence_root

        self._host = host
        self._port = port
        self._downlink_host = downlink_host
        self._downlink_port = downlink_port
        self._downlink_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._config_path = Path(config_path)
        self._model = MonitorModel(
            session_root=session_root if session_root is not None else Path(__file__).resolve().parents[1] / "sessions",
            session_metadata={"status_endpoint": f"{host}:{port}", "config_path": str(self._config_path),
                              "board_protocol": "ST/AL v1", "application": "ExamGuard"})
        self._packet_queue: queue.Queue[Packet | str] = queue.Queue()
        self._stop_event = threading.Event()
        self._receiver_thread = threading.Thread(
            target=self._receive_packets,
            name="fpga-udp-receiver",
            daemon=True,
        )
        self._selected_region_id: int | None = None
        self._exam_timer = ExamTimer()
        self._evidence_health_view = EvidenceHealthView()
        self._layout_error: str | None = None

        try:
            self._layout = load_layout(self._config_path)
        except ConfigError as exc:
            self._layout = default_layout()
            self._layout_error = str(exc)

        self._setup_styles()
        self._build_ui()
        self._populate_regions()
        if self._layout_error:
            self._set_network_status(f"区域配置错误：{self._layout_error}", error=True)

        self._receiver_thread.start()
        self._monitor_button.configure(text="停止监测")
        self._packet_poll_job = self.after(self.POLL_INTERVAL_MS, self._poll_packets)

    def _setup_styles(self) -> None:
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure("Panel.TFrame", background="#17232d")
        style.configure(
            "Panel.TLabel",
            background="#17232d",
            foreground="#e6edf3",
        )
        style.configure(
            "Title.TLabel",
            background="#101820",
            foreground="#7dd3fc",
            font=("Segoe UI", 16, "bold"),
        )
        style.configure(
            "Muted.TLabel",
            background="#101820",
            foreground="#9aa9b5",
        )
        style.configure(
            "Value.TLabel",
            background="#17232d",
            foreground="#f8fafc",
            font=("Consolas", 11, "bold"),
        )
        style.configure(
            "Treeview",
            background="#0f1921",
            fieldbackground="#0f1921",
            foreground="#e6edf3",
            rowheight=25,
        )
        style.configure(
            "Treeview.Heading",
            background="#263746",
            foreground="#e6edf3",
            relief="flat",
        )
        style.map(
            "Treeview",
            background=[("selected", "#155e75")],
            foreground=[("selected", "#ffffff")],
        )
        style.configure("TButton", padding=(9, 5))
        style.configure("TEntry", padding=4)
        style.configure("Horizontal.TProgressbar", troughcolor="#0f1921")

    def _build_ui(self) -> None:
        header = ttk.Frame(self, padding=(18, 14, 18, 8))
        header.pack(fill="x")
        ttk.Label(
            header,
            text="ExamGuard 监考台",
            style="Title.TLabel",
        ).pack(side="left")
        self._network_status = tk.StringVar(value="正在启动接收...")
        self._network_status_label = ttk.Label(
            header,
            textvariable=self._network_status,
            style="Muted.TLabel",
        )
        self._network_status_label.pack(side="right")

        self._session_status = tk.StringVar()
        self._session_status_label = ttk.Label(self, textvariable=self._session_status,
                                               style="Muted.TLabel", padding=(18, 0, 18, 0))
        self._session_status_label.pack(fill="x")
        self._refresh_session_status()

        body = ttk.Frame(self, padding=(18, 8, 18, 18))
        body.pack(fill="both", expand=True)
        body.columnconfigure(1, weight=1)
        body.rowconfigure(0, weight=1)

        self._build_status_panel(body).grid(row=0, column=0, sticky="nsew", padx=(0, 12))
        tabs = ttk.Notebook(body)
        self._tabs = tabs
        tabs.grid(row=0, column=1, sticky="nsew")
        tabs.add(self._build_event_panel(tabs), text="实时事件")
        self._browser = EvidenceBrowser(tabs, self._model, root=self._evidence_root)
        tabs.add(self._browser, text="图像回放 / 报告")
        from .agent_panel import AgentPanel
        self._agent_panel = AgentPanel(tabs, self._model,
                                      evidence_root=lambda: self._browser.root,
                                      open_evidence=self._open_agent_evidence)
        tabs.add(self._agent_panel, text='Agent 复核助手（日常查询）')
        from .joycode_panel import JoyCodePanel
        session_root = Path(self._model.snapshot().session_path).parent if self._model.snapshot().session_path else Path(__file__).resolve().parents[1] / 'sessions'
        self._joycode_panel = JoyCodePanel(tabs,
            registry_path=session_root.parent / '.private' / 'joycode_current_source.json',
            agent_panel=self._agent_panel, open_evidence=self._open_agent_evidence,
            choose_evidence=self._browser.choose, return_to_agent=self._return_to_daily_agent)
        tabs.add(self._joycode_panel, text='JoyCode 联动（专业智能体）')
        self._agent_panel.professional_handoff = self._handoff_to_joycode
        from .maintenance_panel import MaintenancePanel
        self._maintenance_panel=MaintenancePanel(tabs,self._model,self._downlink_port)
        tabs.add(self._maintenance_panel,text='校时与持久配置')
        from .voice_panel import VoicePanel
        self._voice_panel = VoicePanel(tabs, self._model, self._downlink_host, self._downlink_port)
        self._voice_context_shown = None
        tabs.add(self._voice_panel, text='准备与求助')
        if self._services is not None:
            from .service_panel import ServicePanel
            self._service_panel = ServicePanel(tabs, self._services, self._launch_config_path)
            tabs.add(self._service_panel, text="启动与连接")
            # Open on the monitoring home page; connection controls remain a tab.
            tabs.select(0)

    def _handoff_to_joycode(self, question, reference, signature):
        if self._joycode_panel.receive_handoff(question, reference, signature):
            self._tabs.select(self._joycode_panel)

    def _return_to_daily_agent(self, reference=''):
        if self._agent_panel.prepare_daily_review(reference):
            self._tabs.select(self._agent_panel)

    def _build_status_panel(self, parent: ttk.Frame) -> ttk.Frame:
        panel = ttk.Frame(parent, style="Panel.TFrame", padding=14)
        panel.columnconfigure(1, weight=1)
        ttk.Label(panel, text="实时状态", style="Panel.TLabel").grid(
            row=0, column=0, columnspan=2, sticky="w", pady=(0, 12)
        )

        self._status_values: dict[str, tk.StringVar] = {}
        status_rows = (
            ("stage", "阶段"),
            ("risk", "风险"),
            ("zone", "区域"),
            ("event", "事件"),
            ("frame", "帧号"),
            ("timestamp", "时间戳"),
            ("health", "系统健康"),
        )
        for row, (key, label) in enumerate(status_rows, start=1):
            self._status_values[key] = tk.StringVar(value="-")
            ttk.Label(panel, text=label, style="Panel.TLabel").grid(
                row=row, column=0, sticky="w", padx=(0, 12), pady=3
            )
            ttk.Label(panel, textvariable=self._status_values[key], style="Value.TLabel").grid(
                row=row, column=1, sticky="e", pady=3
            )

        ttk.Separator(panel).grid(row=8, column=0, columnspan=2, sticky="ew", pady=12)
        ttk.Label(panel, text="考试剩余时间 · 45 分钟", style="Panel.TLabel").grid(
            row=9, column=0, columnspan=2, sticky="w", pady=(0, 8)
        )
        self._remaining_time = tk.StringVar(value="45:00")
        self._elapsed_time = tk.StringVar(value="数码管已用时间：00:00")
        self._timer_message = tk.StringVar(value="等待 FPGA；核验后按 S3 开考")
        ttk.Label(panel, textvariable=self._remaining_time, style="Value.TLabel",
                  font=("Consolas", 38, "bold"), foreground="#7dd3fc").grid(
                      row=10, column=0, columnspan=2, pady=(6, 8))
        self._timer_progress = ttk.Progressbar(panel, maximum=1.0, mode="determinate")
        self._timer_progress.grid(row=11, column=0, columnspan=2, sticky="ew")
        ttk.Label(panel, textvariable=self._elapsed_time, style="Panel.TLabel").grid(
            row=12, column=0, columnspan=2, sticky="w", pady=6)
        ttk.Label(panel, textvariable=self._timer_message, style="Panel.TLabel",
                   wraplength=270).grid(row=13, column=0, columnspan=2, sticky="w")
        self._evidence_health_text = tk.StringVar(value="新证据链：等待状态上报")
        ttk.Label(panel, textvariable=self._evidence_health_text, style="Panel.TLabel",
                  wraplength=270, justify="left").grid(row=17, column=0, columnspan=2, sticky="w", pady=8)
        self._rtc_anchor_text = tk.StringVar(value='RTC时间锚：未上报（PERSIST2尚未输出RA）')
        ttk.Label(panel, textvariable=self._rtc_anchor_text, style='Panel.TLabel',
                  wraplength=270, justify='left').grid(row=18, column=0, columnspan=2, sticky='w')

        ttk.Separator(panel).grid(row=14, column=0, columnspan=2, sticky="ew", pady=12)
        ttk.Label(panel, text="联调说明", style="Panel.TLabel").grid(
            row=15, column=0, columnspan=2, sticky="w", pady=(0, 8)
        )
        ttk.Label(panel, text="S3：核验后开考\nS4：考试中强制超时\n静止约10秒：65\n遮挡/画面骤变：64\n\n倒计时以 FPGA 上报为准\n交卷后冻结，复位后等待开考\n\nOV5640证据经UDP落盘",
                  style="Panel.TLabel", justify="left").grid(row=16, column=0, columnspan=2, sticky="nw")
        # Keep legacy config widgets available internally, hidden from exam UI.
        self._build_region_editor(panel)
        panel.rowconfigure(16, weight=1)
        return panel

    def _build_region_editor(self, parent: ttk.Frame) -> ttk.Frame:
        editor = ttk.Frame(parent, style="Panel.TFrame")
        editor.columnconfigure(0, weight=1)
        editor.rowconfigure(0, weight=1)
        self._region_tree = ttk.Treeview(
            editor,
            columns=("id", "x0", "y0", "x1", "y1"),
            show="headings",
            height=5,
            selectmode="browse",
        )
        for column, heading, width in (
            ("id", "ID", 35),
            ("x0", "X0", 48),
            ("y0", "Y0", 48),
            ("x1", "X1", 48),
            ("y1", "Y1", 48),
        ):
            self._region_tree.heading(column, text=heading)
            self._region_tree.column(column, width=width, anchor="center")
        self._region_tree.grid(row=0, column=0, sticky="nsew")
        self._region_tree.bind("<<TreeviewSelect>>", self._select_region)

        fields = ttk.Frame(editor, style="Panel.TFrame")
        fields.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        for column in range(4):
            fields.columnconfigure(column, weight=1)
        self._region_fields: dict[str, tk.StringVar] = {
            key: tk.StringVar() for key in ("x0", "y0", "x1", "y1")
        }
        for column, key in enumerate(("x0", "y0", "x1", "y1")):
            ttk.Label(fields, text=key.upper(), style="Panel.TLabel").grid(
                row=0, column=column, sticky="w", padx=(0, 4)
            )
            ttk.Entry(fields, textvariable=self._region_fields[key], width=7).grid(
                row=1, column=column, sticky="ew", padx=(0, 4)
            )

        threshold_row = ttk.Frame(editor, style="Panel.TFrame")
        threshold_row.grid(row=2, column=0, sticky="ew", pady=(8, 0))
        ttk.Label(threshold_row, text="阈值", style="Panel.TLabel").pack(
            side="left"
        )
        self._threshold_var = tk.StringVar(value="12")
        ttk.Entry(threshold_row, textvariable=self._threshold_var, width=6).pack(
            side="left", padx=(6, 12)
        )
        self._config_status = tk.StringVar(value="尚未下发配置")
        ttk.Label(
            threshold_row,
            textvariable=self._config_status,
            style="Panel.TLabel",
        ).pack(side="left")

        buttons = ttk.Frame(editor, style="Panel.TFrame")
        buttons.grid(row=3, column=0, sticky="ew", pady=(8, 0))
        ttk.Button(buttons, text="应用", command=self._apply_region).pack(
            side="left"
        )
        ttk.Button(buttons, text="默认值", command=self._load_defaults).pack(
            side="left", padx=(6, 0)
        )
        ttk.Button(buttons, text="保存 JSON", command=self._save_layout).pack(
            side="left", padx=(6, 0)
        )
        ttk.Button(
            buttons,
            text="下发到 FPGA",
            command=self._send_config_to_fpga,
        ).pack(side="left", padx=(6, 0))
        return editor

    def _build_event_panel(self, parent: ttk.Frame) -> ttk.Frame:
        panel = ttk.Frame(parent, style="Panel.TFrame", padding=14)
        panel.columnconfigure(0, weight=1)
        panel.rowconfigure(1, weight=1)
        heading = ttk.Frame(panel, style="Panel.TFrame")
        heading.grid(row=0, column=0, sticky="ew", pady=(0, 10))
        ttk.Label(heading, text="考试事件（最近200条）", style="Panel.TLabel").pack(side="left")
        self._packet_count = tk.StringVar(value="0 个数据包")
        ttk.Label(heading, textvariable=self._packet_count, style="Panel.TLabel").pack(
            side="right"
        )

        tree_frame = ttk.Frame(panel, style="Panel.TFrame")
        tree_frame.grid(row=1, column=0, sticky="nsew")
        tree_frame.columnconfigure(0, weight=1)
        tree_frame.rowconfigure(0, weight=1)
        self._event_tree = ttk.Treeview(
            tree_frame,
            columns=("received", "frame", "stage", "zone", "risk", "code", "uid"),
            show="headings",
        )
        for column, heading, width in (
            ("received", "接收时间 (UTC)", 155),
            ("frame", "帧号", 80),
            ("stage", "阶段", 95),
            ("zone", "板内时间 ms", 110),
            ("risk", "风险", 80),
            ("code", "事件", 190),
            ("uid", "事件UID/EI", 150),
        ):
            self._event_tree.heading(column, text=heading)
            self._event_tree.column(column, width=width, anchor="center")
        self._event_tree.grid(row=0, column=0, sticky="nsew")
        self._event_entries = {}
        self._event_tree.bind("<Double-1>", self._open_event_evidence)
        scrollbar = ttk.Scrollbar(
            tree_frame,
            orient="vertical",
            command=self._event_tree.yview,
        )
        scrollbar.grid(row=0, column=1, sticky="ns")
        self._event_tree.configure(yscrollcommand=scrollbar.set)

        actions = ttk.Frame(panel, style="Panel.TFrame")
        actions.grid(row=2, column=0, sticky="ew", pady=(10, 0))
        self._monitor_button = ttk.Button(
            actions,
            text="停止监测",
            command=self._toggle_monitoring,
        )
        self._monitor_button.pack(side="left")
        ttk.Button(actions, text="导出采集会话 CSV", command=self._export_events).pack(
            side="left", padx=(6, 0)
        )
        ttk.Button(actions, text="导出事务ET CSV", command=self._export_transactions).pack(side="left", padx=(6, 0))
        ttk.Button(actions, text="清空列表", command=self._clear_events).pack(
            side="left", padx=(6, 0)
        )
        self._message = tk.StringVar(value="等待状态数据")
        ttk.Label(actions, textvariable=self._message, style="Muted.TLabel").pack(
            side="right"
        )

        evidence_heading = ttk.Frame(panel, style="Panel.TFrame")
        evidence_heading.grid(row=3, column=0, sticky="ew", pady=(12, 6))
        ttk.Label(
            evidence_heading,
            text="证据时间线（最近窗口）",
            style="Panel.TLabel",
        ).pack(side="left")
        self._evidence_summary = tk.StringVar(value="尚未捕获证据窗口")
        ttk.Label(
            evidence_heading,
            textvariable=self._evidence_summary,
            style="Panel.TLabel",
        ).pack(side="right")

        evidence_frame = ttk.Frame(panel, style="Panel.TFrame")
        evidence_frame.grid(row=4, column=0, sticky="nsew")
        evidence_frame.columnconfigure(0, weight=1)
        evidence_frame.rowconfigure(0, weight=1)
        self._evidence_tree = ttk.Treeview(
            evidence_frame,
            columns=("index", "frame", "stage", "risk", "zone", "code",
                     "pickup", "operation", "forbidden"),
            show="headings",
            height=6,
        )
        for column, heading, width in (
            ("index", "序号", 42),
            ("frame", "帧号", 70),
            ("stage", "阶段", 80),
            ("risk", "风险", 70),
            ("zone", "区域", 80),
            ("code", "事件码", 70),
            ("pickup", "取料", 62),
            ("operation", "操作", 70),
            ("forbidden", "禁区", 70),
        ):
            self._evidence_tree.heading(column, text=heading)
            self._evidence_tree.column(column, width=width, anchor="center")
        self._evidence_tree.grid(row=0, column=0, sticky="nsew")
        evidence_scroll = ttk.Scrollbar(
            evidence_frame,
            orient="vertical",
            command=self._evidence_tree.yview,
        )
        evidence_scroll.grid(row=0, column=1, sticky="ns")
        self._evidence_tree.configure(yscrollcommand=evidence_scroll.set)
        self._evidence_tree.configure(displaycolumns=("index", "frame", "stage", "risk", "code"))

        evidence_actions = ttk.Frame(panel, style="Panel.TFrame")
        evidence_actions.grid(row=5, column=0, sticky="ew", pady=(6, 0))
        ttk.Button(
            evidence_actions,
            text="导出证据 CSV",
            command=self._export_evidence,
        ).pack(side="left")
        panel.rowconfigure(4, weight=1)
        return panel

    def _receive_packets(self) -> None:
        try:
            for packet in receive_packets(
                self._host,
                self._port,
                timeout=0.5,
                stop_event=self._stop_event,
            ):
                self._packet_queue.put(packet)
        except OSError as exc:
            self._packet_queue.put(f"接收错误：{exc}")

    def _poll_packets(self) -> None:
        if self._packet_poll_job is not None:
            self.after_cancel(self._packet_poll_job)
            self._packet_poll_job = None
        received_event = False
        received_evidence = False
        received_ack = False
        try:
            # Limit synchronous commits/render work per tick so a burst cannot
            # monopolize Tk's event loop. Close drains the remainder separately.
            for _ in range(100):
                item = self._packet_queue.get_nowait()
                if isinstance(item, str):
                    self._set_network_status(item, error=True)
                    self._message.set(item)
                    continue
                self._model.apply(item)
                if isinstance(item, VoiceStatus):
                    self._voice_panel.poll()
                    key = (item.binding, item.ticket if item.help_pending else 0)
                    if (self._voice_panel.current is item and self._voice_panel.fresh() and
                            key != self._voice_context_shown and item.stage in (2, 3, 4)):
                        if item.help_pending or item.stage == 2:
                            self._tabs.select(self._voice_panel)
                        self._voice_context_shown = key
                if isinstance(item, StatusPacket):
                    self._exam_timer.apply(item)
                    self._evidence_health_view.apply(item)
                self._set_network_status(f"监听 {self._host}:{self._port}")
                self._message.set("已接收实时数据")
                if isinstance(item, (EventPacket, EventIdentityPacket, TransactionEventPacket)):
                    received_event = True
                elif isinstance(item, EvidenceEndPacket):
                    received_evidence = True
                elif isinstance(item, ConfigAckPacket):
                    received_ack = True
        except queue.Empty:
            pass

        snapshot = self._model.snapshot()
        self._refresh_session_status()
        self._packet_count.set(
            f"{snapshot.packets_received} 个数据包 "
            f"（状态 {snapshot.status_packets}，报警 {snapshot.event_packets}，"
            f"证据 {snapshot.evidence_packets}，事务ET {snapshot.transaction_packets}）"
        )
        if snapshot.latest_status is not None:
            self._update_status(snapshot.latest_status)
        if snapshot.anchors:
            entry = snapshot.anchors[-1]
            text = entry.packet.text()
            status_boot = snapshot.latest_status.evidence_health.identity[:2] if snapshot.latest_status and snapshot.latest_status.evidence_health else None
            if status_boot and status_boot != (entry.packet.device, entry.packet.boot):
                text += '；旧boot锚，不能用于当前事件'
            self._rtc_anchor_text.set(text)
        self._refresh_timer()
        if received_event:
            self._refresh_event_tree(snapshot.events, snapshot.transactions)
        if received_evidence:
            self._refresh_evidence_tree(snapshot.latest_evidence)
        if received_ack:
            self._refresh_config_status(snapshot.latest_config_ack)
        if not self._receiver_thread.is_alive() and not self._stop_event.is_set():
            self._monitor_button.configure(text="开始监测")
        if not self._stop_event.is_set():
            self._packet_poll_job = self.after(self.POLL_INTERVAL_MS, self._poll_packets)

    def _update_status(self, packet: StatusPacket) -> None:
        self._status_values["stage"].set(
            f"{STAGE_NAMES.get(packet.state_id, '未知')} ({packet.state_id})"
        )
        self._status_values["risk"].set(
            f"{RISK_NAMES.get(packet.risk_level, '未知')} ({packet.risk_level})"
        )
        self._status_values["zone"].set(
            f"{ZONE_NAMES.get(packet.zone_id, '未知')} ({packet.zone_id})"
        )
        self._status_values["event"].set(format_event(packet.event_code))
        self._status_values["frame"].set(str(packet.frame_id))
        self._status_values["timestamp"].set(str(packet.timestamp))
        self._status_values["health"].set(format_health(packet.health_flags))
        self._evidence_health_text.set(self._evidence_health_view.text())

    def _refresh_timer(self) -> None:
        view = self._exam_timer.view()
        self._remaining_time.set(view.remaining)
        self._elapsed_time.set(f"数码管已用时间：{view.elapsed}")
        self._timer_message.set(view.message)
        self._timer_progress["value"] = view.fraction

    def _refresh_session_status(self) -> None:
        snapshot = self._model.snapshot()
        if snapshot.persistence_error:
            text = f"存档异常：{snapshot.persistence_error} | 已落盘 {snapshot.persisted_events} / AL {snapshot.event_packets}"
        else:
            text = f"采集会话 {snapshot.host_session_id} | 已落盘AL {snapshot.persisted_events} / ET {snapshot.persisted_transactions} / ST {snapshot.persisted_statuses} / RA {snapshot.persisted_anchors} / MR {snapshot.persisted_maintenance} | {snapshot.session_path}"
        self._session_status.set(text)
        self._session_status_label.configure(foreground="#fb7185" if snapshot.persistence_error else "#9aa9b5")

    def _refresh_event_tree(self, events: tuple, transactions: tuple = ()) -> None:
        selected = self._event_tree.selection()
        self._event_tree.delete(*self._event_tree.get_children())
        self._event_entries = {}
        for entry in events:
            packet = entry.packet
            identity = getattr(entry, "identity", None)
            # v1 has no EI line; show a clear placeholder rather than a fake id.
            uid_text = (f"uid={identity.uid} dev={identity.device_id} "
                        f"boot={identity.boot_id} sess={identity.session_id}") if identity else "未收到EI(v1)"
            item = self._event_tree.insert(
                "",
                "end",
                iid=f'AL_{entry.receipt_id}',
                values=(
                    entry.received_at,
                    packet.frame_id,
                    STAGE_NAMES.get(packet.stage_id, str(packet.stage_id)),
                    packet.timestamp,
                    RISK_NAMES.get(packet.risk_level, str(packet.risk_level)),
                    format_event(packet.event_code),
                    uid_text,
                ),
            )
            self._event_entries[item] = entry
        for entry in transactions:
            packet = entry.packet
            dev, boot, sess, uid = packet.identity
            item = self._event_tree.insert('', 'end', iid=f'ET_{entry.receipt_id}', values=(
                entry.received_at, 'ET无帧号', STAGE_NAMES.get(packet.stage_id, str(packet.stage_id)), packet.timestamp,
                RISK_NAMES.get(packet.risk_level, str(packet.risk_level)), format_event(packet.event_code),
                f'ET uid={uid} dev={dev} boot={boot} sess={sess} 源={packet.source}'))
            self._event_entries[item] = entry
        children = self._event_tree.get_children()
        for row in selected:
            if self._event_tree.exists(row):
                self._event_tree.selection_add(row)
        if children:
            self._event_tree.see(children[-1])

    def _open_event_evidence(self, _event=None) -> None:
        if _event is not None:
            clicked=self._event_tree.identify_row(_event.y)
            if clicked:
                self._event_tree.selection_set(clicked)
        selection = self._event_tree.selection()
        if selection and selection[0] in self._event_entries:
            entry = self._event_entries[selection[0]]
            if isinstance(entry.packet, TransactionEventPacket):
                self._message.set(f'ET完整身份 {entry.packet.identity}：已接受事件，查看同源EGv2图像结果')
                self._browser.find_event(entry.packet)
                self._tabs.select(self._browser)
                return
            self._show_ov5640(entry.packet, getattr(entry, "identity", None))

    def _export_transactions(self):
        path = filedialog.asksaveasfilename(parent=self, title='导出同源事务ET', defaultextension='.csv', filetypes=[('CSV', '*.csv')])
        if path:
            try:
                self._model.export_transactions_csv(path)
            except (OSError, sqlite3.Error, ValueError) as exc:
                messagebox.showerror('事务导出失败', str(exc), parent=self)
            else:
                self._message.set('已导出事务ET（源接受记录，非图像成功结果）')

    def _show_ov5640(self, packet, identity=None):
        self._browser.find_event(packet, identity)
        self._tabs.select(self._browser)

    def _populate_regions(self) -> None:
        self._region_tree.delete(*self._region_tree.get_children())
        for region in self._layout.regions:
            self._region_tree.insert(
                "",
                "end",
                iid=str(region.region_id),
                values=(region.region_id, region.x0, region.y0, region.x1, region.y1),
            )
        children = self._region_tree.get_children()
        if children:
            self._region_tree.selection_set(children[0])
            self._region_tree.focus(children[0])
            self._select_region()

    def _select_region(self, _event: object | None = None) -> None:
        selection = self._region_tree.selection()
        if not selection:
            self._selected_region_id = None
            return
        region_id = int(selection[0])
        self._selected_region_id = region_id
        region = next(region for region in self._layout.regions if region.region_id == region_id)
        for key in self._region_fields:
            self._region_fields[key].set(str(getattr(region, key)))

    def _apply_region(self) -> None:
        if self._selected_region_id is None:
            return
        try:
            coordinates = {
                key: int(self._region_fields[key].get(), 10)
                for key in self._region_fields
            }
            regions = list(self._layout.regions)
            index = next(
                index
                for index, region in enumerate(regions)
                if region.region_id == self._selected_region_id
            )
            regions[index] = RegionConfig(
                region_id=self._selected_region_id,
                **coordinates,
            )
            new_layout = RegionLayout(
                width=self._layout.width,
                height=self._layout.height,
                regions=tuple(regions),
            )
            validate_layout(new_layout)
        except (ConfigError, StopIteration, ValueError) as exc:
            messagebox.showerror("区域无效", str(exc))
            return
        self._layout = new_layout
        self._populate_regions()
        self._message.set("区域已更新，请保存 JSON 以持久化")

    def _load_defaults(self) -> None:
        self._layout = default_layout()
        self._layout_error = None
        self._populate_regions()
        self._message.set("已加载默认 1280x720 区域")

    def _save_layout(self) -> None:
        try:
            save_layout(self._config_path, self._layout)
        except ConfigError as exc:
            messagebox.showerror("保存失败", str(exc))
            return
        self._layout_error = None
        self._message.set(f"已保存区域配置：{self._config_path}")

    def _send_config_to_fpga(self) -> None:
        """Send the selected region to the FPGA and wait for its acknowledgement."""
        if self._selected_region_id is None:
            messagebox.showinfo("未选择区域", "请先选择一个区域")
            return
        region = next(
            (
                candidate
                for candidate in self._layout.regions
                if candidate.region_id == self._selected_region_id
            ),
            None,
        )
        if region is None:
            return

        try:
            threshold = int(self._threshold_var.get(), 10)
            request = encode_config_request(
                region_id=region.region_id,
                x0=region.x0,
                y0=region.y0,
                x1=region.x1,
                y1=region.y1,
                threshold=threshold,
            )
        except (ValueError, ProtocolError) as exc:
            messagebox.showerror("配置无效", str(exc))
            return

        try:
            self._downlink_socket.sendto(
                request.strip(),
                (self._downlink_host, self._downlink_port),
            )
        except OSError as exc:
            messagebox.showerror("下发失败", str(exc))
            return

        self._config_status.set(
            f"已向 FPGA 下发区域 {region.region_id}，等待应答"
        )

    def _refresh_config_status(self, ack: object) -> None:
        if ack is None:
            return
        if ack.accepted:
            self._config_status.set(f"配置已应用：版本 {ack.version}")
        else:
            self._config_status.set(
                f"配置已拒绝（版本 {ack.version}）：{ack.status_name}"
            )

    def _export_events(self) -> None:
        path = filedialog.asksaveasfilename(
            title="导出报警事件",
            defaultextension=".csv",
            filetypes=(("CSV 文件", "*.csv"), ("所有文件", "*.*")),
            initialfile="报警事件.csv",
        )
        if not path:
            return
        try:
            self._model.export_events_csv(path)
        except (OSError, sqlite3.Error, ValueError) as exc:
            messagebox.showerror("导出失败", str(exc))
            return
        self._message.set(f"已导出已落盘会话事件：{path}")

    def _clear_events(self) -> None:
        self._model.clear_events()
        self._event_tree.delete(*self._event_tree.get_children())
        self._event_entries = {}
        self._message.set("界面列表已清空；采集会话存档保留")

    def _refresh_evidence_tree(self, window: object) -> None:
        self._evidence_tree.delete(*self._evidence_tree.get_children())
        if window is None:
            self._evidence_summary.set("尚未捕获证据窗口")
            return

        samples = window.samples
        if window.complete:
            self._evidence_summary.set(
                f"序列 {window.seq}：{len(samples)}/{window.expected} 条记录完整"
            )
        else:
            missing = ", ".join(str(index) for index in window.missing_indices)
            self._evidence_summary.set(
                f"序列 {window.seq}：{len(samples)}/{window.expected} 条记录，"
                f"缺少 {missing}"
            )

        for sample in samples:
            self._evidence_tree.insert(
                "",
                "end",
                values=(
                    sample.index,
                    sample.frame_id,
                    STAGE_NAMES.get(sample.stage_id, str(sample.stage_id)),
                    RISK_NAMES.get(sample.risk_level, str(sample.risk_level)),
                    ZONE_NAMES.get(sample.zone_id, str(sample.zone_id)),
                    format_event(sample.event_code),
                    sample.motion_pickup,
                    sample.motion_operation,
                    sample.motion_forbidden,
                ),
            )
        children = self._evidence_tree.get_children()
        if children:
            self._evidence_tree.see(children[0])

    def _export_evidence(self) -> None:
        path = filedialog.asksaveasfilename(
            title="导出证据窗口",
            defaultextension=".csv",
            filetypes=(("CSV 文件", "*.csv"), ("所有文件", "*.*")),
            initialfile="证据窗口.csv",
        )
        if not path:
            return
        try:
            self._model.export_evidence_csv(path)
        except (OSError, ValueError) as exc:
            messagebox.showerror("导出失败", str(exc))
            return
        self._message.set(f"已导出证据：{path}")

    def _toggle_monitoring(self) -> None:
        if self._receiver_thread.is_alive():
            self._stop_event.set()
            self._monitor_button.configure(text="开始监测")
            self._set_network_status("监测已停止")
            self._message.set("UDP 接收已停止")
            return

        self._stop_event = threading.Event()
        self._receiver_thread = threading.Thread(
            target=self._receive_packets,
            name="fpga-udp-receiver",
            daemon=True,
        )
        self._receiver_thread.start()
        self._monitor_button.configure(text="停止监测")
        self._set_network_status(f"监听 {self._host}:{self._port}")
        self._message.set("UDP 接收已启动")
        if self._packet_poll_job is not None:
            self.after_cancel(self._packet_poll_job)
        self._packet_poll_job = self.after(self.POLL_INTERVAL_MS, self._poll_packets)

    def _set_network_status(self, text: str, *, error: bool = False) -> None:
        self._network_status.set(text)
        self._network_status_label_color(error)

    def _network_status_label_color(self, error: bool) -> None:
        # Keep the status text readable on both the dark and default Tk themes.
        self._network_status_label.configure(foreground="#fb7185" if error else "#9aa9b5")

    @staticmethod
    def _format_code(code: int) -> str:
        return f"0x{code:02X}"

    def _open_agent_evidence(self, packet, root):
        self._browser.pause()
        self._browser.root = Path(root)
        self._browser.find_event(packet)
        self._tabs.select(self._browser)

    def _close(self) -> None:
        self._joycode_panel.close()
        self._agent_panel.close()
        self._browser.pause()
        if self._services is not None:
            self._services.stop()
        self._stop_event.set()
        if self._receiver_thread.is_alive():
            self._receiver_thread.join(timeout=1.5)
        # Persist decoded packets already queued before closing the session.
        while not self._packet_queue.empty():
            self._poll_packets()
        self._poll_packets()
        self._model.close()
        try:
            self._downlink_socket.close()
        except OSError:
            pass
        self.destroy()


def run_dashboard(
    *,
    host: str,
    port: int,
    config_path: str | Path,
    downlink_host: str = "127.0.0.1",
    downlink_port: int = 5006,
    session_root: str | Path | None = None,
) -> None:
    """Start the dashboard application."""
    app = Dashboard(
        host=host,
        port=port,
        config_path=config_path,
        downlink_host=downlink_host,
        downlink_port=downlink_port,
        session_root=session_root,
    )
    app.mainloop()
