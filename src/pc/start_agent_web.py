"""Standalone read-only judge website. Does not open serial ports or start capture."""
import argparse
import getpass
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent / 'host'))
from app.agent_controller import ModelConfig
from app.agent_tools import AgentSource
from app.agent_web import AgentWebService


def main():
    parser = argparse.ArgumentParser(description='ExamGuard可登录的只读复核网页')
    parser.add_argument('--session', required=True, type=Path, help='明确选择本工程的.sqlite3会话')
    parser.add_argument('--evidence-root', type=Path, default=Path(__file__).resolve().parent / 'host' / 'evidence_out')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--public-origin', help='部署后实际HTTPS源地址，例如https://exam.example.com')
    parser.add_argument('--llm', action='store_true', help='启用服务端环境变量配置的大模型工具调用')
    args = parser.parse_args()
    if not args.session.is_file():
        parser.error('指定的会话文件不存在')
    if args.host not in ('localhost', '127.0.0.1') and not args.public_origin:
        parser.error('对外监听需设置--public-origin；默认仅本机访问')
    password = os.environ.get('EXAMGUARD_WEB_PASSWORD') or getpass.getpass('设置网页访问密码（账号judge，至少8位）：')
    config = ModelConfig(os.environ.get('EXAMGUARD_API_BASE', ''), os.environ.get('EXAMGUARD_MODEL', ''),
                         os.environ.get('EXAMGUARD_API_KEY', ''))
    source = AgentSource(args.session.resolve(), args.evidence_root.resolve(), label='指定存档复核（非实时在线证明）')
    try:
        service = AgentWebService(lambda: source, password=password, host=args.host, port=args.port,
                                  mode='llm' if args.llm else 'local', config=config, public_origin=args.public_origin)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    service.start()
    print('ExamGuard复核网页：' + (args.public_origin or service.url))
    print('账号：judge；' + ('大模型API模式，等待真实查询验证' if args.llm else '本地工具演示，尚未接入大模型'))
    print('数据源：' + args.session.name + '；按Ctrl+C停止。')
    try:
        while service.thread.is_alive():
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        service.close()


if __name__ == '__main__':
    main()
