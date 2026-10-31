"""Capture ST/AL/EV/EO packets from the ACX750 UART and optionally bridge UDP.

Uplink: serial -> validate -> print -> optional UDP forward.
Downlink: optional UDP listener -> serial, used to send RC configuration lines
back to the FPGA.

Run from the host directory:

    python capture_uart.py COM7 --forward-host 127.0.0.1 --forward-port 5005 \
        --downlink-port 5006
"""

from __future__ import annotations

import argparse
import socket
import sys
import threading
from pathlib import Path

from app.protocol import ProtocolError, StatusPacket, decode_packet


def downlink_worker(serial_port, sock, stop_event, write_lock) -> None:
    """Forward UDP datagrams to the FPGA as newline-terminated lines."""
    while not stop_event.is_set():
        try:
            data, _address = sock.recvfrom(512)
        except socket.timeout:
            continue
        except OSError:
            return

        text = data.decode("ascii", errors="replace").strip()
        if not text:
            continue
        try:
            with write_lock:
                serial_port.write(text.encode("ascii") + b"\n")
                serial_port.flush()
        except Exception as exc:  # noqa: BLE001 - report and keep serving
            print(f"DOWNLINK ERROR: {exc}", file=sys.stderr)
            continue
        print(f"TX      {text}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bridge the ACX750 UART to UDP in both directions"
    )
    parser.add_argument("port", help="Windows serial port, for example COM5")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--cover-debug", action="store_true",
                        help="Decode repurposed ST fields ONLY with coverdbg bitstream")
    parser.add_argument("--forward-host", default="")
    parser.add_argument("--forward-port", type=int, default=5005)
    parser.add_argument('--stop-file', type=Path, help='launcher-owned graceful stop signal')
    parser.add_argument(
        "--downlink-port",
        type=int,
        default=0,
        help="UDP port to listen on for RC configuration lines (0 disables)",
    )
    args = parser.parse_args()

    try:
        import serial
    except ImportError:
        print("pyserial is required: python -m pip install pyserial", file=sys.stderr)
        return 2

    forward_socket: socket.socket | None = None
    if args.forward_host:
        forward_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    downlink_socket: socket.socket | None = None
    downlink_thread: threading.Thread | None = None
    stop_event = threading.Event()

    if args.downlink_port:
        downlink_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            downlink_socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        downlink_socket.settimeout(0.5)
        downlink_socket.bind(("127.0.0.1", args.downlink_port))

    write_lock = threading.Lock()

    try:
        with serial.Serial(
            port=args.port,
            baudrate=args.baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=1.0,
            xonxoff=False,
            rtscts=False,
            dsrdtr=False,
        ) as serial_port:
            print(f"Listening on {args.port} at {args.baud} 8N1")
            if downlink_socket is not None:
                downlink_thread = threading.Thread(
                    target=downlink_worker,
                    args=(serial_port, downlink_socket, stop_event, write_lock),
                    name="downlink",
                    daemon=True,
                )
                downlink_thread.start()
                print(f"Downlink UDP on 127.0.0.1:{args.downlink_port}")

            while True:
                if args.stop_file is not None and args.stop_file.exists():
                    break
                raw_line = serial_port.readline()
                if not raw_line:
                    continue

                text = raw_line.decode("ascii", errors="replace").rstrip("\r\n")
                try:
                    packet = decode_packet(raw_line)
                except ProtocolError as exc:
                    print(f"INVALID {text!r}: {exc}")
                    continue

                print(f"OK      {text}")
                print(f"        {packet}")
                if args.cover_debug and isinstance(packet, StatusPacket):
                    flags = packet.motion_forbidden
                    print(f"[DEBUG-cover] luma={packet.motion_pickup} "
                          f"base={packet.motion_operation} dark={flags & 1} "
                          f"spike={(flags >> 1) & 1} episode={(flags >> 2) & 1} "
                          f"base_valid={(flags >> 3) & 1} was64={(flags >> 4) & 1} "
                          f"hold={(flags >> 5) & 1} tick={(flags >> 6) & 1} "
                          f"marker={(flags >> 7) & 1} flags=0x{flags:02X}")
                if forward_socket is not None:
                    forward_socket.sendto(
                        raw_line.strip(),
                        (args.forward_host, args.forward_port),
                    )
    except KeyboardInterrupt:
        print("\nStopped")
    except serial.SerialException as exc:
        print(f"Serial error: {exc}", file=sys.stderr)
        return 1
    finally:
        stop_event.set()
        if forward_socket is not None:
            forward_socket.close()
        if downlink_socket is not None:
            downlink_socket.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
