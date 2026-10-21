"""只管理本服务自己的进程组；不建立常驻服务。"""
from contextlib import asynccontextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import threading
import time


def serve(app, settings, port, ready_file=None, parent_pid=None):
    import uvicorn
    settings.backend_dir.mkdir(parents=True, exist_ok=True)
    lock = open(settings.backend_dir / '.service.lock', 'a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise ValueError('此资料库已有本地服务，请回到正在运行的应用。') from None
    managed = parent_pid is not None
    if managed and os.getpgrp() != os.getpid():
        os.setsid()
    ready = Path(ready_file) if ready_file else None
    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', port))
            actual_port = listener.getsockname()[1]
            original = app.router.lifespan_context

            @asynccontextmanager
            async def lifespan(instance):
                async with original(instance):
                    if ready:
                        ready.parent.mkdir(parents=True, exist_ok=True)
                        temporary = ready.with_suffix('.tmp')
                        temporary.write_text(json.dumps({'url': f'http://127.0.0.1:{actual_port}'}))
                        temporary.chmod(0o600)
                        temporary.replace(ready)
                    yield

            app.router.lifespan_context = lifespan
            server = uvicorn.Server(uvicorn.Config(app, access_log=False, log_level='critical', timeout_graceful_shutdown=2))
            finished = threading.Event()
            if managed:
                def stop():
                    server.should_exit = True
                    # 失联后硬上限，避免无法响应取消的第三方子进程无限存活。
                    if not finished.wait(6):
                        os.killpg(os.getpgrp(), signal.SIGKILL)
                def lifeline():
                    try:
                        while os.read(0, 1):
                            pass
                    finally:
                        stop()
                def parent_watch():
                    while not finished.wait(0.5):
                        if os.getppid() != parent_pid:
                            stop()
                            return
                threading.Thread(target=lifeline, daemon=True).start()
                threading.Thread(target=parent_watch, daemon=True).start()
            try:
                server.run(sockets=[listener])
            finally:
                finished.set()
    finally:
        if ready:
            ready.unlink(missing_ok=True)
        lock.close()
