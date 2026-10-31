"""One-shot RTC/config maintenance over the FPGA's existing UART, no retries.

Close the normal COM5 bridge before direct serial mode. This is not CH569 ISP.
Requires a maintenance-capable FPGA candidate; RTC1 does not implement MC/MR.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from app.maintenance_protocol import encode_command, rtc_payload, decode_result
from app.persistent_config import PersistentConfig
from app.protocol import decode_packet, ProtocolError, StatusPacket


def execute(link, operation, payload, output, timeout=15):
    """Discover live boot, send once, preserve raw bytes, require matching reply."""
    deadline=time.monotonic()+timeout
    identity=None;stage=None
    with output.open('xb') as saved:
        while time.monotonic()<deadline:
            raw=link.readline()
            if raw:saved.write(raw);saved.flush()
            try:packet=decode_packet(raw)
            except ProtocolError:continue
            if isinstance(packet,StatusPacket) and packet.evidence_health:
                identity=packet.evidence_health.identity[:2];stage=packet.state_id
                if all(identity):break
        if not identity or not all(identity):raise ValueError('No live ST device/boot received; command not sent')
        if stage in (3,4):raise ValueError('Exam/submitted state; command not sent')
        token=int(time.time())
        if operation==2:payload=rtc_payload()  # sample clock after live identity discovery
        command=encode_command(operation,token,*identity,payload)
        request_path=output.with_suffix('.request')
        with request_path.open('xb') as target:target.write(command)
        if link.write(command)!=len(command):raise OSError('Partial command write; result unknown, do not retry automatically')
        link.flush();deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            raw=link.readline()
            if raw:saved.write(raw);saved.flush()
            if not raw.startswith(b'MR,'):continue
            packet=decode_result(raw)
            if (packet.request_id,packet.operation,(packet.device,packet.boot))==(token,operation,identity):
                return packet
        raise TimeoutError('No matching MR response; result unknown. No automatic retry; inspect raw/request logs and read configuration first.')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True)
    parser.add_argument('--action',choices=('load','save','set-time'),required=True)
    parser.add_argument('--seat',type=int,default=1)
    parser.add_argument('--duration',type=int,default=2700)
    parser.add_argument('--mute',action='store_true')
    args=parser.parse_args()
    operation={'load':0,'save':1,'set-time':2}[args.action]
    payload=bytes(32)
    if operation==1:payload=PersistentConfig(args.seat,args.duration,480,args.mute).encode()
    elif operation==2:payload=rtc_payload()
    logs=Path(__file__).resolve().parent/'logs'
    if not logs.is_dir():raise ValueError('host/logs missing')
    output=logs/('maintenance_direct_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.raw')
    import serial
    with serial.Serial(args.port,115200,timeout=.2) as link:
        result=execute(link,operation,payload,output)
    with output.with_suffix('.json').open('x',encoding='utf-8') as target:
        json.dump({'received_utc':datetime.now(timezone.utc).isoformat(),'result':result.text(),
                   'raw_hex':result.raw.hex(),'source':'PC current clock UTC+8' if operation==2 else 'operator',
                   'interpretation':'Board reply only; no FPGA/Flash programming or physical power observation.'},target,ensure_ascii=False,indent=2)
    print(result.text());print('Raw:',output)
    return 0 if result.error==0 else 2


if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,ValueError,TimeoutError) as exc:
        print('MAINTENANCE FAILED:',exc);raise SystemExit(2)
