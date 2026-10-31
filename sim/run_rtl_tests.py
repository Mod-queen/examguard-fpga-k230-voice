"""Run existing boundary and integration testbenches against packaged sources."""
from pathlib import Path
import argparse, json, subprocess, shutil

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--iverilog',default='iverilog');p.add_argument('--vvp',default='vvp');a=p.parse_args()
out=ROOT/'sim/results/rtl';out.mkdir(parents=True,exist_ok=True)
def source(name):
    matches=list((ROOT/'src/fpga').rglob(name))
    if not matches:matches=list((ROOT/'src/rtl_support').rglob(name))
    if len(matches)!=1:raise ValueError((name,[str(x) for x in matches]))
    return matches[0]

groups=[
 ('camera_black_boundary_tb',['camera_black_gate.v','camera_black_boundary_tb.sv']),
 ('camera_black_720p_tb',['camera_black_gate.v','camera_black_720p_tb.sv']),
 ('camera_black_noise_tb',['camera_black_gate.v','camera_black_noise_tb.sv']),
 ('compact_identity_tb',['candidate_overlay.sv','candidate_glyph.sv','text_overlay.v','char_rom.v','char_rom_cn.v','compact_identity_tb.sv']),
 ('history_reference_directory_tb',['history_reference_directory.v','history_reference_directory_tb.sv']),
 ('voice_notice_queue_tb',['voice_notice_queue.sv','voice_notice_queue_tb.sv']),
]
# The full wire-level I2C model uses Vivado XSim: run_voice.tcl.
shutil.copy2(ROOT/'board/records/field_noise_upper.hex',out/'field_noise_upper.hex')
results=[]
for top,files in groups:
    exe=out/(top+'.vvp')
    build=subprocess.run([a.iverilog,'-g2012','-s',top,'-o',str(exe)]+[str(source(n)) for n in files],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=60)
    log=build.stdout+build.stderr
    if build.returncode==0:
        run=subprocess.run([a.vvp,str(exe)],cwd=out,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=90)
        log+=run.stdout+run.stderr;passed=run.returncode==0 and 'PASS' in run.stdout and 'FATAL' not in run.stdout
    else:passed=False
    (out/(top+'.log')).write_text(log,encoding='utf-8')
    results.append({'top':top,'passed':passed,'sources':[str(source(n).relative_to(ROOT)).replace('\\','/') for n in files]})
    print(top,'PASS' if passed else 'FAIL',flush=True)
data={'passed':all(x['passed'] for x in results),'cases':results,'hardware_access':False}
(out/'summary.json').write_text(json.dumps(data,indent=2),encoding='utf-8')
raise SystemExit(0 if data['passed'] else 1)
