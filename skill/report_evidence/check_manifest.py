"""Read-only verification of arbitrary project report sources, standard library only."""
import argparse, hashlib, json
from pathlib import Path

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--manifest',type=Path,required=True)
    a=p.parse_args();manifest=json.loads(a.manifest.read_text(encoding='utf-8'))
    records=[]
    for entry in manifest['files']:
        source=Path(entry['path'])
        if not source.is_absolute():source=a.root/source
        item={'path':entry['path'],'role':entry.get('role','source'),'exists':source.is_file()}
        if item['exists']:
            raw=source.read_bytes();item['sha256']=hashlib.sha256(raw).hexdigest()
            item['hash_matches']=item['sha256']==entry['sha256']
            decoded=raw.decode('utf-8','replace')
            item['text_matches']=all(token in decoded for token in entry.get('contains',[]))
        item['passed']=item['exists'] and item.get('hash_matches',False) and item.get('text_matches',False)
        records.append(item)
    result={'passed':all(x['passed'] for x in records),'files':records,'scope':'Only declared source identity and text; no hardware or model conclusions.'}
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result['passed'] else 1

if __name__=='__main__':raise SystemExit(main())
