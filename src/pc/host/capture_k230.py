"""Capture raw Yahboom ASCII frames from the K230 UART for bring-up step 1.

Use before wiring the K230 to the FPGA: a USB-UART adapter connects the
K230 TX pin to a PC COM port. Every line is logged raw (optionally hex)
and validated against the frame rule confirmed from the vendor PICO
receiver example: '$' + length + ',' + '%02d' algorithm + ',' + fields
+ '#', where length counts every character of $...# excluding the
trailing newline.

Run from the host directory:

    python capture_k230.py COM6 --out k230_raw_log.txt --hex
"""

from __future__ import annotations

import argparse
import sys
import time


class FrameError(ValueError):
    """Raised when a line does not match the Yahboom ASCII frame rule."""


def parse_frame(line: bytes) -> dict:
    """Validate one frame and return {'length', 'algorithm', 'fields', 'raw'}.

    Accepts an optional trailing LF (and a CR before it). Raises FrameError
    with a reason on any mismatch.
    """
    if not isinstance(line, (bytes, bytearray)):
        raise FrameError("line must be bytes")
    raw = bytes(line)
    if not raw:
        raise FrameError("empty line")
    body = raw.rstrip(b"\r\n")
    if not body.startswith(b"$"):
        raise FrameError("missing '$' start")
    if not body.endswith(b"#"):
        raise FrameError("missing '#' end")
    head, sep, rest = body[1:-1].partition(b",")
    if not sep:
        raise FrameError("missing ',' after length")
    if not head.isdigit():
        raise FrameError("length is not digits: %r" % head)
    length = int(head)
    if length != len(body):
        raise FrameError("length field %d != actual %d" % (length, len(body)))
    algo_bytes, sep, tail = rest.partition(b",")
    if not sep:
        raise FrameError("missing ',' after algorithm")
    if len(algo_bytes) != 2 or not algo_bytes.isdigit():
        raise FrameError("algorithm is not two digits: %r" % algo_bytes)
    fields = [f.decode("ascii", errors="replace") for f in tail.split(b",")]
    return {
        "length": length,
        "algorithm": int(algo_bytes),
        "fields": fields,
        "raw": body,
    }


ALGORITHM_NAMES = {
    6: "face-detect",
    7: "gaze",
    8: "face-recognition",
    9: "person",
    12: "gesture",
    14: "object-detect",
}


def describe(frame: dict) -> str:
    name = ALGORITHM_NAMES.get(frame["algorithm"], "?")
    return "id=%02d(%s) len=%0d fields=%s" % (
        frame["algorithm"], name, frame["length"], ",".join(frame["fields"]))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Capture and validate raw K230 Yahboom ASCII frames")
    parser.add_argument("port", help="Windows serial port, for example COM6")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--out", default="",
                        help="append raw bytes to this file for provenance")
    parser.add_argument("--hex", action="store_true",
                        help="also print a hex dump of every line")
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        print("pyserial is required: python -m pip install pyserial",
              file=sys.stderr)
        return 2

    counts: dict = {}
    invalid = 0
    out_file = None
    try:
        serial_port = serial.Serial(
            port=args.port,
            baudrate=args.baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=1.0,
            xonxoff=False,
            rtscts=False,
            dsrdtr=False,
        )
    except serial.SerialException as exc:
        print("Serial error: %s" % exc, file=sys.stderr)
        return 1

    if args.out:
        out_file = open(args.out, "ab")

    print("Listening on %s at %d 8N1%s" % (
        args.port, args.baud, " -> " + args.out if out_file else ""))
    start = time.time()
    try:
        while True:
            raw_line = serial_port.readline()
            if not raw_line:
                continue
            if out_file is not None:
                out_file.write(raw_line)
                out_file.flush()
            stamp = time.time() - start
            try:
                frame = parse_frame(raw_line)
            except FrameError as exc:
                invalid += 1
                print("[%7.3fs] INVALID %r: %s" % (stamp, raw_line, exc))
                continue
            algo = frame["algorithm"]
            counts[algo] = counts.get(algo, 0) + 1
            print("[%7.3fs] OK %s" % (stamp, frame["raw"].decode(
                "ascii", errors="replace")))
            print("           %s" % describe(frame))
            if args.hex:
                print("           %s" % frame["raw"].hex(" "))
    except KeyboardInterrupt:
        pass
    finally:
        serial_port.close()
        if out_file is not None:
            out_file.close()

    print("\nSummary: %s" % ", ".join(
        "id%02d=%d" % (algo, n) for algo, n in sorted(counts.items()))
        or "no valid frames")
    print("Invalid lines: %d" % invalid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
