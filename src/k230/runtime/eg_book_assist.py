"""Existing public book model supplements the unchanged six-class head/phone model.

Only model-located books with purple pixels become notes candidates. The rotated
view is a same-frame fallback, never a cached detection or a color-only alarm.
"""
import gc
import nncase_runtime as nn
import ulab.numpy as np
from live_app import LiveApp,file_sha256
from eg_live_fast import decode_fast
from eg_book_fast import decode_fast as decode_book
from eg_scene_guard import purple_fraction

BOOK_SHA256='c8dfe0fa9a3ff9d2a1eb75cb8b1727e9c367fd945b28a6db4d39b023d14843f6'

def purple_books(rows,image,flipped=False):
    result=[]
    for row in rows:
        if row['class']!='book':continue
        box=row['box']
        if flipped:
            x0,y0,x1,y1=box;box=[640-x1,480-y1,640-x0,480-y0]
        if box[2]-box[0]<24 or box[3]-box[1]<24:continue
        fraction,matches,_=purple_fraction(image,box)
        if fraction<.15 or matches<12:continue
        result.append(dict(box=box,score=row['score'],class_id=1,
                           **{'class':'notes','source':'public_book_purple','view':180 if flipped else 0}))
    return result

class BookAssistedApp(LiveApp):
    def __init__(self,path,book_path):
        super().__init__(path)
        if file_sha256(book_path)!=BOOK_SHA256:raise ValueError('public book model SHA mismatch')
        self.book_kpu=nn.kpu()
        self.book_kpu.load_kmodel(book_path)
        if self.book_kpu.inputs_size()!=1 or self.book_kpu.outputs_size()!=1:
            raise ValueError('public book model IO mismatch')

    def _book(self,tensor):
        self.book_kpu.set_input_tensor(0,tensor)
        self.book_kpu.run()
        raw=self.book_kpu.get_output_tensor(0).to_numpy()
        return decode_book(raw,self.geometry,np)[0]

    def run(self,image):
        if tuple(image.shape) not in ((3,480,640),(1,3,480,640)):
            raise ValueError('expected fresh RGB planar source')
        tensor=self.padding.run(self.resize.run(image).to_numpy())
        self.kpu.set_input_tensor(0,tensor);self.kpu.run()
        primary,projection,work=decode_fast(self.kpu.get_output_tensor(0).to_numpy(),self.geometry,np)
        books=purple_books(self._book(tensor),image)
        flipped=False
        if not books:
            # Explicit copy: the KPU receives contiguous pixels, no negative-stride tensor.
            turned=tensor.to_numpy()[:,:,::-1,::-1].copy()
            rotated=nn.from_numpy(turned)
            books=purple_books(self._book(rotated),image,True)
            del rotated,turned
            flipped=True
        rows=[row for row in primary if row['class']!='notes']
        if not books:
            for row in primary:
                if row['class']=='notes' and row['score']>=.5 and row['box'][2]>row['box'][0] and row['box'][3]>row['box'][1]:
                    fraction,matches,_=purple_fraction(image,row['box'])
                    if fraction>=.15 and matches>=12:books.append(row)
        rows.extend(books)
        work['public_book_candidates']=len(books)
        work['same_frame_flipped_view']=flipped
        return rows,projection,work

    def deinit(self):
        if hasattr(self,'book_kpu'):del self.book_kpu
        super().deinit()
        gc.collect()
