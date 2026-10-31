"""Hash-bound activation16 model, fixed-validated resize->center114 input."""
import gc
import uhashlib
import ubinascii
import nncase_runtime as nn
import ulab.numpy as np
from libs.AI2D import Ai2d
from eg_live_core import geometry
from eg_live_fast import decode_fast

MODEL_SHA256 = '7954b4c1b26da2b86899dbd961564b580519710b16b2e1ff74b0e68b25c3b04b'


def file_sha256(path):
    h = uhashlib.sha256()
    with open(path, 'rb') as f:
        while True:
            data = f.read(65536)
            if not data:
                break
            h.update(data)
    return ubinascii.hexlify(h.digest()).decode()


class LiveApp:
    def __init__(self, path):
        if nn.version() != '2.9.0' or file_sha256(path) != MODEL_SHA256:
            raise ValueError('Runtime or activation16 model mismatch')
        self.geometry = geometry()
        self.kpu = nn.kpu()
        self.kpu.load_kmodel(path)
        if self.kpu.inputs_size() != 1 or self.kpu.outputs_size() != 1:
            raise ValueError('Unexpected model IO')
        self.resize = Ai2d(0)
        self.resize.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT, np.uint8, np.uint8)
        self.resize.resize(nn.interp_method.tf_bilinear, nn.interp_mode.half_pixel)
        self.resize.build([1,3,480,640], [1,3,240,320])
        self.padding = Ai2d(0)
        self.padding.set_ai2d_dtype(nn.ai2d_format.NCHW_FMT, nn.ai2d_format.NCHW_FMT, np.uint8, np.uint8)
        self.padding.pad([0,0,0,0,40,40,0,0], 0, [114,114,114])
        self.padding.build([1,3,240,320], [1,3,320,320])

    def run(self, image):
        if tuple(image.shape) not in ((3,480,640), (1,3,480,640)):
            raise ValueError('Expected RGB planar640x480')
        resized = self.resize.run(image)
        tensor = self.padding.run(resized.to_numpy())
        self.kpu.set_input_tensor(0, tensor)
        self.kpu.run()
        output_tensor = self.kpu.get_output_tensor(0)
        raw = output_tensor.to_numpy()
        rows, projection, work = decode_fast(raw, self.geometry, np)
        return rows, projection, work

    def deinit(self):
        del self.kpu
        del self.resize
        del self.padding
        gc.collect()
        nn.shrink_memory_pool()
