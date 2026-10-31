"""Serial raw-REPL client for the K230 CanMV board (default COM12).

The K230 exposes a standard MicroPython raw REPL on its USB CDC. The
board may be running an autostart script, so this client sends Ctrl-C
until a >>> prompt appears before entering raw REPL.

PC->board throughput on this CDC is only ~6 KB/s (board->PC ~700 KB/s),
so use the CanMV MTP portable device (see k230/README) for large files.
This client is for executing code, small uploads, stat/checksum and
reading status files. A KPU hang can wedge the whole USB and requires a
physical reset; a `progress.txt` written after each step helps localise
where it stopped after the board comes back.

Usage:
    python k230/repl_client.py run  k230/diag/test_ball.py
    python k230/repl_client.py exec "import os; print(os.listdir('/sdcard'))"
    python k230/repl_client.py ls   /sdcard/examguard
    python k230/repl_client.py cat  /sdcard/examguard/progress.txt
    python k230/repl_client.py sizes /sdcard/kmodel/face_recognition.kmodel:46333280
"""
import argparse
import base64
import os
import sys
import time

import serial

DEFAULT_PORT = 'COM12'
DEFAULT_BAUD = 115200


class ReplError(Exception):
    pass


class Repl:
    def __init__(self, port=DEFAULT_PORT, baud=DEFAULT_BAUD):
        self.s = serial.Serial(port, baud, timeout=0.05, write_timeout=5)
        try:
            self._interrupt_until_prompt()
            self._enter_raw()
        except BaseException:
            self.s.close()
            raise

    def _read_until(self, token, timeout):
        buf = b''
        t0 = time.time()
        while time.time() - t0 < timeout:
            chunk = self.s.read(8192)
            if chunk:
                buf += chunk
                if token in buf:
                    break
        return buf

    def _interrupt_until_prompt(self, timeout=15.0):
        deadline = time.time() + timeout
        buf = b''
        attempts = 0
        while time.time() < deadline:
            try:
                self.s.write(b'\x03')
                # --start leaves the interpreter in raw REPL when interrupted.
                # Raw REPL has a single '>' prompt (and can be silent after C),
                # so asking only for '>>>' can never recover it. Ctrl-B returns
                # to friendly REPL after the running script has been stopped.
                if attempts % 2 == 1:
                    self.s.write(b'\x02')
            except serial.SerialException:
                pass
            attempts += 1
            time.sleep(0.25)
            chunk = self.s.read(8192)
            if chunk:
                buf = (buf + chunk)[-8192:]
            if buf.rstrip().endswith(b'>>>'):
                return
        raise ReplError('no REPL prompt; tail=%r' % buf[-200:])

    def _enter_raw(self):
        self.s.reset_input_buffer()
        self.s.write(b'\x01')
        if b'raw REPL' not in self._read_until(b'raw REPL', 4.0):
            raise ReplError('could not enter raw REPL')

    def exec(self, code, timeout=30.0):
        """Execute code, return (stdout, stderr) as bytes."""
        self.s.reset_input_buffer()
        self.s.write(code.encode('utf-8') + b'\x04')
        out = self._read_until(b'\x04', timeout)
        err = self._read_until(b'\x04', timeout)
        out = out[:-1] if out.endswith(b'\x04') else out
        err = err[:-1] if err.endswith(b'\x04') else err
        if out.startswith(b'OK'):
            out = out[2:]
        return out, err

    def soft_reset(self, timeout=15.0):
        """Reset interpreter/media state in raw REPL before starting models.

        Empty raw Ctrl-D performs a soft reboot; it is not a source upload.
        A boot banner AND new prompt are required, so stale prompts cannot pass.
        """
        self.s.reset_input_buffer()
        self.s.write(b'\x04')
        response = self._read_until(b'raw REPL; CTRL-B to exit\r\n>', timeout)
        if b'MPY: soft reboot' not in response or not response.rstrip().endswith(b'>'):
            raise ReplError('soft reboot did not return raw REPL; tail=%r' % response[-200:])
        return response

    def stop_program(self, timeout=1.5):
        """Interrupt and wait for a friendly prompt, allowing finally cleanup."""
        self._interrupt_until_prompt(timeout=timeout)

    def run_file(self, path, extra_path=None):
        with open(path, 'r', encoding='utf-8') as fh:
            code = fh.read()
        if extra_path:
            code = "import sys\nsys.path.append(%r)\n" % extra_path + code
        return self.exec(code)

    def upload(self, local, remote, chunk=900):
        with open(local, 'rb') as fh:
            data = fh.read()
        for idx in range(0, len(data), chunk):
            mode = 'wb' if idx == 0 else 'ab'
            b64 = base64.b64encode(data[idx:idx + chunk]).decode('ascii')
            code = ("import ubinascii; f=open(%s,%s); "
                    "f.write(ubinascii.a2b_base64(%s)); f.close()"
                    % (repr(remote), repr(mode), repr(b64)))
            out, err = self.exec(code)
            if err.strip():
                raise ReplError('upload chunk %d: %r' % (idx, err))
        out, err = self.exec(
            "print(os.stat(%s)[6], sum(open(%s,'rb').read()) & 0xFFFF)"
            % (repr(remote), repr(remote)))
        return out.strip().decode('utf-8', 'replace'), len(data), sum(data) & 0xFFFF

    def close(self):
        try:
            self.s.write(b'\x02\x03')
        except Exception:
            pass
        self.s.close()


def _sizes(repl, specs):
    code = 'import os\n'
    for spec in specs:
        path, _, want = spec.partition(':')
        code += ("try:\n"
                 "    print(%r, os.stat(%r)[6])\n"
                 "except Exception as e:\n"
                 "    print(%r, 'ERR', e)\n" % (path, path, path))
    code += "print('SIZES DONE')\n"
    out, err = repl.exec(code)
    sys.stdout.write(out.decode('utf-8', 'replace'))
    if err.strip():
        sys.stdout.write('STDERR: ' + err.decode('utf-8', 'replace'))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--port', default=DEFAULT_PORT)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p_run = sub.add_parser('run')
    p_run.add_argument('file')
    p_run.add_argument('--path', default='/sdcard/examguard')
    p_exec = sub.add_parser('exec')
    p_exec.add_argument('code')
    p_up = sub.add_parser('upload')
    p_up.add_argument('local')
    p_up.add_argument('remote')
    p_cat = sub.add_parser('cat')
    p_cat.add_argument('remote')
    p_ls = sub.add_parser('ls')
    p_ls.add_argument('remote')
    p_ck = sub.add_parser('checksum')
    p_ck.add_argument('remote', nargs='+')
    p_sz = sub.add_parser('sizes')
    p_sz.add_argument('spec', nargs='+')
    args = ap.parse_args()

    repl = Repl(args.port)
    try:
        if args.cmd == 'run':
            out, err = repl.run_file(args.file, args.path)
            sys.stdout.write(out.decode('utf-8', 'replace'))
            if err.strip():
                sys.stdout.write('STDERR: ' + err.decode('utf-8', 'replace'))
        elif args.cmd == 'exec':
            out, err = repl.exec(args.code)
            sys.stdout.write(out.decode('utf-8', 'replace'))
            if err.strip():
                sys.stdout.write('STDERR: ' + err.decode('utf-8', 'replace'))
        elif args.cmd == 'upload':
            got, n, s = repl.upload(args.local, args.remote)
            print('uploaded %d bytes (local sum %d) -> %s' % (n, s, got))
        elif args.cmd == 'cat':
            out, err = repl.exec("print(open(%r).read())" % args.remote)
            sys.stdout.write(out.decode('utf-8', 'replace'))
            if err.strip():
                sys.stdout.write('STDERR: ' + err.decode('utf-8', 'replace'))
        elif args.cmd == 'ls':
            code = ("import os\nfor n in sorted(os.listdir(%r)):\n"
                    "    print('  ', n)\nprint('LS DONE')\n" % args.remote)
            out, err = repl.exec(code)
            sys.stdout.write(out.decode('utf-8', 'replace'))
        elif args.cmd == 'sizes':
            _sizes(repl, args.spec)
        elif args.cmd == 'checksum':
            code = 'import hashlib, ubinascii\n'
            for path in args.remote:
                code += ("try:\n"
                         "    h=hashlib.sha256(); f=open(%r,'rb')\n"
                         "    d=f.read(65536)\n"
                         "    while d:\n"
                         "        h.update(d); d=f.read(65536)\n"
                         "    f.close()\n"
                         "    print(%r, os.stat(%r)[6], "
                         "ubinascii.hexlify(h.digest()).decode())\n"
                         "except Exception as e:\n"
                         "    print(%r, 'ERR', e)\n" % (path, path, path, path))
            code = 'import os\n' + code
            out, err = repl.exec(code)
            sys.stdout.write(out.decode('utf-8', 'replace'))
    finally:
        repl.close()


if __name__ == '__main__':
    main()
