"""Read-only Agent tools. Reuse the recorder and strict ET/EG/HR review rules."""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
import re
import sqlite3
import threading
import time

from .board_monitor import decode_board_monitor
from .exam_events import format_event, format_health, stage_name
from .protocol import decode_packet
from .review import HISTORY_LABELS, history_details, load_evidence_review
from .transaction_protocol import decode_transaction_event


class ToolError(ValueError):
    pass


@dataclass(frozen=True)
class AgentSource:
    session_path: Path | None
    evidence_root: Path
    snapshot: object = None
    label: str = '当前采集会话'


def _integer(value, name, lower, upper):
    if type(value) is not int or not lower <= value <= upper:
        raise ToolError(f'{name} 必须是 {lower} 到 {upper} 的整数')
    return value


class AgentTools:
    """One request's source, never an LLM-supplied SQL string or filesystem path."""

    def __init__(self, source: AgentSource, *, cancelled=None, now=None):
        self.source = source
        self.cancelled = cancelled or threading.Event()
        self.now = now or datetime.now(timezone.utc)
        self._evidence_cache = {}

    def _check(self):
        if self.cancelled.is_set():
            raise ToolError('本次查询已取消')

    @contextmanager
    def _db(self):
        self._check()
        if self.source.session_path is None:
            raise ToolError('没有可查询的会话存档；请先启动监测或选择存档')
        uri = Path(self.source.session_path).resolve().as_uri() + '?mode=ro'
        try:
            db = sqlite3.connect(uri, uri=True, timeout=2)
        except sqlite3.Error as exc:
            raise ToolError('无法只读打开所选会话存档') from exc
        db.row_factory = sqlite3.Row
        deadline = time.monotonic() + 8
        db.set_progress_handler(lambda: int(self.cancelled.is_set() or time.monotonic() > deadline), 1000)
        try:
            db.execute('PRAGMA query_only=ON')
            db.execute('BEGIN')
            row = db.execute('SELECT schema_version FROM session WHERE singleton=1').fetchone()
            if row is None or not 3 <= row[0] <= 8:
                raise ToolError('不支持的会话版本；请选择本工程的监考存档')
            yield db
        except sqlite3.Error as exc:
            raise ToolError('存档读取失败或查询超时；本次结果不可用') from exc
        finally:
            db.close()

    @staticmethod
    def _has_table(db, table):
        return db.execute('SELECT 1 FROM sqlite_master WHERE type=? AND name=?', ('table', table)).fetchone() is not None

    def _cutoff(self, time_range):
        _integer(time_range, 'time_range（分钟）', 1, 1440)
        return (self.now - timedelta(minutes=time_range)).isoformat(timespec='milliseconds')

    def get_recent_events(self, time_range=30, event_code=None, limit=10):
        """time_range is minutes of PC receipt time, never FPGA uptime."""
        cutoff = self._cutoff(time_range)
        _integer(limit, 'limit', 1, 50)
        if event_code is not None:
            _integer(event_code, 'event_code', 0, 255)
        with self._db() as db:
            meta = dict(db.execute('SELECT * FROM session WHERE singleton=1').fetchone())
            rows = db.execute('SELECT receipt_id,received_at,transaction_hex FROM transaction_events '
                              'WHERE received_at>=? AND received_at<=? ORDER BY receipt_id DESC LIMIT 501',
                              (cutoff, self.now.isoformat(timespec='milliseconds'))).fetchall()
            # AL and ET have different namespaces. Never add them into one event count.
            alarms = db.execute('SELECT received_at,event_code FROM events WHERE received_at>=? AND received_at<=? '
                                'ORDER BY receipt_id DESC LIMIT 501',
                                (cutoff, self.now.isoformat(timespec='milliseconds'))).fetchall()
        packets, seen = [], set()
        for row in rows[:500]:
            packet = decode_transaction_event(row['transaction_hex'])
            if packet.transaction in seen:
                continue
            seen.add(packet.transaction)
            if event_code is None or packet.event_code == event_code:
                packets.append(self._event(packet, row['received_at'], row['receipt_id']))
        legacy = [dict(received_at=r['received_at'], event=format_event(r['event_code']))
                  for r in alarms[:500] if event_code is None or r['event_code'] == event_code]
        return dict(source=self.source.label, host_session_id=meta['host_session_id'],
                    queried_at=self.now.isoformat(), time_basis='PC接收时间（UTC）；不是事件发生的墙钟时间',
                    time_range_minutes=time_range, events=packets[:limit],
                    unique_transactions_in_scanned_rows=len(packets), scanned_receipts=min(len(rows), 500),
                    scan_truncated=len(rows) > 500, display_truncated=len(packets) > limit,
                    legacy_alarm_receipts=legacy[:limit], legacy_receipts_in_scanned_rows=len(legacy),
                    legacy_scan_truncated=len(alarms) > 500,
                    persistence_error=(getattr(self.source.snapshot, 'persistence_error', None) or meta.get('last_error')),
                    note='ET为已接收的疑似事件；AL单列、不与ET相加；未发现记录不等于没有发生。最多检查最近500条回执。')

    @staticmethod
    def _event(packet, received_at=None, receipt_id=None):
        dev, boot, session, uid = packet.identity
        return dict(event_ref=packet.transaction.hex().upper(), device=str(dev), boot=str(boot),
                    session=str(session), event_uid=str(uid), source_time_ms=str(packet.timestamp),
                    received_at=received_at, receipt_id=receipt_id,
                    event_code=packet.event_code, event_code_hex=f'0x{packet.event_code:02X}',
                    event=format_event(packet.event_code),
                    stage=stage_name(packet.stage_id), assessment='疑似，需人工复核')

    def resolve_event(self, event_ref):
        if not isinstance(event_ref, str) or len(event_ref) > 80:
            raise ToolError('event_ref 必须是工具返回的事件引用，或明确的十进制UID')
        with self._db() as db:
            if re.fullmatch(r'[0-9A-Fa-f]{64}', event_ref):
                rows = db.execute('SELECT DISTINCT upper(transaction_hex) FROM transaction_events '
                                  'WHERE upper(transaction_hex)=? LIMIT 3', (event_ref.upper(),)).fetchall()
            elif re.fullmatch(r'[0-9]{1,20}', event_ref) and 0 < int(event_ref) < 2**64:
                rows = db.execute('SELECT DISTINCT upper(transaction_hex) FROM transaction_events '
                                  'WHERE upper(substr(transaction_hex,25,16))=? LIMIT 3',
                                  (f'{int(event_ref):016X}',)).fetchall()
            else:
                raise ToolError('事件引用格式无效')
            if not rows:
                raise ToolError('当前会话没有该ET事件；不能凭UID猜测图像关联')
            if len(rows) != 1:
                raise ToolError('UID对应多个事件，请从事件列表选择完整引用，不能只按UID关联')
            packet = decode_transaction_event(rows[0][0])
            contexts = db.execute('SELECT DISTINCT upper(transaction_hex) FROM transaction_events '
                                  'WHERE upper(substr(transaction_hex,1,40))=? LIMIT 2',
                                  (packet.transaction[:20].hex().upper(),)).fetchall()
            if len(contexts) > 1:
                raise ToolError('同一完整身份存在冲突事务，拒绝自动关联证据')
        return packet

    def _review(self, event_ref):
        packet = self.resolve_event(event_ref)
        key = packet.transaction.hex().upper()
        if key not in self._evidence_cache:
            self._check()
            windows, errors = load_evidence_review(self.source.evidence_root, event=packet, cancelled=self.cancelled)
            exact = [w for w in windows if w.get('transaction') == packet.transaction]
            conflict = any(w.get('identity') == packet.identity and w.get('transaction') != packet.transaction for w in windows)
            if errors or conflict or len(exact) > 1:
                verdict = 'invalid'
            elif exact:
                verdict = exact[0]['history_verdict']
            else:
                verdict = 'not_received'
            self._evidence_cache[key] = (packet, exact, errors, verdict)
        return self._evidence_cache[key]

    def check_evidence_status(self, event_ref):
        packet, windows, errors, verdict = self._review(event_ref)
        return dict(source=self.source.label, scope='selected_session_and_evidence_directory',
                    event_ref=packet.transaction.hex().upper(), event_uid=str(packet.identity[3]),
                    event_code=packet.event_code, event_code_hex=f'0x{packet.event_code:02X}',
                    event=format_event(packet.event_code),
                    status=verdict, status_label=HISTORY_LABELS.get(verdict, '尚无可关联证据'),
                    received_frames=sum(len(w['frames']) for w in windows),
                    expected_frames=windows[0]['expected'] if len(windows) == 1 else None,
                    missing_frame_indices=windows[0].get('missing_indices', []) if len(windows) == 1 else [],
                    details=[history_details(w) for w in windows],
                    validation_errors=len(errors),
                    note='仅查询选定会话和证据目录；未查到不代表从未采集或PC从未收到，也不能确定网络原因。'
                         '像素缺失不能直接换算UDP丢包数；证据完整也不代表已确认违规。')

    def get_image_path(self, event_ref):
        packet, windows, errors, verdict = self._review(event_ref)
        images = []
        if verdict != 'invalid':
            root = Path(self.source.evidence_root).resolve()
            for window in windows:
                for frame in window['frames']:
                    path = (window['path'] / frame['file']).resolve()
                    if not path.is_relative_to(root) or not path.is_file():
                        raise ToolError('证据路径越界或图像已不可用')
                    images.append(dict(path=str(path), frame_index=frame['index'],
                                       frame_id=str(frame['frame_id']), timestamp_ms=str(frame['timestamp_ms']),
                                       sha256=frame.get('sha256')))
        return dict(source=self.source.label, scope='selected_session_and_evidence_directory',
                    event_ref=packet.transaction.hex().upper(), event_uid=str(packet.identity[3]),
                    event_code=packet.event_code, event_code_hex=f'0x{packet.event_code:02X}',
                    event=format_event(packet.event_code), status=verdict, images=images[:32],
                    display_truncated=len(images) > 32,
                    note='仅返回选定会话和证据目录内校验通过的现有PPM帧；空列表不代表从未采集。'
                         '路径不等于已经看过图像，不承诺前后两秒或连续录像。')

    def get_system_health(self):
        with self._db() as db:
            meta = dict(db.execute('SELECT * FROM session WHERE singleton=1').fetchone())
            status = db.execute('SELECT received_at,canonical_st FROM status_history ORDER BY receipt_id DESC LIMIT 1').fetchone()
            board = (db.execute('SELECT received_at,canonical_bm FROM board_monitor_history ORDER BY receipt_id DESC LIMIT 1').fetchone()
                     if self._has_table(db, 'board_monitor_history') else None)
        def age(row):
            if row is None:
                return None
            stamp = datetime.fromisoformat(row['received_at'])
            if stamp.tzinfo is None:
                raise ToolError('存档时间缺少时区，无法判断新鲜程度')
            return (self.now - stamp).total_seconds()
        status_age, board_age = age(status), age(board)
        live = self.source.snapshot is not None and meta['ended_at'] is None
        fresh = live and status_age is not None and 0 <= status_age <= 3
        packet = decode_packet(status['canonical_st']) if status else None
        bm = decode_board_monitor(board['canonical_bm']) if board else None
        temperature = (round(bm.adc[0] * 503.975 / 65536 - 273.15, 1)
                       if bm and bm.valid and live and 0 <= board_age <= 3 else None)
        snapshot = self.source.snapshot
        return dict(source=self.source.label, live_session=live,
                    status='fresh' if fresh else ('stale' if status else 'unknown'),
                    last_status_received_at=status['received_at'] if status else None,
                    status_age_seconds=round(status_age, 3) if status_age is not None else None,
                    stage=stage_name(packet.state_id) if packet else '未知',
                    reported_health=(format_health(packet.health_flags) if packet and len(status['canonical_st'].strip().split(',')) >= 11 else '未知（无健康字段）'),
                    fpga_temperature_c=temperature,
                    temperature_status='fresh' if temperature is not None else 'unknown_or_stale',
                    transport='近期收到状态回执' if fresh else '未知或状态停更；不能据此宣布网络正常',
                    evidence_network_summary=packet.evidence_health.phy_text if packet and packet.evidence_health else '未上报',
                    persistence_error=(getattr(snapshot, 'persistence_error', None) or meta.get('last_error')),
                    persistence_failures=(getattr(snapshot, 'persistence_failures', 0) or sum(v for k, v in meta.items() if k.startswith('failed_'))),
                    note='温度仅为芯片内部测量；历史存档不代表当前在线，未接收不能报告为正常。')

    def call(self, name, arguments):
        if name not in TOOL_NAMES or not isinstance(arguments, dict):
            raise ToolError('不支持的工具或参数类型')
        allowed = {'get_recent_events': {'time_range', 'event_code', 'limit'},
                   'get_system_health': set(), 'check_evidence_status': {'event_ref'},
                   'get_image_path': {'event_ref'}}[name]
        if set(arguments) - allowed:
            raise ToolError('工具包含未支持的参数')
        if name in ('check_evidence_status', 'get_image_path') and 'event_ref' not in arguments:
            raise ToolError('缺少event_ref')
        self._check()
        return getattr(self, name)(**arguments)


TOOL_NAMES = ('get_recent_events', 'check_evidence_status', 'get_image_path', 'get_system_health')
TOOL_SCHEMAS = [
    dict(type='function', function=dict(name='get_recent_events',
         description='按PC接收时间查当前选定会话最近的疑似ET事件；AL另列不相加；无记录不代表没有发生。',
         parameters=dict(type='object', properties=dict(
             time_range=dict(type='integer', minimum=1, maximum=1440, description='最近多少分钟，默认30'),
             event_code=dict(type='integer', minimum=0, maximum=255, description='手机80/资料81/扭头96；省略查全部'),
             limit=dict(type='integer', minimum=1, maximum=50)), additionalProperties=False))),
    *[dict(type='function', function=dict(name=name, description=description,
          parameters=dict(type='object', properties=dict(event_ref=dict(type='string', description='优先使用get_recent_events返回的完整event_ref；UID只有唯一时才接受')),
                          required=['event_ref'], additionalProperties=False)))
      for name, description in (
          ('check_evidence_status', '校验ET、最新EG像素和HR的完整性，同时返回event_code事件类型；event_uid只是编号，不能转换成类型。'),
          ('get_image_path', '返回已校验PPM路径、帧时间和event_code事件类型；event_uid只是编号，不代表类型；不能获取不存在的视频。'))],
    dict(type='function', function=dict(name='get_system_health', description='查询最后状态和芯片温度；明确未知或停更。',
         parameters=dict(type='object', properties={}, additionalProperties=False))),
]
