"""Authenticated read-only review website sharing the desktop Agent tools."""
from __future__ import annotations

from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import hashlib
import hmac
import json
import re
import secrets
import struct
import threading
import time
from urllib.parse import parse_qs, urlsplit
import zlib

from .agent_controller import AgentController, ModelConfig
from .agent_tools import AgentTools, ToolError
from .agent_report import build_review_record, utc_now


def ppm_to_png(raw):
    """Our strict evidence writer's P6 preview, using only the standard library."""
    match = re.match(rb'P6\n([0-9]+) ([0-9]+)\n255\n', raw)
    if not match:
        raise ToolError('不是本工程的P6图像')
    width, height = int(match[1]), int(match[2])
    pixels = raw[match.end():]
    if not 0 < width * height <= 4 * 1024 * 1024 or len(pixels) != width * height * 3:
        raise ToolError('图像尺寸无效')
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    scanlines = b''.join(b'\0' + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b''))


class AgentWebService:
    def __init__(self, source_factory, *, password, host='127.0.0.1', port=0,
                 mode='local', config=None, public_origin=None):
        if not isinstance(password, str) or not 8 <= len(password) <= 128:
            raise ValueError('网页访问密码需要8到128位')
        if mode not in ('local', 'llm', 'opencode'):
            raise ValueError('unknown mode')
        if public_origin:
            parsed = urlsplit(public_origin)
            if parsed.scheme != 'https' or not parsed.netloc or parsed.path not in ('', '/') or parsed.query or parsed.fragment or parsed.username:
                raise ValueError('公开入口需要HTTPS源地址，例如https://exam.example.com')
        self.source_factory = source_factory
        self.password_hash = hashlib.sha256(password.encode('utf-8')).digest()
        self.mode = mode
        self.config = config or ModelConfig()
        if mode == 'llm':
            self.config.url()
        elif mode == 'opencode':
            from .agent_opencode import FREE_MODELS
            if self.config.model not in FREE_MODELS:
                raise ValueError('请选择支持的OpenCode免费模型')
        self.public_origin = public_origin.rstrip('/') if public_origin else None
        self.cancelled = threading.Event()
        self.lock = threading.Lock()
        self.sessions = {}
        self.failures = {}
        self.capacity = threading.BoundedSemaphore(2)
        self.server = ThreadingHTTPServer((host, port), _Handler)
        self.server.daemon_threads = True
        self.server.owner = self
        self.thread = None
        address = self.server.server_address
        self.url = f'http://127.0.0.1:{address[1]}/'

    def start(self):
        self.thread = threading.Thread(target=lambda: self.server.serve_forever(poll_interval=0.1),
                                       daemon=True, name='examguard-agent-web')
        self.thread.start()

    def close(self):
        self.cancelled.set()
        if self.thread:
            self.server.shutdown()
            self.thread.join(timeout=1)
        self.server.server_close()
        with self.lock:
            self.sessions.clear()
        self.config = ModelConfig()


class _Handler(BaseHTTPRequestHandler):
    server_version = 'ExamGuardReview/1'

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, *_args):
        pass  # Passwords, questions, tokens and event references are never HTTP logs.

    @property
    def app(self):
        return self.server.owner

    def _reply(self, status, value, content_type='application/json; charset=utf-8', cookie=None):
        raw = json.dumps(value, ensure_ascii=False).encode('utf-8') if isinstance(value, dict) else value
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        if cookie:
            self.send_header('Set-Cookie', cookie)
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (OSError, TimeoutError):
            pass

    def _valid_origin(self):
        port = self.server.server_address[1]
        allowed_hosts = {f'127.0.0.1:{port}', f'localhost:{port}'}
        if self.app.public_origin:
            allowed_hosts.add(urlsplit(self.app.public_origin).netloc)
        host = self.headers.get('Host', '')
        origin = self.headers.get('Origin')
        return host in allowed_hosts and (not origin or origin in {f'http://127.0.0.1:{port}', f'http://localhost:{port}', self.app.public_origin})

    def _session(self):
        try:
            cookie = SimpleCookie(self.headers.get('Cookie', ''))
            token = cookie['examguard_session'].value if 'examguard_session' in cookie else ''
        except Exception:
            return None
        with self.app.lock:
            now = time.monotonic()
            self.app.sessions = {k: v for k, v in self.app.sessions.items() if v['expires'] > now}
            return self.app.sessions.get(token)

    def _json(self):
        if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
            raise ToolError('需要JSON请求')
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 8192:
            raise ToolError('请求长度无效')
        value = json.loads(self.rfile.read(size))
        if not isinstance(value, dict):
            raise ToolError('需要JSON对象')
        return value

    def do_GET(self):
        if not self._valid_origin():
            self._reply(403, dict(error='访问来源无效'))
            return
        path = urlsplit(self.path).path
        static = {'/': ('agent_review.html', 'text/html; charset=utf-8'),
                  '/app.js': ('agent_review.js', 'text/javascript; charset=utf-8'),
                  '/style.css': ('agent_review.css', 'text/css; charset=utf-8')}
        if path in static:
            filename, mime = static[path]
            self._reply(200, (Path(__file__).parent / 'web' / filename).read_bytes(), mime)
            return
        session = self._session()
        if session is None:
            self._reply(401, dict(error='请先登录'))
            return
        if path == '/api/session':
            source = self.app.source_factory()
            self._reply(200, dict(csrf=session['csrf'], mode=self.app.mode, source=source.label,
                                  scope=source.session_path.name if source.session_path else '没有存档',
                                  public=bool(self.app.public_origin)))
        elif path == '/api/image':
            if not self.app.capacity.acquire(blocking=False):
                self._reply(429, dict(error='正在核验其他请求，请稍后'))
                return
            try:
                query = parse_qs(urlsplit(self.path).query)
                ref = query.get('event_ref', [''])[0]
                index = int(query.get('index', ['-1'])[0])
                result = AgentTools(self.app.source_factory(), cancelled=self.app.cancelled).get_image_path(ref)
                image = next((f for f in result['images'] if f['frame_index'] == index), None)
                if image is None:
                    raise ToolError('没有该已校验图像')
                path = Path(image['path'])
                if path.stat().st_size > 16 * 1024 * 1024:
                    raise ToolError('图像过大')
                raw = path.read_bytes()
                if hashlib.sha256(raw).hexdigest() != image['sha256']:
                    raise ToolError('图像在核验后发生变化')
                self._reply(200, ppm_to_png(raw), 'image/png')
            except (ValueError, OSError, KeyError, TypeError):
                self._reply(404, dict(error='该图像不存在或未通过校验'))
            finally:
                self.app.capacity.release()
        else:
            self._reply(404, dict(error='没有该接口'))

    def do_POST(self):
        try:
            body = self._json()
        except (ValueError, OSError):
            self._reply(400, dict(error='请求无效'))
            return
        # Consume the small bounded body before rejecting origin. Closing a
        # Windows socket with unread POST bytes can reset the 403 response.
        if not self._valid_origin():
            self._reply(403, dict(error='访问来源无效'))
            return
        path = urlsplit(self.path).path
        if path == '/api/login':
            self._login(body)
            return
        session = self._session()
        if session is None:
            self._reply(401, dict(error='登录已过期，请重新登录'))
            return
        if not hmac.compare_digest(self.headers.get('X-CSRF-Token', ''), session['csrf']):
            self._reply(403, dict(error='登录校验失败，请刷新页面'))
            return
        if path == '/api/logout':
            with self.app.lock:
                self.app.sessions = {k: v for k, v in self.app.sessions.items() if v is not session}
            self._reply(200, dict(ok=True), cookie='examguard_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict')
            return
        if path != '/api/ask':
            self._reply(404, dict(error='没有该接口'))
            return
        if not self.app.capacity.acquire(blocking=False):
            self._reply(429, dict(error='正在处理其他查询，请稍后'))
            return
        owns_query = False
        try:
            with self.app.lock:
                if session['busy']:
                    self._reply(429, dict(error='上一次查询尚未结束'))
                    return
                session['busy'] = True
                owns_query = True
                history = list(session['history'])
            source = self.app.source_factory()
            queried_at = utc_now()
            controller = AgentController(AgentTools(source, cancelled=self.app.cancelled))
            reply = controller.ask(body.get('question'), mode=self.app.mode, config=self.app.config, history=history)
            data = reply.as_dict()
            data['review_record'] = build_review_record(body.get('question'), reply, source, queried_at,
                                                        secrets=(self.app.config.api_key,))
            # A remote browser needs frame references, not the host's filesystem layout.
            for call in data['trace']:
                if call['name'] == 'get_image_path':
                    for image in call['result'].get('images', []):
                        image.pop('path', None)
            with self.app.lock:
                session['history'].extend([dict(role='user', content=body['question']), dict(role='assistant', content=reply.answer)])
                session['history'] = session['history'][-8:]
            self._reply(200, data)
        except (ToolError, ValueError, TypeError):
            self._reply(400, dict(error='查询未完成，请检查问题或所选数据源'))
        except Exception:
            self._reply(500, dict(error='查询未完成；未更改证据或设备状态'))
        finally:
            if owns_query:
                with self.app.lock:
                    session['busy'] = False
            self.app.capacity.release()

    def _login(self, body):
        ip, now = self.client_address[0], time.monotonic()
        with self.app.lock:
            self.app.failures = {k: v for k, v in self.app.failures.items() if now - v[0] < 300}
            attempt = self.app.failures.get(ip, (now, 0))
            if attempt[1] >= 8 or len(self.app.failures) >= 64:
                self._reply(429, dict(error='登录尝试过多，请5分钟后重试'))
                return
            username, password = body.get('username'), body.get('password')
            valid = (isinstance(password, str) and len(password) <= 128 and username == 'judge'
                     and hmac.compare_digest(hashlib.sha256(password.encode('utf-8')).digest(), self.app.password_hash))
            if not valid:
                self.app.failures[ip] = (attempt[0], attempt[1] + 1)
                self._reply(401, dict(error='账号或密码不正确'))
                return
            if len(self.app.sessions) >= 64:
                self.app.sessions = {k: v for k, v in self.app.sessions.items() if v['expires'] > now}
                if len(self.app.sessions) >= 64:
                    self._reply(429, dict(error='登录会话已满，请稍后'))
                    return
            self.app.failures.pop(ip, None)
            token, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
            self.app.sessions[token] = dict(csrf=csrf, expires=now + 3600, history=[], busy=False)
        cookie = f'examguard_session={token}; Path=/; Max-Age=3600; HttpOnly; SameSite=Strict'
        if self.app.public_origin:
            cookie += '; Secure'
        self._reply(200, dict(ok=True, csrf=csrf), cookie=cookie)
