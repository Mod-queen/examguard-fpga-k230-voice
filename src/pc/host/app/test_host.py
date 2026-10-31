"""Tests for host configuration and monitoring state."""

from __future__ import annotations

import csv
import json
import queue
import socket
import tempfile
import threading
import unittest
from pathlib import Path

from .config import ConfigError, RegionLayout, default_layout, load_layout, save_layout
from .evidence_udp import (
    EvidenceUdpReassembler,
    ImageFrameChunk,
    decode_image_chunk,
    encode_image_chunk,
)
from .image_store import ImageEvidenceFrame, write_image_evidence
from .monitor import MonitorModel
from .protocol import (
    ConfigAckPacket,
    EventPacket,
    EvidenceEndPacket,
    EvidencePacket,
    ProtocolError,
    RegionConfig,
    StatusPacket,
)
from .receiver import receive_packets


class ConfigTests(unittest.TestCase):
    def test_default_layout_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "regions.json"
            layout = default_layout()
            save_layout(path, layout)
            self.assertEqual(load_layout(path), layout)

    def test_missing_layout_uses_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            layout = load_layout(Path(directory) / "missing.json")
            self.assertEqual(layout, default_layout())

    def test_invalid_region_is_rejected(self) -> None:
        layout = RegionLayout(
            regions=(RegionConfig(region_id=1, x0=10, y0=10, x1=10, y1=20),)
        )
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ConfigError):
                save_layout(Path(directory) / "regions.json", layout)

    def test_malformed_json_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "regions.json"
            path.write_text("{not-json", encoding="utf-8")
            with self.assertRaises(ConfigError):
                load_layout(path)


class MonitorTests(unittest.TestCase):
    def test_latest_status_and_bounded_events(self) -> None:
        model = MonitorModel(max_events=2)
        status = StatusPacket(
            frame_id=4,
            state_id=1,
            risk_level=0,
            zone_id=1,
            timestamp=100,
            event_code=0,
            motion_pickup=20,
        )
        model.apply(status)
        for frame_id in (1, 2, 3):
            model.apply(
                EventPacket(
                    frame_id=frame_id,
                    timestamp=frame_id,
                    stage_id=1,
                    zone_id=3,
                    risk_level=2,
                    event_code=0x40,
                )
            )

        snapshot = model.snapshot()
        self.assertEqual(snapshot.latest_status, status)
        self.assertEqual([entry.packet.frame_id for entry in snapshot.events], [2, 3])
        self.assertEqual(snapshot.packets_received, 4)
        self.assertEqual(snapshot.status_packets, 1)
        self.assertEqual(snapshot.event_packets, 3)

    def test_evidence_window_assembly(self) -> None:
        model = MonitorModel()
        for index in range(3):
            model.apply(
                EvidencePacket(
                    seq=4,
                    index=index,
                    frame_id=100 + index,
                    timestamp_ms=1000 + index * 33,
                    stage_id=2,
                    risk_level=2,
                    zone_id=3,
                    event_code=0x40,
                    motion_pickup=5,
                    motion_operation=6,
                    motion_forbidden=90,
                    config_version=0,
                    health_flags=0,
                )
            )
        model.apply(EvidenceEndPacket(seq=4, count=3))

        window = model.snapshot().latest_evidence
        self.assertIsNotNone(window)
        assert window is not None
        self.assertTrue(window.complete)
        self.assertEqual([sample.index for sample in window.samples], [0, 1, 2])
        self.assertEqual(window.missing_indices, ())

    def test_incomplete_evidence_window(self) -> None:
        model = MonitorModel()
        model.apply(
            EvidencePacket(
                seq=9,
                index=1,
                frame_id=1,
                timestamp_ms=1,
                stage_id=0,
                risk_level=0,
                zone_id=0,
                event_code=0,
                motion_pickup=0,
                motion_operation=0,
                motion_forbidden=0,
                config_version=0,
                health_flags=0,
            )
        )
        model.apply(EvidenceEndPacket(seq=9, count=3))
        window = model.snapshot().latest_evidence
        assert window is not None
        self.assertFalse(window.complete)
        self.assertEqual(window.missing_indices, (0, 2))

    def test_evidence_csv_export(self) -> None:
        model = MonitorModel()
        model.apply(
            EvidencePacket(
                seq=1,
                index=0,
                frame_id=42,
                timestamp_ms=99,
                stage_id=1,
                risk_level=1,
                zone_id=1,
                event_code=1,
                motion_pickup=7,
                motion_operation=8,
                motion_forbidden=9,
                config_version=2,
                health_flags=3,
            )
        )
        model.apply(EvidenceEndPacket(seq=1, count=1))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.csv"
            model.export_evidence_csv(path)
            with path.open(newline="", encoding="utf-8") as csv_file:
                rows = list(csv.reader(csv_file))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1][:5], ["1", "0", "42", "99", "1"])

    def test_config_ack_is_tracked(self) -> None:
        model = MonitorModel()
        model.apply(ConfigAckPacket(version=3, status=0))
        ack = model.snapshot().latest_config_ack
        assert ack is not None
        self.assertEqual(ack.version, 3)
        self.assertTrue(ack.accepted)

        model.apply(ConfigAckPacket(version=4, status=3))
        ack = model.snapshot().latest_config_ack
        assert ack is not None
        self.assertFalse(ack.accepted)

    def test_config_ack_does_not_disturb_events(self) -> None:
        model = MonitorModel()
        model.apply(ConfigAckPacket(version=1, status=0))
        model.apply(
            EventPacket(
                frame_id=1,
                timestamp=1,
                stage_id=1,
                zone_id=3,
                risk_level=2,
                event_code=0x40,
            )
        )
        snapshot = model.snapshot()
        self.assertEqual(len(snapshot.events), 1)
        self.assertEqual(snapshot.event_packets, 1)
        self.assertIsNotNone(snapshot.latest_config_ack)

    def test_event_csv_export(self) -> None:
        model = MonitorModel()
        model.apply(
            EventPacket(
                frame_id=7,
                timestamp=8,
                stage_id=2,
                zone_id=3,
                risk_level=2,
                event_code=0x40,
            )
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.csv"
            model.export_events_csv(path)
            with path.open(newline="", encoding="utf-8") as csv_file:
                rows = list(csv.reader(csv_file))
        self.assertEqual(rows[0][-1], "event_code")
        self.assertEqual(rows[1][1:], ["7", "8", "2", "3", "2", "64"])


class ImageStoreTests(unittest.TestCase):
    def test_complete_window_writes_manifest_timeline_and_pgm(self) -> None:
        frames = [
            ImageEvidenceFrame(
                seq=7,
                index=index,
                frame_id=100 + index,
                timestamp_ms=1000 + index,
                config_version=3,
                width=2,
                height=2,
                pixels=bytes([index, index + 1, index + 2, index + 3]),
            )
            for index in range(2)
        ]
        with tempfile.TemporaryDirectory() as directory:
            event_dir = write_image_evidence(
                directory,
                event_seq=7,
                expected_count=2,
                frames=frames,
                width=2,
                height=2,
            )
            manifest = json.loads(
                (event_dir / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertTrue(manifest["complete"])
            self.assertEqual(manifest["missing_indices"], [])
            self.assertEqual(len(manifest["frames"]), 2)
            self.assertEqual(
                (event_dir / "frame_000.pgm").read_bytes(),
                b"P5\n2 2\n255\n\x00\x01\x02\x03",
            )
            with (event_dir / "timeline.csv").open(
                newline="", encoding="utf-8"
            ) as csv_file:
                rows = list(csv.reader(csv_file))
            self.assertEqual(rows[1][1], "received")
            self.assertEqual(rows[2][2], "101")

    def test_rgb565_window_timeline_references_ppm(self) -> None:
        frame = ImageEvidenceFrame(
            seq=3,
            index=0,
            frame_id=10,
            timestamp_ms=100,
            config_version=0,
            width=1,
            height=1,
            pixels=b"\x00\x1f",
            pixel_format="RGB565",
        )
        with tempfile.TemporaryDirectory() as directory:
            event_dir = write_image_evidence(
                directory,
                event_seq=3,
                expected_count=1,
                frames=[frame],
                width=1,
                height=1,
                pixel_format="RGB565",
            )
            self.assertTrue((event_dir / "frame_000.ppm").exists())
            with (event_dir / "timeline.csv").open(
                newline="", encoding="utf-8"
            ) as csv_file:
                rows = list(csv.reader(csv_file))
            self.assertEqual(rows[1][5], "frame_000.ppm")

    def test_incomplete_window_marks_missing_frame(self) -> None:
        frame = ImageEvidenceFrame(
            seq=2,
            index=1,
            frame_id=11,
            timestamp_ms=22,
            config_version=1,
            width=1,
            height=2,
            pixels=b"ab",
        )
        with tempfile.TemporaryDirectory() as directory:
            event_dir = write_image_evidence(
                directory,
                event_seq=2,
                expected_count=3,
                frames=[frame],
                width=1,
                height=2,
            )
            manifest = json.loads(
                (event_dir / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertFalse(manifest["complete"])
            self.assertEqual(manifest["missing_indices"], [0, 2])


def _image_chunk(
    *,
    event_seq: int,
    frame_index: int,
    frame_id: int,
    pixel_offset: int,
    payload: bytes,
    frame_count: int = 2,
    timestamp_ms: int = 1000,
) -> bytes:
    return encode_image_chunk(
        ImageFrameChunk(
            event_seq=event_seq,
            frame_index=frame_index,
            frame_count=frame_count,
            frame_id=frame_id,
            timestamp_ms=timestamp_ms,
            config_version=0,
            width=1,
            height=2,
            pixel_offset=pixel_offset,
            payload=payload,
        )
    )


class EvidenceUdpTests(unittest.TestCase):
    def test_out_of_order_chunks_reassemble_and_persist(self) -> None:
        pixels = bytes(range(8))
        common = dict(
            event_seq=5,
            frame_index=1,
            frame_count=2,
            frame_id=42,
            timestamp_ms=900,
            config_version=3,
            width=4,
            height=2,
        )
        first = encode_image_chunk(
            ImageFrameChunk(pixel_offset=0, payload=pixels[:4], **common)
        )
        second = encode_image_chunk(
            ImageFrameChunk(pixel_offset=4, payload=pixels[4:], **common)
        )
        reassembler = EvidenceUdpReassembler()
        self.assertIsNone(reassembler.ingest(second))
        completed = reassembler.ingest(first)
        self.assertIsNotNone(completed)
        assert completed is not None
        self.assertEqual(completed.pixels, pixels)

        with tempfile.TemporaryDirectory() as directory:
            event_dir = reassembler.write_event(directory, 5)
            manifest = json.loads(
                (event_dir / "manifest.json").read_text(encoding="utf-8")
            )
            self.assertFalse(manifest["complete"])
            self.assertEqual(manifest["missing_indices"], [0])

    def test_repeated_event_seq_resets_stale_window(self) -> None:
        reassembler = EvidenceUdpReassembler()
        # Old window: only the first byte of frame 1 arrived before it expired.
        self.assertIsNone(
            reassembler.ingest(
                _image_chunk(
                    event_seq=9, frame_index=1, frame_id=101,
                    pixel_offset=0, payload=b"\x11",
                )
            )
        )
        # The FPGA reuses event_seq 9 for a later window (frame_id moved on).
        self.assertIsNone(
            reassembler.ingest(
                _image_chunk(
                    event_seq=9, frame_index=1, frame_id=103,
                    pixel_offset=0, payload=b"\x21",
                )
            )
        )
        completed = reassembler.ingest(
            _image_chunk(
                event_seq=9, frame_index=1, frame_id=103,
                pixel_offset=1, payload=b"\x22",
            )
        )
        self.assertIsNotNone(completed)
        assert completed is not None
        self.assertEqual(completed.pixels, b"\x21\x22")

    def test_late_datagram_from_older_window_is_ignored(self) -> None:
        reassembler = EvidenceUdpReassembler()
        self.assertIsNone(
            reassembler.ingest(
                _image_chunk(
                    event_seq=4, frame_index=0, frame_id=200,
                    pixel_offset=0, payload=b"\x31",
                )
            )
        )
        # A straggler from an older window must not overwrite the new one.
        self.assertIsNone(
            reassembler.ingest(
                _image_chunk(
                    event_seq=4, frame_index=0, frame_id=150,
                    pixel_offset=0, payload=b"\x41",
                )
            )
        )
        completed = reassembler.ingest(
            _image_chunk(
                event_seq=4, frame_index=0, frame_id=200,
                pixel_offset=1, payload=b"\x32",
            )
        )
        self.assertIsNotNone(completed)
        assert completed is not None
        self.assertEqual(completed.pixels, b"\x31\x32")

    def test_crc_error_is_rejected(self) -> None:
        packet = bytearray(
            encode_image_chunk(
                ImageFrameChunk(
                    event_seq=1,
                    frame_index=0,
                    frame_count=1,
                    frame_id=1,
                    timestamp_ms=2,
                    config_version=0,
                    width=1,
                    height=2,
                    pixel_offset=0,
                    payload=b"ab",
                )
            )
        )
        packet[-1] ^= 1
        with self.assertRaises(ProtocolError):
            decode_image_chunk(bytes(packet))


class ReceiverTests(unittest.TestCase):
    def test_receiver_ignores_bad_lines_and_stops(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]

        stop_event = threading.Event()
        packets = receive_packets(
            "127.0.0.1",
            port,
            timeout=0.1,
            stop_event=stop_event,
        )
        packet_queue: queue.Queue[object] = queue.Queue()

        def receive_one() -> None:
            try:
                packet_queue.put(next(packets))
            except BaseException as exc:  # Pass generator failures to the test thread.
                packet_queue.put(exc)

        receiver_thread = threading.Thread(target=receive_one)
        receiver_thread.start()

        def send_datagram() -> None:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                sender.sendto(
                    b"malformed\nST,5,1,0,1,10,0,20,0,0\n",
                    ("127.0.0.1", port),
                )

        sender_thread = threading.Thread(target=send_datagram)
        sender_thread.start()
        result = packet_queue.get(timeout=2)
        if isinstance(result, BaseException):
            raise result
        packet = result
        sender_thread.join()
        receiver_thread.join()
        self.assertEqual(packet.frame_id, 5)

        stop_event.set()
        with self.assertRaises(StopIteration):
            next(packets)


if __name__ == "__main__":
    unittest.main()
