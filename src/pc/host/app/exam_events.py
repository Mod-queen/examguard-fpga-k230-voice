"""ExamGuard terminology: stage / risk / event-code labels.

Kept separate from the wire protocol so both the dashboard and the report
export share one vocabulary (see docs/examguard_final_plan.md section 7).
"""

from __future__ import annotations

STAGE_NAMES = {
    0: "待机",
    1: "候考",
    2: "核验",
    3: "考试",
    4: "交卷",
    5: "完成",
}

RISK_NAMES = {
    0: "正常",
    1: "疑似",
    2: "确认",
    3: "严重",
}

ZONE_NAMES = {
    0: "-",
}

# Event code -> Chinese label. Codes follow docs/examguard_final_plan.md.
EVENT_NAMES = {
    0x00: "-",
    0x01: "身份核验通过",
    0x03: "考试结束",
    0x10: "未核验入场",
    0x11: "非授权人员",
    0x12: "多人/尾随",
    0x13: "面部遮挡",
    0x21: "提前交卷",
    0x31: "超时未交卷",
    0x40: "进入禁区",
    0x50: "检测到手机",
    0x51: "小抄/资料",
    0x52: "耳机",
    0x53: "智能手表",
    0x54: "其他违禁物",
    0x60: "频繁扭头",
    0x61: "交头接耳/传递",
    0x62: "离座",
    0x63: "他人面孔",
    0x64: "遮挡/画面骤变",
    0x65: "异常静止",
}


# C04 health flags carried on the 11-field ST line (bit -> label).
HEALTH_FLAG_NAMES = {
    0x01: "相机停帧",
    0x02: "K230无结果",
    0x04: "证据忙",
    0x08: "证据溢出(丢事件)",
    0x10: "持久身份等待",
    0x20: "持久身份失败(事务准入关闭)",
}


def format_health(value: int) -> str:
    """Human text for the ST health byte; 0 is fully healthy."""
    if value == 0:
        return "正常 (0x00)"
    names = [name for bit, name in HEALTH_FLAG_NAMES.items() if value & bit]
    unknown = value & ~sum(HEALTH_FLAG_NAMES)
    if unknown:
        names.append(f"未知位0x{unknown:02X}")
    return "、".join(names) + f" (0x{value:02X})"


def stage_name(value: int) -> str:
    return STAGE_NAMES.get(value, f"未知({value})")


def risk_name(value: int) -> str:
    return RISK_NAMES.get(value, f"未知({value})")


def event_name(value: int) -> str:
    return EVENT_NAMES.get(value, f"未知(0x{value:02X})")


def format_event(value: int) -> str:
    """Human label plus raw code, e.g. '检测到手机 (0x50)'."""
    return f"{event_name(value)} (0x{value:02X})"
