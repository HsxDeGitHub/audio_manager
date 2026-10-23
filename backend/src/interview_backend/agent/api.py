import asyncio
import json
import time
import uuid
from typing import Annotated
from fastapi import APIRouter, Header, Query
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, ConfigDict, Field, StringConstraints
from interview_backend.errors import DomainError
from interview_backend.services.common import encode, require
from interview_backend.agent.streaming import output_snapshot


class NewSession(BaseModel):
    title: str = '新对话'
    scope: dict = Field(default_factory=dict)


class RenameSession(BaseModel):
    model_config = ConfigDict(extra='forbid')
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]


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
            return {'items': [dict(r) for r in c.execute('SELECT * FROM sessions WHERE deleted=0 ORDER BY created_at DESC,id')]}

    @staticmethod
    def require_session(c, session_id):
        row = require(c, 'sessions', session_id)
        if row['deleted']:
            raise DomainError('not_found', '该会话已删除。', 404)
        return row

    def create_session(self, body: NewSession):
        identifier = str(uuid.uuid4())
        with self.database.transaction(True) as c:
            c.execute('INSERT INTO sessions(id,title,scope,created_at) VALUES(?,?,?,?)', (identifier, body.title, encode(body.scope), time.time()))
        return {'id': identifier, 'title': body.title}

    def rename_session(self, session_id: str, body: RenameSession):
        with self.database.transaction(True) as c:
            self.require_session(c, session_id)
            c.execute('UPDATE sessions SET title=?,title_edited=1 WHERE id=?', (body.title, session_id))
        return {'id': session_id, 'title': body.title}

    def delete_session(self, session_id: str):
        with self.database.transaction(True) as c:
            row = require(c, 'sessions', session_id)
            if row['deleted']:
                return {'id': session_id, 'deleted': True}
            if c.execute("SELECT 1 FROM agent_runs WHERE session_id=? AND state IN ('queued','running')", (session_id,)).fetchone():
                raise DomainError('session_busy', '此会话仍在生成，请先停止或等待完成后再删除。', 409)
            from interview_backend.services.device import DeviceService
            for run in c.execute('SELECT id FROM agent_runs WHERE session_id=?', (session_id,)).fetchall():
                DeviceService.cancel_run(c, run['id'])
            c.execute('UPDATE sessions SET deleted=1 WHERE id=?', (session_id,))
        return {'id': session_id, 'deleted': True}

    def history(self, session_id, before=None, limit=50):
        with self.database.transaction() as c:
            self.require_session(c, session_id)
            clause = ''; parameters = [session_id]
            if before:
                cursor = require(c, 'agent_runs', before)
                if cursor['session_id'] != session_id:
                    raise DomainError('invalid_cursor','历史位置不属于当前会话。',422)
                clause = ' AND (created_at<? OR (created_at=? AND id<?))'
                parameters += [cursor['created_at'],cursor['created_at'],cursor['id']]
            rows = c.execute('SELECT * FROM agent_runs WHERE session_id=?'+clause+' ORDER BY created_at DESC,id DESC LIMIT ?',parameters+[limit+1]).fetchall()
            page = rows[:limit]
            message_ids = {r['message_id'] for r in page}; run_ids = {r['id'] for r in page}
            # 用 SQL 限定本页消息，避免加载整个会话后在内存切片。
            items = []
            if page:
                placeholders = ','.join('?' for _ in page)
                items = [{**dict(r),'context':json.loads(r['context'])} for r in c.execute(
                    f"SELECT * FROM messages WHERE session_id=? AND (id IN ({placeholders}) OR (role='assistant' AND json_extract(context,'$.run_id') IN ({placeholders}))) ORDER BY created_at,id",
                    [session_id]+sorted(message_ids)+sorted(run_ids))]
            return {'items':items,
                    'runs':[{**dict(r),'context':json.loads(r['context']),'result':self.current_result(c,r),'output':output_snapshot(c,r['id'])} for r in reversed(page)],
                    'has_more':len(rows)>limit,'before':page[-1]['id'] if page else None}

    def conversation(self, session_id):
        rounds=[]; remaining=16000; omitted=False
        with self.database.transaction() as c:
            rows=c.execute("SELECT m.content,m.context,r.result FROM agent_runs r JOIN messages m ON m.id=r.message_id WHERE r.session_id=? AND r.state IN ('completed','awaiting_input') ORDER BY r.created_at DESC,r.id DESC LIMIT 7",(session_id,)).fetchall()
        for row in rows[:6]:
            result=json.loads(row['result']) if row['result'] else {}
            question=row['content']; answer=result.get('answer','')
            if not answer:continue
            quotes=json.loads(row['context']).get('quotes',[])
            quote_length=len(encode(quotes)) if quotes else 0
            if len(question)+len(answer)+quote_length>remaining:
                omitted=True
                if rounds:break
                # 超长最近轮次保留带标记的首尾；不把节选伪装为完整历史。
                budget=remaining//2-16
                def excerpt(value):
                    return value if len(value)<=budget else value[:budget//2]+'\n[较早内容已省略]\n'+value[-budget//2:]
                question,answer=excerpt(question),excerpt(answer)
                quotes=[]; quote_length=0
            remaining-=len(question)+len(answer)+quote_length
            user={'role':'user','content':question}
            if quotes:user['selected_quotes']=quotes
            rounds.insert(0,[user,{'role':'assistant','content':answer}])
        return [message for pair in rounds for message in pair], omitted or len(rows)>6

    async def start(self, body):
        # 响应丢失后的幂等重试不能先重新冻结已由该运行修改的版本。
        with self.database.transaction() as c:
            self.require_session(c,body.session_id)
            prior=c.execute('SELECT * FROM messages WHERE id=?',(body.message_id,)).fetchone()
            if prior:
                original=json.loads(prior['context'])
                if prior['session_id']!=body.session_id or prior['content']!=body.instruction or ('request_context' in original and original['request_context']!=body.context):
                    raise DomainError('message_conflict','消息标识已用于不同指令或范围。',409)
                run=c.execute('SELECT id,state FROM agent_runs WHERE message_id=?',(body.message_id,)).fetchone()
                return {'id':run['id'],'state':run['state']}
        semantic = hasattr(self.engine, 'prepare_context')
        context = self.evidence.freeze(body.context, body.instruction, semantic=True) if semantic else self.evidence.freeze(body.context, body.instruction)
        context['request_context']=body.context
        context['conversation_history'],context['history_omitted']=self.conversation(body.session_id)
        if not hasattr(self.engine, 'prepare_context') and hasattr(self.engine, 'reports') and __import__('re').search(r'本周|这周|周报', body.instruction):
            context['report_plan'] = self.engine.reports.freeze(context, body.instruction)
        context['instruction'] = body.instruction
        context['message_id'] = body.message_id
        context['session_id'] = body.session_id
        from interview_backend.agent.proposals import pending
        with self.database.transaction() as c:
            context['pending_proposals'] = pending(c, context)
        if hasattr(self.engine, 'prepare_context'):
            context['intent_policy'] = 'semantic-v2'
            # 周报由语义分类决定；不因资料或主题里出现“本周”而重选目标。
            context.pop('report_plan', None)
        identifier = str(uuid.uuid4())
        with self.database.transaction(True) as c:
            self.require_session(c, body.session_id)
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
            c.execute("UPDATE sessions SET title=? WHERE id=? AND title='新对话' AND title_edited=0", (' '.join(body.instruction.split())[:24],body.session_id))
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
            if context.get('intent_policy') in {'semantic-v1', 'semantic-v2'} and not context.get('task_intent'):
                context = await self.engine.prepare_context(identifier, context, emit)
                with self.database.transaction(True) as c:
                    c.execute('UPDATE agent_runs SET context=? WHERE id=?', (encode(context), identifier))
                    c.execute('UPDATE messages SET context=? WHERE id=?', (encode(context), run['message_id']))
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
            self.require_session(c, row['session_id'])
            return {**row, 'context': json.loads(row['context']), 'result': self.current_result(c,row), 'output':output_snapshot(c,identifier)}

    async def cancel(self, identifier):
        with self.database.transaction(True) as c:
            run = require(c, 'agent_runs', identifier)
            self.require_session(c, run['session_id'])
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
            self.require_session(c, run['session_id'])
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
            row = require(c, 'agent_runs', identifier)
            self.require_session(c, row['session_id'])
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
    def history(session_id: str, before: str | None = None, limit: int = Query(50, ge=1, le=100)): return service.history(session_id, before, limit)
    @api.patch('/sessions/{session_id}')
    def rename_session(session_id: str, body: RenameSession): return service.rename_session(session_id, body)
    @api.delete('/sessions/{session_id}')
    def delete_session(session_id: str): return service.delete_session(session_id)
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
