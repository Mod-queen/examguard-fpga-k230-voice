"""Read-only K230 console telemetry; no camera, REPL or board configuration."""
from collections import Counter
import math
import re

from capture_k230 import FrameError, parse_frame

FRAME = re.compile(r'frame=(\d+) ([A-Z+]+) sent=([1-9]\d*) (\$[^\r\n]+#)')
PERF = re.compile(r'perf ([A-Z+]+) fetch=(\d+)ms infer=(\d+)ms loop=(\d+)ms free=(\d+)')
HEALTH_PREFIX = 'K230 recognition health '


def recognition_frame(line):
    """Validate the echoed ASCII frame, not FPGA reception or correctness."""
    match = FRAME.fullmatch(line.strip())
    if match is None:
        return None
    try:
        wire = parse_frame(match[4].encode('ascii'))
        fields = wire['fields']
        algorithm = wire['algorithm']
        if algorithm not in (7, 8, 14) or len(fields) != {7: 4, 8: 6, 14: 5}[algorithm]:
            return None
        if any(not field.isdigit() for field in fields[:4]):
            return None
        if algorithm == 14 and fields[4] not in ('none', 'phone', 'notes'):
            return None
        if algorithm == 8 and (not fields[5].isdigit() or not 0 <= int(fields[5]) <= 100):
            return None
    except (FrameError, UnicodeError):
        return None
    return {'cycle': int(match[1]), 'mode': match[2], 'algorithm': algorithm,
            'object': fields[4] if algorithm == 14 else None}


class RecognitionHealth:
    """PC receive-side liveness, requiring an advancing valid frame counter.

    Raw USB traffic, perf, source image chunks and PC health do not refresh it.
    A stale state is recoverable; callers retain independent hard error latches.
    """
    def __init__(self, started, *, startup_timeout=30.0, stale_timeout=5.0):
        if any(not math.isfinite(v) or v <= 0 for v in (startup_timeout, stale_timeout)):
            raise ValueError('health timeouts must be finite and positive')
        self.started = started
        self.startup_timeout = startup_timeout
        self.stale_timeout = stale_timeout
        self.last_at = None
        self.last_cycle = None
        self.frames = 0
        self.invalid = 0
        self.nonadvancing = 0
        self.state = 'starting'

    def feed(self, line, now):
        frame = recognition_frame(line)
        if frame is None:
            if line.startswith('frame='):
                self.invalid += 1
            return False
        if self.last_cycle is not None and frame['cycle'] <= self.last_cycle:
            self.nonadvancing += 1
            return False
        self.frames += 1
        self.last_at = now
        self.last_cycle = frame['cycle']
        return True

    def snapshot(self, now):
        if self.last_at is None:
            age = max(0.0, now - self.started)
            state = 'startup_timeout' if age >= self.startup_timeout else 'starting'
        else:
            age = max(0.0, now - self.last_at)
            state = 'stale' if age >= self.stale_timeout else 'running'
        changed = self.state != state
        self.state = state
        return {'state': state, 'frames': self.frames, 'last_cycle': self.last_cycle,
                'age_s': round(age, 3), 'invalid': self.invalid,
                'nonadvancing': self.nonadvancing}, changed

    def line(self, snapshot):
        return HEALTH_PREFIX + ' '.join('%s=%s' % (key, value) for key, value in snapshot.items())


def health_state(line):
    if not line.startswith(HEALTH_PREFIX):
        return None
    match = re.search(r'\bstate=(starting|startup_timeout|stale|running)\b', line[len(HEALTH_PREFIX):])
    return match[1] if match else None


class Samples:
    """Exact quantiles of sampled integer timings, stored as a histogram."""
    def __init__(self):
        self.counts = Counter()
        self.count = 0
        self.total = 0

    def add(self, value):
        self.counts[value] += 1
        self.count += 1
        self.total += value

    def quantile(self, fraction):
        target = max(1, math.ceil(self.count * fraction))
        accumulated = 0
        for value, count in sorted(self.counts.items()):
            accumulated += count
            if accumulated >= target:
                return value

    def summary(self):
        if not self.count:
            return {'samples': 0}
        return {'samples': self.count, 'min': min(self.counts),
                'mean': round(self.total / self.count, 3),
                'p50': self.quantile(.5), 'p95': self.quantile(.95), 'max': max(self.counts)}


class RuntimeSummary:
    """Offline console summary. Sparse perf samples are not all-loop timings."""
    def __init__(self):
        self.frames = 0
        self.invalid = 0
        self.nonadvancing = 0
        self.segments = 0
        self.last_cycle = None
        self.objects = Counter()
        self.algorithms = Counter()
        self.perf = {}
        self.min_free = None
        self.error_lines = 0
        self.health_states = Counter()
        self.candidates = Counter()
        self.colors = Counter()

    def feed(self, line):
        # Some camera firmware messages contain embedded NULs.
        line = line.replace('\x00', '').strip()
        frame = recognition_frame(line)
        if frame is not None:
            if self.last_cycle is None or frame['cycle'] < self.last_cycle:
                self.segments += 1
            elif frame['cycle'] == self.last_cycle:
                self.nonadvancing += 1
            self.last_cycle = frame['cycle']
            self.frames += 1
            self.algorithms[str(frame['algorithm'])] += 1
            if frame['object'] is not None:
                self.objects[frame['object']] += 1
        elif line.startswith('frame='):
            self.invalid += 1
        match = PERF.fullmatch(line)
        if match:
            stats = self.perf.setdefault(match[1], {key: Samples() for key in ('fetch_ms', 'infer_ms', 'loop_ms')})
            for key, value in zip(stats, match.groups()[1:4]):
                stats[key].add(int(value))
            free = int(match[5])
            self.min_free = free if self.min_free is None else min(self.min_free, free)
        state = health_state(line)
        if state:
            self.health_states[state] += 1
        for label in ('phone', 'notes'):
            if line.startswith("obj ('" + label + "',"):
                self.candidates[label] += 1
        for color in ('purple', 'blue'):
            if line.startswith(color + ' '):
                self.colors[color] += 1
        if ('Traceback' in line or 'Serial error:' in line or 'ERROR' in line or
                line.startswith('K230 stop not confirmed:')):
            self.error_lines += 1

    def report(self):
        return {'schema': 'examguard-k230-runtime-baseline-v1',
                'valid_echoed_frames': self.frames, 'invalid_frame_lines': self.invalid,
                'equal_cycle_lines': self.nonadvancing, 'counter_segments': self.segments,
                'echoed_algorithm_counts': dict(self.algorithms), 'object_uart_line_counts': dict(self.objects),
                'candidate_log_line_counts': dict(self.candidates), 'color_log_line_counts': dict(self.colors),
                'sampled_perf_by_mode': {mode: {key: stat.summary() for key, stat in stats.items()}
                                         for mode, stats in self.perf.items()},
                'sampled_min_free_bytes': self.min_free, 'error_marker_lines': self.error_lines,
                'health_state_log_counts': dict(self.health_states),
                'limits': [
                    'USB console echoes are not FPGA acknowledgements, events, ground truth or accuracy.',
                    'Object line counts include hold/repeated outputs, not independent detections.',
                    'perf is sparsely sampled (restored main prints every 60 loops); quantiles describe samples only.',
                    'Modes are grouped separately; absent face-heavy perf samples do not imply no face-heavy loops.',
                    'Legacy logs have no PC receive timestamps; elapsed duration, FPS and gap time cannot be reconstructed.',
                    'Error marker line count is not a unique failure count; missing markers do not prove stability.',
                ]}
