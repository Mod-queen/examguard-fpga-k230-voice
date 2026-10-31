import dataclasses
import unittest

from .evidence_health import EvidenceHealth, EvidenceHealthView, decode_evidence_health
from .protocol import StatusPacket, ProtocolError, decode_packet, encode_status


def health(flags=0x70):
    w = [0] * 32
    w[:12] = [0x01000000 | flags, 1, 7, 3, 11, 2, 10, 0x84, 2, 9, 0x12345678, 0xFFFFFFFF]
    if flags & 0x10:
        w[12:20] = [100, 90, 80, 3, 2, 1, 0, 0]
    if flags & 0x20:
        w[20:28] = [0x80000402, 10, 8, 77, 1, 2, 3, 444]
    if flags & 0x40:
        w[28:32] = [1, 443, 0, 0]
    return EvidenceHealth(tuple(w))


def status(h):
    return StatusPacket(1, 3, 0, 0, 1234, 0, remaining_s=2600, exam_duration_s=2700, evidence_health=h)


class EvidenceHealthTests(unittest.TestCase):
    def test_phy_v2_independent_of_transport_freshness(self):
        # PHY diagnostics remain available while shared transport is reset.
        w = list(health(1).words)
        w[0] = 0x02000001
        for summary, text in ((0x01000000, "未知"), (0x010003FE, "陈旧"),
                              (0x01000200, "型号未确认"), (0x01000280, "读回无效"),
                              (0x010002C0, "链路未就绪"), (0x010002FE, "1000M 全双工"),
                              (0x010002ED, "100M 全双工 TX延迟未开启"),
                              (0x010002C4, "10M 半双工")):
            w[31] = summary
            h = EvidenceHealth(tuple(w))
            decoded = decode_packet(encode_status(status(h))).evidence_health
            self.assertEqual(decoded, h)
            self.assertIn(text, decoded.phy_text)
            view = EvidenceHealthView()
            view.apply(status(h), now=0)
            self.assertIn(text, view.text(now=0))

    def test_phy_reserved_unknown_and_invalid_speed_rejected(self):
        w = list(health().words)
        w[0] = 0x02000070
        for summary in (0, 0x020002FE, 0x010006FE, 0x010000FE, 0x01000100, 0x010002FF):
            w[31] = summary
            with self.subTest(summary=summary), self.assertRaises(ProtocolError):
                decode_evidence_health(EvidenceHealth(tuple(w)).encode())

    def test_wire_extension_roundtrip_all_words_and_legacy(self):
        packet = status(health())
        raw = encode_status(packet)
        self.assertEqual(len(raw.strip().split(b",")), 14)
        self.assertEqual(decode_packet(raw), packet)
        self.assertEqual(decode_packet(raw).evidence_health.time_ms, 0x12345678FFFFFFFF)
        self.assertIsNone(decode_packet(b"ST,1,3,0,0,10,0,0,0,0,0,2600,2700").evidence_health)

    def test_reject_malformed_reserved_version_and_inconsistent_freshness(self):
        original = health()
        for index, value in ((0, 0x02000070), (0, 0x01010070), (0, 0x01000071),
                             (0, 0x010000F0), (7, 0x19), (20, 0x3FFF0000), (28, 4), (31, 1)):
            words = list(original.words)
            words[index] = value
            with self.subTest(index=index, value=value), self.assertRaises(ProtocolError):
                decode_evidence_health(EvidenceHealth(tuple(words)).encode())
        for raw in (original.encode()[:-1], "G" * 256, "0" * 258):
            with self.assertRaises(ProtocolError):
                decode_evidence_health(raw)
        with self.assertRaises(ProtocolError):
            decode_evidence_health(health(0x60).encode()[:96] + original.encode()[96:])

    def test_reset_unknown_stale_and_receipt_stale_never_healthy(self):
        view = EvidenceHealthView()
        self.assertIn("未上报", view.text(now=0))
        view.apply(status(health(1)), now=10)
        self.assertIn("传输复位", view.text(now=11))
        view.apply(status(health(0)), now=12)
        self.assertIn("统计尚未就绪", view.text(now=12))
        view.apply(status(health(0x80)), now=13)
        self.assertIn("采样统计停更", view.text(now=14))
        self.assertIn("状态停更", view.text(now=17))
        self.assertEqual(view.latest.words[2], 7)

    def test_counters_faults_and_old_protocol_after_new_epoch(self):
        view = EvidenceHealthView()
        view.apply(status(health(0x70 | 2 | 0x800 | 0x2000)), now=1)
        text = view.text(now=1)
        for label in ("启动身份耗尽", "DDR错误", "发送错误", "boot=7", "接受/拒绝=11/2", "取消epoch=2", "UDP发送/丢弃=443/0"):
            self.assertIn(label, text)
        view.apply(dataclasses.replace(status(None)), now=2)
        self.assertIn("旧协议", view.text(now=2))

    def test_extension_requires_timer_and_typed_valid_payload(self):
        for packet in (dataclasses.replace(status(health()), remaining_s=None, exam_duration_s=None),
                       dataclasses.replace(status(health()), evidence_health="bad")):
            with self.assertRaises(ProtocolError):
                encode_status(packet)


if __name__ == "__main__":
    unittest.main()
