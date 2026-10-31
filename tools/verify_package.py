"""Verify declared package bytes and active project/SD dependencies, read only."""
from pathlib import Path
import json,hashlib,xml.etree.ElementTree as E,sys
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/'package_manifest.json').read_text(encoding='utf-8'))
failures=[]
for item in manifest['files']:
    p=root/item['path']
    if not p.is_file() or p.stat().st_size!=item['bytes'] or hashlib.sha256(p.read_bytes()).hexdigest()!=item['sha256']:failures.append(item['path'])
work=root/'src/fpga';prj=work/'ov5640_ddr3_hdmi_vga.xpr';tree=E.parse(prj)
refs=[]
for n in tree.findall('.//File'):
    s=n.attrib['Path'].replace('$PSRCDIR',str(work/'ov5640_ddr3_hdmi_vga.srcs')).replace('$PPRDIR',str(work))
    p=Path(s);refs.append(p)
    if not p.is_file():failures.append('project:'+s)
sd=json.loads((root/'board/k230/sdcard_manifest.json').read_text(encoding='utf-8'))
for r in sd['files']:
    p=root/r['source']
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=r['sha256']:failures.append('sd:'+r['source'])
sys.path.insert(0,str(root/'src/pc/host'))
from app.voice_roster import load_voice_roster
from app.services import load_config
from app.candidate_display import encode_display
roster=load_voice_roster(root/'src/pc/host/voice_roster.json')
assert roster
for name,number,tag in roster.values():assert len(encode_display(name,number))==16
assert load_config(root/'src/pc/host/launch_config.json')['k230_runtime']=='book_assist_20261030'
result={'passed':not failures,'files_checked':len(manifest['files']),'project_references':len(refs),'sd_files':len(sd['files']),'failures':failures,'scope':'File identity and declared dependencies only; no hardware or cloud.'}
print(json.dumps(result,ensure_ascii=False))
raise SystemExit(0 if not failures else 1)
