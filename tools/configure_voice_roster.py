"""Explicitly save real candidate fields with a new revision; no device writes."""
import argparse
import json
from pathlib import Path
import secrets
import sys
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'src/pc/host'))
from app.voice_roster import load_voice_roster
from app.candidate_display import encode_display


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--face', type=int, choices=(1, 2, 3), default=1)
    parser.add_argument('--name', required=True)
    parser.add_argument('--exam-number', required=True)
    parser.add_argument('--roster', type=Path, default=ROOT/'src/pc/host'/'voice_roster.json')
    args = parser.parse_args()
    for text in (args.name, args.exam_number):
        if not text.strip() or len(text) > 64 or any(ord(c) < 32 for c in text):
            parser.error('Fields must contain 1..64 non-control characters')
    if not args.roster.parent.is_dir():
        raise FileNotFoundError(args.roster.parent)
    encode_display(args.name.strip(), args.exam_number.strip())
    old = load_voice_roster(args.roster) if args.roster.exists() else {}
    revision = secrets.randbits(64) or 1
    while any(item[2] == revision for item in old.values()):
        revision = secrets.randbits(64) or 1
    old[args.face] = (args.name.strip(), args.exam_number.strip(), revision)
    if args.roster.exists():
        backup = args.roster.with_suffix('.before_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json')
        with backup.open('xb') as stream:
            stream.write(args.roster.read_bytes())
    result = dict(schema=1, candidates=[dict(face_id=face, name=item[0], exam_number=item[1],
                                           info_tag=f'{item[2]:016x}') for face, item in sorted(old.items())])
    temporary = args.roster.with_suffix('.new.json')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    load_voice_roster(temporary)
    temporary.replace(args.roster)
    print('ROSTER_SAVED: reload roster, then click Apply current roster / recheck information in preparation tab')
    print(f'face={args.face} info_tag={revision:016x}')


if __name__ == '__main__':
    main()
