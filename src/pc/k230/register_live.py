"""Live-camera face registration for ExamGuard.

Why: registering from a still photo and then recognizing from the camera
mismatches domains and drops the similarity (observed 0.51 for a photo that
matches itself at 0.70). Capturing the template from the same camera fixes it.

Usage (run in CanMV IDE, or `python k230/repl_client.py run ...`):
  1. edit NAME below (Alice / Bob / Carol),
  2. face the camera (only ONE face in view),
  3. run; it captures FRAMES frames, averages the normalized embeddings of
     frames with exactly one detected face, and writes
     /sdcard/examguard/face_db/<NAME>.bin (512 float32 = 2048 bytes).
"""
import sys
import os
import gc
import time

sys.path.append('/sdcard/examguard')

import ulab.numpy as np
from libs.PipeLine import PipeLine
from vendor_face import FaceDetApp, FaceRegistrationApp

NAME = 'Alice'
DATABASE_DIR = '/sdcard/examguard/face_db/'
DET_MODEL = '/sdcard/kmodel/face_detection_320.kmodel'
REG_MODEL = '/sdcard/kmodel/face_recognition.kmodel'
ANCHORS_PATH = '/sdcard/utils/prior_data_320.bin'
RGB_SIZE = [640, 480]
DISPLAY_SIZE = [640, 480]
DISPLAY_MODE = 'lcd'
FRAMES = 300
MIN_FACE_AREA = 80 * 80
MAX_SAMPLES = 12


def main():
    if NAME not in ('Alice', 'Bob', 'Carol'):
        raise ValueError('NAME must be Alice, Bob or Carol')

    pl = PipeLine(rgb888p_size=RGB_SIZE, display_size=DISPLAY_SIZE,
                  display_mode=DISPLAY_MODE)
    pl.create()
    anchors = np.fromfile(ANCHORS_PATH, dtype=np.float).reshape((4200, 4))
    det = FaceDetApp(DET_MODEL, [320, 320], anchors,
                     confidence_threshold=0.5, nms_threshold=0.2,
                     rgb888p_size=RGB_SIZE, display_size=DISPLAY_SIZE)
    det.config_preprocess(input_image_size=RGB_SIZE)
    reg = FaceRegistrationApp(REG_MODEL, [112, 112],
                              rgb888p_size=RGB_SIZE, display_size=DISPLAY_SIZE)

    acc = None
    n = 0
    try:
        for i in range(FRAMES):
            os.exitpoint()
            img = pl.get_frame()
            boxes, landms = det.run(img)
            pl.osd_img.clear()
            ok = False
            if len(boxes) == 1 and len(landms) == 1:
                x, y, w, h = [float(v) for v in boxes[0][:4]]
                if w * h >= MIN_FACE_AREA and n < MAX_SAMPLES:
                    reg.config_preprocess(landms[0], input_image_size=RGB_SIZE)
                    feat = reg.run(img)
                    feat = feat / np.linalg.norm(feat)
                    acc = feat if acc is None else acc + feat
                    n += 1
                    ok = True
            if len(boxes):
                for det_box in boxes:
                    bx, by, bw, bh = [int(round(float(v))) for v in det_box[:4]]
                    color = (255, 0, 255, 0) if ok else (255, 255, 0, 0)
                    pl.osd_img.draw_rectangle(bx, by, bw, bh, color=color, thickness=4)
            pl.osd_img.draw_string_advanced(8, 8, 24, 'REG %s  samples=%d/%d' % (NAME, n, MAX_SAMPLES),
                                            color=(255, 0, 255, 0))
            pl.show_image()
            if i % 30 == 0:
                print('REG %s frame=%d faces=%d samples=%d' % (NAME, i, len(boxes), n))
            gc.collect()
            if n >= MAX_SAMPLES:
                break
    finally:
        det.deinit()
        reg.deinit()
        pl.destroy()
        gc.collect()

    if acc is None:
        print('REG FAILED: no usable single-face frame captured for ' + NAME)
        return
    mean = acc / n
    mean = mean / np.linalg.norm(mean)
    data = mean.tobytes()
    path = DATABASE_DIR + NAME + '.bin'
    with open(path, 'wb') as f:
        f.write(data)
    print('REG OK %s samples=%d bytes=%d -> %s' % (NAME, n, len(data), path))


main()
