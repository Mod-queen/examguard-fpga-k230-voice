"""按原报告逐条整理CDC结构与待核项，不更改设计或豁免约束。"""
from pathlib import Path
import csv,hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
import argparse,time
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--report',type=Path,default=ROOT/'build/reports/cdc_review/cdc_all_checks.rpt')
parser.add_argument('--output',type=Path,default=ROOT/'build'/('cdc_review_'+time.strftime('%Y%m%d_%H%M%S')))
args=parser.parse_args()
report=args.report.resolve()
OUT=args.output.resolve()
if OUT.exists():raise SystemExit('拒绝覆盖已有CDC核对目录。')
OUT.mkdir(parents=True)
summary={};rows=[];src=dst=None
for line in report.read_text(encoding='utf-8').splitlines():
 m=re.match(r'^(CDC-\d+)\s+(Critical|Warning|Info)\s+(\d+)\s+(.+)$',line)
 if m:summary[m[1]]=dict(severity=m[2],count=int(m[3]),description=m[4])
 if line.startswith('Source Clock:'):src=line.split(':',1)[1].strip()
 if line.startswith('Destination Clock:'):dst=line.split(':',1)[1].strip()
 if not re.match(r'^\s*\d+\s+CDC-\d+\s+Critical',line):continue
 parts=re.split(r'\s{2,}',line.strip())
 if len(parts)!=8:raise ValueError(parts)
 num,check,severity,description,depth,exception,start,end=parts
 if end.endswith('/PRE'):
  kind='复位输入';explain='异步置位、当地时钟逐级释放。多路复位条件与跨域扇出仍需结合实际失效场景复核；不自动豁免。'
  sources=['ov5640_ddr3_hdmi_vga.srcs/sources_1/imports/event_identity/evidence_reset_barrier.v','ov5640_ddr3_hdmi_vga.srcs/sources_1/imports/ddr3_test/video_epoch_clear.v']
 elif 'ddr3_ready_' in end:
  kind='DDR就绪状态';explain='MIG就绪输出进入两级ASYNC_REG链。首级前存在组合逻辑；需复核就绪状态稳定性，不能据双级标记宣布完全签核。'
  sources=['ov5640_ddr3_hdmi_vga.srcs/sources_1/top/ov5640_ddr3_hdmi_vga.v']
 elif 'mdc_clk_reg' in end:
  kind='管理时钟分频反馈';explain='RTL在50MHz域更新MDC分频寄存器；该寄存器又作为生成时钟使用。报告把Q到D反馈列作CDC，需进一步核对生成时钟关系与反馈路径计时。'
  sources=['ov5640_ddr3_hdmi_vga.srcs/sources_1/eth_acx750/phy_reg_config.v']
 elif '/fifo/mem_' in start:
  kind='异步FIFO存储数据';explain='LUTRAM异步读出，经empty与目标holding寄存器门控。Gray指针为双级同步；仍需核对实际存储到目标路径的最大延迟与指针偏斜约束，不能仅靠功能仿真豁免。'
  sources=['ov5640_ddr3_hdmi_vga.srcs/sources_1/imports/ddr3_test/history_stream_cdc.sv','ov5640_ddr3_hdmi_vga.srcs/sources_1/imports/ddr3_test/async_fifo.v']
 else:raise ValueError('Unclassified endpoint '+end)
 rows.append(dict(index=len(rows)+1,report_row=int(num),check=check,source_clock=src,destination_clock=dst,
   source=start,destination=end,exception=exception,category=kind,review=explain,
   disposition='已定位结构，保留待签核；未新增豁免',rtl_sources=sources))
audit=dict(report_sha256=hashlib.sha256(report.read_bytes()).hexdigest(),summary=summary,
 critical_check_count=sum(r['count'] for r in summary.values() if r['severity']=='Critical'),
 printed_critical_detail_rows=len(rows),default_report_critical_count=18,
 counting_note='all_checks_per_endpoint与默认报告的检查口径不同；摘要统计与打印明细行数不一定相等，均保留原值。26项不是由代码改动引入的新回归。',
 status='structure_reviewed_signoff_pending',constraints_modified=False,waivers_added=False,
 external_delay_budgets_pending=dict(inputs=29,outputs=48),rows=rows)
(OUT/'structure_audit.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2),encoding='utf-8')
with (OUT/'structure_review.tsv').open('w',encoding='utf-8-sig',newline='') as stream:
 w=csv.writer(stream,delimiter='\t');w.writerow(['序号','检查','源时钟','目标时钟','源端点','目标端点','结构','核对说明','处理状态'])
 for r in rows:w.writerow([r[k] for k in ('index','check','source_clock','destination_clock','source','destination','category','review','disposition')])
(OUT/'readme.md').write_text('''# CDC结构核对

本目录对应已固化语音修复版。默认报告18项Critical；补充全端点检查为26项Critical。检查选项不同，不能把26误写为新增回归，也不能说已经清零。

逐条端点、RTL结构和核对意见见structure_review.tsv；原始报告与JSON均保留。已定位复位组合、DDR就绪同步、MDC分频反馈及FIFO异步读出四类。没有增加false_path，没有自动豁免。结构说明不是完整硬件签核。

实现内部时序WNS +0.134ns、WHS +0.031ns；外部29输入、48输出仍待板级延迟预算。正裕量不能代替这部分核对。
''',encoding='utf-8')
print(json.dumps({k:audit[k] for k in ('critical_check_count','printed_critical_detail_rows','status')},ensure_ascii=False))
