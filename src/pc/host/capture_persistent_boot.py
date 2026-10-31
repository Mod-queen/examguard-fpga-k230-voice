"""Receive write-probe PB1+PS1. No serial writes or hardware programming.

On blank media press S3 only after probe initial scan (wait 2 seconds). Existing
valid records automatically allocate NEXT_BOOT once after each FPGA reset.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys
import time

from app.persistent_boot_probe import LENGTH, decode_report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port')
    source.add_argument('--input', type=Path)
    parser.add_argument('--hex-input', action='store_true')
    parser.add_argument('--previous', type=Path, help='Previous successful binary .raw for exact +1/old-slot comparison')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--timeout', type=float, default=120)
    args = parser.parse_args()
    try:
        if args.timeout <= 0:
            raise ValueError('timeout must be positive')
        prior = args.previous.read_bytes() if args.previous else None
        if prior is not None and not decode_report(prior)['verified']:
            raise ValueError('previous report failed verification')
        if args.input:
            if args.out:
                raise ValueError('--out applies only to capture')
            raw = bytes.fromhex(args.input.read_text()) if args.hex_input else args.input.read_bytes()
        else:
            if args.hex_input:
                raise ValueError('--hex-input requires --input')
            import serial
            out = args.out or Path(__file__).resolve().parent/'logs'/('persistent_boot_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.raw')
            if not out.parent.is_dir():
                raise ValueError(f'output parent missing: {out.parent}')
            summary = out.with_suffix('.json')
            if summary.exists():
                raise FileExistsError(summary)
            raw = bytearray()
            with out.open('xb') as saved:
                print(f'Raw capture: {out}', flush=True)
                with serial.Serial(args.port, 115200, timeout=0.2) as link:
                    print('Listening. Program BOOT WRITE probe or press RESET now.', flush=True)
                    print('Blank media: wait 2 seconds after programming, then press S3 once to explicitly FORMAT device1/config0.', flush=True)
                    deadline = time.monotonic() + args.timeout
                    while time.monotonic() < deadline:
                        block = link.read(512)
                        if block:
                            raw.extend(block); saved.write(block); saved.flush()
                        if len(raw) >= LENGTH:
                            break
                    else:
                        raise ValueError(f'timeout received {len(raw)} bytes; raw retained')
            raw = bytes(raw)
        report = decode_report(raw, prior)
        if args.port:
            with summary.open('x', encoding='utf-8') as output:
                json.dump(report, output, ensure_ascii=False, indent=2)
            print(f'Summary: {summary}')
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report['verified']:
            print(f'BOOT WRITE AND INDEPENDENT INVENTORY VALIDATED; device={report["device"]} generation={report["generation"]} boot={report["boot"]}')
        else:
            print('BOOT PROBE FAILED; keep raw:', report['reasons'])
        print('Restore RESET1 after independent test. No main-top identity integration yet.')
        return 0 if report['verified'] else 2
    except (ValueError, OSError, ImportError) as exc:
        print(f'Boot capture failed: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
