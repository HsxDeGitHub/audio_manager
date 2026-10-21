"""供 Swift 契约测试启动的合成本机服务；仅使用调用方创建的临时目录。"""
import asyncio
from contextlib import asynccontextmanager
import json
from pathlib import Path
import socket
import sys

from fastapi.responses import JSONResponse, RedirectResponse
import uvicorn

from conftest import make_legacy
from interview_backend.app import create_app
from interview_backend.config import Settings


def main():
    directory = Path(sys.argv[1])
    # 必须是新建的测试目录；不能覆盖调用方已有的资料库。
    if not directory.is_dir() or any(directory.iterdir()):
        raise ValueError('合成服务只接受空测试目录。')
    make_legacy(directory / 'library.sqlite')
    app = create_app(Settings(data_dir=directory, token='synthetic-backend-token'))
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
        original_lifespan = app.router.lifespan_context

        @asynccontextmanager
        async def lifespan(instance):
            async with original_lifespan(instance):
                ready = directory / 'ready.tmp'
                ready.write_text(json.dumps({'url': f'http://127.0.0.1:{port}'}))
                ready.replace(directory / 'ready.json')
                yield

        app.router.lifespan_context = lifespan

        @app.middleware('http')
        async def transport_cases(request, call_next):
            path = request.url.path
            if path == '/api/v1/recordings/fixture-redirect':
                return RedirectResponse(f'http://127.0.0.1:{port}/fixture-redirect-target', status_code=302)
            if path == '/fixture-redirect-target':
                (directory / 'redirect-followed').touch()
                return JSONResponse({})
            if path in ['/api/v1/recordings/fixture-timeout', '/api/v1/recordings/fixture-cancel']:
                if path.endswith('fixture-cancel'):
                    (directory / 'cancel-started').touch()
                await asyncio.sleep(5)
            return await call_next(request)

        server = uvicorn.Server(uvicorn.Config(app, log_level='critical', access_log=False,
                                              timeout_graceful_shutdown=1))
        server.run(sockets=[listener])


if __name__ == '__main__':
    main()
