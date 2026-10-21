import argparse
from dataclasses import asdict
import json
from pathlib import Path
import sys

from interview_backend.config import Settings
from interview_backend.errors import DomainError


def main():
    parser = argparse.ArgumentParser(description='听阅本地业务服务与安全导入工具')
    parser.add_argument('--data-dir', type=Path, help='独立数据根目录')
    commands = parser.add_subparsers(dest='command', required=True)
    serve = commands.add_parser('serve', help='启动本机业务服务')
    serve.add_argument('--host', choices=['127.0.0.1'], default='127.0.0.1', help='仅允许本机回环地址')
    serve.add_argument('--port', type=int, default=8765, help='本机服务端口')
    serve.add_argument('--ready-file', type=Path)
    serve.add_argument('--parent-pid', type=int)
    importer = commands.add_parser('import-legacy', help='只读复制旧库至独立后端资料库')
    importer.add_argument('--source', type=Path, required=True, help='旧库或测试副本路径')
    args = parser.parse_args()
    settings = Settings.from_env(args.data_dir)
    try:
        if args.command == 'import-legacy':
            from interview_backend.legacy import initialize_database
            print(json.dumps(asdict(initialize_database(settings, args.source)), ensure_ascii=False))
        else:
            if not 0 <= args.port <= 65535:
                raise ValueError('端口需在 0 至 65535 之间。')
            from interview_backend.app import create_app
            from interview_backend.lifecycle import serve
            serve(create_app(settings), settings, args.port, args.ready_file, args.parent_pid)
    except (DomainError, ValueError) as error:
        print(f'无法完成操作：{error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
