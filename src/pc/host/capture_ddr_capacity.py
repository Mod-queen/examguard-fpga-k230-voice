"""Capture DC report from standalone capacity bit. Opens UART, never programs."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import time
from app.ddr_capacity import decode_capacity


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True);parser.add_argument('--timeout',type=float,default=300)
    args=parser.parse_args();import serial
    logs=Path(__file__).resolve().parent/'logs'
    out=logs/('ddr_capacity_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    with serial.Serial(args.port,115200,timeout=.25) as link,out.with_suffix('.raw').open('xb') as saved:
        print('Listening; load independent capacity candidate after this message.')
        deadline=time.monotonic()+args.timeout;buffer=bytearray()
        while time.monotonic()<deadline:
            data=link.read(512)
            if data:saved.write(data);saved.flush();buffer.extend(data)
            while b'\n' in buffer:
                line,_,rest=buffer.partition(b'\n');buffer=bytearray(rest)
                if line.startswith(b'DC,'):
                    result=decode_capacity(bytes(line))
                    with out.with_suffix('.json').open('x') as target:json.dump(result,target,indent=2)
                    print('DDR CAPACITY VALIDATED' if result['passed'] else 'DDR CAPACITY FAILED',result)
                    return 0 if result['passed'] else 1
            if len(buffer)>4096:raise ValueError('Overlong/incomplete DC line; raw retained')
    raise TimeoutError('No DC result; raw retained, not a pass')


if __name__=='__main__':raise SystemExit(main())
