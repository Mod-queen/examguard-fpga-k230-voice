import json
import tempfile
import unittest
from pathlib import Path

from app.history_association import (
    associate,
    load_history_records,
    load_pixel_records,
    verdict_for,
)
from app.history_result import FLAG_COVERAGE_OK, FLAG_GAP_UNKNOWN, FLAG_OK, encode_history_result
from app.history_result_receiver import HistoryResultReceiver


TX = bytes(range(32))
TX_HEX = TX.hex().upper()


def hr_record(**overrides):
    kwargs = dict(
        transaction=TX, window=1, token=7, code=0, frames=2, gap_count=0,
        lower_ms=100, upper_ms=300,
        flags=FLAG_OK | FLAG_COVERAGE_OK,
    )
    kwargs.update(overrides)
    return encode_history_result(**kwargs)


def write_eg(root, tx_hex=TX_HEX, *, status="complete", complete=True,
             received=2, expected=2, missing=(), stream_bad=False):
    identity = [1, 1, 1, 1]
    path = Path(root) / "egv2_00000001_00000001_00000001_0000000000000001" / "revision_1"
    path.mkdir(parents=True)
    manifest = dict(
        schema_version=2, protocol="EGv2", transaction_hex=tx_hex, identity=identity,
        status=status, complete=complete, received_frames=received,
        expected_frames=expected, missing_indices=list(missing), stream_bad=stream_bad,
    )
    (path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return path


class HistoryAssociationTests(unittest.TestCase):
    def test_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record())
            write_eg(tmp)
            result = associate(tmp)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0].verdict, "complete")
            self.assertEqual(result[0].history[0].transaction_hex, TX_HEX)
            self.assertEqual(result[0].pixels[0].transaction_hex, TX_HEX)

    def test_gap_degrades_even_with_complete_pixels(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record(gap_count=1, flags=FLAG_OK))
            write_eg(tmp)
            result = associate(tmp)[0]
            self.assertEqual(result.verdict, "degraded")
            self.assertIn("gap", result.reason)

    def test_unknown_degrades(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record(flags=FLAG_OK | FLAG_GAP_UNKNOWN))
            write_eg(tmp)
            self.assertEqual(associate(tmp)[0].verdict, "degraded")

    def test_failed_result(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record(code=4, frames=0, flags=0))
            write_eg(tmp, status="failed", complete=False, missing=(0, 1))
            self.assertEqual(associate(tmp)[0].verdict, "failed")

    def test_hr_ok_but_pixels_partial(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record())
            write_eg(tmp, status="partial", complete=False, received=1, missing=(1,))
            result = associate(tmp)[0]
            self.assertEqual(result.verdict, "partial")
            self.assertIn("pixels", result.reason)

    def test_awaiting_sides(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record())
            self.assertEqual(associate(tmp)[0].verdict, "awaiting_pixels")
        with tempfile.TemporaryDirectory() as tmp:
            write_eg(tmp)
            self.assertEqual(associate(tmp)[0].verdict, "awaiting_result")

    def test_transaction_case_and_raw_hash(self):
        with tempfile.TemporaryDirectory() as tmp:
            HistoryResultReceiver(tmp).ingest(hr_record())
            write_eg(tmp, tx_hex=TX_HEX.lower())
            history = load_history_records(tmp)
            pixels = load_pixel_records(tmp)
            self.assertIn(TX_HEX, history)
            self.assertIn(TX_HEX, pixels)
            self.assertEqual(verdict_for(TX_HEX, history[TX_HEX], pixels[TX_HEX]).verdict, "complete")
            raw = next((Path(tmp) / "history_results").rglob("raw.hr"))
            raw.write_bytes(raw.read_bytes()[:-1] + b"\x00")
            with self.assertRaises(ValueError):
                load_history_records(tmp)


if __name__ == "__main__":
    unittest.main()
