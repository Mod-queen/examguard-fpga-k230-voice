"""Verified import of K230 inference-source assets; no clock-based auto-binding."""
from __future__ import annotations

import base64
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import tempfile
from datetime import datetime, timezone

SCHEMA = 'examguard-k230-source-v1'
ID = re.compile(r'k[0-9a-f]{16}_[0-9]{6}')
MAX_BYTES = 16 * 1024 * 1024
MAX_MANIFEST = 65536


def validate_manifest(m):
    if m.get('schema') != SCHEMA or not ID.fullmatch(m.get('capture_id', '')):
        raise ValueError('Invalid K230 schema/capture identity')
    if m.get('k230_run_id') != m['capture_id'].rsplit('_', 1)[0]:
        raise ValueError('K230 run identity mismatch')
    for name in ('frame_id', 'captured_ms'):
        if type(m.get(name)) is not int or not 0 <= m[name] <= 2**64-1:
            raise ValueError('Invalid ' + name)
    assets = m.get('assets')
    if not isinstance(assets, list) or not 1 <= len(assets) <= 2:
        raise ValueError('Invalid asset count')
    names = set()
    for a in assets:
        if a.get('file') not in ('inference.rgb', 'color.rgb') or a['file'] in names:
            raise ValueError('Invalid/duplicate source asset')
        names.add(a['file'])
        if a.get('role') != ('inference_source' if a['file'] == 'inference.rgb' else 'color_auxiliary'):
            raise ValueError('Incorrect camera role')
        expected_layout = 'CHW_RGB888' if a['file'] == 'inference.rgb' else 'HWC_RGB888'
        if a.get('layout') != expected_layout:
            raise ValueError('Incorrect source layout')
        w, h = a.get('width'), a.get('height')
        if type(w) is not int or type(h) is not int or not (1 <= w <= 1920 and 1 <= h <= 1080):
            raise ValueError('Invalid source dimensions')
        if type(a.get('bytes')) is not int or a['bytes'] != w*h*3:
            raise ValueError('Invalid image length')
        if not re.fullmatch('[0-9a-f]{64}', a.get('sha256', '')):
            raise ValueError('Invalid image SHA256')
    if 'inference.rgb' not in names:
        raise ValueError('Missing actual inference input')
    if sum(a['bytes'] for a in assets) > MAX_BYTES:
        raise ValueError('Oversize capture')
    triggers = m.get('triggers')
    if not isinstance(triggers, list) or not triggers or any(
            t not in ('phone', 'notes', 'gaze') for t in triggers):
        raise ValueError('Invalid capture triggers')
    if m.get('source') != 'k230_camera' or m.get('fpga_event') is not None or m.get('association') != 'unbound':
        raise ValueError('Invalid source/unsolicited FPGA binding')
    def valid_box(box):
        return isinstance(box, list) and len(box) == 4 and all(
            isinstance(v, (int, float)) and math.isfinite(v) for v in box) and box[2] > 0 and box[3] > 0
    obs = m.get('observation')
    if obs and obs.get('fresh'):
        if not valid_box(obs.get('box')):
            raise ValueError('Invalid selected box')
    raw = m.get('raw_detections')
    if not isinstance(raw, list) or len(raw) > 100:
        raise ValueError('Invalid raw detections')
    for det in raw:
        if not valid_box(det.get('box')) or not isinstance(det.get('raw_score'), (int, float)) or not (
                0 <= det['raw_score'] <= 1):
            raise ValueError('Invalid raw model detection')
    colors = m.get('color') or {}
    for key in ('purple', 'blue'):
        boxes = colors.get(key, [])
        if not isinstance(boxes, list) or len(boxes) > 1000 or not all(valid_box(b) for b in boxes):
            raise ValueError('Invalid auxiliary boxes')
    if (colors.get('purple') or colors.get('blue')) and 'color.rgb' not in names:
        raise ValueError('Missing actual auxiliary source')
    for box in (m.get('gaze') or {}).get('boxes', []):
        if not valid_box(box):
            raise ValueError('Invalid gaze source box')
    coordinate_size = m.get('settings', {}).get('box_coordinate_size', [1, 1])
    if len(coordinate_size) != 2 or any(type(v) is not int or v <= 0 for v in coordinate_size):
        raise ValueError('Invalid coordinate scale')
    # Content, not arrival time, establishes source-frame identity.
    return m


def read_manifest(path):
    path = Path(path)
    if path.stat().st_size > MAX_MANIFEST:
        raise ValueError('Oversize manifest')
    return validate_manifest(json.loads(path.read_text(encoding='utf-8')))


def verify_assets(directory, manifest):
    directory = Path(directory).resolve()
    for a in manifest['assets']:
        path = (directory / a['file']).resolve()
        if path.parent != directory or path.stat().st_size != a['bytes']:
            raise ValueError('Missing/truncated source: ' + a['file'])
        if hashlib.sha256(path.read_bytes()).hexdigest() != a['sha256']:
            raise ValueError('Source SHA256 mismatch: ' + a['file'])


def ppm_pixels(raw, asset):
    w, h = asset['width'], asset['height']
    if len(raw) != w*h*3:
        raise ValueError('Incorrect raw pixel length')
    if asset['layout'] == 'CHW_RGB888':
        n = w*h
        rgb = bytearray(n*3)
        rgb[0::3], rgb[1::3], rgb[2::3] = raw[:n], raw[n:2*n], raw[2*n:]
        raw = rgb
    return b'P6\n%d %d\n255\n' % (w, h) + raw


def import_record(source, root):
    """Verify raw SD/USB data then publish atomically; duplicates cannot overwrite."""
    source, root = Path(source), Path(root)
    m = read_manifest(source / 'manifest.json')
    verify_assets(source, m)
    root.mkdir(parents=True, exist_ok=True)
    target = root / m['capture_id']
    if target.exists():
        old = read_manifest(target / 'manifest.json')
        if old != m:
            raise ValueError('Conflicting capture ID ' + m['capture_id'])
        verify_assets(target, old)
        return target
    staging = Path(tempfile.mkdtemp(prefix='.import_', dir=root))
    try:
        for a in m['assets']:
            shutil.copyfile(source / a['file'], staging / a['file'])
            (staging / (a['file'] + '.ppm')).write_bytes(ppm_pixels((staging / a['file']).read_bytes(), a))
        (staging / 'manifest.json').write_text(json.dumps(m, ensure_ascii=False, indent=2), encoding='utf-8')
        verify_assets(staging, m)
        staging.rename(target)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return target


def load_captures(root):
    records, errors = [], []
    for manifest in sorted(Path(root).glob('k*_*' + '/manifest.json')):
        try:
            m = read_manifest(manifest)
            verify_assets(manifest.parent, m)
            records.append({'path': manifest.parent, 'manifest': m})
        except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
            errors.append(f'{manifest}: {exc}')
    return records, errors


def bind_manual(record, entry, host_session_id):
    """Explicit human assertion, not protocol-confirmed or timestamp inferred."""
    from .protocol import encode_event
    m = read_manifest(Path(record) / 'manifest.json')
    verify_assets(record, m)
    p = entry.packet
    data = {'method': 'manual_operator_selection', 'protocol_confirmed': False,
            'capture_id': m['capture_id'], 'host_session_id': host_session_id,
            'receipt_id': entry.receipt_id, 'received_at': entry.received_at,
            'al_wire': encode_event(p).decode().strip(),
            'fpga_event_id': None,
            'linked_at_utc': datetime.now(timezone.utc).isoformat()}
    path = Path(record) / 'manual_link.json'
    # Do not silently replace a previously reviewed selection.
    with path.open('x', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    return data


class UsbEvidenceDecoder:
    """Bounded sequential KB1 transfer. Reorder/gaps/duplicate offsets rejected."""
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.active = None
        self.manifest = None
        self.offsets = {}
        self.received = 0
        self.errors = 0

    def close(self):
        if self.active is not None:
            shutil.rmtree(self.active)
        self.active = self.manifest = None
        self.offsets = {}

    def feed(self, line):
        if not line.startswith(b'KB1 '):
            return None
        try:
            return self._feed(line.strip())
        except (OSError, ValueError, KeyError, TypeError, UnicodeError, AttributeError) as exc:
            self.errors += 1
            self.close()
            raise ValueError('K230 transfer rejected: ' + str(exc)) from exc

    def _feed(self, line):
        fields = line.split(b' ')
        if fields[1] == b'M' and len(fields) == 3:
            if self.active is not None:
                self.errors += 1  # interrupted previous capture, never publish it
                self.close()
            if len(fields[2]) > MAX_MANIFEST * 4 // 3 + 4:
                raise ValueError('Oversize manifest')
            m = validate_manifest(json.loads(base64.b64decode(fields[2], validate=True)))
            self.manifest = m
            self.active = Path(tempfile.mkdtemp(prefix='.usb_', dir=self.root))
            (self.active / 'manifest.json').write_text(json.dumps(m), encoding='utf-8')
            self.offsets = {a['file']: 0 for a in m['assets']}
        elif fields[1] == b'D' and len(fields) == 6:
            if self.active is None or fields[2].decode() != self.manifest['capture_id']:
                raise ValueError('Asset outside active capture')
            name = fields[3].decode()
            offset = int(fields[4])
            if name not in self.offsets or offset != self.offsets[name]:
                raise ValueError('Invalid asset/offset')
            if len(fields[5]) > 4096:
                raise ValueError('Oversize chunk')
            payload = base64.b64decode(fields[5], validate=True)
            asset = next(a for a in self.manifest['assets'] if a['file'] == name)
            if not payload or offset + len(payload) > asset['bytes']:
                raise ValueError('Asset overflow')
            with (self.active / name).open('ab') as f:
                f.write(payload)
            self.offsets[name] += len(payload)
        elif fields[1] == b'E' and len(fields) == 3:
            if self.active is None or fields[2].decode() != self.manifest['capture_id']:
                raise ValueError('End outside active capture')
            target = import_record(self.active, self.root)
            self.close()
            self.received += 1
            return target
        else:
            raise ValueError('Malformed KB1 line')
        return None


def export_source_report(path, root):
    path = Path(path).resolve()
    root = Path(root).resolve()
    if path.is_relative_to(root):
        raise ValueError('Report must be outside the source-evidence root')
    records, errors = load_captures(root)
    lines = ['# K230 识别源帧证据', '',
             '图像SHA256已复核。K230候选不等于FPGA已接受事件；两板时间域不自动匹配。',
             '人工关联是操作者选择，不是统一事件ID协议确认。原图未画框，查看页叠加框。', '']
    for record in records:
        m = record['manifest']
        obs = m.get('observation') or {}
        lines += [f"## {m['capture_id']}", '',
                  f"- 帧：{m['frame_id']}；K230运行内时间：{m['captured_ms']} ms",
                  f"- 触发：{', '.join(m['triggers'])}；来源：{obs.get('source', '-')}",
                  f"- 原始模型分数：{obs.get('raw_score')}；策略分数：{obs.get('policy_score')}",
                  f"- 目录：`{record['path']}`"]
        for a in m['assets']:
            lines.append(f"- {a['role']}：[{a['file']}]({(record['path']/a['file']).resolve().as_uri()}) SHA256 `{a['sha256']}`")
        link = record['path'] / 'manual_link.json'
        if link.exists():
            lines.append('- 人工关联：`' + link.read_text(encoding='utf-8').replace('\n', ' ') + '`')
        else:
            lines.append('- FPGA事件：未关联')
        lines.append('')
    if errors:
        lines += ['## 校验异常', *errors]
    path.write_text('\n'.join(lines)+'\n', encoding='utf-8')
