"""Explicit GUI-selected data source for JoyCode's existing stdio MCP connection."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from uuid import uuid4

from .agent_tools import AgentSource, ToolError


SOURCE_TTL_SECONDS = 15


class SourceSelectionError(ToolError):
    """A safe, actionable source-selection error that can be shown to the model."""


def source_signature(source):
    return (str(Path(source.session_path).resolve()) if source.session_path else None,
            str(Path(source.evidence_root).resolve()), source.snapshot is not None)


class SourcePublisher:
    def __init__(self, path, *, now=None):
        self.path = Path(path).resolve()
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.owner = uuid4().hex
        self.selection_id = None
        self.signature = None
        self.last_write = None

    def publish(self, source, *, force=False):
        signature = source_signature(source)
        if signature[0] is None or not Path(signature[0]).is_file():
            raise SourceSelectionError('当前没有可查询的会话存档，请检查上位机存档状态。')
        stamp = self.now()
        changed = signature != self.signature
        selection_id = uuid4().hex if changed else self.selection_id
        if not force and not changed and self.path.is_file() and self.last_write and 0 <= (stamp - self.last_write).total_seconds() < 3:
            return
        record = dict(version=1, owner=self.owner, active=True, selection_id=selection_id,
                      heartbeat_at=stamp.isoformat(), session_path=signature[0],
                      evidence_root=signature[1], selection_mode='current' if signature[2] else 'archive')
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=self.path.parent,
                                             prefix='joycode_source_', suffix='.tmp', delete=False) as stream:
                temporary = Path(stream.name)
                json.dump(record, stream, ensure_ascii=False)
            temporary.replace(self.path)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
        self.signature, self.selection_id, self.last_write = signature, selection_id, stamp

    def close(self):
        # Another application may have registered a newer selection in the meantime.
        try:
            record = json.loads(self.path.read_text(encoding='utf-8'))
            if isinstance(record, dict) and record.get('owner') == self.owner:
                self.path.unlink(missing_ok=True)
        except (OSError, ValueError):
            pass


class SelectedSource:
    """Re-read only the explicit selection, never scan for a 'latest' database."""
    def __init__(self, path, *, now=None):
        self.path = Path(path)
        self.now = now or (lambda: datetime.now(timezone.utc))
        self.selection_id = None
        self.requires_refresh = False
        self.context = {}

    def resolve(self, tool_name):
        try:
            record = json.loads(self.path.read_text(encoding='utf-8'))
            if (not isinstance(record, dict) or record.get('version') != 1 or record.get('active') is not True
                    or not isinstance(record.get('selection_id'), str) or not record['selection_id']
                    or record.get('selection_mode') not in ('current', 'archive')):
                raise ValueError('invalid selection')
            stamp = datetime.fromisoformat(record['heartbeat_at'])
            age = (self.now() - stamp).total_seconds()
            if not 0 <= age <= SOURCE_TTL_SECONDS:
                raise ValueError('expired selection')
            session, evidence = Path(record['session_path']), Path(record['evidence_root'])
            if not session.is_absolute() or not evidence.is_absolute() or not session.is_file():
                raise ValueError('invalid paths')
        except (OSError, ValueError, KeyError, TypeError, OverflowError):
            # Invalidate any prior multi-tool chain, including after a GUI crash/restart.
            self.requires_refresh = self.selection_id is not None
            raise SourceSelectionError('上位机联动未就绪或已停止。请启动监考台，在“JoyCode 联动”页刷新；不会回退旧存档。') from None
        if self.selection_id is not None and record['selection_id'] != self.selection_id:
            self.requires_refresh = True
        self.selection_id = record['selection_id']
        if tool_name in ('get_recent_events', 'get_system_health'):
            self.requires_refresh = False
        elif self.requires_refresh:
            raise SourceSelectionError('上位机已切换会话或证据目录，请先重新调用 get_recent_events 或 get_system_health，再复核事件。')
        self.context = dict(selection_id=self.selection_id, selection_mode=record['selection_mode'],
                            selected_session=session.name,
                            source_note='上位机选择与数据联动已就绪；MCP只读落盘数据，不构成设备实时在线证明。')
        label = 'MCP上位机当前所选会话' if record['selection_mode'] == 'current' else 'MCP上位机所选历史存档'
        return AgentSource(session, evidence, label=label + '（仅落盘数据，非实时在线证明）')


def joycode_mcp_config(registry_path, *, python=None):
    root = Path(__file__).resolve().parents[2]
    executable = Path(python or sys.executable)
    if executable.name.lower() == 'pythonw.exe' and executable.with_name('python.exe').is_file():
        executable = executable.with_name('python.exe')
    return dict(mcpServers=dict(examguard=dict(type='stdio', command=str(executable),
                args=['-u', str(root / 'start_agent_mcp.py'), '--current-session-file', str(Path(registry_path).resolve())],
                env=dict(PYTHONUTF8='1'))))


def launch_joycode():
    # Launch only the known user-installed application shortcut; no private APIs/cookies.
    shortcut = Path.home() / 'OneDrive' / 'Desktop' / 'JoyCode.lnk'
    if os.name != 'nt' or not shortcut.is_file():
        raise OSError('未找到 JoyCode 桌面快捷方式，请手动打开已安装的 JoyCode。')
    os.startfile(str(shortcut))
