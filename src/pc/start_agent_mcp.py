"""Launch a local MCP client subprocess; stdout is reserved for JSON-RPC."""
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / 'host'))
from app.agent_mcp import ReviewMCP
from app.agent_tools import AgentSource
from app.agent_joycode import SelectedSource


def main():
    parser = argparse.ArgumentParser(description='ExamGuard只读证据MCP（本机stdio）')
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument('--session', type=Path)
    selection.add_argument('--current-session-file', type=Path, help='跟随上位机明确选定的会话；未就绪时不回退旧存档')
    parser.add_argument('--evidence-root', type=Path, default=Path(__file__).resolve().parent / 'host' / 'evidence_out')
    parser.add_argument('--audit-log', type=Path, help='本次PC请求的本机工具回执记录')
    parser.add_argument('--max-tool-calls', type=int, choices=range(1, 7))
    args = parser.parse_args()
    if args.session is not None and not args.session.is_file():
        parser.error('指定会话不存在')
    source = (AgentSource(args.session.resolve(), args.evidence_root.resolve(), label='MCP指定存档复核（非实时在线证明）')
              if args.session is not None else None)
    source_provider = SelectedSource(args.current_session_file) if args.current_session_file else None
    def audit(record):
        with args.audit_log.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + '\n')
    ReviewMCP(source, audit=audit if args.audit_log else None,
              max_calls=args.max_tool_calls, source_provider=source_provider).serve(sys.stdin.buffer, sys.stdout.buffer)


if __name__ == '__main__':
    main()
