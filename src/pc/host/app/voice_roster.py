"""Explicit face-ID mapping; missing entries never fabricate candidate identity."""
import json
from pathlib import Path


def load_voice_roster(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    if not isinstance(data, dict) or data.get('schema') != 1 or not isinstance(data.get('candidates'), list):
        raise ValueError('名册格式需要schema=1及candidates列表')
    result = {}
    for item in data['candidates']:
        if not isinstance(item, dict):
            raise ValueError('无效名册条目')
        face = item.get('face_id')
        if type(face) is not int or face not in (1, 2, 3) or face in result:
            raise ValueError('人脸编号须为1/2/3且不得重复')
        values = []
        for key in ('name', 'exam_number'):
            text = item.get(key)
            if not isinstance(text, str) or not text.strip() or len(text) > 64 or any(ord(c) < 32 for c in text):
                raise ValueError('姓名和考号不能为空、过长或包含控制字符')
            values.append(text.strip())
        revision = item.get('info_tag')
        if not isinstance(revision, str) or len(revision) != 16:
            raise ValueError('info_tag需要16位十六进制修订标识')
        tag = int(revision, 16)
        if not tag:
            raise ValueError('info_tag不能为0')
        result[face] = (*values, tag)
    return result
