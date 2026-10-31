"""Read-only model lineage and captured-log audit; never opens a board."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(relative):
    return json.loads((ROOT / relative).read_text(encoding='utf-8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--log', type=Path)
    args = parser.parse_args()
    public = load('runs/public_objects320_v2/input.json')
    public_done = load('runs/public_objects320_v2/finished.json')
    field = load('runs/field_six320_fit_v1/input.json')
    field_done = load('runs/field_six320_fit_v1/finished.json')
    export = load('exports/field_six320_fit_v1/manifest.json')
    precision = load('compiler_290/precision_experiments/six320_act16_20261027_01/experiment.json')
    compiled = load('compiler_290/precision_experiments/six320_act16_20261027_01/compiled.json')
    activation = load('results/live290_activation_20261027_01/finished.json')
    release_dir = ROOT / 'runtime_releases/examguard_live290_act16_20261027_02'
    release = load('runtime_releases/examguard_live290_act16_20261027_02/release_manifest.json')
    assert sha(ROOT/'runs/public_objects320_v2/train/weights/best.pt') == public_done['best_sha256'] == field['weights_sha256']
    assert sha(ROOT/'runs/field_six320_fit_v1/train/weights/best.pt') == field_done['best_sha256'] == export['source_weights_sha256']
    model = next(item for item in export['models'] if item['size'] == 320)
    assert sha(ROOT/'exports/field_six320_fit_v1'/model['file'].replace('\\', '/')) == model['sha256'] == precision['onnx_sha256']
    assert sha(release_dir/'candidate_act16.kmodel') == compiled['sha256'] == release['model_sha256'] == activation['model_sha256']
    assert sha(release_dir/'release_manifest.json') == activation['release_manifest_sha256']
    installed = (ROOT/'results/live290_activation_20261027_01/installed_hashes.raw').read_bytes()
    for item in release['files']:
        assert sha(release_dir/item['path']) == item['sha256']
        remote = '/sdcard/examguard_live290_act16/'+item['path']
        assert activation['board_expected_files'][remote] == item['sha256']
        assert (remote+' '+item['sha256']).encode() in installed
    assert b'LIVE_FINAL_INSTALL_VERIFIED' in installed and b'Traceback' not in installed
    report = dict(
        result='LOCAL_LINEAGE_AND_PRIOR_DEPLOYMENT_EVIDENCE_MATCH',
        scope='Local preserved files and 2026-10-27 board hash evidence; NOT a new current-board readback or accuracy test',
        public_training=dict(images=public['dataset_audit']['splits']['train'],
            validation_images=public['dataset_audit']['splits']['val'],
            classes=['phone', 'book'], epochs=public['arguments']['epochs'],
            best_sha256=public_done['best_sha256']),
        six_class_finetune=dict(images=field['data']['field_unique_images'],
            sessions=field['data']['field_sessions'], public_replay=field['data']['public_replay_unique_images'],
            boxes=field['data']['training_boxes'], epochs=field['arguments']['epochs'],
            evaluation_scope=field['data']['validation_scope'], best_sha256=field_done['best_sha256']),
        not_deployed_object_replay=load('runs/field_objects320_replay_v1/data_input.json'),
        deployed_model=dict(sha256=compiled['sha256'], bytes=compiled['bytes'],
            onnx_sha256=precision['onnx_sha256'], calibration_sha256=precision['calibration_sha256']),
        observations_from_user=dict(object_errors=['wrong boxes on K230 LCD', 'phone/notes confused'],
            head_error='no head_left/right labels on K230 LCD during side turns',
            quantified_false_positive_or_recall_rate='not measured'),
        code_observations=dict(lcd_detection_confidence=.3, object_low=.3, object_high=.6, object_confirm=2,
            head_confidence=.6, head_margin=.15, head_side_confirm=3, head_side_ms=400,
            fpga_away_samples=5,
            note='LCD displays decoded rows before Policy confirmation; Policy/FPGA changes alone cannot fix wrong LCD class boxes'),
    )
    if args.log:
        raw = args.log.read_bytes()
        text = raw.decode('utf-8', errors='replace')
        states = Counter(re.findall(r'LIVE290_STATE\s+\d+\s+(\S+)\s+(\S+)', text))
        report['captured_log'] = dict(path=str(args.log.resolve()), bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest(),
            nul_bytes=raw.count(b'\0'), sampled_states=[dict(head=k[0], object=k[1], samples=v) for k,v in states.items()],
            limitations='Sparse state printout; no raw scores, exact source images or synchronized action labels. Counts are NOT accuracy.')
    with args.out.open('x', encoding='utf-8') as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
    print(json.dumps(report, ensure_ascii=True, indent=2))


if __name__ == '__main__':
    main()
