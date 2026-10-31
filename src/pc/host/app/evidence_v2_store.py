"""Immutable, atomically published EGv2 revisions, including incomplete chunks.

Only complete RGB565 frames get previews; raw CRC-checked datagrams preserve
partial frames and permit a late packet to resume the same full identity.
"""
from __future__ import annotations

import hashlib
import json
import os
import errno
import shutil
from pathlib import Path
import struct
import time
import uuid

from .evidence_v2 import WindowAssembly, decode_window_packet
from .image_store import _rgb565_to_rgb888
from .protocol import ProtocolError
from .transaction_protocol import decode_transaction_event

MAX_ARCHIVE_BYTES = 32 * 1024 * 1024


def identity_name(identity):
    return 'egv2_' + '_'.join(f'{value:0{16 if i == 3 else 8}X}' for i, value in enumerate(identity))


def latest_revision(root, identity):
    directory = Path(root) / identity_name(identity)
    revisions = sorted(directory.glob('revision_*/manifest.json'))
    return revisions[-1].parent if revisions else None


def _write(path, data):
    with path.open('xb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def write_revision(root, window, datagrams, *, reason, host_failed=False, min_free_bytes=0):
    """Publish a new revision; failure leaves previous revision untouched.

    Unpublished .pending directories are intentionally retained for diagnosis,
    ignored by the browser. This is normal process-crash atomic publication,
    not a claim of power-loss atomic directory durability on every filesystem.
    """
    root = Path(root)
    parent = root / identity_name(window.identity)
    parent.mkdir(parents=True, exist_ok=True)
    # Advisory preflight, not a disk reservation: other writers can consume
    # space afterward. Never delete an old revision to make a new one fit.
    raw_size = sum(2 + len(packet) for packet in datagrams)
    if raw_size > MAX_ARCHIVE_BYTES:
        raise ProtocolError('EGv2 archive exceeds capacity')
    complete_count = sum(frame.complete(window.frame_bytes) for frame in window.frames.values())
    estimated_bytes = raw_size + complete_count * (window.width * window.height * 3 + 64) + 1024*1024
    if shutil.disk_usage(parent).free < estimated_bytes + min_free_bytes:
        raise OSError(errno.ENOSPC, 'EGv2 free-space reserve would be exceeded; archive retained', str(parent))
    # Sortable revision IDs must keep advancing even if PC wall time rolls
    # back. One receiver owns this output root (UDP bind is exclusive).
    previous = sorted(parent.glob('revision_*/manifest.json'))
    last = int(previous[-1].parent.name.split('_')[1]) if previous else 0
    token = f'{max(time.time_ns(), last+1):020d}_{uuid.uuid4().hex}'
    pending = parent / ('.pending_' + token)
    pending.mkdir()
    raw = b''.join(struct.pack('!H', len(packet)) + packet for packet in datagrams)
    _write(pending / 'packets.bin', raw)
    frames = []
    incomplete = []
    for index, frame in sorted(window.frames.items()):
        if not frame.complete(window.frame_bytes):
            incomplete.append(dict(index=index, frame_id=frame.metadata[0], timestamp_ms=frame.metadata[1],
                                   ranges=[[offset, len(data)] for offset, data in sorted(frame.chunks.items())]))
            continue
        pixels = window.frame_data(index)
        preview = f'P6\n{window.width} {window.height}\n255\n'.encode('ascii') + _rgb565_to_rgb888(pixels)
        filename = f'frame_{index:03d}.ppm'
        _write(pending / filename, preview)
        frames.append(dict(index=index, frame_id=frame.metadata[0], timestamp_ms=frame.metadata[1],
                           file=filename, bytes=len(pixels), sha256=hashlib.sha256(preview).hexdigest(),
                           rgb565_sha256=hashlib.sha256(pixels).hexdigest()))
    result = window.result
    status = 'failed' if host_failed else window.status
    expected = result.planned_frames if result else None
    manifest = dict(schema_version=2, protocol='EGv2', transaction_hex=window.transaction.hex().upper(),
                    identity=list(window.identity), source_time_ms=int.from_bytes(window.transaction[20:28], 'big'),
                    status=status, complete=status == 'complete', host_failed=host_failed,
                    conflict=window.conflict, stream_bad=window.stream_bad, deferred=window.deferred,
                    reason=reason, expected_frames=expected, emitted_frames=result.frame_index if result else None,
                    assembly_limits=dict(max_frames=window.max_frames, max_frame_bytes=window.max_frame_bytes,
                                         max_window_bytes=window.max_window_bytes),
                    result_flags=result.flags if result else None, width=window.width, height=window.height,
                    pixel_format='RGB565', received_frames=len(frames), frames=frames, incomplete_frames=incomplete,
                    missing_indices=[i for i in range(expected) if i not in {f['index'] for f in frames}] if expected is not None else None,
                    packets_file='packets.bin', packets_bytes=len(raw), packets_sha256=hashlib.sha256(raw).hexdigest(),
                    packet_count=len(datagrams))
    _write(pending / 'manifest.json', (json.dumps(manifest, indent=2, sort_keys=True) + '\n').encode('utf-8'))
    final = parent / ('revision_' + token)
    pending.rename(final)
    return final


def read_revision(path):
    """Validate manifest, raw CRCs, assembly verdict and every preview hash."""
    path = Path(path).resolve()
    manifest = json.loads((path / 'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('schema_version') != 2 or manifest.get('protocol') != 'EGv2':
        raise ValueError('unsupported EGv2 archive')
    event = decode_transaction_event(manifest['transaction_hex'])
    if list(event.identity) != manifest['identity']:
        raise ValueError('archive identity/context mismatch')
    raw_path = path / 'packets.bin'
    if raw_path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ValueError('EGv2 archive exceeds capacity')
    raw = raw_path.read_bytes()
    if len(raw) != manifest['packets_bytes'] or hashlib.sha256(raw).hexdigest() != manifest['packets_sha256']:
        raise ValueError('EGv2 raw datagram archive hash mismatch')
    datagrams = []
    cursor = 0
    window = None
    limits = manifest['assembly_limits']
    if (set(limits) != {'max_frames', 'max_frame_bytes', 'max_window_bytes'} or
            any(not isinstance(v, int) or v < 1 for v in limits.values()) or
            limits['max_frames'] > 256 or limits['max_frame_bytes'] > 4*1024*1024 or
            limits['max_window_bytes'] > 64*1024*1024):
        raise ValueError('invalid stored EGv2 assembly limits')
    while cursor < len(raw):
        if cursor + 2 > len(raw):
            raise ValueError('truncated EGv2 packet archive')
        size = struct.unpack_from('!H', raw, cursor)[0]
        cursor += 2
        if not 84 <= size <= 1108 or cursor + size > len(raw):
            raise ValueError('invalid EGv2 archived datagram length')
        data = raw[cursor:cursor+size]
        cursor += size
        packet = decode_window_packet(data)
        if packet.identity != event.identity:
            raise ValueError('mixed EGv2 identities in archive')
        if window is None:
            window = WindowAssembly(packet, **limits)
        else:
            try:
                window.add(packet)
            except ProtocolError:
                if not window.conflict:
                    raise
        datagrams.append(data)
    if window is None or window.transaction != event.transaction:
        raise ValueError('empty or changed EGv2 archive context')
    status = 'failed' if manifest['host_failed'] else window.status
    expected = window.result.planned_frames if window.result else None
    if (manifest['status'] != status or manifest['complete'] != (status == 'complete') or
            manifest['expected_frames'] != expected or manifest['width'] != window.width or
            manifest['height'] != window.height or manifest['packet_count'] != len(datagrams) or
            manifest['conflict'] != window.conflict or manifest['stream_bad'] != window.stream_bad or
            manifest['deferred'] != window.deferred or manifest['source_time_ms'] != event.timestamp or
            manifest['emitted_frames'] != (window.result.frame_index if window.result else None) or
            manifest['result_flags'] != (window.result.flags if window.result else None)):
        raise ValueError('EGv2 manifest disagrees with datagram verdict')
    valid_indices = {i for i, f in window.frames.items() if f.complete(window.frame_bytes)}
    if ({f['index'] for f in manifest['frames']} != valid_indices or len(manifest['frames']) != len(valid_indices) or
            manifest['received_frames'] != len(valid_indices) or
            manifest['missing_indices'] != ([i for i in range(expected) if i not in valid_indices] if expected is not None else None)):
        raise ValueError('EGv2 manifest frame coverage mismatch')
    for frame in manifest['frames']:
        filename = f"frame_{frame['index']:03d}.ppm"
        if frame['file'] != filename:
            raise ValueError('invalid EGv2 preview path')
        data = (path / filename).read_bytes()
        pixels = window.frame_data(frame['index'])
        expected_preview = f'P6\n{window.width} {window.height}\n255\n'.encode('ascii') + _rgb565_to_rgb888(pixels)
        if (data != expected_preview or hashlib.sha256(data).hexdigest() != frame['sha256'] or
                hashlib.sha256(pixels).hexdigest() != frame['rgb565_sha256'] or
                (frame['frame_id'], frame['timestamp_ms']) != window.frames[frame['index']].metadata):
            raise ValueError('EGv2 preview/source metadata hash mismatch')
    return manifest, window, datagrams
