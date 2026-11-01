"""按监考台保存配置生成本机MCP连接文件；不读取会话内容或访问设备。"""
from pathlib import Path
import argparse,json,sys

ROOT=Path(__file__).resolve().parents[1]
HOST=ROOT/'src/pc/host'
sys.path.insert(0,str(HOST))
from app.services import load_config,storage_paths

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,default=HOST/'launch_config.json',help='与监考台相同的配置文件')
    parser.add_argument('--output',type=Path,default=ROOT/'board/pc/mcp_follow_dashboard.json',help='生成的本机连接文件')
    args=parser.parse_args()
    config=load_config(args.config)
    base=storage_paths(config,HOST)['sessions'].parent
    registry=base/'.private/joycode_current_source.json'
    data={'mcpServers':{'examguard':{'type':'stdio','command':sys.executable,
        'args':['-u',str(ROOT/'src/pc/start_agent_mcp.py'),'--current-session-file',str(registry)],
        'env':{'PYTHONUTF8':'1'}}}}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(args.output)
    print('会话发布位置：'+str(registry))
    print('将生成文件导入JoyCode并启用examguard；监考台选择会话后发布数据来源。')

if __name__=='__main__':main()
