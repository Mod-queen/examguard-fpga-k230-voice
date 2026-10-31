"""Durable separate AL, ET and canonical ST receipt journals per host session."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import threading
import uuid

from .protocol import EventIdentityPacket, EventPacket, StatusPacket, encode_event, encode_status, decode_packet
from .transaction_protocol import TransactionEventPacket, encode_transaction_event, decode_transaction_event
from .rtc_anchor import RTCAnchor, decode_rtc_anchor
from .maintenance_protocol import MaintenanceResult, decode_result
from .board_monitor import BoardMonitor, decode_board_monitor
from .voice_protocol import VoiceStatus, decode_voice_status


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


@dataclass(frozen=True)
class EventLogEntry:
    received_at: str
    packet: EventPacket
    receipt_id: int = 0
    # Protocol v2: the EI identity that followed this AL, if it arrived.
    identity: EventIdentityPacket | None = None


@dataclass(frozen=True)
class SessionArchive:
    host_session_id: str
    session_path: str
    started_at: str
    ended_at: str | None
    metadata: dict
    events: tuple[EventLogEntry, ...]
    event_packets: int
    persistence_failures: int
    persistence_error: str | None = None
    transactions: tuple[TransactionLogEntry, ...] = ()
    transaction_packets: int = 0
    transaction_failures: int = 0
    statuses: tuple[StatusLogEntry, ...] = ()
    status_packets: int = 0
    status_failures: int = 0
    anchors: tuple[AnchorLogEntry, ...] = ()
    anchor_packets: int = 0
    anchor_failures: int = 0
    maintenance: tuple[MaintenanceLogEntry, ...] = ()
    maintenance_packets: int = 0
    maintenance_failures: int = 0
    board_monitors: tuple[BoardMonitorLogEntry, ...] = ()
    board_packets: int = 0
    board_failures: int = 0
    voice: tuple[VoiceLogEntry, ...] = ()
    voice_packets: int = 0
    voice_failures: int = 0


@dataclass(frozen=True)
class TransactionLogEntry:
    received_at: str
    packet: TransactionEventPacket
    receipt_id: int


@dataclass(frozen=True)
class StatusLogEntry:
    received_at: str
    packet: StatusPacket
    receipt_id: int
    elapsed_ns: int  # host monotonic time since model creation, not FPGA time


@dataclass(frozen=True)
class AnchorLogEntry:
    received_at: str
    packet: RTCAnchor
    receipt_id: int
    elapsed_ns: int


@dataclass(frozen=True)
class MaintenanceLogEntry:
    received_at: str
    packet: MaintenanceResult
    receipt_id: int
    elapsed_ns: int


@dataclass(frozen=True)
class BoardMonitorLogEntry:
    received_at: str
    packet: BoardMonitor
    receipt_id: int
    elapsed_ns: int


@dataclass(frozen=True)
class VoiceLogEntry:
    received_at: str
    packet: VoiceStatus
    receipt_id: int
    elapsed_ns: int


class EventStore:
    """Exclusive per-launch SQLite file; commit each receipt before UI history trim.

    Receipt IDs count received AL packets. Identical retransmissions are kept;
    the v1 protocol cannot prove unique board events. No status-derived alarms.
    SQLite FULL synchronous commits provide normal crash recovery; no guarantee
    of upstream delivery or immunity to disk/controller failure is implied.
    """

    def __init__(self, root: str | Path, *, metadata: dict | None = None):
        root = Path(root).resolve()
        root.mkdir(parents=True, exist_ok=True)
        self.session_id = uuid.uuid4().hex
        self.started_at = utc_now()
        name = datetime.now(timezone.utc).strftime("capture_%Y%m%dT%H%M%S_") + self.session_id + ".sqlite3"
        self.path = root / name
        self._lock = threading.Lock()
        self._closed = False
        with self.path.open("xb"):
            pass
        self._db = sqlite3.connect(self.path, timeout=2.0, check_same_thread=False)
        try:
            self._db.execute("PRAGMA synchronous=FULL")
            self._db.executescript("""
                CREATE TABLE session (
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    schema_version INTEGER NOT NULL,
                    host_session_id TEXT NOT NULL,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    metadata_json TEXT NOT NULL,
                    received_al INTEGER NOT NULL DEFAULT 0,
                    failed_al INTEGER NOT NULL DEFAULT 0,
                    received_et INTEGER NOT NULL DEFAULT 0,
                    failed_et INTEGER NOT NULL DEFAULT 0,
                    received_st INTEGER NOT NULL DEFAULT 0,
                    failed_st INTEGER NOT NULL DEFAULT 0,
                    received_ra INTEGER NOT NULL DEFAULT 0,
                    failed_ra INTEGER NOT NULL DEFAULT 0,
                    received_mr INTEGER NOT NULL DEFAULT 0,
                    failed_mr INTEGER NOT NULL DEFAULT 0,
                    received_bm INTEGER NOT NULL DEFAULT 0,
                    failed_bm INTEGER NOT NULL DEFAULT 0,
                    received_vi INTEGER NOT NULL DEFAULT 0,
                    failed_vi INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT
                );
                CREATE TABLE events (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    frame_id INTEGER NOT NULL,
                    timestamp TEXT NOT NULL,
                    stage_id INTEGER NOT NULL,
                    zone_id INTEGER NOT NULL,
                    risk_level INTEGER NOT NULL,
                    event_code INTEGER NOT NULL,
                    device_id INTEGER,
                    boot_id INTEGER,
                    session_id INTEGER,
                    uid TEXT
                );
                CREATE TABLE transaction_events (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    transaction_hex TEXT NOT NULL
                );
                CREATE TABLE status_history (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    elapsed_ns TEXT NOT NULL,
                    canonical_st TEXT NOT NULL
                );
                CREATE TABLE rtc_anchor_history (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    elapsed_ns TEXT NOT NULL,
                    canonical_ra TEXT NOT NULL
                );
                CREATE TABLE maintenance_history (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    elapsed_ns TEXT NOT NULL,
                    canonical_mr TEXT NOT NULL
                );
                CREATE TABLE board_monitor_history (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    elapsed_ns TEXT NOT NULL,
                    canonical_bm TEXT NOT NULL
                );
                CREATE TABLE voice_history (
                    receipt_id INTEGER PRIMARY KEY,
                    received_at TEXT NOT NULL,
                    elapsed_ns TEXT NOT NULL,
                    canonical_vi TEXT NOT NULL
                );
            """)
            with self._db:
                self._db.execute(
                    "INSERT INTO session(singleton,schema_version,host_session_id,started_at,metadata_json) "
                    "VALUES(1,8,?,?,?)",
                    (self.session_id, self.started_at, json.dumps(metadata or {}, ensure_ascii=False)),
                )
        except Exception:
            self._db.close()
            raise

    def append(self, entry: EventLogEntry) -> None:
        encode_event(entry.packet)  # validate the stored protocol values
        if entry.receipt_id < 1:
            raise ValueError("receipt_id must be positive")
        p = entry.packet
        with self._lock:
            if self._closed:
                raise OSError("capture session is closed")
            with self._db:
                ident = entry.identity
                # Timestamp/uid stored as decimal TEXT to preserve the full
                # uint64 protocol range beyond SQLite's signed 64-bit integer.
                self._db.execute(
                    "INSERT INTO events(receipt_id,received_at,frame_id,timestamp,stage_id,"
                    "zone_id,risk_level,event_code,device_id,boot_id,session_id,uid) "
                    "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)", (
                    entry.receipt_id, entry.received_at, p.frame_id, str(p.timestamp),
                    p.stage_id, p.zone_id, p.risk_level, p.event_code,
                    ident.device_id if ident else None, ident.boot_id if ident else None,
                    ident.session_id if ident else None, str(ident.uid) if ident else None))
                self._db.execute("UPDATE session SET received_al=? WHERE singleton=1", (entry.receipt_id,))

    def attach_identity(self, receipt_id: int, identity: EventIdentityPacket) -> None:
        """Fill the v2 identity columns of an already-committed AL receipt."""
        if receipt_id < 1:
            raise ValueError("receipt_id must be positive")
        with self._lock:
            if self._closed:
                raise OSError("capture session is closed")
            with self._db:
                self._db.execute(
                    "UPDATE events SET device_id=?,boot_id=?,session_id=?,uid=? WHERE receipt_id=?",
                    (identity.device_id, identity.boot_id, identity.session_id,
                      str(identity.uid), receipt_id))

    def append_transaction(self, entry: TransactionLogEntry) -> None:
        encode_transaction_event(entry.packet)
        if entry.receipt_id < 1:
            raise ValueError('transaction receipt_id must be positive')
        with self._lock:
            if self._closed:
                raise OSError('capture session is closed')
            with self._db:
                self._db.execute('INSERT INTO transaction_events VALUES(?,?,?)',
                                 (entry.receipt_id, entry.received_at, entry.packet.transaction.hex()))
                self._db.execute('UPDATE session SET received_et=? WHERE singleton=1', (entry.receipt_id,))

    def read(self) -> SessionArchive:
        with self._lock:
            if self._closed:
                return load_session(self.path)
            return _read_session(self._db, self.path)

    def append_status(self, entry: StatusLogEntry) -> None:
        canonical = encode_status(entry.packet).decode('ascii').rstrip('\n')
        if entry.receipt_id < 1 or entry.elapsed_ns < 0:
            raise ValueError('invalid status receipt/time')
        with self._lock:
            if self._closed:
                raise OSError('capture session is closed')
            with self._db:
                self._db.execute('INSERT INTO status_history VALUES(?,?,?,?)',
                                 (entry.receipt_id, entry.received_at, str(entry.elapsed_ns), canonical))
                self._db.execute('UPDATE session SET received_st=? WHERE singleton=1', (entry.receipt_id,))

    def close(self, *, received_al: int, failed_al: int, last_error: str | None,
              received_et: int = 0, failed_et: int = 0,
              received_st: int = 0, failed_st: int = 0,
              received_ra: int = 0, failed_ra: int = 0,
              received_mr: int = 0, failed_mr: int = 0,
              received_bm: int = 0, failed_bm: int = 0,
              received_vi: int = 0, failed_vi: int = 0) -> None:
        with self._lock:
            if self._closed:
                return
            try:
                with self._db:
                    self._db.execute(
                        "UPDATE session SET ended_at=?,received_al=?,failed_al=?,last_error=?,received_et=?,failed_et=?,received_st=?,failed_st=?,received_ra=?,failed_ra=?,received_mr=?,failed_mr=?,received_bm=?,failed_bm=?,received_vi=?,failed_vi=? WHERE singleton=1",
                        (utc_now(), received_al, failed_al, last_error, received_et, failed_et, received_st, failed_st, received_ra, failed_ra, received_mr, failed_mr, received_bm, failed_bm, received_vi, failed_vi))
            finally:
                self._db.close()
                self._closed = True

    def append_anchor(self, entry: AnchorLogEntry) -> None:
        canonical = entry.packet.encode().decode('ascii').rstrip('\n')
        decode_rtc_anchor(canonical)
        if entry.receipt_id < 1 or entry.elapsed_ns < 0:
            raise ValueError('invalid RTC anchor receipt/time')
        with self._lock:
            if self._closed:
                raise OSError('capture session is closed')
            with self._db:
                self._db.execute('INSERT INTO rtc_anchor_history VALUES(?,?,?,?)',
                                 (entry.receipt_id, entry.received_at, str(entry.elapsed_ns), canonical))
                self._db.execute('UPDATE session SET received_ra=? WHERE singleton=1', (entry.receipt_id,))

    def append_maintenance(self, entry: MaintenanceLogEntry) -> None:
        canonical = 'MR,' + entry.packet.raw.hex().upper()
        if decode_result(canonical) != entry.packet or entry.receipt_id < 1 or entry.elapsed_ns < 0:
            raise ValueError('Invalid maintenance receipt')
        with self._lock:
            if self._closed:
                raise OSError('capture session is closed')
            with self._db:
                self._db.execute('INSERT INTO maintenance_history VALUES(?,?,?,?)',
                                 (entry.receipt_id, entry.received_at, str(entry.elapsed_ns), canonical))
                self._db.execute('UPDATE session SET received_mr=? WHERE singleton=1', (entry.receipt_id,))

    def append_board_monitor(self, entry: BoardMonitorLogEntry) -> None:
        canonical = 'BM,' + entry.packet.raw.hex().upper()
        if decode_board_monitor(canonical) != entry.packet or entry.receipt_id < 1 or entry.elapsed_ns < 0:
            raise ValueError('Invalid board monitor receipt')
        with self._lock:
            if self._closed:
                raise OSError('capture session is closed')
            with self._db:
                self._db.execute('INSERT INTO board_monitor_history VALUES(?,?,?,?)',
                                 (entry.receipt_id, entry.received_at, str(entry.elapsed_ns), canonical))
                self._db.execute('UPDATE session SET received_bm=? WHERE singleton=1', (entry.receipt_id,))

    def append_voice(self, entry: VoiceLogEntry) -> None:
        canonical = entry.packet.encode().decode('ascii').rstrip('\n')
        if decode_voice_status(canonical) != entry.packet or entry.receipt_id < 1 or entry.elapsed_ns < 0:
            raise ValueError('Invalid voice receipt')
        with self._lock:
            if self._closed:
                raise OSError('capture session is closed')
            with self._db:
                self._db.execute('INSERT INTO voice_history VALUES(?,?,?,?)',
                                 (entry.receipt_id, entry.received_at, str(entry.elapsed_ns), canonical))
                self._db.execute('UPDATE session SET received_vi=? WHERE singleton=1', (entry.receipt_id,))


def _read_session(db: sqlite3.Connection, path: Path) -> SessionArchive:
    row = db.execute("SELECT schema_version,host_session_id,started_at,ended_at,metadata_json,"
                     "received_al,failed_al,last_error FROM session WHERE singleton=1").fetchone()
    if row is None or row[0] not in (1, 2, 3, 4, 5, 6, 7, 8):
        raise ValueError("Unsupported capture-session database")
    version = row[0]
    base = ("SELECT receipt_id,received_at,frame_id,timestamp,stage_id,zone_id,"
            "risk_level,event_code")
    query = base + (",device_id,boot_id,session_id,uid FROM events ORDER BY receipt_id"
                    if version >= 2 else " FROM events ORDER BY receipt_id")
    entries = []
    previous = 0
    for values in db.execute(query):
        receipt_id, received_at, frame_id, timestamp, stage, zone, risk, code = values[:8]
        if receipt_id <= previous:
            raise ValueError("Invalid receipt order")
        previous = receipt_id
        packet = EventPacket(frame_id, int(timestamp), stage, zone, risk, code)
        encode_event(packet)
        identity = None
        if version >= 2:
            dev, boot, sess, uid = values[8:12]
            if dev is not None:
                identity = EventIdentityPacket(dev, boot, sess, int(uid))
        entries.append(EventLogEntry(received_at, packet, receipt_id, identity))
    observed = max(row[5], previous)
    missing = max(row[6], observed-len(entries))
    transactions = []
    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='transaction_events'").fetchone():
        for receipt, received_at, raw in db.execute('SELECT receipt_id,received_at,transaction_hex FROM transaction_events ORDER BY receipt_id'):
            transactions.append(TransactionLogEntry(received_at, decode_transaction_event(raw), receipt))
    et_received, et_failed = (db.execute('SELECT received_et,failed_et FROM session').fetchone()
                              if version >= 3 else (0, 0))
    et_observed = max(et_received, transactions[-1].receipt_id if transactions else 0)
    statuses = []
    st_received, st_failed = 0, 0
    if version >= 4:
        last_elapsed = -1
        for receipt, received_at, elapsed, raw in db.execute(
                'SELECT receipt_id,received_at,elapsed_ns,canonical_st FROM status_history ORDER BY receipt_id'):
            packet = decode_packet(raw)
            elapsed = int(elapsed)
            if not isinstance(packet, StatusPacket) or receipt < 1 or elapsed < last_elapsed:
                raise ValueError('Invalid archived status receipt/time')
            statuses.append(StatusLogEntry(received_at, packet, receipt, elapsed))
            last_elapsed = elapsed
        st_received, st_failed = db.execute('SELECT received_st,failed_st FROM session').fetchone()
        st_received = max(st_received, statuses[-1].receipt_id if statuses else 0)
        st_failed = max(st_failed, st_received-len(statuses))
    anchors, ra_received, ra_failed = [], 0, 0
    if version >= 5:
        last_elapsed = -1
        for receipt, received_at, elapsed, raw in db.execute(
                'SELECT receipt_id,received_at,elapsed_ns,canonical_ra FROM rtc_anchor_history ORDER BY receipt_id'):
            elapsed = int(elapsed)
            if receipt < 1 or elapsed < last_elapsed:
                raise ValueError('Invalid archived RTC anchor receipt/time')
            anchors.append(AnchorLogEntry(received_at, decode_rtc_anchor(raw), receipt, elapsed))
            last_elapsed = elapsed
        ra_received, ra_failed = db.execute('SELECT received_ra,failed_ra FROM session').fetchone()
        ra_received = max(ra_received, anchors[-1].receipt_id if anchors else 0)
        ra_failed = max(ra_failed, ra_received-len(anchors))
    maintenance, mr_received, mr_failed = [], 0, 0
    if version >= 6:
        last_receipt, last_elapsed = 0, -1
        for receipt, received_at, elapsed, raw in db.execute(
                'SELECT receipt_id,received_at,elapsed_ns,canonical_mr FROM maintenance_history ORDER BY receipt_id'):
            elapsed = int(elapsed)
            if receipt <= last_receipt or elapsed < last_elapsed:
                raise ValueError('Invalid archived maintenance receipt/time')
            maintenance.append(MaintenanceLogEntry(received_at, decode_result(raw), receipt, elapsed))
            last_receipt, last_elapsed = receipt, elapsed
        mr_received, mr_failed = db.execute('SELECT received_mr,failed_mr FROM session').fetchone()
        mr_received = max(mr_received, last_receipt)
        mr_failed = max(mr_failed, mr_received-len(maintenance))
    monitors, bm_received, bm_failed = [], 0, 0
    if version >= 7:
        last_receipt, last_elapsed = 0, -1
        for receipt, received_at, elapsed, raw in db.execute(
                'SELECT receipt_id,received_at,elapsed_ns,canonical_bm FROM board_monitor_history ORDER BY receipt_id'):
            elapsed = int(elapsed)
            if receipt <= last_receipt or elapsed < last_elapsed:
                raise ValueError('Invalid board-monitor receipt/time')
            monitors.append(BoardMonitorLogEntry(received_at, decode_board_monitor(raw), receipt, elapsed))
            last_receipt, last_elapsed = receipt, elapsed
        bm_received, bm_failed = db.execute('SELECT received_bm,failed_bm FROM session').fetchone()
        bm_received = max(bm_received,last_receipt)
        bm_failed = max(bm_failed,bm_received-len(monitors))
    voice, vi_received, vi_failed = [], 0, 0
    if version >= 8:
        last_receipt, last_elapsed = 0, -1
        for receipt, received_at, elapsed, raw in db.execute(
                'SELECT receipt_id,received_at,elapsed_ns,canonical_vi FROM voice_history ORDER BY receipt_id'):
            elapsed = int(elapsed)
            if receipt <= last_receipt or elapsed < last_elapsed:
                raise ValueError('Invalid voice receipt/time')
            voice.append(VoiceLogEntry(received_at, decode_voice_status(raw), receipt, elapsed))
            last_receipt, last_elapsed = receipt, elapsed
        vi_received, vi_failed = db.execute('SELECT received_vi,failed_vi FROM session').fetchone()
        vi_received = max(vi_received, last_receipt)
        vi_failed = max(vi_failed, vi_received-len(voice))
    return SessionArchive(row[1], str(path), row[2], row[3], json.loads(row[4]),
                          tuple(entries), observed, missing, row[7], tuple(transactions),
                          et_observed, max(et_failed, et_observed-len(transactions)),
                            tuple(statuses), st_received, st_failed, tuple(anchors), ra_received, ra_failed,
                            tuple(maintenance), mr_received, mr_failed,tuple(monitors),bm_received,bm_failed,
                            tuple(voice),vi_received,vi_failed)


def load_session(path: str | Path) -> SessionArchive:
    """Read an archived or active session without creating/changing its DB."""
    path = Path(path).resolve()
    if not path.is_file():
        raise FileNotFoundError(path)
    db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2.0)
    try:
        result = db.execute("PRAGMA quick_check").fetchone()
        if result != ("ok",):
            raise ValueError("Capture database integrity check failed: " + str(result))
        # One read transaction, including session counters and event rows.
        db.execute("BEGIN")
        return _read_session(db, path)
    finally:
        db.close()
