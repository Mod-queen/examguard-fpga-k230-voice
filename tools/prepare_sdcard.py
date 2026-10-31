"""Prepare an SD directory, restoring case-sensitive vendor paths; no board access."""
from pathlib import Path
import argparse,json,hashlib,shutil
p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1]
items=json.loads((root/'board/k230/sdcard_manifest.json').read_text(encoding='utf-8'))['files']
checked=[]
for item in items:
    source=root/item['source'];target=a.output/item['target']
    if hashlib.sha256(source.read_bytes()).hexdigest()!=item['sha256']:raise SystemExit('Source hash mismatch: '+item['source'])
    if target.exists() and target.read_bytes()!=source.read_bytes():raise SystemExit('Refuse overwrite different file: '+str(target))
    checked.append((source,target))
for source,target in checked:
    target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(source,target)
(a.output/'examguard/face_db').mkdir(parents=True,exist_ok=True)
print('SD files prepared:',len(checked),'Enroll a permitted face before formal startup.')
