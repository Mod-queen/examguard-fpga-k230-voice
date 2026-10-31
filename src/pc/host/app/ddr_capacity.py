"""Standalone destructive-test DC report verifier, distinct from live ST/EG."""
import re
import struct
import zlib


def decode_capacity(line):
    if isinstance(line,bytes):line=line.decode('ascii')
    match=re.fullmatch(r'DC,([0-9a-fA-F]{192})\n?',line)
    if not match:raise ValueError('DC length/hex')
    raw=bytes.fromhex(match[1])
    if raw[:6]!=b'DC\1\1\0\x60' or raw[6]&~1 or raw[7] or any(raw[80:92]):raise ValueError('DC header/reserved')
    if zlib.crc32(raw[:92])!=int.from_bytes(raw[92:],'big'):raise ValueError('DC CRC')
    region,passes,done,errors,written,read=struct.unpack_from('!6I',raw,8)
    if region<512 or region>268435456 or region%512 or not passes or done!=passes:raise ValueError('DC coverage/count')
    expected=region//16*4*passes
    if written!=min(expected,0xffffffff) or read!=min(expected,0xffffffff):raise ValueError('DC beat coverage')
    region_errors=struct.unpack_from('!4I',raw,32)[::-1]
    wcycles=struct.unpack_from('!4I',raw,48)[::-1];rcycles=struct.unpack_from('!4I',raw,64)[::-1]
    if not all(wcycles+rcycles):raise ValueError('DC missing cycle observations')
    return dict(passed=not raw[6] and errors==0 and not any(region_errors),timed_out=bool(raw[6]),
                region_bytes=region,passes=passes,passes_done=done,total_bytes_per_pass=region*4,
                errors=errors,region_errors=region_errors,beats_written=written,beats_read=read,
                write_cycles=wcycles,read_cycles=rcycles,
                scope='Only the reported standalone test; not continuous video/whole-system validation')
