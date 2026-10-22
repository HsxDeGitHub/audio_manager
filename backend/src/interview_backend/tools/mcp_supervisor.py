"""外部 stdio 工具的进程生命线；协议管道原样继承，不实现或解析 MCP。

SDK 为此启动器建立独立进程组。工具结束、SDK 取消或后端失联后，只清理本组；
最终 KILL 包含监督进程自身，保证忽略 TERM 的工具及同组后代也不会残留。
"""
import argparse
import os
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description='管理本应用外部 stdio 工具生命线')
    parser.add_argument('--parent-pid', type=int, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if os.name != 'posix' or os.getpgrp() != os.getpid() or args.parent_pid <= 1 or not command:
        print('外部工具必须在专属隔离进程组中启动。', file=sys.stderr)
        return 2
    if os.getppid() != args.parent_pid:
        return 0
    stopping = False
    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        child = subprocess.Popen(command, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr)
    except OSError:
        print('外部工具启动失败。', file=sys.stderr)
        return 127
    try:
        while not stopping and os.getppid() == args.parent_pid and child.poll() is None:
            time.sleep(.05)
    finally:
        # 此时进程组仍由本启动器持有，不按名称扫描或终止任何用户进程。
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        os.killpg(os.getpgrp(), signal.SIGTERM)
        time.sleep(.5)
        os.killpg(os.getpgrp(), signal.SIGKILL)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
