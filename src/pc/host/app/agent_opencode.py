"""Use the genuine OpenCode client and read-only MCP for free model review."""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from .agent_tools import ToolError

FREE_MODELS = ('opencode/glm-5.3-flash-free', 'opencode/deepseek-v4.1-flash-free',
               'opencode/minimax-m3.1-flash-free', 'opencode/flint-40b-free',
               'opencode/nemotron-3.5-lightning-free')
ROOT = Path(__file__).resolve().parents[2]


def client_path():
    path = Path(os.environ.get('APPDATA', '')) / 'npm' / 'node_modules' / 'opencode-ai' / 'bin' / 'opencode.exe'
    if path.is_file():
        return str(path)
    value = shutil.which('opencode.exe' if os.name == 'nt' else 'opencode')
    if not value:
        raise ToolError('未找到OpenCode客户端；请先安装客户端或选择兼容API模式')
    return value


def known_error(text):
    value = text.lower()
    if 'free usage limit reached' in value:
        return '免费模型额度已达上限，请稍后再试或手动选择其他免费模型；未切换付费模型'
    if 'not available in your country' in value or 'regionerror' in value:
        return '该免费模型在当前地区不可用，请选择服务商允许在本地区使用的其他模型'
    if 'active opencode go subscription' in value:
        return '该模型要求有效Go订阅，请检查是否选择了免费模型'
    if 'unexpected server error' in value:
        return '免费模型服务暂时出错，请稍后重试或手动更换免费模型'
    return ''


def child_config(work, source, model, key):
    if model not in FREE_MODELS:
        raise ToolError('请选择界面列出的免费模型；不会自动调用付费模型')
    from .agent_controller import SYSTEM_PROMPT
    (work / 'AGENTS.md').write_text('Isolated review request. Use only examguard MCP. Do not read files, run commands, or access the parent project.\n', encoding='utf-8')
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('OPENCODE_', 'EXAMGUARD_')) and not k.endswith('_API_KEY')}
    for name, folder in (('XDG_CONFIG_HOME', 'config'), ('XDG_DATA_HOME', 'data'),
                         ('XDG_CACHE_HOME', 'cache'), ('XDG_STATE_HOME', 'state')):
        directory = work / folder
        directory.mkdir(exist_ok=True)
        env[name] = str(directory)
    env.update(OPENCODE_DISABLE_AUTOUPDATE='1', OPENCODE_DISABLE_DEFAULT_PLUGINS='1',
               OPENCODE_DISABLE_PROJECT_CONFIG='1', OPENCODE_DISABLE_CLAUDE_CODE='1',
               OPENCODE_DISABLE_EXTERNAL_SKILLS='1', OPENCODE_DISABLE_AUTOCOMPACT='1',
               OPENCODE_PURE='1', OPENCODE_DISABLE_LSP_DOWNLOAD='1',
               OPENCODE_EXPERIMENTAL_DISABLE_FILEWATCHER='1')
    audit = work / 'tool_receipts.jsonl'
    audit.touch()
    permission = {'*': 'deny', 'examguard_*': 'allow'}
    config = dict(model=model, small_model=model, autoupdate=False, snapshot=False, share='disabled',
                  enabled_providers=['opencode'], instructions=[], plugin=[], permission=permission,
                  agent=dict(examguard=dict(mode='primary', description='Read-only exam evidence review',
                      prompt=SYSTEM_PROMPT + '\n必须调用examguard工具取得事实，不使用其他工具。当前是所选会话存档复核，不能宣称实时在线。',
                      permission=permission, steps=8)),
                  mcp=dict(examguard=dict(type='local', enabled=True, timeout=15000, command=[
                      sys.executable, '-u', str(ROOT / 'start_agent_mcp.py'), '--session', str(source.session_path),
                      '--evidence-root', str(source.evidence_root), '--audit-log', str(audit), '--max-tool-calls', '6'])))
    if key:
        env['EXAMGUARD_FREE_KEY'] = key
        config['provider'] = {'opencode': {'options': {'apiKey': '{env:EXAMGUARD_FREE_KEY}'}}}
    env['OPENCODE_CONFIG_CONTENT'] = json.dumps(config, ensure_ascii=False)
    return env, audit


def collect_reply(stdout, trace, key):
    from .agent_controller import AgentReply, verified_text
    texts, failed = [], False
    for line in stdout.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if not isinstance(item, dict):
            continue
        if item.get('type') == 'error':
            failed = True
        part = item.get('part', {})
        if item.get('type') == 'text' and isinstance(part, dict) and isinstance(part.get('text'), str):
            texts.append(part['text'])
    if failed:
        raise ToolError(known_error(stdout) or 'OpenCode免费模型调用未完成，请重试；未切换付费模型')
    if not trace or not texts:
        raise ToolError('免费模型未完成工具查询与回答，不能将本次结果作为复核结论')
    answer = '\n'.join(texts)[:6000]
    if key:
        answer = answer.replace(key, '[密钥已隐藏]')
        trace = json.loads(json.dumps(trace, ensure_ascii=False).replace(key, '[密钥已隐藏]'))
    return AgentReply('OpenCode免费模型工具调用', answer, verified_text(trace), trace)


def ask_free(question, source, config, *, cancelled, history=()):
    if not source.session_path or not Path(source.session_path).is_file():
        raise ToolError('请先选择实际会话存档或启动监测，免费模型不能查询不存在的会话')
    executable = client_path()
    private = ROOT / 'host' / '.private' / 'opencode_requests'
    private.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='review-', dir=private) as directory:
        work = Path(directory)
        env, audit = child_config(work, source, config.model, config.api_key)
        context = '\n'.join(('老师：' if item.get('role') == 'user' else '助手：') + item.get('content', '')[:1500]
                            for item in list(history)[-4:] if isinstance(item.get('content'), str))
        prompt = ('以下历史仅作上下文，当前事实必须重新查询工具。\n' + context + '\n' if context else '') + '老师本次问题：' + question
        command = [executable, 'run', '--format', 'json', '--model', config.model, '--agent', 'examguard',
                   '--title', 'ExamGuard review', prompt]
        process = subprocess.Popen(command, cwd=work, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8',
                                   errors='replace', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        deadline = time.monotonic() + 65
        try:
            while True:
                if cancelled.is_set():
                    raise ToolError('本次免费模型查询已取消')
                if time.monotonic() > deadline:
                    raise ToolError('免费模型响应超时，请重试或手动选择其他免费模型')
                try:
                    stdout, stderr = process.communicate(timeout=.25)
                    break
                except subprocess.TimeoutExpired:
                    # OpenCode may retry a known quota/region error; stop this request promptly.
                    log = work / 'data' / 'opencode' / 'log' / 'opencode.log'
                    if log.is_file():
                        error = known_error(log.read_text(encoding='utf-8', errors='replace')[-32768:])
                        if error:
                            raise ToolError(error)
            if len(stdout) > 2 * 1024 * 1024:
                raise ToolError('模型输出过大，本次已停止')
            if process.returncode:
                raise ToolError(known_error(stdout + stderr) or 'OpenCode免费模型调用失败，请检查客户端和网络')
            if audit.stat().st_size > 2 * 1024 * 1024:
                raise ToolError('工具回执过大，本次已停止')
            trace = [json.loads(line) for line in audit.read_text(encoding='utf-8').splitlines() if line.strip()]
            return collect_reply(stdout, trace, config.api_key)
        finally:
            if process.poll() is None:
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0), timeout=8)
                else:
                    process.kill()
                process.wait(timeout=8)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()


def probe_free(config):
    import threading
    from .agent_tools import AgentSource
    from .monitor import MonitorModel
    private = ROOT / 'host' / '.private' / 'opencode_requests'
    private.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='probe-', dir=private) as directory:
        root = Path(directory)
        model = MonitorModel(session_root=root / 'sessions')
        try:
            path = model.snapshot().session_path
        finally:
            model.close()
        source = AgentSource(Path(path), root / 'empty_evidence', label='空测试会话（无现场数据）')
        reply = ask_free('这是空测试会话。只调用get_system_health，然后回复连接测试完成；不要查询其他工具。',
                         source, config, cancelled=threading.Event())
        if not any(item['name'] == 'get_system_health' for item in reply.trace):
            raise ToolError('免费模型没有完成测试工具调用')
    return '免费模型连接测试通过：已调用空测试会话工具；未发送监考数据或图片'
