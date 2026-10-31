"""Candidate RGB gate for the specified purple-cover book; no hardware IO.

Color alone never creates a book. Only existing notes model candidates can pass.
Phone/head observations are unchanged. Defaults are development values.
"""
import math


def purple_pixel(r, g, b):
    r, g, b = int(r), int(g), int(b)
    high, low = max(r, g, b), min(r, g, b)
    delta = high - low
    if high < 35 or delta == 0 or delta * 255 < 50 * high:
        return False
    if high == r:
        hue = (60 * (g - b)) // delta
        if hue < 0:
            hue += 360
    elif high == g:
        hue = 120 + (60 * (b - r)) // delta
    else:
        hue = 240 + (60 * (r - g)) // delta
    return 250 <= hue <= 325


def purple_fraction(image, box, grid=16):
    shape = tuple(image.shape)
    if len(shape) == 4 and shape[0] == 1:
        image = image[0]
        shape = shape[1:]
    if len(shape) != 3 or shape[0] != 3:
        raise ValueError('Expected RGB planar image, not BGR/interleaved/padded input')
    if len(box) != 4 or not all(math.isfinite(v) for v in box):
        raise ValueError('Invalid notes box')
    _, height, width = shape
    x0, y0, x1, y1 = box
    if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
        raise ValueError('Notes box outside source image')
    # At most 256 samples/candidate; no full-frame HSV buffer on K230.
    nx, ny = min(grid, max(1, int(x1-x0))), min(grid, max(1, int(y1-y0)))
    matches = 0
    for iy in range(ny):
        y = min(height-1, int(y0 + (iy+.5)*(y1-y0)/ny))
        for ix in range(nx):
            x = min(width-1, int(x0 + (ix+.5)*(x1-x0)/nx))
            matches += int(purple_pixel(image[0,y,x], image[1,y,x], image[2,y,x]))
    return matches / (nx*ny), matches, nx*ny


def overlap(a, b):
    intersection = max(0, min(a[2],b[2])-max(a[0],b[0])) * max(0, min(a[3],b[3])-max(a[1],b[1]))
    union = (a[2]-a[0])*(a[3]-a[1]) + (b[2]-b[0])*(b[3]-b[1]) - intersection
    return intersection / union if union > 0 else 0


class PurpleNotesGate:
    def __init__(self, min_fraction=.15, min_score=.5, min_matches=12,
                 confirm_frames=2, dwell_ms=180, max_gap_ms=250, min_iou=.4):
        if not (0 < min_fraction <= 1 and 0 <= min_score <= 1 and 0 < min_iou <= 1):
            raise ValueError('Invalid purple gate thresholds')
        if min_matches < 1 or confirm_frames < 2 or dwell_ms < 0 or max_gap_ms <= 0:
            raise ValueError('Invalid purple gate confirmation')
        self.fraction, self.score, self.matches = min_fraction, min_score, min_matches
        self.need, self.dwell, self.gap, self.iou = confirm_frames, dwell_ms, max_gap_ms, min_iou
        self.seq = self.time = None
        self.reset()

    def reset(self):
        self.box = self.start = None
        self.count = 0

    def update(self, rows, image, seq, captured_ms):
        if min(seq, captured_ms) < 0 or (self.seq is not None and
                (seq <= self.seq or captured_ms <= self.time)):
            raise ValueError('Purple gate requires a new advancing frame')
        if self.time is not None and captured_ms-self.time > self.gap:
            self.reset()
        self.seq, self.time = seq, captured_ms
        kept, candidates = [], []
        report = dict(notes_candidates=0, rejected=0, accepted=False, purple_fraction=None)
        for row in rows:
            if row['class'] != 'notes':
                kept.append(row)
                continue
            report['notes_candidates'] += 1
            if not math.isfinite(row['score']) or not 0 <= row['score'] <= 1:
                raise ValueError('Invalid notes score')
            fraction, matches, total = purple_fraction(image, row['box'])
            if row['score'] >= self.score and fraction >= self.fraction and matches >= self.matches:
                candidates.append((row, fraction))
            else:
                report['rejected'] += 1
        if not candidates:
            self.reset()
            return kept, report
        row, fraction = max(candidates, key=lambda pair: pair[0]['score'])
        if self.box is None or overlap(row['box'], self.box) < self.iou:
            self.start, self.count = captured_ms, 1
        else:
            self.count += 1
        self.box = list(row['box'])
        report['purple_fraction'] = fraction
        if self.count >= self.need and captured_ms-self.start >= self.dwell:
            kept.append(row)
            report['accepted'] = True
        return kept, report
