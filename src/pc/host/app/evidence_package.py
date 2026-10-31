"""Immutable scoped evidence ZIP, verified again from its own bytes.

Hashes detect changed bytes, not signatures/authentication. Latest published EG
revisions only; no inferred completeness outside this selected directory/session.
"""
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import sqlite3
import stat
import tempfile
import zipfile

from .event_store import load_session
from .monitor import MonitorModel
from .protocol import decode_packet
from .review import load_evidence_review, export_report

SCHEMA = 'examguard-evidence-package-v1'
MAX_FILES = 100000
MAX_BYTES = 2 * 1024**3
MAX_MEMBER_BYTES = 64 * 1024**2


def _summary(windows):
    return dict(counts=dict(sorted(Counter(w.get('history_verdict', 'legacy') for w in windows).items())),
                windows=[dict(protocol=w.get('protocol', 'PGv1'),
                              transaction_hex=w['transaction'].hex().upper() if w.get('transaction') else None,
                              identity=list(w['identity']) if w.get('identity') else None,
                              status=w.get('status'), history_verdict=w.get('history_verdict'),
                              received_frames=len(w['frames']), expected_frames=w['expected'],
                              missing_indices=w.get('missing_indices')) for w in windows])


def _review(root):
    windows, errors = load_evidence_review(root)
    invalid = [w for w in windows if w.get('history_verdict') == 'invalid']
    if errors or invalid:
        raise ValueError('Evidence validation failed: ' + '; '.join(errors + [str(w['path']) for w in invalid]))
    return windows


def _temp(parent=None):
    # Default artifact work goes to the harness-approved temporary directory.
    approved = Path('C:/Users/35225/AppData/Local/Temp/opencode')
    return tempfile.TemporaryDirectory(prefix='examguard_package_', dir=parent or (approved if approved.is_dir() else None))


def _copy_file(source, destination):
    if source.is_symlink() or not source.is_file():
        raise ValueError(f'Expected a regular evidence file: {source}')
    if source.stat().st_size > MAX_MEMBER_BYTES:
        raise ValueError(f'Package member exceeds capacity: {source}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive destinations; never write back into the evidence directory.
    with source.open('rb') as incoming, destination.open('xb') as outgoing:
        shutil.copyfileobj(incoming, outgoing)


def _uart_summary(path):
    raw = path.read_bytes()
    complete, _, tail = raw.rpartition(b'\n')
    counts = Counter()
    for line in complete.split(b'\n') if complete else ():
        decode_packet(line)
        counts[line[:2].decode('ascii')] += 1
    return dict(bytes=len(raw), complete_lines=dict(sorted(counts.items())), trailing_partial_bytes=len(tail))


def export_evidence_package(root, output, *, session_path=None, uart_path=None, metadata=None):
    """Export fresh ZIP without modifying sources; verify staged AND ZIP content.

    Live SQLite is snapshotted using its read-only backup API. Evidence writers
    may continue publishing revisions, but the exact selected files are rechecked
    after copy. An inconsistent changing source fails instead of publishing it.
    """
    root, output = Path(root).resolve(), Path(output).absolute()
    if not root.is_dir() or not output.parent.is_dir():
        raise ValueError('Existing evidence directory and output parent required')
    if output.exists():
        raise FileExistsError(output)
    windows = _review(root)
    if not windows and not session_path and not uart_path:
        raise ValueError('No published evidence or capture session selected')
    with _temp() as temporary:
        stage = Path(temporary)
        evidence = stage/'evidence'
        evidence.mkdir()
        selected = set()
        for w in windows:
            if w.get('protocol') == 'EGv2':
                selected.add(w['path']/'manifest.json')
                selected.add(w['path']/'packets.bin')
                selected.update(w['path']/frame['file'] for frame in w['frames'])
            elif w.get('protocol') != 'HR':
                selected.add(w['path']/'manifest.json')
                selected.update(w['path']/frame['file'] for frame in w['frames'])
            for h in w.get('history', ()):
                selected.update((h.manifest_path, h.raw_path))
        if len(selected)>MAX_FILES or sum(p.stat().st_size for p in selected)>MAX_BYTES:
            raise ValueError('Selected evidence exceeds package capacity')
        for source in sorted(selected):
            # Resolved containment also rejects directory symlink escape.
            relative = source.resolve().relative_to(root)
            _copy_file(source, evidence/relative)
        diagnostic = root/'udp_ingress_diagnostics.json'
        if diagnostic.is_file():
            _copy_file(diagnostic, evidence/diagnostic.name)
        staged_windows = _review(evidence)
        expected = _summary(windows)
        if _summary(staged_windows) != expected:
            raise ValueError('Evidence changed while copying; original archive retained')
        session = None
        if session_path:
            source_path = Path(session_path).resolve()
            if not source_path.is_file():
                raise FileNotFoundError(source_path)
            incoming = sqlite3.connect(source_path.as_uri()+'?mode=ro', uri=True)
            outgoing = sqlite3.connect(stage/'capture.sqlite3')
            try:
                incoming.backup(outgoing)
            finally:
                outgoing.close();incoming.close()
            session = load_session(stage/'capture.sqlite3')
        uart = None
        if uart_path:
            _copy_file(Path(uart_path), stage/'capture.raw')
            uart = _uart_summary(stage/'capture.raw')
        model = MonitorModel()
        # Without a DB, never fabricate receipt UTCs by replaying raw UART.
        # The raw capture is independently counted and preserved in metadata.
        export_report(stage/'report.md', model.snapshot(), staged_windows, [], session=session)
        text = (stage/'report.md').read_text(encoding='utf-8')
        # Portable evidence links refer to members, never a deleted staging dir.
        text = text.replace(str(stage)+'\\', '').replace(str(stage)+'/', '')
        (stage/'report.md').write_text('> 离线取证包：范围为所选目录/会话；文件哈希不是签名。报告导出时间不是现场接收时间。\n\n'+text, encoding='utf-8')
        rows, total = [], 0
        for path in sorted(stage.rglob('*')):
            if not path.is_file():
                continue
            size = path.stat().st_size
            total += size
            if size > MAX_MEMBER_BYTES or total > MAX_BYTES or len(rows) >= MAX_FILES:
                raise ValueError('Evidence package exceeds capacity')
            rows.append(dict(path=path.relative_to(stage).as_posix(), bytes=size,
                             sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
        manifest = dict(schema=SCHEMA, created_utc=datetime.now(timezone.utc).isoformat(),
                        scope='Latest published EG revisions + all associated HR/PG + optional selected host session/raw UART',
                        evidence=expected, session=bool(session), uart=uart,
                        metadata=metadata or {}, files=rows, total_bytes=total,
                        limitations='No signature/authentication, no inferred zero packet loss or target visibility, no K230 source images, no active/unpublished memory or pending recovery.')
        with zipfile.ZipFile(output, 'x', zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            for row in rows:
                archive.write(stage/row['path'], row['path'])
            archive.writestr('package_manifest.json', json.dumps(manifest, ensure_ascii=False, indent=2))
    # An exception leaves the newly created artifact for diagnosis; never removes
    # user data or substitutes an older complete package. Success requires verify.
    return verify_evidence_package(output)


def _safe_name(name):
    p = PurePosixPath(name)
    if (not name or '\\' in name or ':' in name or p.is_absolute() or
            any(v in ('', '.', '..') for v in name.split('/')) or name.endswith('/')):
        raise ValueError(f'Unsafe package member: {name}')
    return name


def verify_evidence_package(path):
    """Check ZIP membership/hash, then reassemble CRC evidence from ZIP bytes."""
    path = Path(path)
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [_safe_name(i.filename) for i in entries]
        if len(names) != len(set(n.casefold() for n in names)) or len(names) > MAX_FILES+1:
            raise ValueError('Duplicate or excessive package members')
        if any(stat.S_ISLNK(i.external_attr >> 16) for i in entries):
            raise ValueError('Package must not contain links')
        if archive.getinfo('package_manifest.json').file_size > 16*1024**2:
            raise ValueError('Package manifest exceeds capacity')
        manifest = json.loads(archive.read('package_manifest.json'))
        if manifest.get('schema') != SCHEMA:
            raise ValueError('Unsupported evidence package schema')
        rows = manifest['files']
        listed = [_safe_name(r['path']) for r in rows]
        if len(listed) != len(set(n.casefold() for n in listed)) or set(names) != set(listed) | {'package_manifest.json'}:
            raise ValueError('Package membership differs from manifest')
        total = sum(i.file_size for i in entries if i.filename != 'package_manifest.json')
        if total != manifest['total_bytes'] or total > MAX_BYTES:
            raise ValueError('Package total capacity/length mismatch')
        with _temp() as temporary:
            stage = Path(temporary)
            for row in rows:
                info = archive.getinfo(row['path'])
                if info.file_size != row['bytes'] or info.file_size > MAX_MEMBER_BYTES:
                    raise ValueError('Package member size mismatch/capacity')
                data = archive.read(row['path'])
                if hashlib.sha256(data).hexdigest() != row['sha256']:
                    raise ValueError('Package file hash mismatch: '+row['path'])
                dest = stage/row['path']
                dest.parent.mkdir(parents=True, exist_ok=True)
                with dest.open('xb') as target:
                    target.write(data)
            windows = _review(stage/'evidence')
            if _summary(windows) != manifest['evidence']:
                raise ValueError('Package semantic verdict differs from manifest')
            if manifest['session']:
                load_session(stage/'capture.sqlite3')
            if manifest['uart'] is not None and _uart_summary(stage/'capture.raw') != manifest['uart']:
                raise ValueError('Package UART summary mismatch')
    return dict(verified=True, path=str(path.resolve()), files=len(rows), source_bytes=total,
                evidence=manifest['evidence'], session=manifest['session'], uart=manifest['uart'])
