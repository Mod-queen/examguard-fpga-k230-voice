"""Relocatable RTL self-check runner. Standard library only; no board access.

Placed at sim/run_module_tests.py in the submitted source package.
"""
from pathlib import Path
import argparse,concurrent.futures,gzip,hashlib,json,os,re,shutil,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
QUICK=['mdc_waveform_equivalence_tb','ready_source_contract_tb','display_pipeline_contract_tb','dvi_pipeline_contract_tb','voice_notice_backlog_tb','exam_fsm_tb','event_request_fifo_tb','camera_black_boundary_tb','camera_init_contract_tb',
       'dvp_capture_contract_tb','config_parser_contract_tb','config_mailbox_contract_tb',
       'status_mailbox_contract_tb','gmii_rgmii_contract_tb','mdio_readback_tb',
       'tmds_decode_contract_tb','tmds_serializer_contract_tb','video_fifo_stream_bridge_tb',
       'evidence_wrapper_reset_tb','voice_interaction_system_tb','history_sample_source_tb']

def execute(cmd,cwd,log,timeout):
 start=time.monotonic()
 process=subprocess.Popen(list(map(str,cmd)),cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 try:data=process.communicate(timeout=timeout)[0];rc=process.returncode
 except subprocess.TimeoutExpired:
  if os.name=='nt':subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],capture_output=True)
  else:process.kill()
  data=process.communicate()[0];rc=-999
 text=data.decode('utf-8',errors='replace')
 if rc==-999:text+='\nHARNESS_TIMEOUT\n'
 log.write_text(text,encoding='utf-8')
 return rc,text,round(time.monotonic()-start,3)

def resolve_tool(value,name):
 candidate=Path(value) if value else None
 if candidate and candidate.is_dir():candidate=candidate/name
 if candidate and candidate.is_file():return candidate.resolve()
 found=shutil.which(str(candidate) if candidate else name)
 if not found:raise SystemExit('找不到 '+name+'。请先安装对应工具，并指定可执行文件或 bin 目录。')
 return Path(found).resolve()

def main():
 parser=argparse.ArgumentParser(description='可重定位的模块仿真入口。默认运行关键模块；只在电脑中仿真，不访问板卡。')
 group=parser.add_mutually_exclusive_group()
 group.add_argument('--all',action='store_true',help='运行全部当前自检用例')
 group.add_argument('--only',nargs='+',help='只运行指定用例；名称可用 --list 查看')
 group.add_argument('--list',action='store_true',help='列出用例及对应仿真器')
 parser.add_argument('--vivado-bin',help='Vivado 2018.3 的 bin 目录；未指定时查找 PATH')
 parser.add_argument('--iverilog-bin',help='Icarus 的 bin 目录；未指定时查找 PATH')
 parser.add_argument('--output',type=Path,help='新的输出目录，拒绝覆盖已有结果')
 parser.add_argument('--jobs',type=int,default=2,help='并发用例数，默认 2')
 parser.add_argument('--waves',action='store_true',help='另存真实 VCD 波形，限制记录范围以减小文件')
 args=parser.parse_args()
 plan=json.loads((ROOT/'sim/test_plan.json').read_text(encoding='utf-8'))['tests']
 if args.list:
  print('\n'.join(t['top']+' ['+t['engine']+']' for t in plan));return
 wanted=set(args.only or ([] if args.all else QUICK))
 cases=[t for t in plan if args.all or t['top'] in wanted]
 if wanted-{t['top'] for t in cases}:raise SystemExit('未知测试用例：'+str(wanted-{t['top'] for t in cases}))
 out=(args.output or ROOT/'sim/results'/('rerun_'+time.strftime('%Y%m%d_%H%M%S'))).resolve()
 if out.exists():raise SystemExit('输出目录已存在，为保留原结果拒绝覆盖：'+str(out))
 out.mkdir(parents=True)
 tools={}
 if any(t['engine']=='icarus' for t in cases):
  tools['iverilog']=resolve_tool(args.iverilog_bin,'iverilog.exe' if os.name=='nt' else 'iverilog')
  tools['vvp']=tools['iverilog'].with_name('vvp.exe' if os.name=='nt' else 'vvp')
 if any(t['engine']=='xsim' for t in cases):
  tools['xvlog']=resolve_tool(args.vivado_bin,'xvlog.bat' if os.name=='nt' else 'xvlog')
  for n in ('xelab','xsim'):tools[n]=tools['xvlog'].with_name(n+('.bat' if os.name=='nt' else ''))
  tools['glbl']=tools['xvlog'].parent.parent/'data/verilog/src/glbl.v'
 includes=sorted({p.parent for p in (ROOT/'sim').rglob('*.vh')}|{p.parent for p in (ROOT/'src/fpga').rglob('*.vh')})
 def run(case):
  dest=out/case['top'];dest.mkdir()
  files=[tools['glbl'] if s=='@vivado/glbl.v' else ROOT/s for s in case['files']]
  result=dict(top=case['top'],engine=case['engine'],status='compile_failed',hardware_access=False,
              sources=[dict(path=s,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for s,p in zip(case['files'],files)],repairs=case['repairs'])
  for f in (ROOT/'sim/fixtures').iterdir():
   if f.is_file():shutil.copy2(f,dest/f.name)
  inc=sorted(set(includes)|{p.parent for p in files})
  if case['engine']=='icarus':
   cmd=[tools['iverilog'],'-g2012','-s',case['top'],'-o',dest/'simulation.vvp']
   for d in inc:cmd+=['-I',d]
   for d in case['defines']:cmd+=['-D',d]
   if args.waves:
    wrapper=dest/'trace_capture.sv'
    wrapper.write_text('module trace_capture; initial begin $dumpfile("trace.vcd"); $dumpvars(2,'+case['top']+'); $dumplimit(2000000); end endmodule\n')
    cmd+=['-s','trace_capture',wrapper]
   cmd+=files
   rc,log,_=execute(cmd,dest,dest/'compile.log',120)
   if rc==0:rc,log,secs=execute([tools['vvp'],'-n',dest/'simulation.vvp'],dest,dest/'run.log',180)
  else:
   prj=dest/'files.prj'
   prj.write_text('\n'.join(('sv' if p.suffix=='.sv' else 'verilog')+' work "'+p.as_posix()+'"' for p in files)+'\n')
   cmd=[tools['xvlog'],'--relax','-prj',prj]
   for d in inc:cmd+=['-i',d]
   for d in case['defines']:cmd+=['-d',d]
   rc,log,_=execute(cmd,dest,dest/'compile.log',180)
   if rc==0:
    cmd=[tools['xelab'],'--relax','--debug','typical','-L','unisims_ver','-L','unimacro_ver','-L','secureip','work.'+case['top']]
    if any(p.name=='glbl.v' for p in files):cmd+=['work.glbl']
    cmd+=['-s','case_snapshot']
    rc,log,_=execute(cmd,dest,dest/'elaborate.log',180)
    if rc==0:
     tcl=dest/'run.tcl'
     wave=''
     if args.waves:
      # Top-level control signals give useful traces without logging millions
      # of video pixels or a clock edge at every simulator time step.
      names=['rst','reset','rst_n','request','accepted','rejected','event_valid','result_valid','result_ok','protocol_fault','video_fault','frame_done','init_done','tx_qualified','link_up','errors','state']
      paths=' '.join('/'+case['top']+'/'+n for n in names)
      wave='open_vcd trace.vcd\nset signals [get_objects -quiet {'+paths+'}]\nif {[llength $signals]} {log_vcd $signals}\n'
     tcl.write_text(wave+'run all\n'+('close_vcd\n' if args.waves else '')+'quit\n')
     rc,log,secs=execute([tools['xsim'],'case_snapshot','-tclbatch',tcl.as_posix()],dest,dest/'run.log',900)
  if (dest/'run.log').exists():
   bad=re.search(r'(?im)^\s*(?:FAIL|FATAL|ERROR)(?::|\s)|couldn.t read file|unable to open|no such file',log)
   result.update(status='timeout' if rc==-999 else 'failed' if rc or bad else 'passed' if re.search(r'\bPASS(?:ED)?\b',log) else 'observation_only',seconds=secs)
   result['pass_lines']=[s for s in log.splitlines() if re.search(r'\bPASS(?:ED)?\b',s)]
  result['exit_code']=rc
  vcd=dest/'trace.vcd'
  if vcd.exists():
   with vcd.open('rb') as src,gzip.open(dest/'trace.vcd.gz','wb') as dst:shutil.copyfileobj(src,dst)
   result['trace_bytes']=vcd.stat().st_size;vcd.unlink()
  (dest/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
  labels={'passed':'通过','failed':'失败','compile_failed':'编译失败','timeout':'超时','observation_only':'仅观察，无通过结论'}
  print(case['top'],labels[result['status']],flush=True)
  return result
 with concurrent.futures.ThreadPoolExecutor(max_workers=max(1,min(args.jobs,4))) as pool:results=list(pool.map(run,cases))
 summary=dict(cases=len(results),passed=sum(r['status']=='passed' for r in results),hardware_access=False,tool_executables={k:str(v) for k,v in tools.items()},results=results)
 (out/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
 print('结果文件：'+str(out/'summary.json'),flush=True)
 raise SystemExit(0 if summary['passed']==len(results) else 1)

if __name__=='__main__':main()
