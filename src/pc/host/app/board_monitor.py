"""BM64 strict telemetry decoder. On-chip rails only, not board supply sensors."""
from dataclasses import dataclass
import re
import struct
import zlib
from .protocol import ProtocolError


@dataclass(frozen=True)
class BoardMonitor:
    raw: bytes
    valid: bool
    straps_valid: bool
    switches: int
    device: int
    boot: int
    sequence: int
    seat: int
    monotonic_ms: int
    adc: tuple[int, ...]
    adc_sequence: int
    age_cycles: int

    def text(self):
        if not self.valid:
            return f'板级监测 {self.device}/{self.boot} 考位{self.seat}：未知/陈旧'
        temp=self.adc[0]*503.975/65536-273.15
        volts=[raw*3/65536 for raw in self.adc[1:]]
        return (f'板级监测 {self.device}/{self.boot} 考位{self.seat}：{temp:.1f}°C '
                f'VCCINT/AUX/BRAM={volts[0]:.3f}/{volts[1]:.3f}/{volts[2]:.3f}V；'
                f'ADC#{self.adc_sequence} DIP=0x{self.switches:02X}')


def decode_board_monitor(line):
    if isinstance(line,bytes):
        try:line=line.decode('ascii')
        except UnicodeError as exc:raise ProtocolError('BM not ASCII') from exc
    match=re.fullmatch(r'BM,([0-9a-fA-F]{128})\n?',line)
    if not match:raise ProtocolError('BM length/hex')
    raw=bytes.fromhex(match[1])
    if raw[:6]!=b'BM\1\1\0\x40' or raw[6]&~3 or any(raw[48:60]):raise ProtocolError('BM header/reserved')
    if int.from_bytes(raw[60:],'big')!=zlib.crc32(raw[:60]):raise ProtocolError('BM CRC')
    device,boot,sequence,seat,stamp=struct.unpack_from('!IIIIQ',raw,8)
    adc=struct.unpack_from('!4H',raw,32);adc_seq,age=struct.unpack_from('!II',raw,40)
    if not all((device,boot,sequence,seat)) or (raw[6]&1 and (not adc_seq or age>50000000)):
        raise ProtocolError('BM identity/freshness')
    return BoardMonitor(raw,bool(raw[6]&1),bool(raw[6]&2),raw[7],device,boot,sequence,seat,stamp,adc,adc_seq,age)
