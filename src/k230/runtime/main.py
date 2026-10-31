"""Formal activation16+fast+face08 UART1 runtime; no training capture or SD loop IO."""
import sys
BASE = '/sdcard/examguard_book_assist_20261030'
if BASE not in sys.path:
    sys.path.insert(0, BASE)
import os
import time
import gc
import ulab.numpy as np
from libs.PipeLine import PipeLine
from ybUtils.YbUart import YbUart
from live_app import MODEL_SHA256
from eg_book_assist import BookAssistedApp
from eg_live_core import Policy
from eg_scene_guard import PurpleNotesGate
from eg_live_adapter import Reporter, AsciiProtocol, AUTH_NAMES
from eg_live_face import FaceRecognition

DATABASE = '/sdcard/examguard/face_db/'


class WireSink:
    """One bounded write/frame; don't report success after a short UART write."""
    def __init__(self, uart):
        self.uart = uart
        self.count = 0
        self.last = None

    def send(self, frame):
        # Vendor YbUart.write discards the byte count; inspect machine.UART's
        # actual return value rather than interpreting the wrapper's None.
        sent = self.uart.uart.write(frame)
        if sent != len(frame):
            raise OSError('Incomplete hardware UART frame')
        self.count += 1
        self.last = frame


def run(max_frames=None, enable_uart=True):
    if max_frames is not None and max_frames < 1:
        raise ValueError('max_frames must be positive')
    files = sorted(n for n in os.listdir(DATABASE) if n.endswith('.bin'))
    if not files or any(n[:-4] not in AUTH_NAMES or os.stat(DATABASE+n)[6] != 2048 for n in files):
        raise ValueError('Existing face database must contain authorized2048-byte features')
    uart = pl = app = face = None
    try:
        if not enable_uart:
            raise ValueError('Formal runtime requires hardware UART; use diagnostic entry for dry mode')
        uart = YbUart(baudrate=115200)
        if not hasattr(uart, 'uart'):
            raise OSError('UART1 initialization failed')
        sink = WireSink(uart)
        pl = PipeLine(rgb888p_size=[640,480], display_size=[640,480], display_mode='lcd')
        pl.create()
        app = BookAssistedApp(BASE+'/candidate_act16.kmodel',BASE+'/public_phone_act16.kmodel')
        anchors = np.fromfile('/sdcard/utils/prior_data_320.bin', dtype=np.float).reshape((4200,4))
        face = FaceRecognition('/sdcard/kmodel/face_detection_320.kmodel',
             '/sdcard/kmodel/face_recognition.kmodel', [320,320], [112,112], DATABASE, anchors,
             confidence_threshold=.5, nms_threshold=.2, face_recognition_threshold=0.,
             rgb888p_size=[640,480], display_size=[640,480])
        reporter = Reporter(AsciiProtocol(), sink, face_threshold=.65)
        policy = Policy()
        notes_gate = PurpleNotesGate(min_score=.3)
        print('EXAMGUARD_LIVE290_ACT16_START UART1_IO9_IO10_115200', MODEL_SHA256)
        print('EXAMGUARD_SCENE_GUARD_CANDIDATE public_book_purple_180ms_not_field_accepted')
        previous = time.ticks_ms()
        elapsed = 0
        sequence = 0
        while max_frames is None or sequence < max_frames:
            os.exitpoint()
            start = time.ticks_ms()
            elapsed += max(0, time.ticks_diff(start, previous))
            previous = start
            image = pl.get_frame()
            fetch_ms = time.ticks_diff(time.ticks_ms(), start)
            if image is None:
                raise ValueError('Missing camera input; no reuse of stale detections')
            before = sink.count
            rows, projection, work = app.run(image)
            rows, notes_guard = notes_gate.update(rows, image, sequence, elapsed)
            inferred = time.ticks_ms()
            infer_ms = time.ticks_diff(inferred, start)-fetch_ms
            decision = policy.update(rows, sequence, elapsed, elapsed+time.ticks_diff(inferred,start))
            for frame in decision['frames']:
                sink.send(frame)
            face_boxes = []
            identities = []
            if sequence % 3 == 0:
                face_boxes, identities = face.run(image)
                reporter.faces(face_boxes, identities, [640,480])
            pl.osd_img.clear()
            for row in rows:
                x0,y0,x1,y1 = row['box']
                if x1>x0 and y1>y0:
                    color = (255,0,255,0) if row['class'].startswith('head_') else (255,255,0,0)
                    pl.osd_img.draw_rectangle(int(x0),int(y0),int(x1-x0),int(y1-y0),color=color,thickness=2)
                    pl.osd_img.draw_string_advanced(int(x0),max(0,int(y0)-24),20,row['class'],color=color)
            for index, box in enumerate(face_boxes):
                x,y,w,h = [int(v) for v in box[:4]]
                text = identities[index] if index<len(identities) else 'unknown'
                pl.osd_img.draw_rectangle(x,y,w,h,color=(255,0,255,255),thickness=2)
                pl.osd_img.draw_string_advanced(x,max(0,y-28),24,text,color=(255,0,255,255))
            if sequence % 2 == 0:
                pl.show_image()
            sent = sink.count-before
            # Existing PC attach/liveness grammar, echoes only a frame that was
            # written this iteration (not cached repeated "fresh" evidence).
            if sent:
                echo = decision['frames'][0] if decision['frames'] else sink.last
                print('frame=%d FACE+PHONE sent=%d %s' % (sequence,sent,echo.strip()))
            del image, rows, face_boxes, identities
            gc.collect()
            loop_ms = time.ticks_diff(time.ticks_ms(), start)
            if sequence % 60 == 0:
                print('perf FACE+PHONE fetch=%dms infer=%dms loop=%dms free=%d' %
                      (fetch_ms,infer_ms,loop_ms,gc.mem_free()))
                print('LIVE290_STATE', sequence, decision['head_state'], decision['object_class'])
                print('NOTES_GUARD', notes_guard)
            sequence += 1
        print('EXAMGUARD_LIVE290_ACT16_STOP', sequence)
    finally:
        cleanup = []
        if face is not None:
            cleanup.extend([face.face_det.deinit,face.face_reg.deinit])
        if app is not None:
            cleanup.append(app.deinit)
        if pl is not None:
            cleanup.append(pl.destroy)
        if uart is not None:
            cleanup.append(uart.deinit)
        for close in cleanup:
            try:
                close()
            except Exception as exc:
                print('LIVE290_CLEANUP_ERROR',repr(exc))


if __name__ == '__main__':
    run()
