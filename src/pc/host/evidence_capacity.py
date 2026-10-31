"""Read-only evidence disk inventory; never removes old revisions or pending."""
import argparse
import json
from pathlib import Path

from app.evidence_capacity import scan_evidence_capacity


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--out',type=Path)
    args=parser.parse_args()
    result=scan_evidence_capacity(args.root)
    text=json.dumps(result,ensure_ascii=False,indent=2)
    if args.out:
        if not args.out.parent.is_dir():
            parser.error('output parent must exist')
        with args.out.open('x',encoding='utf-8') as target:
            target.write(text+'\n')
    print(text)


if __name__=='__main__': main()
