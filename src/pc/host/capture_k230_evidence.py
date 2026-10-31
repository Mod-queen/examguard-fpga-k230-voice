"""Receive K230 KB1 source evidence over USB CDC, or import an SD/MTP copy."""
import argparse
from pathlib import Path
import sys
import time

from app.k230_evidence import UsbEvidenceDecoder, import_record
from app.k230_runtime import RecognitionHealth


def probe_running(connection, stop_file, timeout=2.0):
    """Observe valid advancing echoes before deciding whether startup is needed.

    No buffer reset, REPL bytes or model startup. Keep every observed byte for
    the normal decoder/health loop when attached, including an incomplete tail.
    """
    deadline = time.monotonic() + timeout
    raw = bytearray()
    pending = bytearray()
    health = RecognitionHealth(time.monotonic())
    while time.monotonic() < deadline:
        if stop_file is not None and stop_file.exists():
            return False, bytes(raw), True
        block = connection.read(8192)
        raw.extend(block)
        pending.extend(block)
        while b'\n' in pending:
            line, _, rest = pending.partition(b'\n')
            pending = bytearray(rest)
            health.feed(bytes(line).decode('utf-8', 'replace'), time.monotonic())
        if health.frames >= 2:
            return True, bytes(raw), False
        if len(raw) > 100000:
            raise ValueError('K230 attach probe exceeded bounded console input')
    return False, bytes(raw), False


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--port', help='K230 USB CDC, NOT FPGA UART; exclusive with CanMV IDE')
    ap.add_argument('--start', action='store_true', help='one REPL command starts deployed main.py')
    runtime = ap.add_mutually_exclusive_group()
    runtime.add_argument('--live290', action='store_true', help='opt in to installed act16 runtime and one-shot boot suppression')
    runtime.add_argument('--scene-guard', action='store_true', help='use installed purple-cover notes runtime')
    runtime.add_argument('--book-assist', action='store_true', help='use installed public-book assisted purple-cover runtime')
    ap.add_argument('--attach-if-running', action='store_true',
                    help='observe valid advancing recognition before --start; attach without REPL/reset if already running')
    ap.add_argument('--recognition-only', action='store_true',
                    help='run recognition/liveness only; do not decode or save KB1 evidence')
    ap.add_argument('--import-dir', type=Path, help='offline copy of SD evidence (recursive)')
    ap.add_argument('--out', type=Path, default=Path(__file__).resolve().parent / 'k230_evidence')
    ap.add_argument('--stop-file', type=Path, help='launcher-owned graceful stop signal')
    ap.add_argument('--startup-timeout', type=float, default=30.0,
                    help='seconds without an advancing recognition frame before startup timeout')
    ap.add_argument('--stale-timeout', type=float, default=5.0,
                    help='seconds without a new recognition frame before stale')
    ap.add_argument('--health-interval', type=float, default=5.0,
                    help='seconds between periodic liveness lines')
    args = ap.parse_args()
    if bool(args.port) == bool(args.import_dir):
        ap.error('choose exactly one of --port or --import-dir')
    if args.start and not args.port:
        ap.error('--start needs --port')
    uses_live_entry = args.live290 or args.scene_guard or args.book_assist
    if uses_live_entry and not (args.start and args.port and args.recognition_only):
        ap.error('installed runtime requires --port --start --recognition-only')
    if args.recognition_only and not args.port:
        ap.error('--recognition-only needs --port')
    if args.attach_if_running and not (args.start and args.recognition_only and args.port):
        ap.error('--attach-if-running requires --port --start --recognition-only')
    if args.import_dir:
        paths = sorted(args.import_dir.rglob('manifest.json'))
        if not paths:
            ap.error('no manifest.json in import directory')
        failed = 0
        for p in paths:
            try:
                print('IMPORTED', import_record(p.parent, args.out))
            except (OSError, ValueError, KeyError, TypeError) as exc:
                failed += 1
                print('REJECTED', p, exc, file=sys.stderr)
        return 1 if failed else 0
    import serial
    repl = None
    connection = None
    prefetched = b''
    attached = False
    if args.attach_if_running:
        print('K230 checking for existing recognition (read-only USB CDC)', flush=True)
        connection = serial.Serial(args.port, 115200, timeout=0.2)
        try:
            # Native USB CDC exposes stdout only when the terminal is ready.
            # DTR is CDC line control, not a Ctrl-C/Ctrl-D REPL command.
            connection.dtr = True
            attached, prefetched, stopped = probe_running(connection, args.stop_file)
        except BaseException:
            connection.close()
            raise
        if stopped:
            connection.close()
            return 0
        if attached:
            print('K230 attached to existing recognition; no REPL/reset command sent', flush=True)
        else:
            connection.close()
            connection = None
            prefetched = b''
            print('K230 no advancing recognition observed; using normal confirmed startup', flush=True)
    if args.start and not attached:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'k230'))
        from repl_client import Repl
        repl = Repl(args.port)
        connection = repl.s
        try:
            print('K230 resetting interpreter before camera/model startup', flush=True)
            if uses_live_entry:
                from app.k230_startup import start_live290, LIVE_ROOT, SCENE_ROOT, BOOK_ROOT
                start_live290(repl, runtime_root=BOOK_ROOT if args.book_assist else SCENE_ROOT if args.scene_guard else LIVE_ROOT)
            else:
                repl.soft_reset()
            print('K230 soft reboot confirmed; starting recognition', flush=True)
            # No model/file upload. Clear prior camera/model interpreter state
            # before the same deployed main.run command on every owned start.
            if not uses_live_entry:
                connection.write(b"import sys; sys.path.insert(0, '/sdcard/examguard'); import main; main.run()\x04")
        except BaseException:
            connection.close()
            raise
    elif connection is None:
        connection = serial.Serial(args.port, 115200, timeout=0.2)
    decoder = None if args.recognition_only else UsbEvidenceDecoder(args.out)
    started = time.monotonic()
    health = RecognitionHealth(started, startup_timeout=args.startup_timeout,
                               stale_timeout=args.stale_timeout)
    buffer = bytearray()
    last = time.monotonic()
    last_health = started
    print('K230 recognition monitor (source evidence disabled)' if args.recognition_only
          else f'K230 source evidence receiver: {args.out} (Ctrl+C to stop)')
    try:
        while True:
            if args.stop_file is not None and args.stop_file.exists():
                break
            if prefetched:
                data, prefetched = prefetched, b''
            else:
                data = connection.read(8192)
            if data:
                buffer.extend(data)
                while b'\n' in buffer:
                    line, _, rest = buffer.partition(b'\n')
                    buffer = bytearray(rest)
                    text = bytes(line).decode('utf-8', 'replace')
                    health.feed(text, time.monotonic())
                    try:
                        path = decoder.feed(bytes(line)) if decoder is not None else None
                        if path:
                            print('VERIFIED', path)
                        elif not line.startswith(b'KB1 '):
                            print(text)
                    except ValueError as exc:
                        print(exc, file=sys.stderr)
                if len(buffer) > 100000:
                    buffer.clear()
                    if decoder is not None:
                        decoder.close()
                    print('Oversize serial line discarded', file=sys.stderr)
            now = time.monotonic()
            snapshot, changed = health.snapshot(now)
            if changed or now - last_health >= args.health_interval:
                print(health.line(snapshot), flush=True)
                last_health = now
            if decoder is not None and now - last >= 10:
                print('health verified=%d errors=%d active=%s' % (
                    decoder.received, decoder.errors,
                    decoder.manifest['capture_id'] if decoder.manifest else '-'))
                last = now
    except KeyboardInterrupt:
        pass
    except serial.SerialException as exc:
        print('Serial error:', exc, file=sys.stderr)
        return 1
    finally:
        if decoder is not None:
            decoder.close()
        if repl is not None:
            try:
                repl.stop_program()
                print('K230 stopped; REPL prompt confirmed')
            except Exception as exc:
                print('K230 stop not confirmed: '+str(exc), file=sys.stderr)
            finally:
                connection.close()
        else:
            connection.close()
            if attached:
                print('K230 listener stopped; running board left untouched', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
