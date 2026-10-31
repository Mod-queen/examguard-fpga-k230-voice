"""Portable review records; never copy credentials or local evidence paths."""
from datetime import datetime, timezone
import json


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def build_review_record(question, reply, source, queried_at, *, secrets=()):
    def clean(value):
        if isinstance(value, dict):
            return {key: clean(item) for key, item in value.items()
                    if key.lower() not in ('path', 'api_key', 'authorization', 'password')}
        if isinstance(value, (list, tuple)):
            return [clean(item) for item in value]
        if isinstance(value, str):
            for secret in secrets:
                if secret:
                    value = value.replace(secret, '[已隐藏]')
        return value
    return clean(dict(
        format='examguard_review_v1', queried_at_utc=queried_at, completed_at_utc=utc_now(),
        source=dict(label=source.label, session=source.session_path.name if source.session_path else None),
        question=question, **reply.as_dict(),
        notice='本文件是一次只读查询的复核记录，不能替代原始证据；识别可能误报或漏报，由老师看图复核。'
               '大模型说明与工具核验结果分别保留；完整性仅表示查询当时的校验结果。'))


def serialize_review_record(record):
    return json.dumps(record, ensure_ascii=False, indent=2) + '\n'
