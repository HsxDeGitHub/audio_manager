#!/usr/bin/env python3
"""用临时资料启动真实本机开发服务，验证认证、工具调用和停止后的端口回收。"""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def main():
    root = Path(__file__).resolve().parent.parent
    python = root / 'backend/.venv/bin/python'
    if not python.exists():
        raise RuntimeError('请先执行 uv sync --project backend --group dev。')
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    token = secrets.token_urlsafe(32)
    base_url = f'http://127.0.0.1:{port}'
    with tempfile.TemporaryDirectory(prefix='interview-backend-smoke-') as directory:
        process = subprocess.Popen([str(python), '-m', 'interview_backend', '--data-dir', directory,
            'serve', '--port', str(port)], cwd=root,
            env={**os.environ, 'INTERVIEW_AUDIO_BACKEND_TOKEN': token},
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 15
            while True:
                try:
                    with urlopen(base_url + '/health', timeout=0.5) as response:
                        assert json.load(response)['status'] == 'ok'
                    break
                except (URLError, TimeoutError):
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('临时服务未能正常启动。') from None
                    time.sleep(0.1)
            try:
                urlopen(base_url + '/api/v1/recordings', timeout=2)
                raise AssertionError('未认证请求未被拒绝。')
            except HTTPError as error:
                assert error.code == 401
            request = Request(base_url + '/api/v1/system/status', headers={'Authorization': 'Bearer ' + token})
            with urlopen(request, timeout=2) as response:
                status = json.load(response)
            assert status['counts']['recordings'] == 0
            assert status['capabilities']['agent'] is True
            request = Request(base_url + '/api/v1/tools/library.list_recordings/invoke',
                data=json.dumps({'arguments': {'limit': 1}}).encode(),
                headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
            with urlopen(request, timeout=2) as response:
                assert json.load(response)['data']['items'] == []
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            process.communicate(timeout=2)
        with socket.socket() as probe:
            probe.settimeout(0.5)
            if probe.connect_ex(('127.0.0.1', port)) == 0:
                raise RuntimeError('临时服务停止后端口未释放。')
    print(json.dumps({'状态': '通过', '真实服务启动': True, '认证与工具调用': True,
                      '子进程已结束': True, '监听端口已释放': True}, ensure_ascii=False))


if __name__ == '__main__':
    main()
