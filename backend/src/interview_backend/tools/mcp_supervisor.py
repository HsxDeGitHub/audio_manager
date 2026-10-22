"""管理外部 stdio 工具生命线，协议管道仍由官方 SDK 直接使用。

SDK 取消时可能直接 KILL 它的子进程；独立观察进程通过非继承管道检测这种退出，
再清理本次专属工具组。观察进程不持有 MCP 标准流，也不扫描用户进程。
"""
import argparse
import os
import select
import signal
import subprocess
import sys
import time


def terminate_group(group):
    try:
        os.killpg(group, signal.SIGTERM)
    except ProcessLookupError:
        return
    time.sleep(.5)
    try:
        os.killpg(group, signal.SIGKILL)
    except ProcessLookupError:
        pass


def start_guard(owner):
    reader, writer = os.pipe()
    ready_reader, ready_writer = os.pipe()
    try:
        guard = os.fork()
    except OSError:
        for descriptor in (reader, writer, ready_reader, ready_writer):
            os.close(descriptor)
        raise
    if guard == 0:
        try:
            os.close(writer); os.close(ready_reader)
            # 脱离 SDK 的工具组，避免 SDK 取消时连观察进程一起杀掉。
            os.setsid()
            for descriptor in (0, 1, 2):
                os.close(descriptor)
            os.write(ready_writer, b'1'); os.close(ready_writer)
            while os.getppid() == owner:
                if select.select([reader], [], [], .05)[0] and not os.read(reader, 1):
                    break
            terminate_group(owner)
        finally:
            os._exit(0)
    os.close(reader); os.close(ready_writer)
    try:
        if not select.select([ready_reader], [], [], 2)[0] or os.read(ready_reader, 1) != b'1':
            os.close(writer)
            raise OSError('生命线观察进程未就绪')
    finally:
        os.close(ready_reader)
    return writer, guard


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
        lifeline, guard = start_guard(os.getpid())
    except OSError:
        print('外部工具生命线未就绪，已拒绝启动。', file=sys.stderr)
        return 127
    try:
        try:
            child = subprocess.Popen(command, stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr)
        except OSError:
            print('外部工具启动失败。', file=sys.stderr)
            return 127
        while not stopping and os.getppid() == args.parent_pid and child.poll() is None:
            if os.waitpid(guard, os.WNOHANG)[0]:
                # 观察者异常退出时，在仍持有的专属组内停止工具。
                terminate_group(os.getpgrp())
                break
            time.sleep(.05)
    finally:
        # 此描述符默认不可继承，工具不能意外延长监督进程的生命线。
        os.close(lifeline)
        try:
            os.waitpid(guard, 0)
        except ChildProcessError:
            terminate_group(os.getpgrp())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
