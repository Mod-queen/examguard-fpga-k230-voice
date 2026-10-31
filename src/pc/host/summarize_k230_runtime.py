"""Read-only K230 console baseline: python summarize_k230_runtime.py <k230.log>."""
import argparse
import hashlib
import json
from pathlib import Path

from app.k230_runtime import RuntimeSummary


def summarize(path):
    summary = RuntimeSummary()
    digest = hashlib.sha256()
    size = 0
    with Path(path).open('rb') as handle:
        for raw in handle:
            size += len(raw)
            digest.update(raw)
            summary.feed(raw.decode('utf-8', 'replace'))
    return {**summary.report(), 'input': str(Path(path).resolve()),
            'bytes_read': size, 'read_sha256': digest.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--out', type=Path, help='new JSON file; refuses to overwrite')
    args = parser.parse_args()
    text = json.dumps(summarize(args.log), ensure_ascii=False, indent=2)
    if args.out:
        with args.out.open('x', encoding='utf-8') as handle:
            handle.write(text + '\n')
    print(text)


if __name__ == '__main__':
    main()
