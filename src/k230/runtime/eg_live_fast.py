"""Array-side validation/filtering; unchanged six_core NMS/threshold semantics.

No Python scan over2100 anchors. Only qualifying anchors are converted to
Python scalars. Finite/envelope/negative-size checks still cover ALL outputs.
ulab availability and actual speed are verified by camera_profile.py preflight.
"""
import math
from eg_live_core import NAMES, box_iou


def decode_fast(output, geom, np, confidence=.3, nms_iou=.6, max_det=100, envelope=.01):
    if tuple(output.shape) != (1,10,2100):
        raise ValueError('Expected [1,10,2100]')
    if not 0 <= envelope <= .01 or not 0 <= confidence <= 1 or not 0 <= nms_iou <= 1 or not 1 <= max_det <= 100:
        raise ValueError('Invalid decoder configuration')
    matrix = output.reshape((10,2100))
    # Yahboom ulab ndarray == returns a scalar bool (observed on board).
    # Explicit isfinite is elementwise and checks even low-score coordinates.
    if not bool(np.all(np.isfinite(matrix))):
        raise ValueError('Nonfinite output')
    if float(np.min(matrix[2:4])) < 0:
        raise ValueError('Negative box size')
    scores = matrix[4:10]
    low, high = float(np.min(scores)), float(np.max(scores))
    if low < -envelope or high > 1+envelope:
        raise ValueError('Quantization probability error exceeds .01 envelope')
    audit = dict(probability_min=low, probability_max=high,
                 below_zero=int(np.sum(scores < 0)), above_one=int(np.sum(scores > 1)),
                 total_scores=12600, envelope=envelope)
    # Derived arrays only: never write to caller's KPU output. Projection before
    # argmax preserves first-class ties when several raw scores exceed1.
    projected = np.minimum(np.maximum(scores, 0.), 1.)
    best_scores = np.max(projected, axis=0)
    kept = []
    anchors_visited = 0
    while float(np.max(best_scores)) > confidence:
        anchor = int(np.argmax(best_scores))
        score = float(best_scores[anchor])
        best_scores[anchor] = -1.
        anchors_visited += 1
        cls = 0
        for c in range(6):
            if float(projected[c,anchor]) == score:
                cls = c
                break
        x, y = float(matrix[0,anchor]), float(matrix[1,anchor])
        w, h = float(matrix[2,anchor]), float(matrix[3,anchor])
        box = [x-w/2, y-h/2, x+w/2, y+h/2]
        if any(r['class_id'] == cls and box_iou(r['box'], box) > nms_iou for r in kept):
            continue
        kept.append(dict(class_id=cls, score=score, box=box))
        if len(kept) == max_det:
            break
    px, py = geom['inverse_pad']
    gain = geom['gain']
    width, height = geom['source_size']
    for row in kept:
        x0,y0,x1,y1 = row['box']
        row['box'] = [max(0.,min(width,(x0-px)/gain)),max(0.,min(height,(y0-py)/gain)),
                      max(0.,min(width,(x1-px)/gain)),max(0.,min(height,(y1-py)/gain))]
        row['class'] = NAMES[row['class_id']]
    return kept, audit, dict(anchors_visited=anchors_visited, python_full_anchor_scan=False)
