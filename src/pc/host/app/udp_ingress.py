"""Bounded socket-drain thread, independent of decoding and disk/preview work.

The byte limit counts queued payloads, not process RSS or the kernel socket
buffer. Overflow drops the NEW datagram explicitly, with counters; it never
blocks the socket reader waiting for a slow consumer. One consumer owns all
protocol reassemblers and archives. Shutdown drains the socket for a bounded
interval, then the consumer empties every queued datagram before final save.
"""
from collections import deque
from dataclasses import dataclass
from pathlib import Path
import queue
import socket
import threading
import time


@dataclass(frozen=True)
class ReceivedDatagram:
    sequence: int
    received_ns: int
    data: bytes
    address: tuple


class UdpIngress:
    def __init__(self, sock, *, max_bytes=64*1024*1024, max_packets=65536,
                 drain_seconds=2., stop_file=None):
        if max_bytes < 1 or max_packets < 1 or drain_seconds < 0:
            raise ValueError('UDP ingress limits must be positive; drain nonnegative')
        self.sock = sock
        self.max_bytes, self.max_packets = max_bytes, max_packets
        self.drain_seconds = drain_seconds
        self.stop_file = Path(stop_file) if stop_file is not None else None
        self.condition = threading.Condition()
        self.items = deque()
        self.queued_bytes = 0
        self.stop_requested = threading.Event()
        self.abort = threading.Event()
        self.finished = False
        self.error = None
        self.started_ns = time.monotonic_ns()
        self.stats = dict(received_packets=0, received_bytes=0, enqueued_packets=0,
                          queue_dropped_packets=0, queue_dropped_bytes=0,
                          dequeued_packets=0, queue_high_packets=0, queue_high_bytes=0,
                          max_queue_wait_ns=0, first_received_ns=None,
                          last_received_ns=None, drain_deadline_reached=False)
        self.processing = {}
        self.slow_operations = []
        self.frame0 = {}  # bounded, header-only observation BEFORE queue admission
        self.thread = threading.Thread(target=self._run, name='evidence-udp-ingress', daemon=True)

    def start(self):
        self.thread.start()

    def request_stop(self):
        self.stop_requested.set()

    def _observe_frame0(self, data, sequence):
        # Diagnostic only: CRC and complete header validation stay in the consumer.
        if len(data) < 84 or data[:4] != b'EG\x02\x01' or data[40:44] != bytes(4):
            return
        key = data[8:40].hex().upper()
        if key not in self.frame0:
            if len(self.frame0) >= 16:
                return
            self.frame0[key] = dict(packet_count=0, offsets={}, trace_limited=False,
                                    first_sequence=sequence, last_sequence=sequence)
        entry = self.frame0[key]
        entry['packet_count'] += 1
        entry['last_sequence'] = sequence
        offset = int.from_bytes(data[56:60], 'big')
        length = int.from_bytes(data[68:70], 'big')
        if offset in entry['offsets'] or len(entry['offsets']) < 1024:
            entry['offsets'][offset] = length
        else:
            entry['trace_limited'] = True

    def _run(self):
        deadline = None
        next_file_check = 0.
        try:
            while not self.abort.is_set():
                now = time.monotonic()
                if deadline is None:
                    if self.stop_requested.is_set():
                        deadline = now+self.drain_seconds
                    elif self.stop_file is not None and now >= next_file_check:
                        next_file_check = now+.05
                        if self.stop_file.exists():
                            deadline = now+self.drain_seconds
                if deadline is not None and now >= deadline:
                    with self.condition:
                        self.stats['drain_deadline_reached'] = True
                    break
                try:
                    data, address = self.sock.recvfrom(65535)
                except socket.timeout:
                    if deadline is not None:
                        break
                    continue
                received_ns = time.monotonic_ns()
                with self.condition:
                    stats = self.stats
                    stats['received_packets'] += 1
                    stats['received_bytes'] += len(data)
                    stats['last_received_ns'] = received_ns
                    if stats['first_received_ns'] is None:
                        stats['first_received_ns'] = received_ns
                    sequence = stats['received_packets']
                    self._observe_frame0(data, sequence)
                    if len(self.items) >= self.max_packets or self.queued_bytes+len(data) > self.max_bytes:
                        stats['queue_dropped_packets'] += 1
                        stats['queue_dropped_bytes'] += len(data)
                    else:
                        self.items.append(ReceivedDatagram(sequence, received_ns, data, address))
                        self.queued_bytes += len(data)
                        stats['enqueued_packets'] += 1
                        stats['queue_high_packets'] = max(stats['queue_high_packets'], len(self.items))
                        stats['queue_high_bytes'] = max(stats['queue_high_bytes'], self.queued_bytes)
                        self.condition.notify()
        except Exception as exc:
            self.error = exc
        finally:
            with self.condition:
                self.finished = True
                self.condition.notify_all()

    def get(self, timeout=None):
        """Return an arrival, None on drained EOF, or raise queue.Empty/error."""
        deadline = None if timeout is None else time.monotonic()+timeout
        with self.condition:
            while not self.items:
                if self.finished:
                    if self.error is not None:
                        raise OSError(f'UDP ingress failed: {self.error}') from self.error
                    return None
                remaining = None if deadline is None else deadline-time.monotonic()
                if remaining is not None and remaining <= 0:
                    raise queue.Empty
                self.condition.wait(remaining)
            item = self.items.popleft()
            self.queued_bytes -= len(item.data)
            self.stats['dequeued_packets'] += 1
            self.stats['max_queue_wait_ns'] = max(self.stats['max_queue_wait_ns'],
                                                 time.monotonic_ns()-item.received_ns)
            return item

    def record_processing(self, stage, elapsed_ns, arrival=None):
        with self.condition:
            metrics = self.processing.setdefault(stage, dict(calls=0, total_ns=0, max_ns=0, slow_calls=0))
            metrics['calls'] += 1
            metrics['total_ns'] += elapsed_ns
            metrics['max_ns'] = max(metrics['max_ns'], elapsed_ns)
            metrics['slow_calls'] += elapsed_ns >= 10_000_000
            if elapsed_ns >= 10_000_000 and len(self.slow_operations) < 64:
                finished_ns = time.monotonic_ns()
                row = dict(stage=stage, elapsed_ns=elapsed_ns,
                           started_ns=finished_ns-elapsed_ns, finished_ns=finished_ns,
                           queue_packets=len(self.items), queue_bytes=self.queued_bytes)
                if arrival is not None:
                    row.update(sequence=arrival.sequence, received_ns=arrival.received_ns)
                    data = arrival.data
                    if len(data) >= 40 and data[:2] in (b'EG', b'HR'):
                        row['transaction_hex'] = data[8:40].hex().upper()
                    if len(data) >= 70 and data[:2] == b'EG':
                        row.update(frame_index=int.from_bytes(data[40:44], 'big'),
                                   byte_offset=int.from_bytes(data[56:60], 'big'))
                self.slow_operations.append(row)

    def backlog_empty(self):
        with self.condition:
            return not self.items

    def snapshot(self):
        with self.condition:
            result = dict(self.stats, queue_packets=len(self.items), queue_bytes=self.queued_bytes,
                        max_queue_bytes=self.max_bytes, max_queue_packets=self.max_packets,
                        finished=self.finished, error=str(self.error) if self.error else None,
                        processing={k: dict(v) for k, v in self.processing.items()},
                        slow_operations=list(self.slow_operations))
            traces = {k: dict(v, offsets=dict(v['offsets'])) for k, v in self.frame0.items()}
        # Sorting/serialization must not hold the socket admission lock.
        result['frame0_header_only'] = {k: dict(v, offsets=sorted(
            [offset, size] for offset, size in v['offsets'].items())) for k, v in traces.items()}
        return result

    def close(self):
        self.abort.set()
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise RuntimeError('UDP ingress did not stop; socket must have a short timeout')
