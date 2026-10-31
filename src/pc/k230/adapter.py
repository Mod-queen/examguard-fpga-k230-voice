"""MicroPython-compatible policy between Yahboom inference and FPGA ASCII.

Length follows the vendor PICO receiver: full $...# length, excluding newline.
Names must match the current ai_mailbox defaults exactly.
"""
import math

AUTH_NAMES = ("Alice", "Bob", "Carol")

# Gaze vector length used to turn (pitch, yaw) into a screen target, matching
# the vendor 07.eye_gaze example (half the 1280-wide protocol canvas).
GAZE_LENGTH = 640.0

# COCO class -> ExamGuard wire keyword. The FPGA ai_mailbox maps
# "phone" -> object_class 1 (0x50) and "notes" -> object_class 2 (0x51).
# In an exam any book/notebook on the desk is prohibited material, so the
# generic COCO "book" class is reported as "notes". Earphones/watches are not
# COCO classes and would need a custom-trained model.
OBJECT_LABEL_MAP = {
    "cell phone": "phone",
    "book": "notes",
}

# Fallbacks used when a caller passes a per-class table that omits a wire name.
OBJECT_LOW_FALLBACK = 0.2
OBJECT_CONFIRM_FALLBACK = 2


def _per_class(table, wire, fallback):
    if isinstance(table, dict):
        return table.get(wire, fallback)
    return table


def merge_object_detections(detections, extra_boxes, class_id, confidence):
    """Merge colour-detector boxes into a YOLO result tuple.

    detections is the model output (boxes, class_ids, scores) or None, with
    boxes in the same (x, y, w, h) source-image convention. The extra boxes are
    classified by Reporter.objects exactly like model hits, so the colour signal
    shares the two-tier gate, confirmation and hold logic. Returns plain lists.
    """
    boxes = []
    classes = []
    scores = []
    if detections is not None and len(detections) >= 3:
        boxes = list(detections[0])
        classes = list(detections[1])
        scores = list(detections[2])
    for box in extra_boxes:
        boxes.append(tuple(box[:4]))
        classes.append(class_id)
        scores.append(confidence)
    return boxes, classes, scores


def _overlap_ratio(inner, outer):
    """Fraction of `inner` (x, y, w, h) that lies inside `outer`."""
    ix, iy, iw, ih = [float(v) for v in inner[:4]]
    ox, oy, ow, oh = [float(v) for v in outer[:4]]
    if iw <= 0 or ih <= 0:
        return 0.0
    x0 = max(ix, ox)
    y0 = max(iy, oy)
    x1 = min(ix + iw, ox + ow)
    y1 = min(iy + ih, oy + oh)
    if x1 <= x0 or y1 <= y0:
        return 0.0
    return ((x1 - x0) * (y1 - y0)) / (iw * ih)


def boost_color_hits(detections, labels, wire, color_boxes, boost_confidence,
                     min_overlap=0.5):
    """Promote weak model hits of `wire` that overlap a colour box.

    A small blue accent on a dark phone is not distinctive enough to start an
    event on its own, but it is good evidence that a weak phone candidate is
    real. `color_boxes` are in the same (x, y, w, h) convention; a hit is
    promoted to boost_confidence when at least min_overlap of a colour box lies
    inside it. Returns new (boxes, class_ids, scores), or the input unchanged.
    """
    if detections is None or len(detections) < 3 or not color_boxes:
        return detections
    boxes = list(detections[0])
    classes = list(detections[1])
    scores = [float(s) for s in detections[2]]
    changed = False
    for i, class_id in enumerate(classes):
        class_id = int(class_id)
        if not 0 <= class_id < len(labels):
            continue
        if OBJECT_LABEL_MAP.get(labels[class_id]) != wire:
            continue
        box = boxes[i]
        if any(_overlap_ratio(c, box) >= min_overlap for c in color_boxes):
            if scores[i] < boost_confidence:
                scores[i] = boost_confidence
                changed = True
    if not changed:
        return detections
    return boxes, classes, scores


class AsciiProtocol:
    """Integer score variant for the current RTL; avoids opaque conversions."""
    def _encode(self, algorithm, fields):
        payload = ',%02d,%s#' % (algorithm, ','.join(str(v) for v in fields))
        length = len(payload) + 2
        while True:
            frame = '$%d%s' % (length, payload)
            if len(frame) == length:
                return frame + '\n'
            length = len(frame)

    def get_face_recoginiton_data(self, x, y, w, h, name, score):
        if name not in AUTH_NAMES + ('unknown',) or not 0 <= score <= 100:
            raise ValueError('invalid face fields')
        return self._encode(8, (x, y, w, h, name, int(score)))

    def get_object_detect_data(self, x, y, w, h, name):
        if name not in ('phone', 'notes', 'none'):
            raise ValueError('unconfigured object')
        return self._encode(14, (x, y, w, h, name))

    def get_eye_gaze_data(self, start_x, start_y, end_x, end_y):
        """Algorithm 07: face centre (start) and gaze target (end), 1280x720."""
        for value in (start_x, start_y, end_x, end_y):
            if not 0 <= int(value) <= 4095:
                raise ValueError('gaze coordinates out of range')
        return self._encode(7, (int(start_x), int(start_y), int(end_x), int(end_y)))


def face_identity(result, threshold=0.65):
    if not isinstance(result, str) or not result.startswith("name: "):
        return "unknown", 0
    parts = result[6:].split(", score: ")
    if len(parts) != 2:
        return "unknown", 0
    try:
        score = float(parts[1])
    except (ValueError, TypeError):
        return "unknown", 0
    if parts[0] not in AUTH_NAMES or not threshold <= score <= 1.0:
        return "unknown", 0
    return parts[0], int(score * 100 + 0.5)


def clip_box(box, source_size, target_size=(1280, 720)):
    """Scale full image coordinates; these are NOT calibrated OV5640 boxes."""
    x, y, w, h = [float(v) for v in box[:4]]
    sw, sh = source_size
    tw, th = target_size
    if sw <= 0 or sh <= 0 or w <= 0 or h <= 0:
        return None
    x0 = max(0, min(tw, int(x * tw / sw)))
    y0 = max(0, min(th, int(y * th / sh)))
    x1 = max(0, min(tw, int((x + w) * tw / sw)))
    y1 = max(0, min(th, int((y + h) * th / sh)))
    if x1 <= x0 or y1 <= y0:
        return None
    return x0, y0, x1 - x0, y1 - y0


class Reporter:
    def __init__(self, protocol, uart, face_threshold=0.65, object_threshold=0.5,
                 object_hold=2, object_threshold_low=0.2, object_confirm=2):
        self.protocol = protocol
        self.uart = uart
        self.face_threshold = face_threshold
        # Confident single-frame hit: reported immediately.
        self.object_threshold = object_threshold
        # Weak hit (far/small phone/notes): must persist object_confirm frames so
        # a one-frame distractor flicker does not raise a serious 0x50/0x51.
        # Both can be a scalar or a {wire: value} table for per-class tuning.
        self.object_threshold_low = object_threshold_low
        self.object_confirm = object_confirm
        # Number of consecutive object frames with no qualifying detection that
        # still repeat the last hit. Score jitter would otherwise emit "none",
        # which lets the FPGA re-arm after 3 nones and re-emit the same event.
        self.object_hold = object_hold
        self.last_frame = None
        self.last_gaze = None
        self._object_frame = None
        self._object_misses = object_hold
        self._object_low_streak = 0
        self._object_low_wire = None

    def faces(self, boxes, results, source_size):
        # No face is not an unknown person. Multiple faces must not authorize
        # whichever person happened to be reported last. Current RTL has no
        # person-count input, so use unknown (0x11), not an invented 0x12 frame.
        if len(boxes) == 0:
            return 0
        if len(boxes) != 1 or len(results) != 1:
            name, score = "unknown", 0
        else:
            name, score = face_identity(results[0], self.face_threshold)
        box = clip_box(boxes[0], source_size)
        if box is None:
            return 0
        frame = self.protocol.get_face_recoginiton_data(*(box + (name, score)))
        self.last_frame = frame
        self.uart.send(frame)
        return 1

    def gaze(self, boxes, gazes, source_size):
        # No face -> all-zero frame, which the FPGA treats as "centre/absent"
        # and uses to re-arm the head-turn counter.
        if not boxes:
            self.last_gaze = self.protocol.get_eye_gaze_data(0, 0, 0, 0)
            self.uart.send(self.last_gaze)
            return 1
        # Pick the largest face and report its gaze, scaled to 1280x720.
        best = None  # (area, centre_x, centre_y, pitch, yaw)
        for box, gaze in zip(boxes, gazes):
            scaled = clip_box(box, source_size)
            if scaled is None:
                continue
            x, y, w, h = scaled
            area = w * h
            if best is None or area > best[0]:
                pitch, yaw = gaze
                best = (area, x + w / 2.0, y + h / 2.0, float(pitch), float(yaw))
        if best is None:
            self.last_gaze = self.protocol.get_eye_gaze_data(0, 0, 0, 0)
        else:
            _, cx, cy, pitch, yaw = best
            # 0x60 means "head turned to look around", not "head bent down at
            # the desk". Looking down to read a phone or notes dominates the
            # vertical axis (FPGA gaze_dy), so report the horizontal turn only:
            # set the target's vertical coordinate to the face centre. The FPGA
            # still ORs dy, but dy is now 0, so only a side turn can trigger.
            tx = cx - GAZE_LENGTH * math.sin(pitch) * math.cos(yaw)
            ty = cy
            self.last_gaze = self.protocol.get_eye_gaze_data(
                int(max(0, min(1280, cx))), int(max(0, min(720, cy))),
                int(max(0, min(1280, tx))), int(max(0, min(720, ty))))
        self.uart.send(self.last_gaze)
        return 1

    def objects(self, detections, labels, source_size):
        # Report the highest-confidence prohibited item per frame. Only COCO
        # classes in OBJECT_LABEL_MAP count (phone -> 0x50, book -> notes 0x51).
        # A hit at/above object_threshold reports immediately; a weaker hit above
        # the class's low gate must persist object_confirm frames (far phone or
        # notes, which score lower). A short run of misses is held so score
        # jitter does not emit "none" and re-arm the FPGA.
        best = None  # (confidence, scaled box, wire name)
        if detections:
            for box, class_id, confidence in zip(*detections):
                class_id = int(class_id)
                if not 0 <= class_id < len(labels):
                    continue
                wire = OBJECT_LABEL_MAP.get(labels[class_id])
                confidence = float(confidence)
                if wire is None or not confidence <= 1.0:
                    continue
                low = _per_class(self.object_threshold_low, wire, OBJECT_LOW_FALLBACK)
                if confidence < low:
                    continue
                scaled = clip_box(box, source_size)
                if scaled is not None and (best is None or confidence > best[0]):
                    best = (confidence, scaled, wire)
        hit = None
        if best is not None and best[0] >= self.object_threshold:
            self._object_low_streak = 0
            self._object_low_wire = None
            hit = best
        elif best is not None:
            wire = best[2]
            if wire == self._object_low_wire:
                self._object_low_streak += 1
            else:
                self._object_low_wire = wire
                self._object_low_streak = 1
            need = _per_class(self.object_confirm, wire, OBJECT_CONFIRM_FALLBACK)
            if self._object_low_streak >= need:
                hit = best
        else:
            self._object_low_streak = 0
            self._object_low_wire = None
        if hit is not None:
            self._object_frame = self.protocol.get_object_detect_data(*(hit[1] + (hit[2],)))
            self._object_misses = 0
        elif self._object_frame is not None and self._object_misses < self.object_hold:
            self._object_misses += 1
        else:
            self._object_frame = None
        if self._object_frame is None:
            frame = self.protocol.get_object_detect_data(0, 0, 0, 0, 'none')
        else:
            frame = self._object_frame
        self.last_frame = frame
        self.uart.send(frame)
        return 1
