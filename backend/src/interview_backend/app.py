from contextlib import asynccontextmanager
import sqlite3
import secrets
import uuid

from fastapi import FastAPI, Query
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from sqlalchemy.exc import SQLAlchemyError
from starlette.exceptions import HTTPException

from interview_backend import __version__, schemas
from interview_backend.config import Settings
from interview_backend.database import Database
from interview_backend.errors import DomainError, error_body
from interview_backend.legacy import initialize_database
from interview_backend.repository import LibraryRepository
from interview_backend.services.library import LibraryService, LibraryCommand
from interview_backend.services.jobs import JobService
from interview_backend.tools.catalog import build_catalog
from interview_backend.tools.registry import ToolContext, ToolInvocation


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.validate_service()

    @asynccontextmanager
    async def lifespan(app):
        initialize_database(settings)
        database = Database(settings.database_path)
        app.state.database = database
        app.state.repository = LibraryRepository(database)
        app.state.library = LibraryService(database)
        app.state.jobs = JobService(database, app.state.library)
        app.state.jobs.recover()
        app.state.tools = build_catalog(app.state.repository)
        try:
            yield
        finally:
            database.close()

    app = FastAPI(title='听阅本地业务后端', version=__version__, lifespan=lifespan)

    @app.middleware('http')
    async def authenticate(request, call_next):
        if request.url.path != '/health':
            authorization = request.headers.get('Authorization', '')
            expected = 'Bearer ' + settings.token
            if not authorization.isascii() or not secrets.compare_digest(authorization, expected):
                return JSONResponse(error_body('unauthorized', '本地会话未认证。'), status_code=401,
                                    headers={'WWW-Authenticate': 'Bearer'})
        return await call_next(request)

    @app.exception_handler(DomainError)
    async def domain_error(_, error):
        return JSONResponse(error_body(error.code, error.message), status_code=error.status_code)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(_, error):
        return JSONResponse(error_body('invalid_request', '请求参数不合法。'), status_code=422)

    @app.exception_handler(sqlite3.Error)
    @app.exception_handler(SQLAlchemyError)
    async def database_error(_, error):
        return JSONResponse(error_body('database_unavailable', '资料库暂时不可用，请稍后重试。'), status_code=503)

    @app.exception_handler(ValidationError)
    async def invalid_stored_data(_, error):
        return JSONResponse(error_body('invalid_stored_data', '资料结构不符合约定，请检查备份。'), status_code=503)

    @app.exception_handler(HTTPException)
    async def http_error(_, error):
        return JSONResponse(error_body('http_error', '请求的接口不可用或不支持此操作。'), status_code=error.status_code)

    @app.get('/health')
    def health():
        return {'status': 'ok', 'service': 'interview-audio-backend', 'version': __version__}

    @app.get('/api/v1/system/status')
    def status():
        return app.state.repository.status()

    @app.get('/api/v1/tools')
    def tools(include_disabled: bool = False):
        return {'items': app.state.tools.list(include_disabled)}

    @app.post('/api/v1/tools/{tool_id}/invoke')
    async def invoke_tool(tool_id: str, invocation: ToolInvocation):
        context = ToolContext(request_id=str(uuid.uuid4()), operation_id=invocation.operation_id)
        return await app.state.tools.execute(tool_id, invocation.arguments, context)

    @app.get('/api/v1/recordings', response_model=schemas.Page[schemas.Recording])
    def recordings(offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return app.state.repository.recordings(offset, limit)

    @app.get('/api/v1/recordings/{recording_id}', response_model=schemas.Recording)
    def recording(recording_id: str):
        return app.state.repository.recording(recording_id)

    @app.get('/api/v1/recordings/{recording_id}/runs', response_model=schemas.Page[schemas.TranscriptRun])
    def runs(recording_id: str, offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return app.state.repository.runs(recording_id, offset, limit)

    @app.get('/api/v1/transcripts/{run_id}/segments', response_model=schemas.Page[schemas.Segment])
    def segments(run_id: str, offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return app.state.repository.segments(run_id, offset, limit)

    @app.get('/api/v1/transcripts/{run_id}/speakers', response_model=schemas.Page[schemas.Speaker])
    def speakers(run_id: str, offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return app.state.repository.speakers(run_id, offset, limit)

    @app.get('/api/v1/transcripts/{run_id}/drafts', response_model=schemas.Page[schemas.Draft])
    def drafts(run_id: str, offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return app.state.repository.drafts(run_id, offset, limit)

    @app.post('/api/v1/library/execute')
    def library_execute(command: LibraryCommand):
        return app.state.library.execute(command)

    @app.post('/api/v1/jobs/start')
    def start_job(request: dict):
        return app.state.jobs.start(request)

    @app.post('/api/v1/jobs/event')
    def job_event(body: dict):
        return app.state.jobs.event(body['request'], body['event'])

    @app.post('/api/v1/jobs/{job_id}/stop')
    def stop_job(job_id: str, body: dict):
        return app.state.jobs.stop(job_id, body['state'])

    return app
