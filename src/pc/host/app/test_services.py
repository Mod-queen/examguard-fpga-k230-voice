"""One-command launcher lifecycle. No real board port is opened by tests."""
from pathlib import Path
import socket
import json
import subprocess
import sys
import tempfile
import time
import unittest
import runpy
import types
from unittest.mock import patch

from .services import (Services, DEFAULTS, InstanceLock, check_udp_free,
                       exclusive_udp, worker_specs, load_config, save_config)


def wait_until(predicate, seconds=8):
    deadline = time.monotonic()+seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.02)
    raise AssertionError('timed out waiting for child state')


def free_ports():
    sockets = [exclusive_udp(0) for _ in range(3)]
    ports = [s.getsockname()[1] for s in sockets]
    for s in sockets:
        s.close()
    return dict(zip(('status_port', 'downlink_port', 'image_port'), ports))


class ServicesTests(unittest.TestCase):
    def test_image_save_has_separate_graceful_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            host = self.fixture_host(directory)
            script = host/'receive_evidence_udp.py'
            script.write_text(script.read_text() + "time.sleep(.35)\nprint('SAVE_COMPLETE',flush=True)\n", encoding='utf-8')
            services = Services({**DEFAULTS, **free_ports()}, host=host, port_list=lambda: [])
            try:
                services.start()
                wait_until(lambda: 'UDP已监听' in services.status.get('images', ''))
                services.stop(timeout=.05, image_timeout=2.)
                self.assertEqual(services.processes['images'].returncode, 0)
                self.assertIn('SAVE_COMPLETE', (services.log_dir/'images.log').read_text(encoding='utf-8'))
            finally:
                if not services.closing:
                    services.stop()

    def test_absolute_command_paths_no_cwd_and_config_validation(self):
        with tempfile.TemporaryDirectory(prefix='examguard space ') as d:
            path = Path(d)/'launch.json'
            config = load_config(path)
            self.assertEqual(config, DEFAULTS)
            save_config(path, {**config, 'fpga_port': 'com9'})
            self.assertEqual(load_config(path)['fpga_port'], 'COM9')
            with self.assertRaises(ValueError):
                save_config(path, {**config, 'k230_port': config['fpga_port']})
            specs = worker_specs(config, Path(d)/'stop.request', Path(d))
            self.assertEqual(specs['fpga'][0], sys.executable)
            self.assertIn('--downlink-port', specs['fpga'])
            self.assertIn('--start', specs['k230'])
            self.assertIn('--recognition-only', specs['k230'])
            self.assertNotIn('--out', specs['k230'])
            for command in specs.values():
                self.assertTrue(Path(command[2]).is_absolute())
                self.assertIn('--stop-file', command)
                self.assertNotIn('deploy.py', ' '.join(command))

    def test_instance_and_udp_exclusive_release_without_stale_lock(self):
        lock = InstanceLock(0)
        port = lock.socket.getsockname()[1]
        try:
            with self.assertRaises(OSError):
                InstanceLock(port)
        finally:
            lock.close()
        new = InstanceLock(port)
        new.close()
        with exclusive_udp(0) as bound:
            with self.assertRaises(OSError):
                check_udp_free(bound.getsockname()[1])

    def fixture_host(self, directory):
        host = Path(directory)
        common = """import argparse,time
from pathlib import Path
p=argparse.ArgumentParser(); p.add_argument('--stop-file',type=Path); a,_=p.parse_known_args()
print(READY,flush=True)
while not a.stop_file.exists(): time.sleep(.02)
print('GRACEFUL_STOP',flush=True)
"""
        for name, ready in [('capture_uart.py', 'Listening on COM_TEST'),
                            ('capture_k230_evidence.py', 'K230 evidence SD /fake'),
                            ('receive_evidence_udp.py', 'listening for image evidence')]:
            (host/name).write_text('READY='+repr(ready)+'\n'+common, encoding='utf-8')
        return host

    def test_three_owned_children_ready_logs_duplicate_and_graceful_stop(self):
        with tempfile.TemporaryDirectory() as d:
            host = self.fixture_host(d)
            config = {**DEFAULTS, **free_ports()}
            services = Services(config, host=host, port_list=lambda: ['COM5', 'COM12'])
            try:
                services.start()
                wait_until(lambda: all('启动中' not in services.status.get(n, '启动中')
                                      for n in ('fpga', 'images', 'k230')))
                old = {n: p.pid for n,p in services.processes.items()}
                services.start_missing()
                self.assertEqual({n:p.pid for n,p in services.processes.items()}, old)
                with self.assertRaises(RuntimeError):
                    services.start()
                self.assertIn('串口已打开', services.status['fpga'])
                self.assertIn('等待源图', services.status['k230'])
            finally:
                services.stop()
            self.assertTrue(all(p.poll() == 0 for p in services.processes.values()))
            for name in services.processes:
                self.assertIn('GRACEFUL_STOP', (services.log_dir/(name+'.log')).read_text(encoding='utf-8'))

    def test_missing_device_manual_start_and_busy_udp_not_stolen(self):
        with tempfile.TemporaryDirectory() as d:
            host = self.fixture_host(d)
            devices = []
            with exclusive_udp(0) as occupied:
                config = {**DEFAULTS, **free_ports(), 'image_port': occupied.getsockname()[1]}
                services = Services(config, host=host, port_list=lambda: devices)
                try:
                    services.start()
                    self.assertIn('未连接', services.status['fpga'])
                    self.assertIn('启动失败', services.status['images'])
                    self.assertEqual(services.processes, {})
                    devices.append('COM12')
                    services.start_missing()
                    wait_until(lambda: '等待源图' in services.status['k230'])
                    self.assertNotIn('fpga', services.processes)
                finally:
                    services.stop()

    def test_restored_k230_frames_ready_without_evidence_and_fault_not_cleared(self):
        traces = [
            (['K230 source evidence receiver: /fake', 'health verified=0 errors=0 active=-'], '启动中'),
            (['frame=0 FACE+PHONE sent=1 $20,14,0,0,0,0,none#',
              'frame=1 PHONE sent=1 $20,14,0,0,0,0,none#'], '识别程序运行中'),
            (['K230 evidence INIT ERROR: SD failed',
              'frame=1 PHONE sent=1 $20,14,0,0,0,0,none#'], '异常'),
            (['K230 evidence SD /fake',
              'frame=1 PHONE sent=1 $20,14,0,0,0,0,none#'], '等待源图'),
        ]
        for lines, expected in traces:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as d:
                host = self.fixture_host(d)
                (host/'capture_k230_evidence.py').write_text(
                    'import argparse,time\nfrom pathlib import Path\n'
                    'p=argparse.ArgumentParser(); p.add_argument("--stop-file",type=Path); a,_=p.parse_known_args()\n'
                    + ''.join('print('+repr(line)+',flush=True)\n' for line in lines)
                    + 'print("TRACE_DONE",flush=True)\n'
                    + 'while not a.stop_file.exists(): time.sleep(.02)\n', encoding='utf-8')
                services = Services({**DEFAULTS, **free_ports()}, host=host, port_list=lambda:['COM12'])
                try:
                    services.start()
                    wait_until(lambda: (services.log_dir/'k230.log').exists() and
                               'TRACE_DONE' in (services.log_dir/'k230.log').read_text(encoding='utf-8'))
                    self.assertIn(expected, services.status['k230'])
                finally:
                    services.stop()

    def test_k230_health_states_surface_distinct_recoverable_messages(self):
        traces = [
            ('K230 recognition health state=running frames=12 last_cycle=11 age_s=0.1 '
             'invalid=0 nonadvancing=0', '识别程序运行中'),
            ('K230 recognition health state=startup_timeout frames=0 last_cycle=None age_s=31.0 '
             'invalid=0 nonadvancing=0', '启动超时'),
            ('K230 recognition health state=stale frames=40 last_cycle=39 age_s=7.5 '
             'invalid=0 nonadvancing=0', '识别帧停更'),
        ]
        for line, expected in traces:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as d:
                host = self.fixture_host(d)
                (host/'capture_k230_evidence.py').write_text(
                    'import argparse,time\nfrom pathlib import Path\n'
                    'p=argparse.ArgumentParser(); p.add_argument("--stop-file",type=Path); a,_=p.parse_known_args()\n'
                    'print(' + repr(line) + ',flush=True)\n'
                    'print("TRACE_DONE",flush=True)\n'
                    'while not a.stop_file.exists(): time.sleep(.02)\n', encoding='utf-8')
                services = Services({**DEFAULTS, **free_ports()}, host=host, port_list=lambda:['COM12'])
                try:
                    services.start()
                    wait_until(lambda: (services.log_dir/'k230.log').exists() and
                               'TRACE_DONE' in (services.log_dir/'k230.log').read_text(encoding='utf-8'))
                    self.assertIn(expected, services.status['k230'])
                finally:
                    services.stop()

    def test_receiver_emits_liveness_line_for_services_without_hardware(self):
        import contextlib
        import io
        host = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as d:
            stop = Path(d)/'stop.request'

            class FakeConnection:
                def __init__(self):
                    self.lines = [
                        b'K230 resetting interpreter before camera/model startup\r\n',
                        b'frame=0 FACE+PHONE sent=1 $20,14,0,0,0,0,none#\r\n',
                        b'frame=1 PHONE sent=1 $20,14,0,0,0,0,none#\r\n',
                    ]
                    self.writes = []

                def read(self, _size):
                    if self.lines:
                        return self.lines.pop(0)
                    stop.touch()
                    return b''

                def write(self, data):
                    self.writes.append(data)

                def close(self):
                    pass

            connection = FakeConnection()
            repl = types.SimpleNamespace(s=connection, soft_reset=lambda: None,
                                         stop_program=lambda: None)
            capture = io.StringIO()
            with patch.dict(sys.modules, {'repl_client': types.SimpleNamespace(Repl=lambda port: repl)}), \
                 patch.object(sys, 'argv', ['capture_k230_evidence.py', '--port', 'FAKE', '--start',
                     '--out', d, '--stop-file', str(stop), '--stale-timeout', '5']), \
                 contextlib.redirect_stdout(capture):
                self.assertEqual(runpy.run_path(str(host/'capture_k230_evidence.py'),
                                                run_name='test_k230_worker')['main'](), 0)
            text = capture.getvalue()
            self.assertIn('K230 recognition health state=running', text)
            self.assertIn('K230 stopped; REPL prompt confirmed', text)
            self.assertIn(b'import main', b''.join(connection.writes))

    def test_actual_image_receiver_stop_file_and_exclusive_port(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)
            stop = directory/'stop.request'
            port = free_ports()['image_port']
            command = [sys.executable, '-u', str(Path(__file__).resolve().parents[1]/'receive_evidence_udp.py'),
                       '--port', str(port), '--out', str(directory/'evidence'), '--stop-file', str(stop)]
            log = (directory/'receiver.log').open('w', encoding='utf-8')
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            try:
                wait_until(lambda: 'listening for image evidence' in (directory/'receiver.log').read_text(encoding='utf-8'))
                with self.assertRaises(OSError):
                    check_udp_free(port)
                # A partial camera window already received must flush on close,
                # not be silently discarded by the new unified stop path.
                from .test_host import _image_chunk
                sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    sender.sendto(_image_chunk(event_seq=5, frame_index=0, frame_id=1,
                        pixel_offset=0, payload=b'ab'), ('127.0.0.1', port))
                finally:
                    sender.close()
                time.sleep(.15)
                stop.touch()
                self.assertEqual(process.wait(timeout=5), 0)
                check_udp_free(port)
                manifests = list((directory/'evidence').glob('*/manifest.json'))
                self.assertEqual(len(manifests), 1)
                saved = json.loads(manifests[0].read_text(encoding='utf-8'))
                self.assertFalse(saved['complete'])
                self.assertEqual(saved['missing_indices'], [1])
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)
                log.close()

    def test_failure_is_visible_and_stop_only_owns_children(self):
        with tempfile.TemporaryDirectory() as d:
            host = self.fixture_host(d)
            (host/'capture_k230_evidence.py').write_text(
                "print('K230 evidence INIT ERROR: SD failed',flush=True)\nraise SystemExit(2)\n")
            services = Services({**DEFAULTS, **free_ports()}, host=host, port_list=lambda:['COM12'])
            try:
                services.start()
                wait_until(lambda: '进程已退出' in services.status.get('k230',''))
                events = []
                while not services.events.empty():
                    events.append(services.events.get_nowait())
                self.assertTrue(any('异常' in e[2] for e in events if e[0]=='status'))
                self.assertTrue(any('INIT ERROR' in e[2] for e in events if e[0]=='log'))
            finally:
                services.stop()

    def test_dashboard_closes_owned_workers_and_persists_event(self):
        from .dashboard import Dashboard
        from .event_store import load_session
        from .protocol import EventPacket
        with tempfile.TemporaryDirectory() as d:
            host = self.fixture_host(d)
            config = {**DEFAULTS, **free_ports()}
            services = Services(config, host=host, port_list=lambda:['COM5','COM12'])
            with patch('app.dashboard.receive_packets', return_value=iter(())):
                app = Dashboard(host='127.0.0.1', port=config['status_port'],
                    config_path=host/'regions.json', session_root=host/'sessions',
                    services=services, launch_config_path=host/'launch.json')
            app.withdraw()
            try:
                services.start()
                wait_until(lambda: '等待源图' in services.status.get('k230',''))
                app._service_panel.poll()
                self.assertIn('等待源图', app._service_panel.values['k230'][1].get())
                self.assertEqual(app._tabs.tab(app._tabs.select(), 'text'), '实时事件')
                app._packet_queue.put(EventPacket(2, 42, 3, 0, 3, 0x50))
                archive = app._model.snapshot().session_path
                app._service_panel.ports['fpga_port'].set('COM9')
                with patch('app.service_panel.messagebox.showinfo'):
                    app._service_panel.save()
                self.assertEqual(load_config(host/'launch.json')['fpga_port'], 'COM9')
            finally:
                app._close()
            self.assertEqual(len(load_session(archive).events), 1)
            self.assertTrue(all(p.poll() == 0 for p in services.processes.values()))

    def test_unresponsive_owned_child_is_terminated_after_graceful_deadline(self):
        with tempfile.TemporaryDirectory() as d:
            host = self.fixture_host(d)
            (host/'capture_k230_evidence.py').write_text(
                "import time\nprint('K230 evidence SD /fake',flush=True)\ntime.sleep(30)\n")
            services = Services({**DEFAULTS, **free_ports()}, host=host, port_list=lambda:['COM12'])
            try:
                services.start()
                wait_until(lambda: '等待源图' in services.status.get('k230',''))
            finally:
                services.stop(timeout=.2)
            self.assertIsNotNone(services.processes['k230'].poll())
            self.assertIsNotNone(services.processes['images'].poll())

    def test_actual_serial_workers_observe_stop_and_release_owned_port(self):
        from unittest.mock import MagicMock
        with tempfile.TemporaryDirectory() as d:
            stop = Path(d)/'stop.request'
            stop.touch()
            host = Path(__file__).resolve().parents[1]
            # These run the real entry functions with fake serial handles;
            # no real COM12 is interrupted during local verification.
            connection = MagicMock()
            repl = MagicMock(s=connection)
            fake_module = types.SimpleNamespace(Repl=lambda port: repl)
            with patch.dict(sys.modules, {'repl_client': fake_module}), \
                 patch.object(sys, 'argv', ['capture_k230_evidence.py', '--port', 'FAKE', '--start',
                     '--out', str(Path(d)/'k230'), '--stop-file', str(stop)]):
                namespace = runpy.run_path(str(host/'capture_k230_evidence.py'), run_name='test_k230_worker')
                self.assertEqual(namespace['main'](), 0)
            repl.soft_reset.assert_called_once()
            repl.stop_program.assert_called_once()
            connection.close.assert_called_once()
            serial = MagicMock()
            with patch('serial.Serial', return_value=serial), \
                 patch.object(sys, 'argv', ['capture_uart.py', 'FAKE', '--stop-file', str(stop)]):
                namespace = runpy.run_path(str(host/'capture_uart.py'), run_name='test_fpga_worker')
                self.assertEqual(namespace['main'](), 0)
            serial.__exit__.assert_called_once()

    def test_recognition_only_keeps_start_stop_and_does_not_create_evidence(self):
        from unittest.mock import MagicMock
        with tempfile.TemporaryDirectory() as d:
            stop = Path(d)/'stop.request'
            stop.touch()
            host = Path(__file__).resolve().parents[1]
            output = Path(d)/'must_not_exist'
            connection = MagicMock()
            repl = MagicMock(s=connection)
            with patch.dict(sys.modules, {'repl_client': types.SimpleNamespace(Repl=lambda port: repl)}), \
                 patch.object(sys, 'argv', ['capture_k230_evidence.py', '--port', 'FAKE', '--start',
                      '--recognition-only', '--out', str(output), '--stop-file', str(stop)]):
                namespace = runpy.run_path(str(host/'capture_k230_evidence.py'), run_name='test_recognition_only')
                with patch.dict(namespace['main'].__globals__, {'UsbEvidenceDecoder': MagicMock(side_effect=AssertionError('evidence enabled'))}):
                    self.assertEqual(namespace['main'](), 0)
            self.assertFalse(output.exists())
            repl.soft_reset.assert_called_once()
            repl.stop_program.assert_called_once()
            connection.close.assert_called_once()

    def test_k230_reset_failure_closes_port_without_starting_models(self):
        from unittest.mock import MagicMock
        host = Path(__file__).resolve().parents[1]
        repl = MagicMock()
        repl.soft_reset.side_effect = RuntimeError('reset handshake missing')
        with patch.dict(sys.modules, {'repl_client': types.SimpleNamespace(Repl=lambda port: repl)}), \
             patch.object(sys, 'argv', ['capture_k230_evidence.py', '--port', 'FAKE', '--start']):
            namespace = runpy.run_path(str(host/'capture_k230_evidence.py'), run_name='test_k230_worker')
            with self.assertRaisesRegex(RuntimeError, 'reset handshake missing'):
                namespace['main']()
        repl.s.write.assert_not_called()
        repl.s.close.assert_called_once()

    def test_k230_usb_read_failure_not_masked_by_stop_write_failure(self):
        from unittest.mock import MagicMock
        import serial
        host = Path(__file__).resolve().parents[1]
        repl = MagicMock()
        repl.s.read.side_effect = serial.SerialException('device disconnected')
        repl.stop_program.side_effect = serial.SerialException('cannot interrupt disconnected device')
        with tempfile.TemporaryDirectory() as d, \
             patch.dict(sys.modules, {'repl_client': types.SimpleNamespace(Repl=lambda port: repl)}), \
             patch.object(sys, 'argv', ['capture_k230_evidence.py', '--port', 'FAKE', '--start', '--out', d]):
            namespace = runpy.run_path(str(host/'capture_k230_evidence.py'), run_name='test_k230_worker')
            self.assertEqual(namespace['main'](), 1)
        repl.stop_program.assert_called_once()
        repl.s.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
