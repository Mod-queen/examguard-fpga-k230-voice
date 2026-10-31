"""MicroPython/CPython six-class decoder and fresh-sample policy, no hardware IO.

Separate candidate: never imported by the accepted main.py. Coordinates xyxy in
source image. Policy defaults are development settings, not field acceptance.
"""
import math

NAMES = ('phone', 'notes', 'head_forward', 'head_down_writing', 'head_left', 'head_right')
MODEL_SHA256 = 'dcc2996576e46ab05d9e6b4e90f63da8ca5fb2516bff9dedaa9a454cf0904243'


def geometry(width=640, height=480, size=320):
    if min(width, height) <= 0 or size != 320:
        raise ValueError('Candidate supports positive source dimensions and model320 only')
    gain = min(size / width, size / height)
    resized = (int(round(width * gain)), int(round(height * gain)))
    dw, dh = (size - resized[0]) / 2, (size - resized[1]) / 2
    return dict(source_size=[width, height], size=size, gain=gain, resized=list(resized),
                pad_ltrb=[round(dw-.1), round(dh-.1), round(dw+.1), round(dh+.1)],
                inverse_pad=[round((size-width*gain)/2-.1), round((size-height*gain)/2-.1)])


def box_iou(a, b):
    area = max(0., min(a[2], b[2])-max(a[0], b[0])) * max(0., min(a[3], b[3])-max(a[1], b[1]))
    union = max(0., a[2]-a[0])*max(0., a[3]-a[1]) + max(0., b[2]-b[0])*max(0., b[3]-b[1])-area
    return area/(union+1e-7)


def decode(output, geom, confidence=.3, nms_iou=.6, max_det=100, envelope=.01):
    if tuple(output.shape) != (1, 10, 2100):
        raise ValueError('Expected [1,10,2100], no transpose/COCO84 output supported')
    if not 0 <= envelope <= .01 or not 0 <= confidence <= 1 or not 0 <= nms_iou <= 1 or not 1 <= max_det <= 100:
        raise ValueError('Invalid decoder configuration')
    candidates = []
    negative, above, low, high = 0, 0, 1., 0.
    for anchor in range(2100):
        values = [float(output[0, c, anchor]) for c in range(10)]
        if not all(math.isfinite(v) for v in values) or min(values[2:4]) < 0:
            raise ValueError('Nonfinite output or negative box size')
        scores = values[4:]
        for score in scores:
            if score < -envelope or score > 1+envelope:
                raise ValueError('Quantization probability error exceeds .01 envelope')
            low, high = min(low, score), max(high, score)
            negative += int(score < 0)
            above += int(score > 1)
        # Only scores are projected. Keep caller-owned raw output unchanged.
        scores = [max(0., min(1., s)) for s in scores]
        cls = max(range(6), key=lambda c: scores[c])
        if scores[cls] > confidence:
            x, y, w, h = values[:4]
            candidates.append(dict(class_id=cls, score=scores[cls],
                                   box=[x-w/2, y-h/2, x+w/2, y+h/2]))
    candidates.sort(key=lambda r: -r['score'])
    kept = []
    for row in candidates:
        if any(r['class_id'] == row['class_id'] and box_iou(r['box'], row['box']) > nms_iou for r in kept):
            continue
        kept.append(row)
        if len(kept) == max_det:
            break
    px, py = geom['inverse_pad']
    gain = geom['gain']
    width, height = geom['source_size']
    for row in kept:
        x0, y0, x1, y1 = row['box']
        row['box'] = [max(0., min(width, (x0-px)/gain)), max(0., min(height, (y0-py)/gain)),
                      max(0., min(width, (x1-px)/gain)), max(0., min(height, (y1-py)/gain))]
        row['class'] = NAMES[row['class_id']]
    return kept, dict(probability_min=low, probability_max=high, below_zero=negative, above_one=above,
                      total_scores=12600, envelope=envelope)


def ascii_frame(algorithm, fields):
    payload = ',%02d,%s#' % (algorithm, ','.join(str(v) for v in fields))
    length = len(payload)+2
    while True:
        frame = '$%d%s' % (length, payload)
        if len(frame) == length:
            return frame+'\n'
        length = len(frame)


class Policy:
    """07 class vectors +14 objects. Identity08 is exclusively old face reporter.

    Unknown sends 07 zeros (present=false), never trusted center. Existing FPGA
    retains accumulated gaze across absence: this adapter cannot clear that
    state or claim consecutive-wall-time semantics without changing FPGA RTL.
    """
    def __init__(self, object_low=.3, object_high=.6, object_confirm=2,
                 head_confidence=.6, head_margin=.15, side_confirm=3, side_ms=400,
                 normal_confirm=2, normal_ms=150, min_interval_ms=100,
                 max_gap_ms=1000, max_age_ms=500):
        if not 0 <= object_low <= object_high <= 1 or not 0 <= head_confidence <= 1 or not 0 <= head_margin <= 1:
            raise ValueError('Invalid thresholds')
        if min(object_confirm, side_confirm, normal_confirm) < 1 or min(side_ms, normal_ms, min_interval_ms) < 0 or min(max_gap_ms, max_age_ms) <= 0:
            raise ValueError('Invalid confirmation/timing')
        self.low, self.high, self.obj_need = object_low, object_high, object_confirm
        self.head_conf, self.margin = head_confidence, head_margin
        self.side_need, self.side_ms = side_confirm, side_ms
        self.normal_need, self.normal_ms = normal_confirm, normal_ms
        self.interval, self.gap, self.age = min_interval_ms, max_gap_ms, max_age_ms
        self.seq, self.last_capture, self.last_emit, self.last_now = -1, None, None, None
        self._reset_streaks()

    def _reset_streaks(self):
        self.obj_class, self.obj_count = None, 0
        self.head_class, self.head_count, self.head_start = None, 0, None

    def update(self, rows, seq, captured_ms, now_ms, source_size=(640, 480)):
        if len(source_size) != 2 or min(source_size) <= 0 or min(seq, captured_ms, now_ms) < 0:
            raise ValueError('Invalid sample identity/time/source dimensions')
        if seq <= self.seq or (self.last_capture is not None and captured_ms <= self.last_capture):
            raise ValueError('Duplicate/nonadvancing frame; no repeated evidence samples allowed')
        if self.last_now is not None and now_ms < self.last_now:
            raise ValueError('Clock moved backwards; create new policy instance')
        if now_ms < captured_ms or now_ms-captured_ms > self.age:
            self._reset_streaks()
            raise ValueError('Stale/future frame; cannot emit fresh 07/14')
        if self.last_capture is not None and captured_ms-self.last_capture > self.gap:
            self._reset_streaks()
        self.seq, self.last_capture, self.last_now = seq, captured_ms, now_ms
        for row in rows:
            if row['class'] not in NAMES or not math.isfinite(row['score']) or not 0 <= row['score'] <= 1:
                raise ValueError('Invalid detection')
            if len(row['box']) != 4 or not all(math.isfinite(v) for v in row['box']):
                raise ValueError('Invalid detection box')
            x0, y0, x1, y1 = row['box']
            if not 0 <= x0 <= x1 <= source_size[0] or not 0 <= y0 <= y1 <= source_size[1]:
                raise ValueError('Detection box not clipped to source')
        usable = [r for r in rows if r['box'][2] > r['box'][0] and r['box'][3] > r['box'][1]]
        objects = sorted((r for r in usable if r['class'] in NAMES[:2] and r['score'] >= self.low), key=lambda r: -r['score'])
        hit = objects[0] if objects else None
        if hit:
            cls = hit['class']
            self.obj_count = self.obj_count+1 if cls == self.obj_class else 1
            self.obj_class = cls
            confirmed = hit['score'] >= self.high or self.obj_count >= self.obj_need
        else:
            self.obj_class, self.obj_count, confirmed = None, 0, False
        object_fields = (0, 0, 0, 0, 'none')
        if confirmed:
            sw, sh = source_size
            x0, y0, x1, y1 = hit['box']
            x0, y0 = int(max(0, min(1280, x0*1280/sw))), int(max(0, min(720, y0*720/sh)))
            x1, y1 = int(max(0, min(1280, x1*1280/sw))), int(max(0, min(720, y1*720/sh)))
            if x1 > x0 and y1 > y0:
                object_fields = (x0, y0, x1-x0, y1-y0, hit['class'])
        heads = sorted((r for r in usable if r['class'] in NAMES[2:]), key=lambda r: -r['score'])
        state = 'unknown'
        if heads and heads[0]['score'] >= self.head_conf:
            primary = heads[0]
            # Multiple spatial heads OR competing class scores for one head are
            # unknown. Class-aware detection NMS deliberately preserves them.
            competitors = [r for r in heads[1:] if r['score'] >= .3]
            ambiguous = any(box_iou(primary['box'], r['box']) < .5 or primary['score']-r['score'] < self.margin for r in competitors)
            if not ambiguous:
                state = primary['class']
        if state == 'unknown':
            self.head_class, self.head_count, self.head_start = None, 0, None
        elif state == self.head_class:
            self.head_count += 1
        else:
            self.head_class, self.head_count, self.head_start = state, 1, captured_ms
        gaze = (0, 0, 0, 0)
        side = state in ('head_left', 'head_right')
        if state != 'unknown':
            need, dwell = (self.side_need, self.side_ms) if side else (self.normal_need, self.normal_ms)
            if self.head_count >= need and captured_ms-self.head_start >= dwell:
                # Canonical classification vector, NOT measured face/gaze point.
                end = 240 if state == 'head_left' else 1040 if state == 'head_right' else 640
                gaze = (640, 360, end, 360)
            else:
                state = 'pending_'+state
        if self.last_emit is not None and now_ms-self.last_emit < self.interval:
            return dict(frames=[], head_state=state, object_class=object_fields[-1], rate_limited=True)
        self.last_emit = now_ms
        return dict(frames=[ascii_frame(14, object_fields), ascii_frame(7, gaze)],
                    head_state=state, object_class=object_fields[-1], rate_limited=False)
