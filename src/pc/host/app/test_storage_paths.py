"""存储目录回归：实际收包、会话、回放与MCP使用同一根目录。"""
import json
from pathlib import Path
import tempfile
import unittest
from .services import storage_paths, worker_specs, validate_config, save_config, load_config


class StoragePathsTests(unittest.TestCase):
    def test_default_and_relative_paths_preserve_portability(self):
        with tempfile.TemporaryDirectory() as d:
            host = Path(d)
            self.assertEqual(storage_paths({}, host)['evidence'], host.resolve() / 'evidence_out')
            self.assertEqual(storage_paths({'storage_root': '../archive'}, host)['sessions'],
                             (host / '../archive/sessions').resolve())

    def test_chinese_directory_survives_configuration_and_receiver_argv(self):
        with tempfile.TemporaryDirectory() as d:
            host = Path(d)
            root = host / '证据回溯'
            cfg = save_config(host / 'config.json', {'storage_root': str(root)})
            self.assertEqual(load_config(host / 'config.json'), cfg)
            argv = worker_specs(cfg, host / 'stop', host)['images']
            self.assertEqual(Path(argv[argv.index('--out') + 1]), root / 'evidence_out')

    def test_invalid_roots_are_rejected(self):
        for value in ('', '  ', None, 123, 'abc\x00def'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate_config({'storage_root': value})

    def test_dashboard_and_mcp_share_selected_evidence_root(self):
        import tkinter as tk
        from .dashboard import Dashboard
        from .agent_joycode import SelectedSource
        with tempfile.TemporaryDirectory() as d:
            host = Path(d)
            paths = storage_paths({'storage_root': str(host / '证据回溯')}, host)
            app = Dashboard(host='127.0.0.1', port=0, config_path=host / 'regions.json',
                            session_root=paths['sessions'], evidence_root=paths['evidence'])
            try:
                app.withdraw()
                source = app._agent_panel._source()
                self.assertEqual(Path(source.evidence_root), paths['evidence'])
                self.assertEqual(Path(source.session_path).parent, paths['sessions'])
                app._joycode_panel.sync(force=True)
                provider = SelectedSource(app._joycode_panel.publisher.path)
                selected = provider.resolve('get_system_health')
                self.assertEqual(Path(selected.evidence_root), paths['evidence'])
                self.assertEqual(Path(selected.session_path).parent, paths['sessions'])
            finally:
                app._close()
