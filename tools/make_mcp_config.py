from pathlib import Path
import sys,json
root=Path(__file__).resolve().parents[1]
data={'mcpServers':{'examguard':{'type':'stdio','command':sys.executable,'args':['-u',str(root/'src/pc/start_agent_mcp.py'),'--current-session-file',str(root/'src/pc/host/.private/joycode_current_source.json')],'env':{'PYTHONUTF8':'1'}}}}
p=root/'board/pc/mcp_follow_dashboard.json'
p.parent.mkdir(parents=True,exist_ok=True)
p.write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf-8')
print(p)
