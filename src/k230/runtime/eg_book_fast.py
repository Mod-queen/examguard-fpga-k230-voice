"""Two-class decoder; bounded score projection, source clipping and class NMS."""
from eg_live_core import box_iou

def decode_fast(output,geom,np,confidence=.3,nms_iou=.6,max_det=100,envelope=.01):
    if tuple(output.shape)!=(1,6,2100):raise ValueError('expected public [1,6,2100]')
    if not 0<=confidence<=1 or not 0<=envelope<=.01 or not 0<=nms_iou<=1 or not 1<=max_det<=100:
        raise ValueError('invalid decoder thresholds')
    matrix=output.reshape((6,2100))
    if not bool(np.all(np.isfinite(matrix))) or float(np.min(matrix[2:4]))<0:
        raise ValueError('invalid public geometry')
    scores=matrix[4:6];low,high=float(np.min(scores)),float(np.max(scores))
    if low < -envelope or high>1+envelope:raise ValueError('public score envelope exceeded')
    projected=np.minimum(np.maximum(scores,0.),1.)
    best=np.max(projected,axis=0);kept=[];visited=0
    while float(np.max(best))>confidence:
        anchor=int(np.argmax(best));score=float(best[anchor]);best[anchor]=-1.;visited+=1
        cls=0 if float(projected[0,anchor])==score else 1
        x,y,w,h=[float(matrix[c,anchor]) for c in range(4)]
        box=[x-w/2,y-h/2,x+w/2,y+h/2]
        if any(r['class_id']==cls and box_iou(r['box'],box)>nms_iou for r in kept):continue
        kept.append(dict(class_id=cls,score=score,box=box))
        if len(kept)==max_det:break
    px,py=geom['inverse_pad'];gain=geom['gain'];width,height=geom['source_size']
    for row in kept:
        x0,y0,x1,y1=row['box']
        row['box']=[max(0.,min(width,(x0-px)/gain)),max(0.,min(height,(y0-py)/gain)),
                    max(0.,min(width,(x1-px)/gain)),max(0.,min(height,(y1-py)/gain))]
        row['class']=('phone','book')[row['class_id']]
    return kept,dict(probability_min=low,probability_max=high,envelope=envelope),dict(anchors_visited=visited)
