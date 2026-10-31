"""Real receiver entry: running-board attach must never enter REPL or stop it."""
import contextlib
import io
from pathlib import Path
import runpy
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


class AttachTests(unittest.TestCase):
    def test_one_command_service_requests_attach_and_stop_before_probe_does_not_start(self):
        from .services import worker_specs, DEFAULTS
        command=worker_specs(DEFAULTS,Path('stop.request'))['k230']
        self.assertIn('--attach-if-running',command)
        with tempfile.TemporaryDirectory() as d:
            stop=Path(d)/'stop.request';stop.touch()
            link=Mock()
            with patch('serial.Serial',return_value=link),patch.object(sys,'argv',[
                    'capture_k230_evidence.py','--port','FAKE','--start','--attach-if-running',
                    '--recognition-only','--stop-file',str(stop)]):
                namespace=runpy.run_path(str(Path(__file__).resolve().parents[1]/'capture_k230_evidence.py'),run_name='test_attach')
                self.assertEqual(namespace['main'](),0)
            link.read.assert_not_called();link.write.assert_not_called();link.close.assert_called_once()

    def test_existing_valid_advancing_stream_attaches_without_any_program_write(self):
        with tempfile.TemporaryDirectory() as d:
            stop=Path(d)/'stop.request'
            class Link:
                dtr=True
                def __init__(self):self.writes=[];self.closed=False;self.reads=0
                def read(self,size):
                    self.reads+=1
                    if self.reads==1:
                        return (b'frame=35 PHONE sent=1 $20,14,0,0,0,0,none#\r\n'
                                b'frame=36 FACE+PHONE sent=1 $20,14,0,0,0,0,none#\r\n')
                    stop.touch();return b''
                def write(self,data):self.writes.append(data)
                def close(self):self.closed=True
            link=Link();repl=Mock(side_effect=AssertionError('must not interrupt live board'))
            output=io.StringIO()
            with patch('serial.Serial',return_value=link),patch.dict(sys.modules,{'repl_client':types.SimpleNamespace(Repl=repl)}),patch.object(
                    sys,'argv',['capture_k230_evidence.py','--port','FAKE','--start','--attach-if-running',
                                '--recognition-only','--stop-file',str(stop)]),contextlib.redirect_stdout(output):
                namespace=runpy.run_path(str(Path(__file__).resolve().parents[1]/'capture_k230_evidence.py'),run_name='test_attach')
                self.assertEqual(namespace['main'](),0)
            self.assertIn('attached to existing recognition',output.getvalue())
            self.assertIn('state=running',output.getvalue())
            self.assertIn('running board left untouched',output.getvalue())
            self.assertEqual(link.writes,[]);self.assertTrue(link.closed);repl.assert_not_called()

    def test_duplicate_counter_is_not_running_and_original_start_error_is_preserved(self):
        class Link:
            def read(self,size):
                return b'frame=35 PHONE sent=1 $20,14,0,0,0,0,none#\n'*2
            def close(self):self.closed=True
        link=Link();link.closed=False
        repl=Mock();repl.s=Mock();repl.soft_reset.side_effect=RuntimeError('reset handshake missing')
        now=[0]
        def clock():now[0]+=.5;return now[0]
        with patch('serial.Serial',return_value=link),patch.dict(sys.modules,{'repl_client':types.SimpleNamespace(Repl=lambda port:repl)}),patch.object(
                sys,'argv',['capture_k230_evidence.py','--port','FAKE','--start','--attach-if-running','--recognition-only']),patch(
                'time.monotonic',side_effect=clock):
            namespace=runpy.run_path(str(Path(__file__).resolve().parents[1]/'capture_k230_evidence.py'),run_name='test_attach')
            with self.assertRaisesRegex(RuntimeError,'reset handshake missing'):namespace['main']()
        self.assertTrue(link.closed);repl.soft_reset.assert_called_once();repl.s.write.assert_not_called()

    def test_probe_failure_closes_handle_and_does_not_interrupt(self):
        import serial
        link=Mock();link.read.side_effect=serial.SerialException('USB read failed')
        with patch('serial.Serial',return_value=link),patch.object(sys,'argv',[
                'capture_k230_evidence.py','--port','FAKE','--start','--attach-if-running','--recognition-only']):
            namespace=runpy.run_path(str(Path(__file__).resolve().parents[1]/'capture_k230_evidence.py'),run_name='test_attach')
            with self.assertRaisesRegex(serial.SerialException,'USB read failed'):namespace['main']()
        link.close.assert_called_once();link.write.assert_not_called()
