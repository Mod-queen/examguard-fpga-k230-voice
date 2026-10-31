"""Actual stdio discovery; intentionally no dashboard data, device or cloud."""
from pathlib import Path
import subprocess,sys,json
root=Path(__file__).resolve().parents[1]
requests=[
 {'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'submission_check','version':'1'}}},
 {'jsonrpc':'2.0','method':'notifications/initialized'},
 {'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}},
 {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'get_system_health','arguments':{}}},
]
run=subprocess.run([sys.executable,'-u',str(root/'src/pc/start_agent_mcp.py'),'--current-session-file',str(root/'sim/results/intentionally_unselected.json')],input=''.join(json.dumps(r)+'\n' for r in requests),capture_output=True,text=True,encoding='utf-8',timeout=20)
responses=[json.loads(s) for s in run.stdout.splitlines() if s.strip()]
byid={r.get('id'):r for r in responses}
names={t['name'] for t in byid[2]['result']['tools']}
assert names=={'get_recent_events','check_evidence_status','get_image_path','get_system_health'},names
assert byid[3]['result']['isError'] is True,byid[3]
assert 'result' in byid[1] and run.returncode==0
result={'passed':True,'discovered_tools':sorted(names),'no_source_query_rejected':True,'cloud_requests':False,'hardware_access':False,'responses':responses}
out=root/'sim/results/mcp_check.json';out.parent.mkdir(exist_ok=True);out.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print('MCP subprocess: initialize, 4 tools, missing-source rejection PASS')
