"""Decode fixed 128-byte EHealth v1 ST extension; separate from legacy health.

Counters belong to the indicated runtime transport epoch. Domains are atomic
snapshots at DIFFERENT instants. Invalid/stale domains are unknown, never zero-
healthy. cancel_epochs counts cancellations, not an invented lost-event total.
"""
from dataclasses import dataclass
import re
import struct
import time

from .protocol import ProtocolError


@dataclass(frozen=True)
class EvidenceHealth:
    words: tuple[int, ...]

    @property
    def flags(self):
        return self.words[0] & 0xFFFFFF

    @property
    def identity(self):
        return self.words[1:4]

    @property
    def phy_text(self):
        if self.words[0] >> 24 == 1:
            return "PHY未上报"
        value = self.words[31]
        if not value & 0x200:
            return "PHY未知"
        if value & 0x100:
            return "PHY状态陈旧"
        if not value & 0x80:
            return "PHY型号未确认"
        if not value & 0x40:
            return "PHY读回无效"
        if not value & 4:
            return "PHY链路未就绪"
        speed = (10, 100, 1000, None)[value & 3]
        text = f"PHY {speed}M {'全双工' if value & 8 else '半双工'}"
        if not value & 16:
            text += " TX延迟未开启"
        return text

    @property
    def time_ms(self):
        return self.words[10] << 32 | self.words[11]

    def domain_fresh(self, index):
        return bool(self.flags & (1 << (4 + index)))

    def encode(self):
        return struct.pack("!32I", *self.words).hex().upper()


def decode_evidence_health(value: str) -> EvidenceHealth:
    if not re.fullmatch(r"[0-9a-fA-F]{256}", value):
        raise ProtocolError("invalid evidence health hex length/content")
    words = struct.unpack("!32I", bytes.fromhex(value))
    version = words[0] >> 24
    if version not in (1, 2) or words[0] & 0xFF0000 or words[7] >> 8:
        raise ProtocolError("unsupported evidence health version/reserved")
    if (words[7] & 15) > 8 or (words[7] >> 4 & 15) > 8:
        raise ProtocolError("invalid evidence source occupancy")
    if words[20] & 0x3FFF0000 or words[28] & ~3 or (version == 1 and words[31]):
        raise ProtocolError("invalid evidence domain state/reserved")
    if version == 2:
        phy = words[31]
        if phy >> 24 != 1 or phy & 0x00FFFC00:
            raise ProtocolError("invalid PHY summary version/reserved")
        if not phy & 0x200 and phy & 0x1FF:
            raise ProtocolError("unknown PHY summary has stale/live values")
        if phy & 0x44 == 0x44 and phy & 3 == 3:
            raise ProtocolError("invalid resolved PHY speed")
    flags = words[0] & 0xFFFFFF
    if flags & 1 and flags & 0x70:
        raise ProtocolError("reset evidence telemetry cannot be fresh")
    if any(flags & (1 << (4+i)) and flags & (1 << (7+i)) for i in range(3)):
        raise ProtocolError("evidence domain both fresh and stale")
    for index, bounds in enumerate(((12, 20), (20, 28), (28, 31 if version == 2 else 32))):
        if not flags & (1 << (4+index)) and any(words[bounds[0]:bounds[1]]):
            raise ProtocolError("invalid evidence domain contains live counters")
    return EvidenceHealth(words)


class EvidenceHealthView:
    def __init__(self):
        self.latest = None
        self.received_at = None

    def apply(self, packet, now=None):
        self.latest = packet.evidence_health
        self.received_at = time.monotonic() if now is None else now

    def text(self, now=None):
        if self.latest is None:
            return "新证据链：未上报（旧协议）"
        now = time.monotonic() if now is None else now
        h, w = self.latest, self.latest.words
        if now - self.received_at > 3:
            state = "状态停更（最后读数保留）"
        elif h.flags & 1:
            state = "传输复位/等待释放"
        else:
            issues = [name for bit, name in ((1, "启动身份耗尽"), (2, "事件ID耗尽"), (3, "源队列满"),
                      (7, "采样统计停更"), (8, "DDR统计停更"), (9, "网络统计停更"),
                      (10, "采样忙丢/无效帧"), (11, "DDR错误"), (12, "分片错误"), (13, "发送错误/丢包")) if h.flags & (1 << bit)]
            if (h.flags & 0x70) != 0x70:
                issues.append("统计尚未就绪")
            if w[5]:
                issues.append("源请求被拒绝")
            if h.domain_fresh(0) and (w[18] or w[19]):
                issues.append("帧时间未知/陈旧拒收")
            state = "、".join(issues) or ("证据处理中" if h.flags & (1 << 15) else "就绪")
        prefix = f"新证据链：{state} | boot={w[2]} 场={w[3]} 接受/拒绝={w[4]}/{w[5]} 取消epoch={w[8]} 准入阻止={w[9]}"
        if h.domain_fresh(1):
            prefix += f" | DDR提交/写失败/读错/窗失败={w[23]}/{w[24]}/{w[25]}/{w[26]}"
        if h.domain_fresh(2):
            prefix += f" | UDP发送/丢弃={w[29]}/{w[30]}"
        if w[0] >> 24 == 2:
            prefix += " | " + h.phy_text
        return prefix
