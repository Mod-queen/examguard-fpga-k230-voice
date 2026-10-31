"""FPGA-authoritative exam timer; never start or advance a PC-side clock."""
from dataclasses import dataclass
import time

from .protocol import StatusPacket


@dataclass(frozen=True)
class TimerView:
    remaining: str
    elapsed: str
    message: str
    fraction: float


def mmss(seconds: int) -> str:
    minutes, seconds = divmod(seconds, 60)
    return f'{minutes:02d}:{seconds:02d}'


class ExamTimer:
    def __init__(self, *, stale_after: float = 3.0):
        self.packet = None
        self.received_at = None
        self.stale_after = stale_after

    def apply(self, packet: StatusPacket, now: float | None = None) -> None:
        self.packet = packet
        self.received_at = time.monotonic() if now is None else now

    def view(self, now: float | None = None) -> TimerView:
        now = time.monotonic() if now is None else now
        packet = self.packet
        if packet is None:
            return TimerView('45:00', '00:00', '等待 FPGA；核验后按 S3 开考', 0.0)
        stale = now - self.received_at > self.stale_after
        if packet.remaining_s is None:
            if packet.state_id < 3:
                remaining, elapsed = '45:00', '00:00'
            else:
                remaining, elapsed = '--:--', '--:--'
            message = '当前位流未上报考试计时，请烧录倒计时升级版'
            if stale:
                message += '；FPGA 状态停更'
            return TimerView(remaining, elapsed, message, 0.0)
        duration = packet.exam_duration_s
        remaining = duration if packet.state_id < 3 else packet.remaining_s
        elapsed = duration - remaining
        if packet.state_id < 3:
            message = '尚未开考 · 核验后按 S3 开始计时'
        elif packet.state_id == 3:
            message = '考试中 · 与 FPGA 数码管同源'
        elif packet.state_id in (4, 5):
            message = '考试时间到 · 已停止计时' if remaining == 0 else '已交卷 · 计时已冻结'
        else:
            message = '未知考试阶段 · 显示 FPGA 最后计时'
        if stale:
            message = 'FPGA 状态停更 · 保持最后读数，等待重连'
        return TimerView(mmss(remaining), mmss(elapsed), message, elapsed / duration)
