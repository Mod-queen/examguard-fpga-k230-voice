"""Owned subprocess lifecycle for the one-command console; no board deployment."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

from .k230_runtime import health_state

HOST = Path(__file__).resolve().parents[1]
DEFAULTS = {'fpga_port': 'COM5', 'k230_port': 'COM12',
            'status_port': 5005, 'downlink_port': 5006, 'image_port': 6102,
            'k230_runtime': 'legacy'}


def validate_config(config):
    result = {**DEFAULTS, **config}
    for key in ('fpga_port', 'k230_port'):
        value = result[key]
        if not isinstance(value, str) or not value.strip():
            raise ValueError(key + ' must be a nonempty serial port')
        result[key] = value.strip().upper()
    if result['fpga_port'] == result['k230_port']:
        raise ValueError('FPGA与K230不能使用同一个串口')
    if result['k230_runtime'] not in ('legacy', 'live290_act16', 'scene_guard_20261030', 'book_assist_20261030'):
        raise ValueError('Unknown K230 runtime entry')
    ports = [result[key] for key in ('status_port', 'downlink_port', 'image_port')]
    if any(type(p) is not int or not 1 <= p <= 65535 for p in ports) or len(set(ports)) != 3:
        raise ValueError('UDP端口须为1–65535且互不相同')
    return result


def load_config(path):
    path = Path(path)
    return validate_config(json.loads(path.read_text(encoding='utf-8')) if path.exists() else {})


def save_config(path, config):
    path = Path(path)
    result = validate_config(config)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    temporary.replace(path)
    return result


def exclusive_udp(port, address='0.0.0.0'):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        sock.bind((address, port))
        return sock
    except BaseException:
        sock.close()
        raise


def check_udp_free(port):
    with exclusive_udp(port):
        pass


class InstanceLock:
    """OS-owned local lock, automatically released after exit/crash; no stale PID."""
    def __init__(self, port=56197):
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            if hasattr(socket, 'SO_EXCLUSIVEADDRUSE'):
                self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            self.socket.bind(('127.0.0.1', port))
            self.socket.listen(1)
        except BaseException:
            self.socket.close()
            raise

    def close(self):
        self.socket.close()


def worker_specs(config, stop_file, host=HOST):
    py = [sys.executable, '-u']
    common = ['--stop-file', str(stop_file)]
    return {
        'fpga': py + [str(host/'capture_uart.py'), config['fpga_port'],
                      '--forward-host', '127.0.0.1', '--forward-port', str(config['status_port']),
                      '--downlink-port', str(config['downlink_port'])] + common,
        'images': py + [str(host/'receive_evidence_udp.py'), '--port', str(config['image_port']),
                        '--out', str(host/'evidence_out')] + common,
        'k230': py + [str(host/'capture_k230_evidence.py'), '--port', config['k230_port'], '--start',
                         '--recognition-only', '--attach-if-running'] +
                         ({'live290_act16': ['--live290'], 'scene_guard_20261030': ['--scene-guard'],
                           'book_assist_20261030': ['--book-assist']}.get(
                             config.get('k230_runtime'), [])) + common,
    }


class Services:
    def __init__(self, config, *, host=HOST, port_list=None):
        self.config = validate_config(config)
        self.host = Path(host)
        self.events = queue.Queue()
        self.processes = {}
        self.threads = {}
        self.status = {}
        self.closing = False
        self.stop_file = None
        self.log_dir = None
        self.port_list = port_list

    def _ports(self):
        if self.port_list is not None:
            return {p.upper() for p in self.port_list()}
        from serial.tools.list_ports import comports
        return {p.device.upper() for p in comports()}

    def _status(self, name, state):
        self.status[name] = state
        self.events.put(('status', name, state))

    def start(self):
        if self.closing or any(p.poll() is None for p in self.processes.values()):
            raise RuntimeError('采集服务仍在运行，请勿重复启动')
        # A fresh file token per owned launch. Workers observe its existence.
        log_root = self.host/'logs'
        log_root.mkdir(exist_ok=True)
        self.log_dir = Path(tempfile.mkdtemp(prefix=time.strftime('launch_%Y%m%d_%H%M%S_'), dir=log_root))
        self.stop_file = self.log_dir/'stop.request'
        specs = worker_specs(self.config, self.stop_file, self.host)
        ports = self._ports()
        for name, command in specs.items():
            if name in ('fpga', 'k230'):
                port = self.config['fpga_port' if name == 'fpga' else 'k230_port']
                if port not in ports:
                    self._status(name, f'未连接：{port}（接好后点“启动缺失服务”）')
                    continue
            self._spawn(name, command)

    def start_missing(self):
        if self.closing or self.stop_file is None:
            return
        ports = self._ports()
        for name, command in worker_specs(self.config, self.stop_file, self.host).items():
            if name in self.processes and self.processes[name].poll() is None:
                continue
            if name in ('fpga', 'k230'):
                port = self.config['fpga_port' if name == 'fpga' else 'k230_port']
                if port not in ports:
                    self._status(name, f'未连接：{port}')
                    continue
            old_thread = self.threads.get(name)
            if old_thread is not None and old_thread.is_alive():
                continue
            self._spawn(name, command)

    def _spawn(self, name, command):
        try:
            # Probe network resources before launching, actual bind in workers
            # remains exclusive so a later race fails visibly instead of stealing.
            if name in ('fpga', 'images'):
                check_udp_free(self.config['downlink_port' if name == 'fpga' else 'image_port'])
            environment = {**os.environ, 'PYTHONIOENCODING': 'utf-8', 'PYTHONUNBUFFERED': '1'}
            process = subprocess.Popen(command, cwd=self.host, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, env=environment,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            self.processes[name] = process
            self._status(name, '启动中（尚未确认硬件数据）')
            thread = threading.Thread(target=self._read, args=(name, process), daemon=True)
            self.threads[name] = thread
            thread.start()
        except (OSError, ValueError) as exc:
            self._status(name, '启动失败：'+str(exc))

    def _read(self, name, process):
        readiness = {'fpga': 'Listening on ', 'images': 'listening for image evidence',
                     'k230': 'K230 evidence SD '}
        fault = False
        k230_running = False
        k230_evidence = False
        try:
            with (self.log_dir/(name+'.log')).open('a', encoding='utf-8') as log:
                for raw in iter(process.stdout.readline, b''):
                    line = raw.decode('utf-8', 'replace').strip()
                    log.write(line+'\n')
                    log.flush()
                    # Show useful milestones; retain full frame stream on disk.
                    if not line.startswith(('frame=', 'obj ', 'purple ', 'blue ', 'raw ', 'gaze ',
                                            'OK ', 'StatusPacket(', 'EventPacket(', 'EvidencePacket(')):
                        self.events.put(('log', name, line))
                    if readiness[name] in line and not fault:
                        if name == 'k230':
                            k230_evidence = True
                        self._status(name, {'fpga': '串口已打开，等待ST/AL数据',
                                            'images': 'UDP已监听，等待图像（需千兆链路）',
                                            'k230': '取证SD已初始化，等待源图'}[name])
                    if ('ERROR' in line or 'Traceback' in line or 'Serial error:' in line or
                            'transfer rejected' in line or 'err=' in line and not line.endswith('err=-')):
                        fault = True
                        self._status(name, '异常：'+line[:180])
                    if name == 'fpga' and line.startswith('OK ') and not fault:
                        self._status(name, '已收到有效ST/AL/证据元数据')
                    if name == 'images' and line.startswith('wrote ') and not fault:
                        self._status(name, line[:180])
                    if name == 'k230' and line.startswith('VERIFIED ') and not fault:
                        k230_evidence = True
                        self._status(name, '源图已完整接收校验：'+line.split('VERIFIED ', 1)[1])
                    if name == 'k230' and not fault:
                        state = health_state(line)
                        if state == 'startup_timeout':
                            self._status(name, 'K230启动超时：设定时间内未收到识别帧，检查供电/USB/程序')
                        elif state == 'stale':
                            self._status(name, 'K230识别帧停更：长时间无新帧，可能USB断开或程序卡住')
                        elif state == 'running' and not k230_running:
                            k230_running = True
                            if not k230_evidence:
                                self._status(name, '识别程序运行中，已收到识别帧（含none状态）')
                        elif (state is None and not k230_running and
                                re.fullmatch(r'frame=\d+ [A-Z+]+ sent=[1-9]\d* \$[^\r\n]+#', line)):
                            k230_running = True
                            if not k230_evidence:
                                self._status(name, '识别程序运行中，已收到识别帧（含none状态）')
        except OSError as exc:
            self.events.put(('log', name, '日志读取失败：'+str(exc)))
        finally:
            process.stdout.close()
            code = process.wait()
            self._status(name, ('已停止' if self.closing else f'进程已退出，代码{code}；请查看日志'))

    def stop(self, timeout=3.0, image_timeout=15.0):
        self.closing = True
        if self.stop_file is not None:
            self.stop_file.touch()
        started = time.monotonic()
        for name, process in self.processes.items():
            try:
                deadline = started + (image_timeout if name == 'images' else timeout)
                process.wait(timeout=max(0, deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                # Only children created by this instance; never kill old tools.
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
                detail = ('图像保存未确认完成；仅已发布revision可恢复，内存中的新片段可能丢失'
                          if name == 'images' else '本次未收完K230源图可从SD补导入' if name == 'k230' else '未确认正常退出')
                self.events.put(('log', name, '退出超时，已终止本实例子进程；'+detail))
        for thread in self.threads.values():
            thread.join(timeout=1)
