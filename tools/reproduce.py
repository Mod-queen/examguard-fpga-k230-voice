"""从零检查、仿真与构建的统一入口；不连接板卡、不烧写 Flash。"""
from pathlib import Path
import argparse,datetime,hashlib,importlib.util,json,os,shutil,subprocess,sys,time

ROOT=Path(__file__).resolve().parents[1]

def main():
 p=argparse.ArgumentParser(description=__doc__,epilog='已验证环境：Windows x64、Vivado 2018.3、Python 3.12、Icarus 12.0 devel。指南允许其他工具版本，但本工程的厂商 IP 沿用 2018.3；请先用该版本复现。')
 p.add_argument('--full',action='store_true',help='依次完成文件检查、PC测试、全部RTL仿真、SD目录准备与FPGA构建')
 p.add_argument('--simulate',action='store_true',help='运行关键模块仿真；与 --all 配合运行全部用例')
 p.add_argument('--all',action='store_true',help='运行全部模块用例')
 p.add_argument('--build',action='store_true',help='执行完整综合、布局布线与位流生成')
 p.add_argument('--pc-tests',action='store_true',help='运行PC软件的本地测试，不调用云模型')
 p.add_argument('--prepare-sd',action='store_true',help='在本次结果目录准备SD文件；不会写真实SD卡')
 p.add_argument('--vivado-bin',help='Vivado 2018.3 的 bin 目录')
 p.add_argument('--iverilog-bin',help='Icarus 的 bin 目录')
 p.add_argument('--output',type=Path,help='全新的结果目录；默认 build/reproduction_日期时间')
 p.add_argument('--jobs',type=int,default=2,help='并行仿真数量，默认2')
 a=p.parse_args()
 required={'serial':'pyserial'}
 missing=[v for k,v in required.items() if not importlib.util.find_spec(k)]
 if missing:raise SystemExit('缺少Python依赖：'+','.join(missing)+'。请先执行 python -m pip install -r requirements.txt')
 out=(a.output or ROOT/'build'/('reproduction_'+time.strftime('%Y%m%d_%H%M%S'))).resolve()
 if out.exists():raise SystemExit('输出目录已存在，请指定新目录：'+str(out))
 out.mkdir(parents=True)
 data=dict(start_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),python=sys.version,root=str(ROOT),output=str(out),hardware_access=False,cloud_requests=False,steps=[],status='running')
 result=out/'reproduction_result.json'
 def save():result.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
 def step(name,cmd):
  print('正在执行：'+name,flush=True);start=time.monotonic()
  log=out/(f'{len(data["steps"])+1:02d}.log')
  with log.open('wb') as stream:
   run=subprocess.run(list(map(str,cmd)),cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT)
  r=dict(name=name,exit_code=run.returncode,seconds=round(time.monotonic()-start,3),log=log.name,command=list(map(str,cmd)))
  data['steps'].append(r);save()
  if run.returncode:
   data['status']='failed';save();raise SystemExit('执行失败：'+name+'；请查看 '+str(log))
  print('已通过：'+name,flush=True)
 try:
  step('工程文件与依赖校验',[sys.executable,'-X','utf8',ROOT/'tools/verify_package.py'])
  if a.full or a.pc_tests:step('PC本地功能测试',[sys.executable,'-X','utf8',ROOT/'sim/run_pc_tests.py','--output',out/'pc_tests'])
  if a.full or a.simulate or a.all:
   cmd=[sys.executable,'-X','utf8',ROOT/'sim/run_module_tests.py','--output',out/'simulation','--jobs',a.jobs]
   if a.full or a.all:cmd+=['--all']
   if a.vivado_bin:cmd+=['--vivado-bin',a.vivado_bin]
   if a.iverilog_bin:cmd+=['--iverilog-bin',a.iverilog_bin]
   step('RTL模块自检仿真',cmd)
  if a.full or a.prepare_sd:step('准备K230的SD文件目录',[sys.executable,'-X','utf8',ROOT/'tools/prepare_sdcard.py','--output',out/'sdcard'])
  if a.full or a.build:
   exe=Path(a.vivado_bin)/('vivado.bat' if os.name=='nt' else 'vivado') if a.vivado_bin else shutil.which('vivado.bat' if os.name=='nt' else 'vivado')
   if not exe or not Path(exe).is_file():raise SystemExit('找不到Vivado，请用 --vivado-bin 指定2018.3的bin目录。')
   step('FPGA综合与布局布线',[exe,'-mode','batch','-source',ROOT/'build/build_fpga.tcl','-log',out/'vivado.log','-journal',out/'vivado.jou','-tclargs',out/'fpga'])
  data['status']='passed';data['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
  print('本次复现步骤全部通过。结果：'+str(result),flush=True)
  print('新生成的位流仅在电脑中保存，未下载或固化到板卡。',flush=True)
 except BaseException:
  if data['status']=='running':data['status']='failed';save()
  raise

if __name__=='__main__':main()
