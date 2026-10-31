"""Capture main ASCII UART identity, optionally periodic RTC anchors; no writes/JTAG."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import sys
import time

from app.main_persistent_validation import MainPersistentValidation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port')
    source.add_argument('--input', type=Path)
    parser.add_argument('--previous-boot', type=int)
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--cold-boot', action='store_true',
                        help='show QSPI cold-start instructions; does not control power or prove startup source')
    parser.add_argument('--require-rtc', type=int, default=0, metavar='COUNT',
                        help='RTC1: arm on first RA, then require COUNT trusted consecutive anchors plus ST/ET/EI')
    parser.add_argument('--require-board', type=int, default=0, metavar='COUNT',
                        help='MONITOR1: first BM excludes old RTC1 traffic, then require advancing trusted BM records')
    args = parser.parse_args()
    try:
        if args.timeout <= 0 or (args.previous_boot is not None and not 0 < args.previous_boot < 0xffffffff):
            raise ValueError('invalid timeout or previous boot')
        if args.require_rtc and args.require_rtc < 2:
            raise ValueError('--require-rtc needs at least 2 anchors (or 0 to disable)')
        if args.require_board and (args.require_board < 2 or args.require_rtc < 2):
            raise ValueError('--require-board needs at least 2 records and --require-rtc at least 2')
        audit = MainPersistentValidation(args.previous_boot, min_rtc_anchors=args.require_rtc,
                                         min_board_records=args.require_board)
        pending = bytearray()
        if args.input:
            raw = args.input.read_bytes()
            complete, _, tail = raw.rpartition(b'\n')
            if complete:
                for line in complete.split(b'\n'):
                    audit.accept(line)
            pending.extend(tail)
            out = None
        else:
            import serial
            parent = Path(__file__).resolve().parent / 'logs'
            if not parent.is_dir():
                raise ValueError('host/logs parent missing')
            out = parent / ('main_persistent_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.raw')
            raw = bytearray()
            with out.open('xb') as saved, serial.Serial(args.port, 115200, timeout=.2) as link:
                print(f'Raw capture: {out}', flush=True)
                if args.cold_boot:
                    print('Listening for QSPI cold-boot validation. Do NOT Program Device or press RESET.', flush=True)
                else:
                    print('Listening. Program MONITOR1 main bit now.' if args.require_board else
                          'Listening. Program RTC1 main bit now.' if args.require_rtc else
                          'Listening. Program persistent main bit (or RESET if already running).', flush=True)
                if args.require_board:
                    print('Waiting for first BM to exclude older RTC1/RA traffic; then first RA arms identity validation.', flush=True)
                if args.require_rtc:
                    print('Waiting for first RA to arm capture; earlier old-configuration traffic is retained but excluded.', flush=True)
                print('Wait for MAIN BOOT READY, then authenticate/start exam and briefly cover camera to generate ET.', flush=True)
                deadline = time.monotonic() + args.timeout
                pending = bytearray()
                announced = False
                announced_anchors = 0
                announced_board = 0
                while time.monotonic() < deadline:
                    block = link.read(512)
                    if block:
                        saved.write(block); saved.flush(); raw.extend(block); pending.extend(block)
                    while b'\n' in pending:
                        line, _, remaining = pending.partition(b'\n'); pending = bytearray(remaining)
                        audit.accept(line)
                        if len(audit.board_records) > announced_board:
                            print(audit.board_records[-1].text(), flush=True)
                            announced_board = len(audit.board_records)
                        if len(audit.anchors) > announced_anchors:
                            print(audit.anchors[-1].text(), flush=True)
                            announced_anchors = len(audit.anchors)
                        if audit.boot and not announced:
                            print(f'MAIN BOOT READY; device=1 boot={audit.boot}', flush=True)
                            announced = True
                    complete = (audit.summary()['verified'] if args.require_rtc else
                                audit.boot and audit.transaction_count)
                    if audit.reasons or complete:
                        break
        report = audit.summary()
        # A 512-byte serial read can contain a complete successful ET followed
        # by the prefix of the next ST. Retain it raw, never parse it as a line.
        report['trailing_partial_bytes'] = len(pending)
        report['raw_sha256'] = hashlib.sha256(raw).hexdigest()
        if args.require_rtc:
            report['rtc'] = audit.rtc_summary()
        if args.require_board:
            report['board'] = audit.board_summary()
        if out:
            with out.with_suffix('.json').open('x', encoding='utf-8') as target:
                json.dump(report, target, ensure_ascii=False, indent=2)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        success = ('MAIN MONITOR IDENTITY VALIDATED' if args.require_board else
                   'MAIN RTC IDENTITY VALIDATED' if args.require_rtc else 'MAIN PERSISTENT IDENTITY VALIDATED')
        print((success if report['verified'] else 'MAIN PERSISTENT VALIDATION FAILED') + f'; boot={report["boot"]}')
        return 0 if report['verified'] else 2
    except (OSError, ValueError, ImportError) as exc:
        print(f'Main persistent capture failed: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
