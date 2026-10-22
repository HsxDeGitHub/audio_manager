"""使用真实独立进程组验证外部 MCP 失联回收，不扫描或终止无关进程。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest

pytestmark = pytest.mark.skipif(os.name != 'posix', reason='当前应用的 POSIX 进程组验收')


def alive(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False


@pytest.mark.parametrize('termination', ['parent', 'supervisor'])
def test_supervisor_reaps_stubborn_tool_tree_without_killing_parent(tmp_path, termination):
    worker = tmp_path / 'worker.py'
    worker.write_text('''import json,os,signal,subprocess,sys,time
from pathlib import Path
signal.signal(signal.SIGTERM,signal.SIG_IGN)
child=subprocess.Popen([sys.executable,'-c','import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)'])
Path(sys.argv[1]).write_text(json.dumps({'worker':os.getpid(),'grandchild':child.pid}))
time.sleep(60)
''')
    parent_code = '''import os,subprocess,sys,time
from pathlib import Path
p=subprocess.Popen([sys.executable,'-m','interview_backend.tools.mcp_supervisor','--parent-pid',str(os.getpid()),'--',sys.executable,sys.argv[1],sys.argv[2]],start_new_session=True)
Path(sys.argv[3]).write_text(str(p.pid))
p.wait()
time.sleep(60)
'''
    parent = subprocess.Popen([sys.executable, '-c', parent_code, str(worker), str(tmp_path/'tree.json'), str(tmp_path/'supervisor.pid')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    supervisor = None; tree = {}
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not (tmp_path/'tree.json').exists(): time.sleep(.05)
        assert (tmp_path/'tree.json').exists(), '监督进程未启动真实工具'
        supervisor = int((tmp_path/'supervisor.pid').read_text())
        tree = json.loads((tmp_path/'tree.json').read_text())
        assert all(alive(pid) for pid in [supervisor, *tree.values()])
        start = time.monotonic()
        os.kill(parent.pid if termination == 'parent' else supervisor, signal.SIGTERM)
        while time.monotonic() - start < 4 and any(alive(pid) for pid in [supervisor, *tree.values()]): time.sleep(.05)
        assert not any(alive(pid) for pid in [supervisor, *tree.values()])
        if termination == 'supervisor': assert parent.poll() is None
    finally:
        if parent.poll() is None: parent.terminate()
        parent.wait(timeout=3)
        if supervisor:
            try: os.killpg(supervisor, signal.SIGKILL)
            except ProcessLookupError: pass


def test_supervisor_refuses_nonisolated_process_group(tmp_path):
    sentinel = tmp_path/'must-not-run'
    result = subprocess.run([sys.executable, '-m', 'interview_backend.tools.mcp_supervisor', '--parent-pid', str(os.getpid()), '--', sys.executable, '-c', f'from pathlib import Path;Path({str(sentinel)!r}).touch()'], capture_output=True, timeout=3)
    assert result.returncode == 2 and not sentinel.exists()
