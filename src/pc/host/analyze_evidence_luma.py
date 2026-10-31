"""Summarize evidence RGB brightness; not a substitute for FPGA telemetry."""
import argparse
import json
from pathlib import Path
from statistics import mean

from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', type=Path, default=Path(__file__).parent / 'evidence_out')
    parser.add_argument('--events', nargs='+', help='Event directory names to inspect')
    parser.add_argument('--frames', action='store_true', help='Print each frame brightness')
    args = parser.parse_args()
    for manifest in sorted(args.dir.glob('event_*/manifest.json')):
        if args.events and manifest.parent.name not in args.events:
            continue
        data = json.loads(manifest.read_text(encoding='utf-8'))
        stats = []
        for frame in sorted(data['frames'], key=lambda f: f['index']):
            with Image.open(manifest.parent / frame['file']) as image:
                rgb = image.convert('RGB')
                values = [(r >> 2) + (g >> 1) + (b >> 2)
                          for r, g, b in rgb.get_flattened_data()]
            stats.append((frame['timestamp_ms'], mean(values),
                          100 * sum(v < 32 for v in values) / len(values)))
            if args.frames:
                print(f'{manifest.parent.name}/{frame["file"]} '
                      f't={frame["timestamp_ms"]}ms '
                      f'luma={stats[-1][1]:.2f} dark<32={stats[-1][2]:.1f}%')
        if stats:
            print(f'{manifest.parent.name} complete={data["complete"]} '
                  f't={stats[0][0]}..{stats[-1][0]}ms '
                  f'luma min/mean/max={min(s[1] for s in stats):.2f}/'
                  f'{mean(s[1] for s in stats):.2f}/{max(s[1] for s in stats):.2f} '
                  f'dark<32={mean(s[2] for s in stats):.1f}%')


if __name__ == '__main__':
    main()
