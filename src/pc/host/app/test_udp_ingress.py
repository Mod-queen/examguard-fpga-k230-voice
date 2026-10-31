"""Receive/processing isolation at the real socket boundary."""
from contextlib import closing
import queue
import socket
import threading
import time
import unittest

from .udp_ingress import UdpIngress


class UdpIngressTests(unittest.TestCase):
    def socket_pair(self):
        receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        receiver.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        receiver.bind(('127.0.0.1', 0))
        receiver.settimeout(.02)
        return receiver, socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def test_drains_socket_while_consumer_is_blocked(self):
        receiver, sender = self.socket_pair()
        with closing(receiver), closing(sender):
            ingress = UdpIngress(receiver, max_bytes=256*1024, max_packets=512,
                                 drain_seconds=.5)
            ingress.start()
            try:
                target = receiver.getsockname()
                sender.sendto(b'HR first slow write', target)
                first = ingress.get(timeout=2)
                self.assertEqual(first.data, b'HR first slow write')
                # Main consumer is deliberately blocked until all traffic ends.
                def send_burst():
                    for i in range(160):
                        sender.sendto(i.to_bytes(4, 'big') + b'x'*508, target)
                        time.sleep(.001)
                thread = threading.Thread(target=send_burst)
                thread.start()
                thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
                deadline = time.monotonic()+2
                while ingress.snapshot()['received_packets'] < 161 and time.monotonic() < deadline:
                    time.sleep(.005)
                self.assertEqual(ingress.snapshot()['received_packets'], 161)
                ingress.request_stop()
                received = []
                while True:
                    try:
                        item = ingress.get(timeout=2)
                    except queue.Empty:
                        self.fail('ingress did not finish drain')
                    if item is None:
                        break
                    received.append(int.from_bytes(item.data[:4], 'big'))
                self.assertEqual(received, list(range(160)))
                stats = ingress.snapshot()
                self.assertEqual(stats['queue_dropped_packets'], 0)
                self.assertGreater(stats['queue_high_packets'], 100)
                self.assertGreater(stats['max_queue_wait_ns'], 50_000_000)
            finally:
                ingress.close()

    def test_bounded_queue_keeps_old_packets_and_reports_drop(self):
        receiver, sender = self.socket_pair()
        with closing(receiver), closing(sender):
            ingress = UdpIngress(receiver, max_bytes=3, max_packets=2, drain_seconds=.1)
            ingress.start()
            try:
                for payload in (b'aa', b'bb', b'cc'):
                    sender.sendto(payload, receiver.getsockname())
                    time.sleep(.02)
                ingress.request_stop()
                self.assertEqual(ingress.get(timeout=2).data, b'aa')
                self.assertIsNone(ingress.get(timeout=2))
                stats = ingress.snapshot()
                self.assertEqual(stats['received_packets'], 3)
                self.assertEqual(stats['enqueued_packets'], 1)
                self.assertEqual(stats['queue_dropped_packets'], 2)
                self.assertEqual(stats['queue_dropped_bytes'], 4)
                self.assertLessEqual(stats['queue_high_bytes'], 3)
            finally:
                ingress.close()

    def test_packet_limit_and_processing_metrics(self):
        receiver, sender = self.socket_pair()
        with closing(receiver), closing(sender):
            ingress = UdpIngress(receiver, max_bytes=1024, max_packets=1, drain_seconds=.1)
            ingress.start()
            try:
                for payload in (b'1', b'2'):
                    sender.sendto(payload, receiver.getsockname())
                    time.sleep(.03)
                ingress.request_stop()
                self.assertEqual(ingress.get(timeout=2).sequence, 1)
                ingress.record_processing('HR', 25_000_000)
                self.assertIsNone(ingress.get(timeout=2))
                stats = ingress.snapshot()
                self.assertEqual(stats['queue_dropped_packets'], 1)
                self.assertEqual(stats['processing']['HR']['max_ns'], 25_000_000)
                self.assertEqual(stats['processing']['HR']['slow_calls'], 1)
            finally:
                ingress.close()

    def test_invalid_limits(self):
        with closing(socket.socket(socket.AF_INET, socket.SOCK_DGRAM)) as sock:
            for kwargs in ({'max_bytes': 0}, {'max_packets': 0}, {'drain_seconds': -1}):
                with self.assertRaises(ValueError):
                    UdpIngress(sock, **kwargs)

    def test_frame0_trace_is_before_queue_drop_and_bounded(self):
        from .test_evidence_v2 import wire
        receiver, sender = self.socket_pair()
        with closing(receiver), closing(sender):
            ingress = UdpIngress(receiver, max_bytes=1, max_packets=1, drain_seconds=.1)
            ingress.start()
            try:
                payload = wire()
                sender.sendto(payload, receiver.getsockname())
                time.sleep(.05)
                ingress.request_stop()
                self.assertIsNone(ingress.get(timeout=2))
                stats = ingress.snapshot()
                self.assertEqual(stats['queue_dropped_packets'], 1)
                trace = next(iter(stats['frame0_header_only'].values()))
                self.assertEqual(trace['offsets'], [[0, 4]])
                self.assertEqual(trace['first_sequence'], 1)
            finally:
                ingress.close()

    def test_socket_failure_is_propagated(self):
        class BrokenSocket:
            def recvfrom(self, size):
                raise OSError('receive failure')
        ingress = UdpIngress(BrokenSocket())
        ingress.start()
        try:
            with self.assertRaisesRegex(OSError, 'receive failure'):
                ingress.get(timeout=2)
            self.assertIsNotNone(ingress.snapshot()['error'])
        finally:
            ingress.close()


if __name__ == '__main__':
    unittest.main()
