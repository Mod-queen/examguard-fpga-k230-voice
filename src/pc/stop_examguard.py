r"""Stop leftover ExamGuard background workers from a previous one-command launch.

The launcher (start_examguard.py) refuses to start when an old owned subprocess
still holds a UDP port (5005/5006/6102) or the instance lock.  Those workers are
headless, so closing the dashboard alone does not always reap them.

Run this to stop them gracefully (workers flush partial evidence and exit), and
optionally force-kill anything that ignores the stop file.

    python D:\fpga_race\stop_examguard.py
    python D:\fpga_race\stop_examguard.py --force
    python D:\fpga_race\stop_examguard.py --dry-run
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
HOST = ROOT / 'host'
DEFAULT_PORTS = (5005, 5006, 6102)


def owned_python_processes():
    """Return [(pid, commandline)] for python processes running our host scripts."""
    query = ("Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | "
             "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress")
    try:
        out = subprocess.check_output(
            ['powershell', '-NoProfile', '-NonInteractive', '-Command', query],
            text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f'could not enumerate processes: {exc}', file=sys.stderr)
        return []
    out = out.strip()
    if not out:
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    result = []
    for item in data:
        command = item.get('CommandLine') or ''
        if 'fpga_race' not in command:
            continue
        if 'host\\' not in command and 'host/' not in command:
            continue
        result.append((item['ProcessId'], command))
    return result


def stop_file_for(command: str):
    parts = command.replace('"', ' ').split()
    for index, token in enumerate(parts):
        if token == '--stop-file' and index + 1 < len(parts):
            return Path(parts[index + 1])
    return None


def process_alive(pid):
    out = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'],
                         capture_output=True, text=True)
    return str(pid) in out.stdout


def listening_ports(ports):
    out = subprocess.run(['netstat', '-ano'], capture_output=True, text=True).stdout
    busy = {}
    for line in out.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        local, pid = fields[1], fields[-1]
        for port in ports:
            if local.endswith(f':{port}'):
                busy[port] = pid
    return busy


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--force', action='store_true',
                        help='force-kill workers that ignore the stop file')
    parser.add_argument('--dry-run', action='store_true',
                        help='only report what would be stopped')
    parser.add_argument('--wait', type=float, default=8.0,
                        help='seconds to wait for graceful exit')
    parser.add_argument('--ports', type=int, nargs='*', default=list(DEFAULT_PORTS))
    args = parser.parse_args()

    procs = owned_python_processes()
    if not procs:
        print('no leftover ExamGuard workers found')
    for pid, command in procs:
        target = stop_file_for(command)
        if args.dry_run:
            print(f'[dry-run] would stop PID {pid} (stop-file={target})')
            continue
        if target is not None:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('stop', encoding='utf-8')
            print(f'asked PID {pid} to stop via {target}')
        else:
            print(f'PID {pid} has no --stop-file; use --force to kill it')

    if args.dry_run:
        print('busy ports:', listening_ports(args.ports) or 'none')
        return 0

    deadline = time.monotonic() + args.wait
    remaining = [pid for pid, _ in procs]
    while remaining and time.monotonic() < deadline:
        remaining = [pid for pid in remaining if process_alive(pid)]
        if remaining:
            time.sleep(0.5)

    if remaining and args.force:
        for pid in remaining:
            subprocess.run(['taskkill', '/PID', str(pid), '/F'],
                           capture_output=True, text=True)
            print(f'force-killed PID {pid}')
        time.sleep(1.0)
        remaining = [pid for pid in remaining if process_alive(pid)]

    if remaining:
        print(f'still running (re-run with --force): {remaining}', file=sys.stderr)
    busy = listening_ports(args.ports)
    print('busy ports:', busy or 'none')
    print('done' if not busy else 'ports still held')
    return 0 if not busy else 1


if __name__ == '__main__':
    raise SystemExit(main())
