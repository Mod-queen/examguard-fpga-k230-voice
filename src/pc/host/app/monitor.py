"""Thread-safe monitoring state and event export."""

from __future__ import annotations

import csv
import threading
import sqlite3
import time
from dataclasses import dataclass, replace
from pathlib import Path

from .event_store import EventLogEntry, TransactionLogEntry, StatusLogEntry, AnchorLogEntry, MaintenanceLogEntry, BoardMonitorLogEntry, EventStore, SessionArchive, utc_now
from .transaction_protocol import TransactionEventPacket
from .rtc_anchor import RTCAnchor
from .maintenance_protocol import MaintenanceResult
from .board_monitor import BoardMonitor
from .voice_protocol import VoiceStatus
from .event_store import VoiceLogEntry

from .protocol import (
    ConfigAckPacket,
    EventIdentityPacket,
    EventPacket,
    EvidenceEndPacket,
    EvidencePacket,
    Packet,
    StatusPacket,
)


@dataclass(frozen=True)
class EvidenceWindow:
    """A complete pre/post alarm window read back from the FPGA.

    ``expected`` is the sample count the FPGA reported; ``samples`` is what
    actually arrived, sorted by index. Comparing the two exposes UART loss.
    """

    seq: int
    expected: int
    samples: tuple[EvidencePacket, ...]

    @property
    def complete(self) -> bool:
        return len(self.samples) == self.expected

    @property
    def missing_indices(self) -> tuple[int, ...]:
        present = {sample.index for sample in self.samples}
        return tuple(
            index
            for index in range(self.expected)
            if index not in present
        )


@dataclass(frozen=True)
class MonitorSnapshot:
    """Immutable view of the data needed by the dashboard."""

    latest_status: StatusPacket | None
    events: tuple[EventLogEntry, ...]
    latest_evidence: EvidenceWindow | None
    latest_config_ack: ConfigAckPacket | None
    packets_received: int
    status_packets: int
    event_packets: int
    evidence_packets: int
    latest_identity: EventIdentityPacket | None = None
    host_session_id: str | None = None
    session_path: str | None = None
    persisted_events: int = 0
    persistence_failures: int = 0
    persistence_error: str | None = None
    transactions: tuple[TransactionLogEntry, ...] = ()
    transaction_packets: int = 0
    persisted_transactions: int = 0
    persisted_statuses: int = 0
    status_failures: int = 0
    anchors: tuple[AnchorLogEntry, ...] = ()
    anchor_packets: int = 0
    persisted_anchors: int = 0
    anchor_failures: int = 0
    latest_maintenance: MaintenanceResult | None = None
    maintenance_packets: int = 0
    persisted_maintenance: int = 0
    maintenance_failures: int = 0
    board_monitors: tuple[BoardMonitorLogEntry, ...] = ()
    board_packets: int = 0
    board_failures: int = 0
    voice: tuple[VoiceLogEntry, ...] = ()
    voice_packets: int = 0
    voice_failures: int = 0


class MonitorModel:
    """Latest status/bounded UI history plus optional durable AL/ET/ST journals."""

    def __init__(self, *, max_events: int = 200, session_root: str | Path | None = None,
                 session_metadata: dict | None = None) -> None:
        if max_events < 1:
            raise ValueError("max_events must be positive")
        self._max_events = max_events
        self._latest_status: StatusPacket | None = None
        self._events: list[EventLogEntry] = []
        self._packets_received = 0
        self._status_packets = 0
        self._persisted_statuses = 0
        self._status_failures = 0
        self._started_ns = time.monotonic_ns()
        self._event_packets = 0
        self._evidence_packets = 0
        self._evidence_seq: int | None = None
        self._evidence_samples: dict[int, EvidencePacket] = {}
        self._latest_evidence: EvidenceWindow | None = None
        self._latest_config_ack: ConfigAckPacket | None = None
        self._latest_maintenance: MaintenanceResult | None = None
        self._maintenance_packets = self._persisted_maintenance = self._maintenance_failures = 0
        self._board_monitors = []
        self._board_packets = self._board_failures = 0
        self._voice = []
        self._voice_packets = self._voice_failures = 0
        self._latest_identity: EventIdentityPacket | None = None
        self._transactions: list[TransactionLogEntry] = []
        self._transaction_packets = 0
        self._persisted_transactions = 0
        self._transaction_failures = 0
        self._anchors: list[AnchorLogEntry] = []
        self._anchor_packets = self._persisted_anchors = self._anchor_failures = 0
        self._lock = threading.Lock()
        self._store: EventStore | None = None
        self._persistence_requested = session_root is not None
        self._persisted_events = 0
        self._persistence_failures = 0
        self._persistence_error: str | None = None
        self._closed = False
        if session_root is not None:
            try:
                self._store = EventStore(session_root, metadata=session_metadata)
            except (OSError, sqlite3.Error) as exc:
                self._persistence_error = f"存档初始化失败：{exc}"

    def apply(self, packet: Packet) -> None:
        """Apply one validated packet received from the FPGA."""
        with self._lock:
            if self._closed:
                raise RuntimeError("Monitor capture session is closed")
            self._packets_received += 1
            if isinstance(packet, StatusPacket):
                self._latest_status = packet
                self._status_packets += 1
                entry = StatusLogEntry(utc_now(), packet, self._status_packets,
                                       time.monotonic_ns() - self._started_ns)
                if self._store is not None:
                    try:
                        self._store.append_status(entry)
                    except (OSError, sqlite3.Error) as exc:
                        self._persistence_failures += 1
                        self._status_failures += 1
                        self._persistence_error = f"健康历史存档失败：{exc}"
                    else:
                        self._persisted_statuses += 1
                elif self._persistence_error:
                    self._persistence_failures += 1
                    self._status_failures += 1
            elif isinstance(packet, RTCAnchor):
                self._anchor_packets += 1
                entry = AnchorLogEntry(utc_now(), packet, self._anchor_packets, time.monotonic_ns()-self._started_ns)
                if self._store is not None:
                    try:
                        self._store.append_anchor(entry)
                    except (OSError, sqlite3.Error) as exc:
                        self._anchor_failures += 1
                        self._persistence_failures += 1
                        self._persistence_error = f'RTC锚存档失败：{exc}'
                    else:
                        self._persisted_anchors += 1
                elif self._persistence_error:
                    self._anchor_failures += 1
                    self._persistence_failures += 1
                self._anchors.append(entry)
                if len(self._anchors)>self._max_events:
                    del self._anchors[:len(self._anchors)-self._max_events]
            elif isinstance(packet, TransactionEventPacket):
                self._transaction_packets += 1
                entry = TransactionLogEntry(utc_now(), packet, self._transaction_packets)
                if self._store is not None:
                    try:
                        self._store.append_transaction(entry)
                    except (OSError, sqlite3.Error) as exc:
                        self._persistence_failures += 1
                        self._persistence_error = f"事务存档失败：{exc}"
                        self._transaction_failures += 1
                    else:
                        self._persisted_transactions += 1
                elif self._persistence_error:
                    self._persistence_failures += 1
                    self._transaction_failures += 1
                self._transactions.append(entry)
                if len(self._transactions) > self._max_events:
                    del self._transactions[:len(self._transactions)-self._max_events]
            elif isinstance(packet, EventPacket):
                entry = EventLogEntry(received_at=utc_now(), packet=packet,
                                      receipt_id=self._event_packets + 1)
                if self._store is not None:
                    try:
                        self._store.append(entry)
                    except (OSError, sqlite3.Error) as exc:
                        self._persistence_failures += 1
                        self._persistence_error = f"事件存档失败：{exc}"
                    else:
                        self._persisted_events += 1
                elif self._persistence_error:
                    self._persistence_failures += 1
                self._events.append(entry)
                if len(self._events) > self._max_events:
                    del self._events[: len(self._events) - self._max_events]
                self._event_packets += 1
            elif isinstance(packet, EvidencePacket):
                if self._evidence_seq != packet.seq:
                    # A new window started before the previous one ended.
                    self._evidence_seq = packet.seq
                    self._evidence_samples = {}
                self._evidence_samples[packet.index] = packet
                self._evidence_packets += 1
            elif isinstance(packet, EvidenceEndPacket):
                samples = tuple(
                    self._evidence_samples[index]
                    for index in sorted(self._evidence_samples)
                )
                self._latest_evidence = EvidenceWindow(
                    seq=packet.seq,
                    expected=packet.count,
                    samples=samples,
                )
                self._evidence_samples = {}
                self._evidence_seq = None
                self._evidence_packets += 1
            elif isinstance(packet, EventIdentityPacket):
                # v2: identify the most recent AL. Attach in memory and, when a
                # session is open, update the already-committed receipt.
                self._latest_identity = packet
                if self._events:
                    last = self._events[-1]
                    self._events[-1] = replace(last, identity=packet)
                    if self._store is not None:
                        try:
                            self._store.attach_identity(last.receipt_id, packet)
                        except (OSError, sqlite3.Error) as exc:
                            self._persistence_failures += 1
                            self._persistence_error = f"身份存档失败：{exc}"
            elif isinstance(packet, ConfigAckPacket):
                self._latest_config_ack = packet
            elif isinstance(packet, MaintenanceResult):
                self._latest_maintenance = packet
                self._maintenance_packets += 1
                entry = MaintenanceLogEntry(utc_now(), packet, self._maintenance_packets, time.monotonic_ns()-self._started_ns)
                if self._store is not None:
                    try:
                        self._store.append_maintenance(entry)
                    except (OSError, sqlite3.Error) as exc:
                        self._maintenance_failures += 1
                        self._persistence_failures += 1
                        self._persistence_error = f'维护回执存档失败：{exc}'
                    else:
                        self._persisted_maintenance += 1
                elif self._persistence_error:
                    self._maintenance_failures += 1
                    self._persistence_failures += 1

            elif isinstance(packet, VoiceStatus):
                self._voice_packets += 1
                entry = VoiceLogEntry(utc_now(), packet, self._voice_packets, time.monotonic_ns()-self._started_ns)
                self._voice.append(entry)
                if len(self._voice)>self._max_events:
                    del self._voice[:-self._max_events]
                if self._store is not None:
                    try:
                        self._store.append_voice(entry)
                    except (OSError, sqlite3.Error) as exc:
                        self._voice_failures += 1
                        self._persistence_failures += 1
                        self._persistence_error = f'语音交互存档失败：{exc}'
                elif self._persistence_error:
                    self._voice_failures += 1
                    self._persistence_failures += 1

            elif isinstance(packet, BoardMonitor):
                self._board_packets += 1
                entry=BoardMonitorLogEntry(utc_now(),packet,self._board_packets,time.monotonic_ns()-self._started_ns)
                self._board_monitors.append(entry)
                if len(self._board_monitors)>self._max_events:del self._board_monitors[:-self._max_events]
                if self._store is not None:
                    try:self._store.append_board_monitor(entry)
                    except (OSError,sqlite3.Error) as exc:
                        self._board_failures+=1;self._persistence_failures+=1
                        self._persistence_error=f'板级监测存档失败：{exc}'
                elif self._persistence_error:self._board_failures+=1;self._persistence_failures+=1

    def snapshot(self) -> MonitorSnapshot:
        """Return a consistent copy suitable for UI rendering or tests."""
        with self._lock:
            return MonitorSnapshot(
                latest_status=self._latest_status,
                events=tuple(self._events),
                latest_evidence=self._latest_evidence,
                latest_config_ack=self._latest_config_ack,
                latest_maintenance=self._latest_maintenance,
                maintenance_packets=self._maintenance_packets,persisted_maintenance=self._persisted_maintenance,
                maintenance_failures=self._maintenance_failures,
                board_monitors=tuple(self._board_monitors),board_packets=self._board_packets,board_failures=self._board_failures,
                voice=tuple(self._voice),voice_packets=self._voice_packets,voice_failures=self._voice_failures,
                packets_received=self._packets_received,
                status_packets=self._status_packets,
                event_packets=self._event_packets,
                evidence_packets=self._evidence_packets,
                latest_identity=self._latest_identity,
                host_session_id=self._store.session_id if self._store else None,
                session_path=str(self._store.path) if self._store else None,
                persisted_events=self._persisted_events,
                persistence_failures=self._persistence_failures,
                persistence_error=self._persistence_error,
                transactions=tuple(self._transactions),transaction_packets=self._transaction_packets,
                persisted_transactions=self._persisted_transactions,
                persisted_statuses=self._persisted_statuses,status_failures=self._status_failures,
                anchors=tuple(self._anchors),anchor_packets=self._anchor_packets,
                persisted_anchors=self._persisted_anchors,anchor_failures=self._anchor_failures,
            )

    def session_archive(self) -> SessionArchive | None:
        """All committed AL receipts; independent of clear/trim of UI history.

        Read errors are raised to the caller, never silently replaced with the
        most recent 200 records and described as a full report.
        """
        from dataclasses import replace
        with self._lock:
            if self._store is None:
                return None
            archive = self._store.read()
            return replace(archive, event_packets=self._event_packets,
                            persistence_failures=self._persistence_failures-self._transaction_failures-self._status_failures-self._anchor_failures-self._maintenance_failures-self._board_failures-self._voice_failures,
                            persistence_error=self._persistence_error,
                            transaction_packets=self._transaction_packets,transaction_failures=self._transaction_failures,
                            status_packets=self._status_packets,status_failures=self._status_failures,
                            anchor_packets=self._anchor_packets,anchor_failures=self._anchor_failures,
                            maintenance_packets=self._maintenance_packets,maintenance_failures=self._maintenance_failures,
                            board_packets=self._board_packets,board_failures=self._board_failures,
                            voice_packets=self._voice_packets,voice_failures=self._voice_failures)

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            if self._store is not None:
                try:
                    self._store.close(received_al=self._event_packets,
                                       failed_al=self._persistence_failures-self._transaction_failures-self._status_failures-self._anchor_failures-self._maintenance_failures-self._board_failures-self._voice_failures,
                                       last_error=self._persistence_error,
                                       received_et=self._transaction_packets,failed_et=self._transaction_failures,
                                       received_st=self._status_packets,failed_st=self._status_failures,
                                       received_ra=self._anchor_packets,failed_ra=self._anchor_failures,
                                       received_mr=self._maintenance_packets,failed_mr=self._maintenance_failures,
                                       received_bm=self._board_packets,failed_bm=self._board_failures,
                                       received_vi=self._voice_packets,failed_vi=self._voice_failures)
                except (OSError, sqlite3.Error) as exc:
                    self._persistence_error = f"会话收尾失败：{exc}"
            self._closed = True

    def clear_events(self) -> None:
        """Remove the local alarm history without changing live status."""
        with self._lock:
            self._events.clear()
            self._transactions.clear()

    def export_events_csv(self, path: str | Path) -> None:
        """Export committed session receipts, or bounded history if no store."""
        snapshot = self.snapshot()
        archive = self.session_archive()
        if self._persistence_requested and archive is None:
            raise OSError(self._persistence_error or "No capture session available")
        entries = archive.events if archive is not None else snapshot.events
        export_path = Path(path)
        if archive is not None and export_path.resolve() == Path(archive.session_path).resolve():
            raise ValueError("CSV output cannot overwrite the capture database")
        export_path.parent.mkdir(parents=True, exist_ok=True)
        with export_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.writer(csv_file)
            columns = [
                "received_at",
                "frame_id",
                "timestamp",
                "stage_id",
                "zone_id",
                "risk_level",
                "event_code",
            ]
            if archive is not None:
                columns += ["host_session_id", "receipt_id"]
            writer.writerow(columns)
            for entry in entries:
                packet = entry.packet
                row = [
                    entry.received_at,
                    packet.frame_id,
                    packet.timestamp,
                    packet.stage_id,
                    packet.zone_id,
                    packet.risk_level,
                    packet.event_code,
                ]
                if archive is not None:
                    row += [archive.host_session_id, entry.receipt_id]
                writer.writerow(row)

    def export_transactions_csv(self, path: str | Path) -> None:
        snapshot = self.snapshot()
        archive = self.session_archive()
        if self._persistence_requested and archive is None:
            raise OSError(self._persistence_error or 'No capture session available')
        entries = archive.transactions if archive else snapshot.transactions
        if archive and Path(path).resolve() == Path(archive.session_path).resolve():
            raise ValueError('CSV output cannot overwrite the capture database')
        with Path(path).open('w', newline='', encoding='utf-8') as output:
            writer = csv.writer(output)
            writer.writerow(['receipt_id', 'received_at', 'device', 'boot', 'session', 'uid', 'source_time_ms', 'source', 'lane_hex', 'transaction_hex'])
            for entry in entries:
                p = entry.packet
                writer.writerow([entry.receipt_id, entry.received_at, *p.identity, p.timestamp, p.source, f'{p.lane:04X}', p.transaction.hex().upper()])

    def export_evidence_csv(self, path: str | Path) -> None:
        """Export the latest evidence window for reports and replay."""
        snapshot = self.snapshot()
        export_path = Path(path)
        if snapshot.session_path and export_path.resolve() == Path(snapshot.session_path).resolve():
            raise ValueError("CSV output cannot overwrite the capture database")
        export_path.parent.mkdir(parents=True, exist_ok=True)
        with export_path.open("w", newline="", encoding="utf-8") as csv_file:
            writer = csv.writer(csv_file)
            writer.writerow(
                [
                    "seq",
                    "index",
                    "frame_id",
                    "timestamp_ms",
                    "stage_id",
                    "risk_level",
                    "zone_id",
                    "event_code",
                    "motion_pickup",
                    "motion_operation",
                    "motion_forbidden",
                    "config_version",
                    "health_flags",
                ]
            )
            window = snapshot.latest_evidence
            if window is None:
                return
            for sample in window.samples:
                writer.writerow(
                    [
                        sample.seq,
                        sample.index,
                        sample.frame_id,
                        sample.timestamp_ms,
                        sample.stage_id,
                        sample.risk_level,
                        sample.zone_id,
                        sample.event_code,
                        sample.motion_pickup,
                        sample.motion_operation,
                        sample.motion_forbidden,
                        sample.config_version,
                        sample.health_flags,
                    ]
                )
