"""Capture/validate the independent EVIDENCE AXI1 probe report (not ST/AL).

Start capture before pressing FPGA RESET or programming the test bitstream.
Raw bytes are retained even on timeout/failure; existing files are never replaced.
"""
from __future__ import annotations

import argparse
from datetime import datetime
from pathlib import Path
import re
import sys
import time

HEADER = b'EVIDENCE AXI1\r\n'
KEYS = 'CFNEWRSJQT'
EXPECTED = dict(C=24, F=0, N=2, E=0, W=43224, R=14408, S=2, J=0, Q=0)


def validate_report(raw: bytes) -> dict[str, int]:
    """Strict order/length/hex + independent counts; a PASS line alone is insufficient."""
    if raw.count(HEADER) != 1:
        raise ValueError('expected exactly one EVIDENCE AXI1 header')
    report = raw[raw.index(HEADER):]
    lines = report.split(b'\r\n')
    if len(lines) != 13 or lines[0] != HEADER[:-2] or lines[-1] != b'':
        raise ValueError('incomplete, repeated or malformed report')
    values = {}
    for key, line in zip(KEYS, lines[1:11]):
        if not re.fullmatch(key.encode() + rb'=[0-9A-F]{8}', line):
            raise ValueError(f'invalid field {key}: {line!r}')
        values[key] = int(line[2:], 16)
    if lines[11] != b'PASS':
        raise ValueError(f'FPGA result is {lines[11]!r}')
    for key, expected in EXPECTED.items():
        if values[key] != expected:
            raise ValueError(f'{key}={values[key]}, expected {expected}')
    if not 0 < values['T'] < 100_000_000:
        raise ValueError('elapsed cycles invalid or watchdog expired')
    return values


def timeout_detail(raw: bytes | bytearray) -> str:
    if not raw:
        return 'capture timeout: received 0 bytes; raw data retained'
    if not any(raw):
        return (f'capture timeout: received {len(raw)} bytes, all 00 (NUL); '
                'no ASCII report, check TX/reset/startup; raw data retained')
    return (f'capture timeout: received {len(raw)} bytes, '
            f'head_hex={bytes(raw[:24]).hex()}; incomplete report; raw data retained')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--port', help='for example COM5, always 115200 8N1')
    mode.add_argument('--input', type=Path, help='validate a retained raw report offline')
    parser.add_argument('--out', type=Path, help='new raw file (parent must exist)')
    parser.add_argument('--timeout', type=float, default=60.0)
    args = parser.parse_args()
    try:
        if args.timeout <= 0:
            raise ValueError('timeout must be positive')
        if args.input:
            if args.out:
                raise ValueError('--out applies only to serial capture')
            raw = args.input.read_bytes()
        else:
            import serial
            output = args.out or Path(__file__).resolve().parent / 'logs' / (
                'ddr_evidence_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.raw')
            if not output.parent.is_dir():
                raise ValueError(f'output parent missing: {output.parent}')
            raw = bytearray()
            with output.open('xb') as saved:
                print(f'Raw capture: {output}', flush=True)
                with serial.Serial(args.port, 115200, timeout=0.2) as link:
                    print('Listening. Program test bitstream or press FPGA RESET now.', flush=True)
                    deadline = time.monotonic() + args.timeout
                    while time.monotonic() < deadline:
                        chunk = link.read(256)
                        if chunk:
                            saved.write(chunk)
                            saved.flush()
                            raw.extend(chunk)
                            print(chunk.decode('ascii', errors='replace'), end='', flush=True)
                        if HEADER in raw and (raw.endswith(b'PASS\r\n') or raw.endswith(b'FAIL\r\n')):
                            break
                    else:
                        raise ValueError(timeout_detail(raw))
            raw = bytes(raw)
        values = validate_report(raw)
        print('VALIDATED: commits=24 windows=2 pixel_errors=0 write_beats=43224 read_beats=14408')
        print(f"elapsed={values['T']} UI cycles, {values['T'] / 100_000_000:.6f}s (not a peak-bandwidth test)")
        return 0
    except (OSError, ValueError, ImportError) as exc:
        print(f'DDR evidence validation failed: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
