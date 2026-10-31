"""Unit tests for the K230 raw capture frame validator."""

import unittest

from capture_k230 import FrameError, describe, parse_frame


class ParseFrameTests(unittest.TestCase):
    def test_vendor_style_object_frame(self):
        frame = parse_frame(b"$28,14,200,160,80,120,phone#\n")
        self.assertEqual(frame["length"], 28)
        self.assertEqual(frame["algorithm"], 14)
        self.assertEqual(frame["fields"], ["200", "160", "80", "120", "phone"])
        self.assertTrue(describe(frame).startswith("id=14(object-detect)"))

    def test_vendor_style_face_frame(self):
        frame = parse_frame(b"$31,08,100,80,120,160,Alice,87#\n")
        self.assertEqual(frame["length"], 31)
        self.assertEqual(frame["algorithm"], 8)
        self.assertEqual(frame["fields"][-2:], ["Alice", "87"])

    def test_accepts_no_newline_and_cr(self):
        self.assertEqual(parse_frame(b"$21,14,1,2,3,4,phone#")["length"], 21)
        self.assertEqual(
            parse_frame(b"$21,14,1,2,3,4,phone#\r\n")["length"], 21)

    def test_length_mismatch_rejected(self):
        with self.assertRaises(FrameError):
            parse_frame(b"$99,14,1,2,3,4,phone#\n")

    def test_missing_delimiters_rejected(self):
        with self.assertRaises(FrameError):
            parse_frame(b"28,14,1,2,3,4,phone#\n")
        with self.assertRaises(FrameError):
            parse_frame(b"$28,14,1,2,3,4,phone\n")
        with self.assertRaises(FrameError):
            parse_frame(b"$28141,2,3,4,phone#\n")
        with self.assertRaises(FrameError):
            parse_frame(b"$28#\n")

    def test_non_digit_algorithm_rejected(self):
        with self.assertRaises(FrameError):
            parse_frame(b"$28,x4,1,2,3,4,phone#\n")

    def test_empty_line_rejected(self):
        with self.assertRaises(FrameError):
            parse_frame(b"")
        with self.assertRaises(FrameError):
            parse_frame(b"\n")


if __name__ == "__main__":
    unittest.main()
