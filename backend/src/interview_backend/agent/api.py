import asyncio
import json
import time
import uuid
from fastapi import APIRouter, Header
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from interview_backend.errors import DomainError
from interview_backend.services.common import encode, require
from interview_backend.agent.streaming import output_snapshot


class NewSession(BaseModel):
    title: str = '新对话'
    scope: dict = Field(default_factory=dict)


class NewRun(BaseModel):
    model_config = ConfigDict(extra='forbid')
    session_id: str
    message_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    instruction: str = Field(min_length=1, max_length=20000)
    context: dict = Field(default_factory=dict)


class AgentAPI:
    def __init__(self, database, engine, evidence):
        self.database, self.engine, self.evidence = database, engine, evidence
        self.tasks = {}

    async def close(self):
        pending = list(self.tasks.values())
        for task in pending: task.cancel()
        if pending: await asyncio.gather(*pending, return_exceptions=True)

    def sessions(self):
        with self.database.transaction() as c:
            return {'items': [dict(r) for r in c.execute('SELECT * FROM sessions ORDER BY created_at DESC,id')]}

    def create_session(self, body: NewSession):
        identifier = str(uuid.uuid4())
        with self.database.transaction(True) as c:
            c.execute('INSERT INTO sessions VALUES(?,?,?,?)', (identifier, body.title, encode(body.scope), time.time()))
        return {'id': identifier, 'title': body.title}

    def history(self, session_id):
        with self.database.transaction() as c:
            require(c, 'sessions', session_id)
            return {'items': [{**dict(r), 'context': json.loads(r['context'])} for r in c.execute('SELECT * FROM messages WHERE session_id=? ORDER BY created_at,id', (session_id,))],
                    'runs': [{**dict(r), 'context': json.loads(r['context']), 'result': self.current_result(c,r), 'output':output_snapshot(c,r['id'])} for r in c.execute('SELECT * FROM agent_runs WHERE session_id=? ORDER BY created_at,id', (session_id,))]}

    def conversation(self, session_id):
        rounds=[]; remaining=16000; omitted=False
        with self.database.transaction() as c:
            rows=c.execute("SELECT m.content,r.result FROM agent_runs r JOIN messages m ON m.id=r.message_id WHERE r.session_id=? AND r.state IN ('completed','awaiting_input') ORDER BY r.created_at DESC,r.id DESC LIMIT 7",(session_id,)).fetchall()
        for row in rows[:6]:
            result=json.loads(row['result']) if row['result'] else {}
            question=row['content']; answer=result.get('answer','')
            if not answer:continue
            if len(question)+len(answer)>remaining:
                omitted=True
                if rounds:break
                # 超长最近轮次保留带标记的首尾；不把节选伪装为完整历史。
                budget=remaining//2-16
                def excerpt(value):
                    return value if len(value)<=budget else value[:budget//2]+'\n[较早内容已省略]\n'+value[-budget//2:]
                question,answer=excerpt(question),excerpt(answer)
            remaining-=len(question)+len(answer)
            rounds.insert(0,[{'role':'user','content':question},{'role':'assistant','content':answer}])
        return [message for pair in rounds for message in pair], omitted or len(rows)>6

    async def start(self, body):
        # 响应丢失后的幂等重试不能先重新冻结已由该运行修改的版本。
        with self.database.transaction() as c:
            require(c,'sessions',body.session_id)
            prior=c.execute('SELECT * FROM messages WHERE id=?',(body.message_id,)).fetchone()
            if prior:
                original=json.loads(prior['context'])
                if prior['session_id']!=body.session_id or prior['content']!=body.instruction or ('request_context' in original and original['request_context']!=body.context):
                    raise DomainError('message_conflict','消息标识已用于不同指令或范围。',409)
                run=c.execute('SELECT id,state FROM agent_runs WHERE message_id=?',(body.message_id,)).fetchone()
                return {'id':run['id'],'state':run['state']}
        context = self.evidence.freeze(body.context, body.instruction)
        context['request_context']=body.context
        context['conversation_history'],context['history_omitted']=self.conversation(body.session_id)
        if hasattr(self.engine, 'reports') and __import__('re').search(r'本周|这周|周报', body.instruction):
            context['report_plan'] = self.engine.reports.freeze(context, body.instruction)
        context['instruction'] = body.instruction
        context['message_id'] = body.message_id
        context['session_id'] = body.session_id
        identifier = str(uuid.uuid4())
        with self.database.transaction(True) as c:
            require(c, 'sessions', body.session_id)
            prior = c.execute('SELECT * FROM messages WHERE id=?', (body.message_id,)).fetchone()
            if prior:
                run = c.execute('SELECT id FROM agent_runs WHERE message_id=?', (body.message_id,)).fetchone()
                if prior['session_id'] != body.session_id or prior['content'] != body.instruction:
                    raise DomainError('message_conflict', '消息标识已用于不同指令。', 409)
                return {'id': run[0], 'state': require(c, 'agent_runs', run[0])['state']}
            if c.execute("SELECT 1 FROM agent_runs WHERE session_id=? AND state IN ('queued','running')", (body.session_id,)).fetchone():
                raise DomainError('session_busy', '此会话仍有运行任务，请先取消或等待。', 409)
            c.execute("UPDATE agent_runs SET state='completed' WHERE session_id=? AND state='awaiting_input'", (body.session_id,))
            c.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', (body.message_id, body.session_id, 'user', body.instruction, encode(context), time.time()))
            c.execute('INSERT INTO agent_runs VALUES(?,?,?,?,?,?,?)', (identifier, body.session_id, body.message_id, 'queued', encode(context), None, time.time()))
            c.execute("UPDATE sessions SET title=? WHERE id=? AND title='新对话'", (' '.join(body.instruction.split())[:24],body.session_id))
        self.tasks[identifier] = asyncio.create_task(self._execute(identifier))
        return {'id': identifier, 'state': 'queued'}

    async def emit(self, run_id, kind, payload):
        with self.database.transaction(True) as c:
            self.append_event(c, run_id, kind, payload)

    @staticmethod
    def append_event(c, run_id, kind, payload):
        sequence = c.execute('SELECT coalesce(max(seq),0)+1 FROM events WHERE run_id=?', (run_id,)).fetchone()[0]
        c.execute('INSERT INTO events VALUES(?,?,?,?)', (run_id, sequence, kind, encode(payload)))
        if kind=='coverage':c.execute('INSERT INTO agent_work VALUES(?,?,?) ON CONFLICT(run_id,step_key) DO UPDATE SET payload=excluded.payload',(run_id,'coverage',encode(payload)))

    async def _execute(self, identifier):
        try:
            with self.database.transaction(True) as c:
                run = require(c, 'agent_runs', identifier)
                c.execute("UPDATE agent_runs SET state='running' WHERE id=?", (identifier,))
            context = json.loads(run['context'])
            await self.emit(identifier, 'started', {'state': 'running'})
            attempt=str(uuid.uuid4())
            await self.emit(identifier,'answer_reset',{'attempt_id':attempt})
            async def emit(kind,payload):
                if kind in {'answer_start','answer_delta'}:payload={**payload,'attempt_id':attempt}
                await self.emit(identifier,kind,payload)
            result = await self.engine.execute(identifier, context['instruction'], context, emit=emit)
            if hasattr(self.engine, 'automatic_memory') and not result.get('clarification'):
                try: result['memories'] = await self.engine.automatic_memory.extract(context, result=result)
                except Exception: await self.emit(identifier, 'memory_pending', {'message':'自动记忆尚未完成，当前回答已保留。'})
            state = 'awaiting_input' if result.get('clarification') else 'interrupted' if result.get('incomplete') else 'completed'
            with self.database.transaction(True) as c:
                c.execute('UPDATE agent_runs SET state=?,result=? WHERE id=?', (state, encode(result), identifier))
                c.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', (str(uuid.uuid4()), run['session_id'], 'assistant', result['answer'], encode({'run_id': identifier}), time.time()))
                self.append_event(c, identifier, 'completed', {'state': state, 'result': result})
        except asyncio.CancelledError:
            with self.database.transaction(True) as c:
                c.execute("UPDATE agent_runs SET state='interrupted' WHERE id=? AND state IN ('queued','running')", (identifier,))
                self.append_event(c, identifier, 'interrupted', {'state': require(c, 'agent_runs', identifier)['state']})
        except Exception as error:
            code = error.code if isinstance(error, DomainError) else 'agent_failed'
            message = error.message if isinstance(error, DomainError) else '运行失败，可检查配置后继续。'
            with self.database.transaction(True) as c:
                result = self.with_changes({'error': {'code': code, 'message': message}}, identifier)
                c.execute("UPDATE agent_runs SET state='failed',result=? WHERE id=?", (encode(result), identifier))
                self.append_event(c, identifier, 'failed', result)
        finally:
            if self.tasks.get(identifier) is asyncio.current_task(): self.tasks.pop(identifier, None)

    def with_changes(self, result, identifier):
        from interview_backend.agent.work import WorkLog
        progress=WorkLog(self.database,identifier).get('finalization_result')
        if progress:
            if (result or {}).get('error'):
                progress={k:v for k,v in progress.items() if k not in {'claims','questions'}}
                if result['error']['code'] in {'stale_source','stale_context'}:progress.pop('answer',None)
            result={**progress,**(result or {})}
        changes = self.evidence.committed(identifier)
        if not changes: return result
        result = dict(result or {})
        result['changesets'] = changes
        if len(changes) == 1: result['changeset'] = changes[0]
        result.setdefault('answer', '已提交的修改已保留，可查看差异或撤销。')
        return result

    def current_result(self, c, row):
        result = json.loads(row['result']) if row['result'] else None
        result = self.with_changes(result, row['id'])
        from interview_backend.agent.work import WorkLog
        work=WorkLog(self.database,row['id'])
        progress=work.get('coverage_progress')
        coverage=progress['coverage'] if progress else work.get('coverage')
        if not coverage:
            last=c.execute("SELECT payload FROM events WHERE run_id=? AND kind='coverage' ORDER BY seq DESC LIMIT 1",(row['id'],)).fetchone()
            coverage=json.loads(last[0]) if last else None
        if coverage and (row['state']!='completed' or not (result or {}).get('coverage')):result={**(result or {}),'coverage':coverage}
        if row['state'] in {'failed','cancelled','interrupted'}:
            partial=work.get('part_results')
            values=[]
            for part in (partial or {}).get('items',{}).values():
                if not work.valid(part.get('dependencies',[])):continue
                try:self.evidence.validate_result(part['result'],part['context'],self.evidence.committed(row['id']))
                except DomainError:continue
                values.append({'answer':part['result'].get('answer',''),'part_ids':part['part_ids']})
            if values:result={**(result or {}),'partial_results':values}
        return result

    def get(self, identifier):
        with self.database.transaction() as c:
            row = require(c, 'agent_runs', identifier)
            return {**row, 'context': json.loads(row['context']), 'result': self.current_result(c,row), 'output':output_snapshot(c,identifier)}

    async def cancel(self, identifier):
        with self.database.transaction(True) as c:
            run = require(c, 'agent_runs', identifier)
            if run['state'] in {'queued','running','awaiting_input'}:
                c.execute("UPDATE agent_runs SET state='cancelled' WHERE id=?", (identifier,))
                from interview_backend.services.device import DeviceService
                DeviceService.cancel_run(c, identifier)
        task = self.tasks.get(identifier)
        if task is not None:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
        return self.get(identifier)

    async def resume(self, identifier):
        run = self.get(identifier)
        if run['state'] not in {'interrupted', 'failed', 'cancelled'}:
            raise DomainError('not_resumable', '当前运行状态不可继续。', 409)
        from interview_backend.agent.work import WorkLog
        WorkLog(self.database,identifier).finalization()
        with self.database.transaction(True) as c:
            if require(c,'agent_runs',identifier)['state'] not in {'interrupted','failed','cancelled'}:
                raise DomainError('not_resumable','当前运行已在恢复或已结束。',409)
            if c.execute("SELECT 1 FROM agent_runs WHERE session_id=? AND id<>? AND state IN ('queued','running')", (run['session_id'], identifier)).fetchone():
                raise DomainError('session_busy', '此会话仍有运行任务，请先取消或等待。', 409)
            changes = self.evidence.committed(identifier)
            sources = list(run['context'].get('sources', []))
            sources += [r for child in run['context'].get('report_plan', {}).get('contexts', {}).values() for r in child.get('resources', [])]
            if any(not self.evidence.valid_after_changes(source, changes) for source in sources):
                raise DomainError('stale_context', '源版本已发生外部变化，请发送基于当前资料的新指令。', 409)
            from interview_backend.services.device import DeviceService
            DeviceService.resume_run(c, identifier)
            c.execute("UPDATE agent_runs SET state='queued' WHERE id=?", (identifier,))
            self.append_event(c, identifier, 'resuming', {'state': 'queued', 'message': '恢复剩余步骤，已完成操作将复用业务回执。'})
        self.tasks[identifier] = asyncio.create_task(self._execute(identifier))
        return {'id': identifier, 'state': 'queued'}

    def events(self, identifier, after):
        with self.database.transaction() as c:
            require(c, 'agent_runs', identifier)
            return [dict(r) for r in c.execute('SELECT * FROM events WHERE run_id=? AND seq>? ORDER BY seq', (identifier, after))]


def router(app):
    class ServiceProxy:
        def __getattr__(self, name): return getattr(app.state.agent, name)
    service = ServiceProxy()
    api = APIRouter(prefix='/api/v1')
    @api.get('/sessions')
    def sessions(): return service.sessions()
    @api.post('/sessions')
    def create_session(body: NewSession): return service.create_session(body)
    @api.get('/sessions/{session_id}')
    def history(session_id: str): return service.history(session_id)
    # 保留类型注解供 FastAPI 区分 JSON 请求体。
    @api.post('/agent/runs')
    async def start(body: NewRun): return await service.start(body)
    @api.post('/sessions/new')
    def create(body: NewSession): return service.create_session(body)
    @api.get('/agent/runs/{identifier}')
    def get(identifier: str): return service.get(identifier)
    @api.post('/agent/runs/{identifier}/cancel')
    async def cancel(identifier: str): return await service.cancel(identifier)
    @api.post('/agent/runs/{identifier}/resume')
    async def resume(identifier: str): return await service.resume(identifier)
    @api.get('/agent/runs/{identifier}/events')
    async def events(identifier: str, after: int = 0, last_event_id: str | None = Header(default=None)):
        try:
            cursor = int(last_event_id) if last_event_id is not None else after
            if cursor < 0: raise ValueError()
        except ValueError:
            raise DomainError('invalid_cursor', '事件序号不合法。', 422) from None
        service.get(identifier)
        async def stream():
            nonlocal cursor
            while True:
                for event in service.events(identifier, cursor):
                    cursor = event['seq']
                    yield f'id: {cursor}\nevent: {event["kind"]}\ndata: {event["payload"]}\n\n'
                if service.get(identifier)['state'] not in {'queued','running'}: return
                yield ': keepalive\n\n'
                await asyncio.sleep(0.2)
        return StreamingResponse(stream(), media_type='text/event-stream', headers={'Cache-Control': 'no-cache'})
    return api
