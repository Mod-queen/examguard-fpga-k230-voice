"""Protocol regression tests."""

from __future__ import annotations

import unittest

from .protocol import (
    ConfigAckPacket,
    EventIdentityPacket,
    EventPacket,
    EvidenceEndPacket,
    EvidencePacket,
    ProtocolError,
    StatusPacket,
    decode_packet,
    encode_config_request,
    encode_event,
    encode_event_identity,
    encode_evidence,
    encode_evidence_end,
    encode_status,
)


class ProtocolTests(unittest.TestCase):
    def test_status_round_trip(self) -> None:
        packet = StatusPacket(
            frame_id=12,
            state_id=2,
            risk_level=1,
            zone_id=2,
            timestamp=123456,
            event_code=0,
            motion_pickup=4,
            motion_operation=88,
            motion_forbidden=0,
        )
        self.assertEqual(decode_packet(encode_status(packet)), packet)

    def test_event_round_trip(self) -> None:
        packet = EventPacket(
            frame_id=99,
            timestamp=456,
            stage_id=2,
            zone_id=3,
            risk_level=2,
            event_code=0x40,
        )
        self.assertEqual(decode_packet(encode_event(packet)), packet)

    def test_event_identity_round_trip_and_fpga_hex_form(self) -> None:
        packet = EventIdentityPacket(device_id=1, boot_id=2, session_id=3, uid=0x1F2E3D4C5B6A7988)
        self.assertEqual(decode_packet(encode_event_identity(packet)), packet)
        # The exact fixed-width hex line the FPGA serializer emits.
        self.assertEqual(
            decode_packet(b"EI,00000001,00000002,00000003,1f2e3d4c5b6a7988\n"), packet)

    def test_event_identity_v2_1_carries_window_sequence(self) -> None:
        packet = EventIdentityPacket(1, 2, 3, 9, event_seq=7)
        self.assertEqual(decode_packet(encode_event_identity(packet)), packet)
        # Field order: hex identity then 3-digit decimal event_seq.
        self.assertEqual(
            decode_packet(b"EI,00000001,00000002,00000003,0000000000000009,007\n"), packet)

    def test_event_identity_rejects_bad_hex_and_field_count(self) -> None:
        with self.assertRaises(ProtocolError):
            decode_packet(b"EI,00000001,00000002,00000003,zz\n")
        with self.assertRaises(ProtocolError):
            decode_packet(b"EI,1,2,3\n")

    def test_evidence_round_trip(self) -> None:
        packet = EvidencePacket(
            seq=7,
            index=12,
            frame_id=1234,
            timestamp_ms=5678,
            stage_id=2,
            risk_level=1,
            zone_id=3,
            event_code=0x40,
            motion_pickup=10,
            motion_operation=20,
            motion_forbidden=30,
            config_version=1,
            health_flags=0,
        )
        encoded = encode_evidence(packet)
        self.assertEqual(len(encoded), 62)
        self.assertEqual(decode_packet(encoded), packet)

    def test_evidence_end_round_trip(self) -> None:
        packet = EvidenceEndPacket(seq=7, count=65)
        self.assertEqual(decode_packet(encode_evidence_end(packet)), packet)

    def test_invalid_evidence_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError):
            decode_packet("EV,1,2,3,4,5,6,7,8,9,10,11,12")

        with self.assertRaises(ProtocolError):
            decode_packet("EV,256,2,3,4,5,6,7,8,9,10,11,12,13,14")

        with self.assertRaises(ProtocolError):
            decode_packet("EO,1")

    def test_config_ack_round_trip(self) -> None:
        packet = decode_packet("CA,007,0\n")
        self.assertIsInstance(packet, ConfigAckPacket)
        assert isinstance(packet, ConfigAckPacket)
        self.assertEqual(packet.version, 7)
        self.assertTrue(packet.accepted)
        self.assertEqual(packet.status_name, "OK")

    def test_config_ack_reports_reason(self) -> None:
        packet = decode_packet("CA,012,2\n")
        assert isinstance(packet, ConfigAckPacket)
        self.assertFalse(packet.accepted)
        self.assertEqual(packet.status_name, "invalid x range")

    def test_config_request_encoding(self) -> None:
        encoded = encode_config_request(
            region_id=2, x0=10, y0=20, x1=300, y1=400, threshold=15
        )
        self.assertEqual(encoded, b"RC,2,10,20,300,400,15\n")

    def test_config_request_rejects_bad_values(self) -> None:
        with self.assertRaises(ProtocolError):
            encode_config_request(
                region_id=0, x0=0, y0=0, x1=10, y1=10, threshold=5
            )
        with self.assertRaises(ProtocolError):
            encode_config_request(
                region_id=1, x0=100, y0=0, x1=100, y1=10, threshold=5
            )
        with self.assertRaises(ProtocolError):
            encode_config_request(
                region_id=1, x0=0, y0=0, x1=10, y1=10, threshold=300
            )

    def test_invalid_config_ack_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError):
            decode_packet("CA,1")
        with self.assertRaises(ProtocolError):
            decode_packet("CA,300,0")

    def test_invalid_packet_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError):
            decode_packet("ST,1,2,3,4,5,6,7,8")

        with self.assertRaises(ProtocolError):
            decode_packet("AL,-1,2,3,4,5,6")

        with self.assertRaises(ProtocolError):
            decode_packet("ST,1,16,0,0,0,0,0,0,0")

        with self.assertRaises(ProtocolError):
            decode_packet(b"ST,1,2,3,4,5,6,7,8,\xff")

        with self.assertRaises(ProtocolError):
            decode_packet("ST,1,2,3,4,5,6,7,8,9,10,11")  # 12 fields is too many

    def test_status_v2_health_field_and_v1_compat(self) -> None:
        v1 = decode_packet(b"ST,1,2,3,4,5,6,7,8,9\n")
        self.assertEqual(v1.health_flags, 0)
        v2 = decode_packet(b"ST,1,2,3,4,5,6,7,8,9,10\n")
        self.assertEqual(v2.health_flags, 10)
        with self.assertRaises(ProtocolError):
            decode_packet(b"ST,1,2,3,4,5,6,7,8,9,999\n")


if __name__ == "__main__":
    unittest.main()
