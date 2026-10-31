"""PC-only model configuration; Windows protects the key for the current user."""
from __future__ import annotations

import base64
import ctypes
from ctypes import wintypes
from dataclasses import dataclass, replace
import json
import os
from pathlib import Path
import tempfile

from .agent_controller import ModelConfig
from .agent_tools import ToolError


OPENCODE_GO_BASE = 'https://opencode.ai/zen/go/v1'
OPENCODE_GO_MODELS = ('glm-5.3-flash', 'glm-5.3')
ZHIPU_BASE = 'https://open.bigmodel.cn/api/paas/v4'
ZHIPU_TEXT_MODEL = 'glm-4.7-flash'
ZHIPU_VISION_MODEL = 'glm-4.6v-flash'
SETTINGS_PATH = Path(__file__).resolve().parents[1] / '.private' / 'agent_settings.json'


@dataclass(frozen=True)
class SavedAgentSettings:
    config: ModelConfig
    mode: str = 'local'
    message: str = ''


class _Blob(ctypes.Structure):
    _fields_ = [('cbData', wintypes.DWORD), ('pbData', ctypes.POINTER(ctypes.c_ubyte))]


def _crypt(value: bytes, *, decrypt=False) -> bytes:
    if os.name != 'nt':
        raise ToolError('当前仅支持Windows本机加密保存；其他系统请使用环境变量')
    crypt32 = ctypes.WinDLL('crypt32', use_last_error=True)
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    buffer = ctypes.create_string_buffer(value)
    source = _Blob(len(value), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = _Blob()
    # CRYPTPROTECT_UI_FORBIDDEN; omit LOCAL_MACHINE, so another user cannot decrypt.
    if decrypt:
        operation = crypt32.CryptUnprotectData
        operation.argtypes = [ctypes.POINTER(_Blob), ctypes.c_void_p, ctypes.c_void_p,
                              ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_Blob)]
        arguments = (ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        operation = crypt32.CryptProtectData
        operation.argtypes = [ctypes.POINTER(_Blob), wintypes.LPCWSTR, ctypes.c_void_p,
                              ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(_Blob)]
        arguments = (ctypes.byref(source), 'ExamGuard model key', None, None, None, 1, ctypes.byref(target))
    operation.restype = wintypes.BOOL
    if not operation(*arguments):
        raise ToolError('Windows密钥加密或解密失败，请在本机重新配置')
    try:
        return ctypes.string_at(target.pbData, target.cbData)
    finally:
        kernel32.LocalFree(ctypes.cast(target.pbData, ctypes.c_void_p))


def default_settings():
    return SavedAgentSettings(ModelConfig(ZHIPU_BASE, ZHIPU_TEXT_MODEL, vision_model=ZHIPU_VISION_MODEL),
                              message='已预填智谱免费双模型；填写智谱密钥后点击“保存并连接”')


def _validate(config, mode):
    if mode == 'opencode':
        from .agent_opencode import FREE_MODELS
        if config.model not in FREE_MODELS:
            raise ToolError('请选择列出的OpenCode免费模型')
    elif mode == 'llm':
        config.url()
    elif mode == 'local':
        replace(config, api_key=config.api_key or 'not-sent').url()
    else:
        raise ToolError('未知的运行模式')
    if not isinstance(config.vision_model, str) or len(config.vision_model) > 100:
        raise ToolError('视觉模型名无效')
    if not isinstance(config.allow_paid_fallback, bool):
        raise ToolError('收费备用开关必须为布尔值')


def load_agent_settings(path=None, *, environ=None):
    path = Path(path) if path is not None else SETTINGS_PATH
    env = os.environ if environ is None else environ
    fallback = default_settings()
    config, mode, message = fallback.config, fallback.mode, fallback.message
    if path.exists():
        try:
            if path.stat().st_size > 64 * 1024:
                raise ValueError('large')
            data = json.loads(path.read_text(encoding='utf-8'))
            if data.get('version') != 1 or data.get('protection') != 'windows-dpapi-current-user':
                raise ValueError('format')
            if any(not isinstance(data.get(name), str) for name in ('endpoint', 'model', 'key_protected', 'mode')):
                raise ValueError('types')
            key = (_crypt(base64.b64decode(data['key_protected'], validate=True), decrypt=True).decode('utf-8')
                   if data['key_protected'] else '')
            config = ModelConfig(data['endpoint'], data['model'], key, vision_model=data.get('vision_model', ''),
                                 allow_paid_fallback=data.get('allow_paid_fallback', False))
            mode = data['mode']
            _validate(config, mode)
            message = '已读取本机加密配置；实际连接状态待测试'
        except (OSError, ValueError, KeyError, TypeError, ToolError):
            config, mode = fallback.config, 'local'
            message = '本机配置无法读取，请重新填写并保存；当前为本地工具演示'
    # An explicit environment override is independent of the stored provider.
    if any(env.get(name) for name in ('EXAMGUARD_API_BASE', 'EXAMGUARD_MODEL', 'EXAMGUARD_API_KEY', 'EXAMGUARD_VISION_MODEL')):
        config = ModelConfig(env.get('EXAMGUARD_API_BASE') or fallback.config.endpoint,
                             env.get('EXAMGUARD_MODEL') or fallback.config.model,
                             env.get('EXAMGUARD_API_KEY') or '', vision_model=env.get('EXAMGUARD_VISION_MODEL') or '')
        mode = 'llm' if config.api_key else 'local'
        message = '已读取本机环境配置；实际连接状态待测试'
    return SavedAgentSettings(config, mode, message)


def save_agent_settings(config, *, mode='llm', path=None):
    _validate(config, mode)
    data = dict(version=1, protection='windows-dpapi-current-user', endpoint=config.endpoint.strip().rstrip('/'),
                model=config.model.strip(), vision_model=config.vision_model.strip(), mode=mode,
                allow_paid_fallback=config.allow_paid_fallback,
                key_protected=base64.b64encode(_crypt(config.api_key.encode('utf-8'))).decode('ascii') if config.api_key else '')
    path = Path(path) if path is not None else SETTINGS_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', prefix='.settings-', suffix='.tmp',
                                         dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(data, stream, ensure_ascii=False, indent=2)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def clear_agent_settings(path=None):
    (Path(path) if path is not None else SETTINGS_PATH).unlink(missing_ok=True)
