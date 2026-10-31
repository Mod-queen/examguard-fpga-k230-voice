"""Opt-in live entry boot suppression, coalesced raw response and legacy isolation."""
from pathlib import Path
from unittest.mock import Mock
import unittest
from .k230_startup import start_live290, PREPARE, START, LIVE_ROOT, SCENE_ROOT, BOOK_ROOT
from .services import worker_specs, validate_config, DEFAULTS


class LiveStartupTests(unittest.TestCase):
    def test_coalesced_raw_eot_then_exactly_one_confirmed_start(self):
        link=Mock()
        link.read.side_effect=[b'OKLIVE290_PC_START_ARMED\r\n\x04\x04>']
        repl=Mock(s=link)
        repl.soft_reset.return_value=b'MPY: soft reboot\r\nEXAMGUARD_LIVE_PC_BOOT_SKIPPED\r\nraw REPL; CTRL-B to exit\r\n>'
        start_live290(repl)
        self.assertEqual([c.args[0] for c in link.write.call_args_list],[PREPARE.encode('ascii')+b'\x04',START])
        repl.soft_reset.assert_called_once()

    def test_rejected_installation_or_wrong_boot_never_launches(self):
        for response,banner in ((b'OK\x04Traceback: missing entry\x04>',b''),
                                (b'OKLIVE290_PC_START_ARMED\x04\x04>',b'raw REPL; CTRL-B to exit\r\n>')):
            link=Mock();link.read.return_value=response
            repl=Mock(s=link);repl.soft_reset.return_value=banner
            with self.assertRaises(RuntimeError):start_live290(repl)
            self.assertEqual(link.write.call_count,1)

    def test_runtime_selection_is_explicit_and_roundtrips(self):
        self.assertNotIn('--live290',worker_specs(DEFAULTS,Path('stop'))['k230'])
        chosen=validate_config({**DEFAULTS,'k230_runtime':'live290_act16'})
        self.assertIn('--live290',worker_specs(chosen,Path('stop'))['k230'])
        with self.assertRaises(ValueError):validate_config({**DEFAULTS,'k230_runtime':'typo'})

    def test_scene_runtime_binds_marker_and_start_to_the_same_installed_root(self):
        link=Mock()
        link.read.return_value=b'OKLIVE290_PC_START_ARMED\r\n\x04\x04>'
        repl=Mock(s=link)
        repl.soft_reset.return_value=b'MPY: soft reboot\r\nEXAMGUARD_LIVE_PC_BOOT_SKIPPED\r\n>'
        start_live290(repl,runtime_root=SCENE_ROOT)
        payloads=[c.args[0] for c in link.write.call_args_list]
        self.assertEqual(len(payloads),2)
        for payload in payloads:
            self.assertIn(SCENE_ROOT.encode('ascii'),payload)
            self.assertNotIn(LIVE_ROOT.encode('ascii'),payload)
        chosen=validate_config({**DEFAULTS,'k230_runtime':'scene_guard_20261030'})
        command=worker_specs(chosen,Path('stop'))['k230']
        self.assertIn('--scene-guard',command)
        self.assertNotIn('--live290',command)

    def test_unknown_root_rejected_before_serial_write(self):
        repl=Mock()
        with self.assertRaises(ValueError):
            start_live290(repl,runtime_root='/sdcard/unreviewed')
        repl.s.write.assert_not_called()
        repl.soft_reset.assert_not_called()

    def test_book_assist_has_one_matching_marker_start_and_worker_selection(self):
        link=Mock();link.read.return_value=b'OKLIVE290_PC_START_ARMED\x04\x04>'
        repl=Mock(s=link)
        repl.soft_reset.return_value=b'MPY: soft reboot\nEXAMGUARD_LIVE_PC_BOOT_SKIPPED\n>'
        start_live290(repl,runtime_root=BOOK_ROOT)
        self.assertEqual(link.write.call_count,2)
        for call in link.write.call_args_list:
            self.assertIn(BOOK_ROOT.encode('ascii'),call.args[0])
            self.assertNotIn(SCENE_ROOT.encode('ascii'),call.args[0])
        command=worker_specs(validate_config({**DEFAULTS,'k230_runtime':'book_assist_20261030'}),Path('stop'))['k230']
        self.assertIn('--book-assist',command)
        self.assertNotIn('--scene-guard',command)
        repl.soft_reset.assert_called_once()


if __name__=='__main__':unittest.main()
