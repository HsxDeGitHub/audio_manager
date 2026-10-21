"""只启动本应用管理的测试服务，验证退出、父进程消失和端口回收。"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.request import urlopen

import pytest


def free_port(port):
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', port))


def wait_ready(process, ready, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if ready.exists():
            value = json.loads(ready.read_text())
            return value['url']
        if process.poll() is not None:
            raise AssertionError('服务在就绪前退出')
        time.sleep(0.05)
    raise AssertionError('服务未在限时内就绪')


def start(tmp_path, parent_pid=None):
    ready = tmp_path / 'ready.json'
    environment = {**os.environ, 'INTERVIEW_AUDIO_BACKEND_TOKEN': 'lifecycle-synthetic-token',
                   'LANGCHAIN_TRACING_V2': 'false', 'LANGSMITH_TRACING': 'false'}
    process = subprocess.Popen([sys.executable, '-m', 'interview_backend', '--data-dir', str(tmp_path / 'data'),
                                'serve', '--port', '0', '--ready-file', str(ready),
                                '--parent-pid', str(parent_pid if parent_pid is not None else os.getpid())],
                               stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               cwd=Path(__file__).resolve().parents[1], env=environment)
    return process, ready


def assert_released(url):
    port = int(url.rsplit(':', 1)[1])
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            free_port(port)
            return
        except OSError:
            time.sleep(0.05)
    raise AssertionError('监听端口未在 10 秒内释放')


def test_stdin_lifeline_and_ready_file_cleanup(tmp_path):
    process, ready = start(tmp_path)
    try:
        url = wait_ready(process, ready)
        with urlopen(url + '/health', timeout=2) as response:
            assert json.load(response)['status'] == 'ok'
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        assert not ready.exists()
        assert_released(url)
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)


def test_forced_termination_releases_port(tmp_path):
    process, ready = start(tmp_path)
    try:
        url = wait_ready(process, ready)
        process.terminate()
        assert process.wait(timeout=10) in {0, -15}
        assert_released(url)
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)


def test_parent_disappearance_triggers_cleanup(tmp_path):
    process, ready = start(tmp_path, parent_pid=999999)
    try:
        assert process.wait(timeout=10) == 0
        assert not ready.exists()
        process.stdin.close()
    finally:
        if process.poll() is None:
            process.kill(); process.wait(timeout=5)
