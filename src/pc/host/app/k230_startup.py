"""Opt-in live290 startup handshake; legacy REPL flow remains the default."""
import time

LIVE_ROOT = '/sdcard/examguard_live290_act16'
SCENE_ROOT = '/sdcard/examguard_scene_guard_20261030'
BOOK_ROOT = '/sdcard/examguard_book_assist_20261030'
PREPARE = (
    "import os\n"
    "assert os.stat('/sdcard/examguard_live290_act16/main.py')[6] > 0\n"
    "assert 'EXAMGUARD_LIVE_PC_BOOT_SKIPPED' in open('/sdcard/main.py').read()\n"
    "assert \"BASE = '/sdcard/examguard_live290_act16'\" in open('/sdcard/main.py').read()\n"
    "with open('/sdcard/examguard_live290_act16/.pc_start_once','w') as f: f.write('1')\n"
    "print('LIVE290_PC_START_ARMED')\n"
)
START = (
    "ns={'__name__':'examguard_pc_entry'}; "
    "exec(open('/sdcard/examguard_live290_act16/main.py').read(),ns); ns['run']()\x04"
).encode('ascii')


def start_live290(repl, timeout=10.0, *, runtime_root=LIVE_ROOT):
    """Bind opt-in entry, suppress one boot, soft reset, then exactly one run.

    Retains coalesced raw EOT delimiters. No model upload, production fallback
    or reset retry. Caller owns connection cleanup on any failure.
    """
    if runtime_root not in (LIVE_ROOT, SCENE_ROOT, BOOK_ROOT):
        raise ValueError('Unknown installed K230 runtime root')
    prepare = PREPARE.replace(LIVE_ROOT, runtime_root)
    start = START.replace(LIVE_ROOT.encode('ascii'), runtime_root.encode('ascii'))
    connection = repl.s
    connection.reset_input_buffer()
    connection.write(prepare.encode('ascii') + b'\x04')
    response = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = connection.read(4096)
        if data:
            response.extend(data)
            if response.count(b'\x04') >= 2 and response.rstrip().endswith(b'>'):
                break
    else:
        raise RuntimeError('live290 startup marker handshake timed out')
    if b'LIVE290_PC_START_ARMED' not in response or b'Traceback' in response:
        raise RuntimeError('live290 entry not installed or boot marker rejected: '+repr(bytes(response[-800:])))
    banner = repl.soft_reset()
    if b'EXAMGUARD_LIVE_PC_BOOT_SKIPPED' not in banner:
        raise RuntimeError('live290 root did not acknowledge one-shot PC boot suppression')
    connection.write(start)
