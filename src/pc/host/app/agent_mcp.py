"""Local stdio MCP adapter for the four existing read-only review tools."""
import json

from .agent_tools import AgentTools, TOOL_SCHEMAS, ToolError
from .agent_joycode import SourceSelectionError


class ReviewMCP:
    versions = ('2025-06-18', '2025-03-26', '2024-11-05')

    def __init__(self, source, *, audit=None, max_calls=None, source_provider=None):
        self.source = source
        self.source_provider = source_provider
        self.initialized = False
        self.audit = audit
        self.max_calls = max_calls
        self.call_count = 0

    def handle(self, request):
        if not isinstance(request, dict) or request.get('jsonrpc') != '2.0':
            return self.error(None, -32600, 'Invalid Request')
        identifier = request.get('id')
        if 'id' not in request:
            return None
        method, params = request.get('method'), request.get('params', {})
        if not isinstance(params, dict):
            return self.error(identifier, -32602, 'Invalid params')
        if method == 'initialize':
            version = params.get('protocolVersion')
            if not isinstance(version, str):
                return self.error(identifier, -32602, 'Missing protocolVersion')
            self.initialized = True
            result = dict(protocolVersion=version if version in self.versions else self.versions[0],
                          capabilities=dict(tools=dict()), serverInfo=dict(name='examguard-review', version='1.1.0'),
                          instructions='只读考场存档查询。event_uid是编号，不可转换为事件类型；类型只读event_code/event_code_hex/event。'
                                       '疑似事件需人工看图复核。图像工具只返回本机路径和元数据，不提供视觉确认。'
                                       '上位机切换数据源后应重新查事件；数据联动就绪不等于设备在线。')
        elif not self.initialized:
            return self.error(identifier, -32002, 'Initialize first')
        elif method == 'ping':
            result = {}
        elif method == 'tools/list':
            result = dict(tools=[dict(name=t['function']['name'], description=t['function']['description'],
                                     inputSchema=t['function']['parameters'],
                                     annotations=dict(readOnlyHint=True, destructiveHint=False, openWorldHint=False))
                                for t in TOOL_SCHEMAS])
        elif method == 'tools/call':
            try:
                if self.max_calls is not None and self.call_count >= self.max_calls:
                    raise ToolError('工具调用次数已达上限')
                self.call_count += 1
                source = self.source_provider.resolve(params.get('name')) if self.source_provider else self.source
                value = AgentTools(source).call(params.get('name'), params.get('arguments', {}))
                if self.source_provider:
                    value.update(self.source_provider.context)
                if self.audit:
                    self.audit(dict(name=params.get('name'), arguments=params.get('arguments', {}), result=value))
                result = dict(content=[dict(type='text', text=json.dumps(value, ensure_ascii=False))], isError=False)
            except SourceSelectionError as exc:
                result = dict(content=[dict(type='text', text=str(exc))], isError=True)
            except (ToolError, ValueError, TypeError):
                result = dict(content=[dict(type='text', text='查询未完成：请检查工具参数、选定存档及证据状态。')], isError=True)
            except Exception:
                result = dict(content=[dict(type='text', text='查询未完成；未修改设备或证据。')], isError=True)
        else:
            return self.error(identifier, -32601, 'Method not found')
        return dict(jsonrpc='2.0', id=identifier, result=result)

    @staticmethod
    def error(identifier, code, message):
        return dict(jsonrpc='2.0', id=identifier, error=dict(code=code, message=message))

    def serve(self, reader, writer):
        while True:
            raw = reader.readline(65537)
            if not raw:
                return
            if len(raw) > 65536:
                # Stop this local connection rather than treating a suffix as a new request.
                response = self.error(None, -32600, 'Request too large')
                writer.write((json.dumps(response) + '\n').encode('utf-8'))
                writer.flush()
                return
            try:
                request = json.loads(raw)
                response = self.handle(request)
            except (UnicodeError, ValueError):
                response = self.error(None, -32700, 'Parse error')
            if response is not None:
                writer.write((json.dumps(response, ensure_ascii=False) + '\n').encode('utf-8'))
                writer.flush()
