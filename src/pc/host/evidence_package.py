"""Export/verify a scoped ExamGuard evidence ZIP without modifying captures."""
import argparse
import json
from pathlib import Path
import sys
import sqlite3
import zipfile

from app.evidence_package import export_evidence_package, verify_evidence_package


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='action',required=True)
    create=sub.add_parser('export')
    create.add_argument('--root',type=Path,required=True)
    create.add_argument('--out',type=Path,required=True)
    create.add_argument('--session',type=Path)
    create.add_argument('--uart',type=Path)
    verify=sub.add_parser('verify');verify.add_argument('package',type=Path)
    args=parser.parse_args()
    try:
        result=(export_evidence_package(args.root,args.out,session_path=args.session,uart_path=args.uart)
                if args.action=='export' else verify_evidence_package(args.package))
        print(json.dumps(result,ensure_ascii=False,indent=2))
        return 0
    except (OSError,ValueError,KeyError,sqlite3.Error,zipfile.BadZipFile) as exc:
        print(f'Evidence package failed: {exc}',file=sys.stderr)
        return 1


if __name__=='__main__':
    raise SystemExit(main())
