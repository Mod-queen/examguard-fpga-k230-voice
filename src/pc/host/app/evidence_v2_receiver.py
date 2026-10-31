"""Bounded EGv2 reception with durable revisions and late-packet recovery."""
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path
import time

from .evidence_v2 import WindowAssembly, decode_window_packet
from .evidence_v2_store import latest_revision, read_revision, write_revision
from .protocol import ProtocolError
from .transaction_protocol import decode_transaction_event


@dataclass
class _Pending:
    window: WindowAssembly
    datagrams: dict[bytes, None] = field(default_factory=dict)
    last_seen: float = 0
    dirty: bool = True
    host_failed: bool = False
    raw_bytes: int = 0
    checkpoint_at: float = 0

    def __post_init__(self):
        self.raw_bytes = sum(len(data) + 2 for data in self.datagrams)

    @property
    def size(self):
        return self.raw_bytes + self.window._stored_bytes


class EvidenceV2Receiver:
    def __init__(self, root, *, flush_after=3., max_windows=8, max_bytes=64*1024*1024,
                 max_window_bytes=16*1024*1024, max_frames=128, max_frame_bytes=2*1024*1024,
                 clock=time.monotonic, on_write=None, checkpoint_after=10., min_free_bytes=64*1024*1024):
        if min(flush_after, max_windows, max_bytes, max_window_bytes, max_frames, max_frame_bytes) <= 0:
            raise ValueError('EGv2 receiver limits must be positive')
        if checkpoint_after <= 0 or min_free_bytes < 0:
            raise ValueError('checkpoint must be positive and free-space reserve nonnegative')
        if max_frames > 256 or max_frame_bytes > 4*1024*1024 or max_window_bytes > 64*1024*1024:
            raise ValueError('EGv2 limits exceed archive format limits')
        self.root = Path(root)
        self.flush_after, self.max_windows, self.max_bytes = flush_after, max_windows, max_bytes
        self.limits = dict(max_window_bytes=max_window_bytes, max_frames=max_frames, max_frame_bytes=max_frame_bytes)
        self.clock, self.on_write = clock, on_write
        self.checkpoint_after, self.min_free_bytes = checkpoint_after, min_free_bytes
        self.pending = OrderedDict()
        self.rejected = 0
        self.written = 0

    def _save(self, identity, reason):
        entry = self.pending[identity]
        if entry.dirty:
            path = write_revision(self.root, entry.window, tuple(entry.datagrams), reason=reason,
                                  host_failed=entry.host_failed, min_free_bytes=self.min_free_bytes)
            entry.dirty = False
            entry.checkpoint_at = self.clock()
            self.written += 1
            if self.on_write:
                self.on_write(path, 'failed' if entry.host_failed else entry.window.status)
            return path

    def _evict(self):
        identity = next(iter(self.pending))
        self._save(identity, 'capacity')  # Disk failure must not silently evict.
        del self.pending[identity]

    def ingest(self, data):
        packet = decode_window_packet(data)
        decode_transaction_event(packet.transaction.hex())
        if (packet.frame_bytes > self.limits['max_frame_bytes'] or
                packet.frame_index >= self.limits['max_frames'] + (packet.kind == 2) or
                packet.planned_frames > self.limits['max_frames']):
            self.rejected += 1
            raise ProtocolError('EGv2 incoming frame/count exceeds receiver limits')
        key = packet.identity
        if key not in self.pending:
            if len(data) + 2 + len(packet.payload) > self.max_bytes:
                self.rejected += 1
                raise ProtocolError('EGv2 datagram exceeds global receiver byte limit')
            while len(self.pending) >= self.max_windows:
                self._evict()
            previous = latest_revision(self.root, key)
            if previous:
                manifest, window, datagrams = read_revision(previous)
                if (window.frame_bytes > self.limits['max_frame_bytes'] or len(window.frames) > self.limits['max_frames'] or
                        any(i >= self.limits['max_frames'] for i in window.frames) or
                        window.result and window.result.planned_frames > self.limits['max_frames'] or
                        window._stored_bytes > self.limits['max_window_bytes']):
                    raise ProtocolError('stored EGv2 window exceeds current receiver limits')
                window.max_frames = min(window.max_frames, self.limits['max_frames'])
                window.max_frame_bytes = min(window.max_frame_bytes, self.limits['max_frame_bytes'])
                window.max_window_bytes = min(window.max_window_bytes, self.limits['max_window_bytes'])
                entry = _Pending(window, dict.fromkeys(datagrams), dirty=False, host_failed=manifest['host_failed'])
            else:
                while sum(e.size for e in self.pending.values()) + len(data)+2+len(packet.payload) > self.max_bytes:
                    self._evict()
                entry = _Pending(WindowAssembly(packet, **self.limits), {data: None})
            if entry.size > self.max_bytes:
                raise ProtocolError('stored EGv2 window exceeds global receiver capacity')
            while sum(e.size for e in self.pending.values()) + entry.size > self.max_bytes:
                self._evict()
            self.pending[key] = entry
            entry.checkpoint_at = self.clock()
        entry = self.pending[key]
        was_failed = entry.window.status == 'failed'
        self.pending.move_to_end(key)
        entry.last_seen = self.clock()
        if data not in entry.datagrams:
            # Charge datagram + possible assembly copy before buffering. If
            # over global capacity, flush OTHER identities before admitting.
            extra = len(data) + 2 + len(packet.payload)
            while sum(e.size for e in self.pending.values()) + extra > self.max_bytes and len(self.pending) > 1:
                other = next(k for k in self.pending if k != key)
                self._save(other, 'capacity')
                del self.pending[other]
            if (sum(e.size for e in self.pending.values()) + extra > self.max_bytes or
                    entry.raw_bytes + len(data)+2 > 24*1024*1024):
                entry.host_failed = entry.dirty = True
                self._save(key, 'host_capacity')
                self.rejected += 1
                raise ProtocolError('EGv2 receiver byte capacity reached')
            entry.datagrams[data] = None
            entry.raw_bytes += len(data) + 2
            entry.dirty = True
            try:
                entry.window.add(packet)
            except ProtocolError:
                self.rejected += 1
                self._save(key, 'conflict')
                raise
        if (entry.window.status == 'complete' or
                entry.window.status == 'failed' and (not was_failed or packet.kind == 2)):
            return self._save(key, entry.window.status)

    def flush(self, *, force=False, expire=True):
        now = self.clock()
        for key, entry in list(self.pending.items()):
            if force or expire and now - entry.last_seen >= self.flush_after:
                self._save(key, 'stop' if force else 'quiet')
                del self.pending[key]
            elif entry.dirty and now - entry.checkpoint_at >= self.checkpoint_after:
                # Active input cannot postpone checkpoints indefinitely. Keep
                # assembly in memory, so the next chunk does not reload disk.
                self._save(key, 'checkpoint')
