"""ET source-accepted transaction log: the exact EG v2 256-bit event context.

ET is not an AL/EI identity attachment or a successful DDR window verdict.
Transport cancellation can leave logged events without image results.
"""
from dataclasses import dataclass
import re
import struct

from .protocol import ProtocolError

TRANSACTION = struct.Struct("!IIIQQBBH")


@dataclass(frozen=True)
class TransactionEventPacket:
    transaction: bytes

    @property
    def identity(self):
        return TRANSACTION.unpack(self.transaction)[:4]

    @property
    def timestamp(self):
        return TRANSACTION.unpack(self.transaction)[4]

    @property
    def source(self):
        return self.transaction[28]

    @property
    def lane(self):
        return int.from_bytes(self.transaction[30:], "big")

    @property
    def stage_id(self):
        return self.lane >> 12 & 7

    @property
    def risk_level(self):
        return self.lane >> 8 & 3

    @property
    def event_code(self):
        return self.lane & 255


def decode_transaction_event(value):
    if not re.fullmatch(r"[0-9A-Fa-f]{64}", value):
        raise ProtocolError("invalid ET transaction hex")
    raw = bytes.fromhex(value)
    packet = TransactionEventPacket(raw)
    if packet.source > 3 or raw[29] or packet.lane & 0x8000 or packet.stage_id > 5 or not packet.identity[3]:
        raise ProtocolError("invalid ET source/reserved/stage/UID")
    return packet


def encode_transaction_event(packet):
    if not isinstance(packet, TransactionEventPacket) or not isinstance(packet.transaction, bytes):
        raise ProtocolError("invalid ET packet type")
    decode_transaction_event(packet.transaction.hex())
    return b"ET," + packet.transaction.hex().upper().encode("ascii") + b"\n"
