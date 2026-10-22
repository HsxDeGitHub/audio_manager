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
from interview_backend.agent.tools import EvidenceService, install_agent_tools, install_app_tools
from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.api import AgentAPI, router as agent_router
from interview_backend.services.device import DeviceService
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
from interview_backend.tools.mcp_client import MCPClientManager
from interview_backend.observability import AuditLog


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.validate_service()

    def apply_tool_settings(registry, database):
        with database.transaction() as c:
            rows = c.execute('SELECT id, enabled FROM tool_settings').fetchall()
        for row in rows:
            if row['id'] in registry._tools:
                registry.set_enabled(row['id'], bool(row['enabled']))

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
        app.state.device = DeviceService(database)
        install_agent_tools(app.state.tools, app.state.changesets)
        app.state.evidence = EvidenceService(database)
        app.state.memories = MemoryService(database, app.state.evidence)
        app.state.documents = DocumentService(database)
        app.state.retrieval = RetrievalIndex(database, settings.backend_dir)
        install_app_tools(app.state.tools, app.state.changesets, app.state.device, settings,
                          app.state.repository, app.state.retrieval)
        apply_tool_settings(app.state.tools, database)
        app.state.mcp = MCPClientManager(database, app.state.tools)
        app.state.audit = AuditLog(settings.backend_dir / 'logs' / 'backend.jsonl')
        app.state.audit.write('service_started', schema=__version__)
        engine = AgentEngine(settings, app.state.tools, app.state.evidence)
        engine.memory_service = app.state.memories
        engine.automatic_memory = AutomaticMemory(settings, app.state.memories)
        engine.reports = ReportService(database, app.state.evidence)
        engine.retrieval = app.state.retrieval
        app.state.agent = AgentAPI(database, engine, app.state.evidence)
        try:
            yield
        finally:
            app.state.audit.write('service_stopping')
            await app.state.agent.close()
            await app.state.mcp.remove_all()
            database.close()

    app = FastAPI(title='听阅本地业务后端', version=__version__, lifespan=lifespan)

    @app.middleware('http')
    async def authenticate(request, call_next):
        import time
        started = time.monotonic()
        if request.url.path != '/health':
            authorization = request.headers.get('Authorization', '')
            expected = 'Bearer ' + settings.token
            if not authorization.isascii() or not secrets.compare_digest(authorization, expected):
                app.state.audit.write('request_denied', method=request.method, path=request.url.path, status=401)
                return JSONResponse(error_body('unauthorized', '本地会话未认证。'), status_code=401,
                                    headers={'WWW-Authenticate': 'Bearer'})
        response = await call_next(request)
        app.state.audit.write('request', method=request.method, path=request.url.path, status=response.status_code,
                              duration_ms=round((time.monotonic() - started) * 1000, 1))
        return response

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

    @app.post('/api/v1/tools/{tool_id}/enabled')
    def set_tool_enabled(tool_id: str, body: dict):
        enabled = body.get('enabled')
        if type(enabled) is not bool:
            raise DomainError('invalid_request', '工具启停参数不合法。', 422)
        app.state.tools.set_enabled(tool_id, enabled)
        with app.state.database.transaction(True) as c:
            c.execute('INSERT INTO tool_settings VALUES(?,?) ON CONFLICT(id) DO UPDATE SET enabled=excluded.enabled',
                      (tool_id, 1 if enabled else 0))
        return {'id': tool_id, 'enabled': enabled}

    @app.get('/api/v1/mcp/connections')
    def mcp_connections():
        return app.state.mcp.list()

    @app.post('/api/v1/mcp/connections')
    async def save_mcp_connection(body: dict):
        config = app.state.mcp.save(body)
        await app.state.mcp.refresh(config.id)
        apply_tool_settings(app.state.tools, app.state.database)
        return app.state.mcp.list()

    @app.delete('/api/v1/mcp/connections/{identifier}')
    async def remove_mcp_connection(identifier: str):
        await app.state.mcp.remove(identifier)
        return app.state.mcp.list()

    @app.post('/api/v1/mcp/connections/{identifier}/refresh')
    async def refresh_mcp_connection(identifier: str):
        await app.state.mcp.refresh(identifier)
        apply_tool_settings(app.state.tools, app.state.database)
        return app.state.mcp.list()

    @app.post('/api/v1/mcp/refresh')
    async def refresh_all_mcp():
        await app.state.mcp.refresh()
        apply_tool_settings(app.state.tools, app.state.database)
        return app.state.mcp.list()

    @app.post('/api/v1/tools/{tool_id}/invoke')
    async def invoke_tool(tool_id: str, invocation: ToolInvocation):
        spec = app.state.tools._tools.get(tool_id)
        if spec is None:
            raise DomainError('tool_not_found', '指定工具不存在。', 404)
        effects = {'read'}
        if spec.effect != 'read':
            if not invocation.operation_id:
                raise DomainError('operation_id_required', '此类工具需要稳定的操作标识。', 422)
            effects.add(spec.effect)
        context = ToolContext(request_id=str(uuid.uuid4()), operation_id=invocation.operation_id,
                              allowed_effects=frozenset(effects))
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

    @app.post('/api/v1/jobs/queue')
    def queue_job(request: dict):
        return app.state.jobs.start(request, state='queued')

    @app.get('/api/v1/jobs/{job_id}')
    def get_job(job_id: str):
        return app.state.jobs.get(job_id)

    @app.post('/api/v1/jobs/start')
    def start_job(request: dict):
        return app.state.jobs.start(request)

    @app.post('/api/v1/jobs/event')
    def job_event(body: dict):
        return app.state.jobs.event(body['request'], body['event'])

    @app.post('/api/v1/jobs/{job_id}/stop')
    def stop_job(job_id: str, body: dict):
        return app.state.jobs.stop(job_id, body['state'])

    @app.post('/api/v1/device/reconnect')
    def reconnect_device(body: dict):return app.state.device.reconnect(body.get('owner'))

    @app.post('/api/v1/device/commands/{command_id}/reconcile')
    def reconcile_device(command_id: str, body: dict):
        return app.state.device.complete(command_id,body.get('owner'),body.get('state'),body.get('result'),reconcile=True)

    @app.get('/api/v1/device/tasks/{kind}/{identifier}')
    def device_task(kind: str, identifier: str):
        from interview_backend.services.device_tasks import task
        with app.state.database.transaction() as c:return task(c,kind,identifier)

    @app.get('/api/v1/device/commands')
    def pending_device_commands():
        return {'items': app.state.device.pending()}

    @app.get('/api/v1/device/commands/{command_id}')
    def device_command(command_id: str):
        return app.state.device.get(command_id)

    @app.get('/api/v1/device/commands/{command_id}/validate')
    def validate_device_command(command_id: str):
        return app.state.device.validate(command_id)

    @app.post('/api/v1/device/commands/{command_id}/claim')
    def claim_device_command(command_id: str, body: dict):
        return app.state.device.claim(command_id, body.get('owner'))

    @app.post('/api/v1/device/commands/{command_id}/result')
    def finish_device_command(command_id: str, body: dict):
        return app.state.device.complete(command_id, body.get('owner'), body.get('state'), body.get('result'))

    @app.get('/api/v1/changesets')
    def list_changes(offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return app.state.changesets.list(offset, limit)

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
    def resolve_source(kind: str, identifier: str, revision: int = Query(..., ge=1), line: int = Query(1, ge=1), historical: bool = False, block_id: str | None = None):
        if kind not in {'recording','segment','draft','document','speaker','memory','message'}:
            raise DomainError('invalid_source','来源类型不正确。',422)
        from interview_backend.services.sources import resolve
        with app.state.database.transaction() as c:
            return resolve(c,kind,identifier,revision,historical,line,block_id)

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
    @app.get('/api/v1/documents/{identifier}')
    def document(identifier: str): return app.state.documents.get(identifier)
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
