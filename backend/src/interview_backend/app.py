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
from interview_backend.services.changesets import ChangeSetService, ChangeRequest
from interview_backend.agent.tools import EvidenceService, install_agent_tools
from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.api import AgentAPI, router as agent_router
from interview_backend.services.memory import MemoryService
from interview_backend.services.documents import DocumentService
from interview_backend.services.reports import ReportService
from interview_backend.retrieval.index import RetrievalIndex
from interview_backend.agent.memory import AutomaticMemory
from pydantic import BaseModel, Field

class ContentUpdate(BaseModel):
    operation_id: str = Field(min_length=1)
    expected_revision: int = Field(ge=1)
    fields: dict

class DocumentImport(BaseModel):
    operation_id: str
    title: str
    format: str
    content: str
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
        app.state.changesets = ChangeSetService(database)
        install_agent_tools(app.state.tools, app.state.changesets)
        app.state.evidence = EvidenceService(database)
        app.state.memories = MemoryService(database, app.state.evidence)
        app.state.documents = DocumentService(database)
        app.state.retrieval = RetrievalIndex(database, settings.backend_dir)
        engine = AgentEngine(settings, app.state.tools, app.state.evidence)
        engine.memory_service = app.state.memories
        engine.automatic_memory = AutomaticMemory(settings, app.state.memories)
        engine.reports = ReportService(database, app.state.evidence)
        engine.retrieval = app.state.retrieval
        app.state.agent = AgentAPI(database, engine, app.state.evidence)
        try:
            yield
        finally:
            await app.state.agent.close()
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

    @app.post('/api/v1/changesets')
    def submit_changes(body: ChangeRequest):
        return app.state.changesets.submit(body.model_dump())

    @app.post('/api/v1/changesets/{identifier}/revert')
    def revert_changes(identifier: str, body: dict):
        return app.state.changesets.revert(identifier, body['operation_id'])

    @app.post('/api/v1/models/test-tools')
    async def test_tools():
        from interview_backend.agent.models import ModelSettings, tool_call_self_test
        return await tool_call_self_test(ModelSettings.load(settings.data_dir))

    @app.get('/api/v1/sources/{kind}/{identifier}')
    def resolve_source(kind: str, identifier: str, revision: int):
        from interview_backend.services.changesets import read_object
        if kind not in {'recording', 'segment', 'draft', 'document', 'speaker', 'memory', 'message'}:
            raise DomainError('invalid_source', '来源类型不正确。', 422)
        ref = {'resource_type': kind, 'resource_id': identifier, 'revision': revision}
        if not app.state.evidence.valid(ref):
            raise DomainError('stale_source', '来源已变化或移除，不能作为当前证据。', 409)
        with app.state.database.transaction() as c:
            row = read_object(c, kind, identifier)
            result = {'resource_type': kind, 'resource_id': identifier, 'revision': revision, 'text': row.get('content', row.get('edited') if row.get('edited') is not None else row.get('original', ''))}
            if kind in {'segment','draft'}:
                from interview_backend.services.common import require
                result.update({'run_id': row['run_id'], 'recording_id': require(c, 'runs', row['run_id'])['recording_id'], 'segment_id': identifier if kind == 'segment' else None, 'start': row.get('start')})
            return result

    @app.patch('/api/v1/recordings/{identifier}')
    def update_recording(identifier: str, body: ContentUpdate):
        return app.state.library.update_metadata(identifier, body.fields, body.expected_revision, body.operation_id)

    @app.get('/api/v1/memories')
    def memories(): return app.state.memories.list()
    @app.patch('/api/v1/memories/{identifier}')
    def update_memory(identifier: str, body: ContentUpdate):
        return app.state.memories.update(identifier, body.fields, body.expected_revision, body.operation_id)

    @app.get('/api/v1/documents')
    def documents(): return app.state.documents.list()
    @app.post('/api/v1/documents')
    def import_document(body: DocumentImport):
        return app.state.documents.import_text(body.title, body.format, body.content, body.operation_id)
    @app.patch('/api/v1/documents/{identifier}')
    def update_document(identifier: str, body: ContentUpdate):
        return app.state.documents.update(identifier, body.fields, body.expected_revision, body.operation_id)

    @app.get('/api/v1/retrieval/status')
    def retrieval_status(): return app.state.retrieval.semantic.status()
    @app.post('/api/v1/retrieval/prepare')
    def prepare_retrieval(): return app.state.retrieval.semantic.prepare(download=True)
    @app.get('/api/v1/retrieval/search')
    def retrieval_search(q: str, limit: int = Query(8,ge=1,le=50)):
        return {'items':app.state.retrieval.search(q,limit),'semantic':app.state.retrieval.semantic.status()}

    app.include_router(agent_router(app))
    return app
