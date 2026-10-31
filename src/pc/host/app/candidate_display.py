"""Wire glyph palette for the FPGA candidate panel (not arbitrary Unicode TTS)."""
CHARS = '姓名考号位彭于晏未配置请核对信息准备已确认等待老师开考试中求助'
PALETTE = ''.join(dict.fromkeys(CHARS))


def encode_display(name, exam_number):
    if len(name)>6 or len(exam_number)>10 or not exam_number.isascii() or not exam_number.isdigit():
        raise ValueError('HDMI名册支持最多6字姓名和最多10位数字考号')
    codes=[]
    for char in name:
        if char not in PALETTE:
            raise ValueError(f'HDMI字库尚未包含“{char}”，需要更新显示字库')
        codes.append(0x80+PALETTE.index(char))
    return bytes(codes).ljust(6,b' ') + exam_number.encode('ascii').ljust(10,b' ')
