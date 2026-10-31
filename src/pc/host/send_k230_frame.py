"""Send Yahboom ASCII frames from a PC serial port, to test the FPGA RX path.

Bring-up isolation for the K230 <-> FPGA link: disconnect the K230, connect a
USB-UART adapter TX to FPGA ai_uart_rx (E14) + common GND, then run this. If the
FPGA seven-segment display moves stage 1 -> 2 and latches event 01, the FPGA
receive path, parser and exam FSM are all proven working.

Run from the host directory:

    python send_k230_frame.py COM6
    python send_k230_frame.py COM6 --text "$32,08,1,2,3,4,Bob,77#" --count 20
"""

from __future__ import annotations

import argparse
import sys
import time


DEFAULT_FRAMES = [
    "$32,08,689,143,307,348,Alice,99#",
    "$34,08,100,80,120,160,unknown,0#",
    "$28,14,200,160,80,120,phone#",
]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Send K230-style ASCII frames over a PC serial port")
    parser.add_argument("port", help="Windows serial port, for example COM6")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--text", default="",
                        help="send this exact frame (LF is appended)")
    parser.add_argument("--count", type=int, default=10,
                        help="repeat count (default 10)")
    parser.add_argument("--period", type=float, default=0.5,
                        help="seconds between frames (default 0.5)")
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        print("pyserial is required: python -m pip install pyserial",
              file=sys.stderr)
        return 2

    frames = [args.text] if args.text else DEFAULT_FRAMES
    try:
        port = serial.Serial(
            port=args.port, baudrate=args.baud,
            bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE, timeout=1.0,
        )
    except serial.SerialException as exc:
        print("Serial error: %s" % exc, file=sys.stderr)
        return 1

    print("Sending %d frame(s) on %s @ %d 8N1" % (
        args.count * len(frames), args.port, args.baud))
    try:
        for i in range(args.count):
            frame = frames[i % len(frames)]
            payload = (frame + "\n").encode("ascii")
            port.write(payload)
            port.flush()
            print("[%3d] TX %s" % (i, frame))
            time.sleep(args.period)
    except KeyboardInterrupt:
        pass
    finally:
        port.close()
    print("Done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
