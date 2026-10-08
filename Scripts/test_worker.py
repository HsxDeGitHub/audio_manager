#!/usr/bin/env python3
"""Exercise worker process boundaries, durable transcript checkpoints, and cancellation."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
BIN = subprocess.check_output(['swift', 'build', '--disable-sandbox', '--show-bin-path'], cwd=ROOT, text=True).strip()
WORKER = Path(BIN) / 'AudioWorker'

with tempfile.TemporaryDirectory(prefix='interview-worker-') as tmp:
    base = Path(tmp); tools = base / 'tools'; (tools / 'sherpa/bin').mkdir(parents=True)
    # Execute a fresh inode: macOS may retain a cached code signature for incrementally replaced binaries.
    stable_worker = base / 'AudioWorker'
    shutil.copy2(WORKER, stable_worker)
    source = base / '中文 样本.wav'
    with wave.open(str(source), 'wb') as audio:
        audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000); audio.writeframes(b'\0\0' * 16000 * 3)
    fingerprint = hashlib.sha256(source.read_bytes()).hexdigest()
    os.symlink(ROOT / '.runtime/tools/ffmpeg', tools / 'ffmpeg')
    def script(path, code):
        path.write_text('#!/usr/bin/env python3\n' + code); path.chmod(0o755)
    script(tools / 'whisper-cli', '''import json,sys,time,os
from pathlib import Path
args=sys.argv[1:]; prefix=args[args.index('-of')+1]
marker=Path(__file__).parent/'sleep'
if marker.exists():
    (Path(__file__).parent/'child.pid').write_text(str(os.getpid()))
    time.sleep(60)
Path(prefix+'.json').write_text(json.dumps({'transcription':[{'offsets':{'from':1000,'to':2500},'text':'数据库事务'}]}))
''')
    speaker = tools / 'sherpa/bin/sherpa-onnx-offline-speaker-diarization'
    script(speaker, "print('1.000 -- 2.500 speaker_00')\n")
    def request(name, **updates):
        data = dict(jobID=name, recordingID='recording', runID='run', source=str(source), fingerprint=fingerprint,
                    toolsDirectory=str(tools), modelsDirectory=str(base), temporaryDirectory=str(base / 'temporary'), speakersOnly=False)
        data.update(updates)
        path = base / (name + '.json'); path.write_text(json.dumps(data)); return path
    def invoke(path):
        result = subprocess.run([str(stable_worker), str(path)], capture_output=True, text=True, timeout=20)
        return result.returncode, [json.loads(line) for line in result.stdout.splitlines() if line]
    code, events = invoke(request('success'))
    assert code == 0, (code, events)
    assert [e['kind'] for e in events] == ['stage','stage','transcript','stage','diarization','done']
    assert events[2]['segments'][0]['start'] == 1
    assert not (base / 'temporary/success').exists()
    print('PASS 完整协议、毫秒转换和临时文件清理')

    script(speaker, "import sys\nprint('injected speaker failure',file=sys.stderr)\nsys.exit(3)\n")
    code, events = invoke(request('speaker-failure'))
    assert code != 0 and any(e['kind'] == 'transcript' for e in events) and events[-1]['kind'] == 'error'
    assert not (base / 'temporary/speaker-failure').exists()
    print('PASS 说话人区分失败前已交付转写，错误后清理临时文件')

    code, events = invoke(request('changed-file', fingerprint='wrong'))
    assert code != 0 and not any(e['kind'] == 'transcript' for e in events)
    assert '不一致' in events[-1]['message']
    print('PASS 拒绝内容不匹配的音频')

    (tools / 'sleep').touch()
    child = subprocess.Popen([str(stable_worker), str(request('cancel'))], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 8
    while not (tools / 'child.pid').exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert (tools / 'child.pid').exists(), 'worker did not start its child'
    engine_pid = int((tools / 'child.pid').read_text())
    child.terminate(); output, error = child.communicate(timeout=8)
    assert child.returncode != 0
    try:
        os.kill(engine_pid, 0)
        raise AssertionError('recognition child remained running after cancellation')
    except ProcessLookupError:
        pass
    assert not (base / 'temporary/cancel').exists()
    print('PASS 取消任务同时停止识别子进程，并清理临时文件')
