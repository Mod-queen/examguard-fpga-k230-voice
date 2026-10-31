"""Read-only UART diagnostic; reports malformed ST without accepting its identity.

Diagnostic fields from invalid packets are explicitly untrusted, not a relaxed
protocol decoder or a board-bitstream version detector.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct

from app.protocol import decode_packet


def inspect_capture(path):
    raw = Path(path).read_bytes()
    complete, separator, tail = raw.rpartition(b'\n')
    lines = complete.split(b'\n') if separator else []
    kinds, valid, errors, boots = Counter(), Counter(), Counter(), Counter()
    samples = []
    for line in lines:
        kind = line.split(b',', 1)[0].decode('ascii', errors='replace')
        kinds[kind] += 1
        try:
            decode_packet(line)
        except (ValueError, UnicodeError) as exc:
            errors[str(exc)] += 1
        else:
            valid[kind] += 1
        if kind == 'ST':
            try:
                fields = line.decode('ascii').split(',')
                w = struct.unpack('!32I', bytes.fromhex(fields[13]))
                boots[w[2]] += 1
                if len(samples) < 4 or (samples and samples[-1]['untrusted_boot'] != w[2]):
                    samples.append(dict(untrusted_boot=w[2], untrusted_source_ms=(w[10]<<32)|w[11],
                                        word20_UI_state=f'{w[20]:08X}', word23_committed=w[23],
                                        word26_windowfail=w[26], word28_eth_state=f'{w[28]:08X}',
                                        word29_sent=w[29], word30_dropped=w[30],
                                        reserved_invalid=bool(w[20]&0x3fff0000 or w[28]&~3)))
            except (ValueError, IndexError, struct.error):
                pass
    return dict(path=str(Path(path).resolve()), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
                complete_lines=dict(kinds), valid_lines=dict(valid), errors=dict(errors),
                trailing_partial_bytes=len(tail), diagnostic_ST_boots=dict(boots), diagnostic_ST_samples=samples,
                interpretation='Invalid ST diagnostic fields are untrusted; no inferred bitstream name or RTC acceptance. No serial access/writes.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path, nargs='+')
    args=parser.parse_args()
    for path in args.capture:
        print(json.dumps(inspect_capture(path), ensure_ascii=False, indent=2))


if __name__=='__main__': main()
