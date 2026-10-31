"""Capture PS1 inventory from read-only FPGA probe; retain raw even on failure.

Start receiver before programming inventory bit or pressing RESET. No serial
writes, no JTAG programming, no I2C/EEPROM changes performed by this script.
"""
from __future__ import annotations

import argparse
from datetime import datetime
import json
from pathlib import Path
import sys
import time

from app.persistence_inventory import HEADER, LENGTH, decode_report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port')
    source.add_argument('--input', type=Path)
    parser.add_argument('--out', type=Path, help='New raw capture; existing parent required')
    parser.add_argument('--timeout', type=float, default=60)
    parser.add_argument('--hex-input', action='store_true', help='Read XSim whitespace-separated hex instead of binary')
    args = parser.parse_args()
    try:
        if args.timeout <= 0:
            raise ValueError('timeout must be positive')
        if args.input:
            if args.out:
                raise ValueError('--out applies only to capture')
            raw = bytes.fromhex(args.input.read_text()) if args.hex_input else args.input.read_bytes()
            report = decode_report(raw)
        else:
            if args.hex_input:
                raise ValueError('--hex-input requires --input')
            import serial
            out = args.out or Path(__file__).resolve().parent/'logs'/('persistence_inventory_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.raw')
            if not out.parent.is_dir():
                raise ValueError(f'output parent missing: {out.parent}')
            summary = out.with_suffix('.json')
            if summary.exists():
                raise FileExistsError(summary)
            raw = bytearray()
            with out.open('xb') as saved:
                print(f'Raw capture: {out}', flush=True)
                with serial.Serial(args.port, 115200, timeout=0.2) as link:
                    print('Listening. Program READ-ONLY inventory bit or press FPGA RESET now.', flush=True)
                    deadline = time.monotonic() + args.timeout
                    while time.monotonic() < deadline:
                        block = link.read(512)
                        if block:
                            raw.extend(block)
                            saved.write(block)
                            saved.flush()
                        if len(raw) >= LENGTH:
                            break
                    else:
                        raise ValueError(f'timeout received {len(raw)} bytes; raw retained')
            # Strict framing: noise, multiple records, wrong length are not silently
            # removed or treated as trusted inventory. Retained raw can be audited.
            report = decode_report(bytes(raw))
            with summary.open('x', encoding='utf-8') as output:
                json.dump(report, output, ensure_ascii=False, indent=2)
            print(f'Summary: {summary}')
        print(json.dumps(report, ensure_ascii=False, indent=2))
        print('REPORT CRC VALIDATED; I2C errors:', report['i2c_errors'])
        print('No device writes. Restore RESET1 bit after this independent test.')
        return 0 if report['all_devices_responded'] else 2
    except (ValueError, OSError, ImportError) as exc:
        print(f'Inventory capture failed: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
