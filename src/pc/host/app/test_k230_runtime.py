"""Read-only K230 console telemetry: parser, liveness, baseline quantiles."""
from pathlib import Path
import unittest

from .k230_runtime import (RecognitionHealth, RuntimeSummary, Samples,
                           health_state, recognition_frame)

OBJECT_NONE = 'frame=0 FACE+PHONE sent=1 $20,14,0,0,0,0,none#'
OBJECT_PHONE = 'frame=1 PHONE sent=1 $25,14,10,20,30,40,phone#'
GAZE = 'frame=2 FACE sent=1 $23,07,100,200,150,200#'
FACE = 'frame=3 FACE sent=1 $28,08,10,20,30,40,Alice,98#'
PERF = 'perf PHONE fetch=1ms infer=65ms loop=74ms free=3800032'


class FrameParserTests(unittest.TestCase):
    def test_accepts_object_gaze_face_echoes(self):
        self.assertEqual(recognition_frame(OBJECT_NONE)['object'], 'none')
        self.assertEqual(recognition_frame(OBJECT_PHONE)['algorithm'], 14)
        self.assertEqual(recognition_frame(GAZE)['algorithm'], 7)
        self.assertEqual(recognition_frame(FACE)['mode'], 'FACE')

    def test_rejects_wrong_length_bad_algorithm_and_free_text(self):
        self.assertIsNone(recognition_frame('frame=0 FACE sent=1 $99,14,0,0,0,0,none#'))
        self.assertIsNone(recognition_frame('frame=0 FACE sent=1 $20,99,0,0,0,0,none#'))
        self.assertIsNone(recognition_frame('frame=0 FACE sent=1 $20,14,0,0,0,0,phone#'))
        self.assertIsNone(recognition_frame(OBJECT_NONE + ' trailing'))
        self.assertIsNone(recognition_frame(PERF))
        self.assertIsNone(recognition_frame('OK      ST,0000000420,1,0,0,0000007000,000,009,012,000'))


class RecognitionHealthTests(unittest.TestCase):
    def test_startup_timeout_then_running_on_advancing_counter(self):
        health = RecognitionHealth(0.0, startup_timeout=30.0, stale_timeout=5.0)
        self.assertEqual(health.snapshot(10.0)[0]['state'], 'starting')
        self.assertEqual(health.snapshot(30.0)[0]['state'], 'startup_timeout')
        self.assertTrue(health.feed(OBJECT_NONE, 31.0))
        self.assertEqual(health.snapshot(31.0)[0]['state'], 'running')
        self.assertEqual(health.snapshot(31.0)[0]['frames'], 1)

    def test_stale_then_recovers_and_nonadvancing_cycle_ignored(self):
        health = RecognitionHealth(0.0)
        health.feed(OBJECT_NONE, 1.0)
        self.assertEqual(health.snapshot(6.1)[0]['state'], 'stale')
        self.assertFalse(health.feed(OBJECT_NONE, 6.2))  # same cycle counter
        self.assertEqual(health.snapshot(6.2)[0]['state'], 'stale')
        self.assertTrue(health.feed(OBJECT_PHONE, 6.3))
        self.assertEqual(health.snapshot(6.3)[0]['state'], 'running')

    def test_health_line_is_self_describing_and_reparseable(self):
        health = RecognitionHealth(0.0)
        health.feed(GAZE, 1.0)
        snapshot, changed = health.snapshot(1.0)
        line = health.line(snapshot)
        self.assertTrue(changed)
        self.assertEqual(health_state(line), 'running')
        self.assertIsNone(health_state('frame=1 PHONE sent=1 ' + OBJECT_NONE.split(' ', 3)[3]))

    def test_rejects_nonpositive_timeouts(self):
        with self.assertRaises(ValueError):
            RecognitionHealth(0.0, startup_timeout=0)
        with self.assertRaises(ValueError):
            RecognitionHealth(0.0, stale_timeout=-1)


class SamplesTests(unittest.TestCase):
    def test_quantiles_are_exact_over_samples(self):
        samples = Samples()
        for value in [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]:
            samples.add(value)
        summary = samples.summary()
        self.assertEqual(summary['samples'], 10)
        self.assertEqual(summary['p50'], 50)
        self.assertEqual(summary['p95'], 100)
        self.assertEqual(summary['min'], 10)
        self.assertEqual(summary['max'], 100)
        self.assertEqual(Samples().summary(), {'samples': 0})


class RuntimeSummaryTests(unittest.TestCase):
    def test_counts_frames_candidates_colors_perf_and_segments(self):
        summary = RuntimeSummary()
        for line in [
            'K230 resetting interpreter before camera/model startup',
            OBJECT_NONE, OBJECT_PHONE, GAZE, FACE, PERF,
            "obj ('phone', 0.41)", 'purple [(10, 20, 30, 40)]', 'blue [(1, 2, 3, 4)]',
            'health verified=0 errors=0 active=-',
            RecognitionHealth(0.0).line(RecognitionHealth(0.0).snapshot(0.0)[0]),
        ]:
            summary.feed(line)
        report = summary.report()
        self.assertEqual(report['valid_echoed_frames'], 4)
        self.assertEqual(report['object_uart_line_counts']['phone'], 1)
        self.assertEqual(report['object_uart_line_counts']['none'], 1)
        self.assertEqual(report['candidate_log_line_counts']['phone'], 1)
        self.assertEqual(report['color_log_line_counts']['purple'], 1)
        self.assertEqual(report['sampled_perf_by_mode']['PHONE']['infer_ms']['p50'], 65)
        self.assertEqual(report['sampled_min_free_bytes'], 3800032)

    def test_reset_counter_creates_segment_and_equal_cycle_counted(self):
        summary = RuntimeSummary()
        summary.feed(OBJECT_PHONE)          # cycle 1
        summary.feed(OBJECT_PHONE)          # cycle 1 again (duplicate)
        summary.feed(OBJECT_NONE)           # cycle 0 < 1 -> new segment
        report = summary.report()
        self.assertEqual(report['valid_echoed_frames'], 3)
        self.assertEqual(report['equal_cycle_lines'], 1)
        self.assertEqual(report['counter_segments'], 2)

    def test_real_launch_log_summarizes_without_claiming_accuracy(self):
        log = (Path(__file__).resolve().parents[1] /
               'logs/launch_20261012_114611_bttrk961/k230.log')
        if not log.exists():
            self.skipTest('recorded launch log not present')
        summary = RuntimeSummary()
        for line in log.read_text(encoding='utf-8', errors='replace').splitlines():
            summary.feed(line)
        report = summary.report()
        self.assertGreater(report['valid_echoed_frames'], 0)
        self.assertEqual(report['error_marker_lines'], 0)
        self.assertTrue(any('not' in limit for limit in report['limits']))


if __name__ == '__main__':
    unittest.main()
