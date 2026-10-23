import asyncio
import json
import pytest
from langchain_core.messages import AIMessage
from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.tools import EvidenceService


class FakeModel:
    def bind_tools(self, tools): return self
    async def ainvoke(self, messages):
        return AIMessage(content=json.dumps({'answer': '资料中的问题已逐项列出。建议按证据准备回答。', 'claims': [{'text': '建议准备回答', 'kind': 'suggestion', 'sources': []}]}))


def test_twenty_questions_are_completely_enumerated_with_valid_sources(client, config):
    database = client.app.state.database
    with database.transaction(True) as c:
        c.execute("DELETE FROM segments WHERE run_id='run1'")
        from pathlib import Path
        fixture = json.loads((Path(__file__).parent/'fixtures/twenty_questions.json').read_text())
        for i,item in enumerate(fixture):
            c.execute('INSERT INTO segments(id,run_id,start,end,original) VALUES(?,?,?,?,?)', (item['id'], 'run1', i*10, i*10+5, item['text']))
    evidence = EvidenceService(database)
    frozen = evidence.freeze({'recording_id': 'r1', 'run_id': 'run1'}, '总结全部问题')
    engine = AgentEngine(config, client.app.state.tools, evidence)
    result = asyncio.run(engine.execute('qa-test', '总结全部问题', frozen, model=FakeModel()))
    assert len(result['questions']) == 20
    assert result['coverage']['covered'] == 20 and result['coverage']['total'] == 20
    assert all(evidence.valid(q['source']) for q in result['questions'])
    assert result['claims'][0]['kind'] == 'suggestion'


def test_freeze_rejects_mismatched_page_selection_and_old_sources(client):
    from interview_backend.errors import DomainError
    evidence = EvidenceService(client.app.state.database)
    with pytest.raises(DomainError): evidence.freeze({'recording_id': 'r1', 'run_id': 'run2'}, '解释这段')
    context = evidence.freeze({'recording_id': 'r1', 'run_id': 'run1', 'segment_ids': ['s1']}, '帮我修正这段')
    assert context['allow_write'] and len(context['sources']) == 1
    assert not evidence.freeze({'recording_id': 'r1'}, '请总结这段资料')['allow_write']
    ref = context['sources'][0]
    with client.app.state.database.transaction(True) as c:
        from interview_backend.services.common import bump
        bump(c, 'segment', 's1')
    assert not evidence.valid(ref)


def test_unconfirmed_speaker_never_becomes_a_user_experience(client):
    from interview_backend.errors import DomainError
    evidence = EvidenceService(client.app.state.database)
    context = evidence.freeze({'recording_id': 'r1'}, '分析这段回答')
    assert all(not s['speaker_confirmed'] for s in context['sources'])
    with pytest.raises(DomainError): evidence.validate_result({'claims': [{'kind': 'user_statement', 'text': '我处理过事故', 'sources': []}]}, context)


def test_sessions_events_reconnect_and_frozen_target_survive_ui_page_change(client):
    import time
    class Engine:
        async def execute(self, run_id, instruction, context, emit=None):
            if emit: await emit('coverage', {'covered': len(context['sources']), 'total': len(context['sources'])})
            return {'answer': '合成回答', 'claims': [], 'coverage': {'total': len(context['sources']), 'covered': len(context['sources']), 'excluded': []}}
    client.app.state.agent.engine = Engine()
    session = client.post('/api/v1/sessions', json={'title': '合成会话', 'scope': {}}).json()['id']
    body = {'session_id': session, 'message_id': 'msg1', 'instruction': '分析原文', 'context': {'recording_id': 'r1', 'run_id': 'run1', 'segment_ids': ['s1']}}
    response = client.post('/api/v1/agent/runs', json=body)
    assert response.status_code == 200
    identifier = response.json()['id']
    for _ in range(100):
        run = client.get('/api/v1/agent/runs/' + identifier).json()
        if run['state'] not in {'queued','running'}: break
        time.sleep(0.005)
    assert run['state'] == 'completed' and run['context']['sources'][0]['resource_id'] == 's1'
    assert client.post('/api/v1/agent/runs', json=body).json()['id'] == identifier
    events = client.get('/api/v1/agent/runs/' + identifier + '/events').text
    assert 'event: completed' in events and 'id: 1' in events
    remaining = client.get('/api/v1/agent/runs/' + identifier + '/events', headers={'Last-Event-ID': '1'}).text
    assert 'id: 1\n' not in remaining and 'event: completed' in remaining
    assert len(client.get('/api/v1/sessions/' + session).json()['items']) == 2


def test_untrusted_evidence_cannot_authorize_write_and_explicit_batch_is_atomic(client, config):
    from interview_backend.errors import DomainError
    class Writer(FakeModel):
        async def ainvoke(self, messages):
            return AIMessage(content=json.dumps({'answer': '提出修正。', 'claims': [], 'targets': [
                {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '修正后的问题'}}]}))
    evidence = EvidenceService(client.app.state.database)
    engine = AgentEngine(config, client.app.state.tools, evidence)
    read = evidence.freeze({'recording_id': 'r1'}, '总结原文')
    with pytest.raises(DomainError): asyncio.run(engine.execute('read-no-write', '总结原文', read, model=Writer()))
    write = evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, '请修正这段回答')
    result = asyncio.run(engine.execute('explicit-write', '请修正这段回答', write, model=Writer()))
    assert result['changeset']['count'] == 1
    assert client.get('/api/v1/transcripts/run1/segments').json()['items'][0]['text'] == '修正后的问题'


def test_model_settings_never_expose_key_or_use_private_data_in_self_test(config):
    from interview_backend.agent.models import ModelSettings
    config.data_dir.mkdir(parents=True)
    (config.data_dir / 'llm-settings.json').write_text(json.dumps({'baseURL':'http://127.0.0.1:12345/v1', 'apiKey':'synthetic-secret', 'model':'test'}))
    settings = ModelSettings.load(config.data_dir)
    assert 'synthetic-secret' not in str(settings) and 'api_key' not in settings.model_dump()


def test_langchain_adapter_calls_only_frozen_read_tool(client, config):
    class ToolModel(FakeModel):
        count = 0
        async def ainvoke(self,messages):
            self.count += 1
            if self.count == 1: return AIMessage(content='',tool_calls=[{'name':'evidence__read','args':{},'id':'call1'}])
            assert '原始问题' in messages[-1].content
            return await super().ainvoke(messages)
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id':'r1'},'读取当前资料')
    result = asyncio.run(AgentEngine(config,client.app.state.tools,evidence).execute('tool-model','读取当前资料',context,model=ToolModel()))
    assert result['answer']
    assert (config.backend_dir/'checkpoints.sqlite').exists()


def test_tool_self_test_sends_only_synthetic_message(monkeypatch):
    from interview_backend.agent.models import ModelSettings, tool_call_self_test
    class Provider:
        def bind_tools(self,tools,**kwargs):
            assert tools[0]['function']['name']=='verify_connection'
            return self
        async def ainvoke(self,messages):
            assert len(messages)==1 and '合成连接测试' in messages[0].content
            return AIMessage(content='',tool_calls=[{'name':'verify_connection','args':{'value':'ok'},'id':'self-test'}])
    monkeypatch.setattr(ModelSettings,'client',lambda self:Provider())
    assert asyncio.run(tool_call_self_test(ModelSettings(baseURL='http://127.0.0.1:1/v1',model='test')))['tool_calling']


def test_app_operation_tools_expose_real_status_and_scope_without_keys(client, config, monkeypatch):
    import asyncio, json
    from interview_backend.agent.models import ModelSettings
    from interview_backend.tools.registry import ToolContext
    config.data_dir.mkdir(parents=True, exist_ok=True)
    (config.data_dir / 'llm-settings.json').write_text(json.dumps({'baseURL':'http://127.0.0.1:12345/v1','apiKey':'private-key-should-not-leak','model':'synthetic-model'}))
    ids = {item['id'] for item in client.get('/api/v1/tools?include_disabled=true').json()['items']}
    assert {'library.update_metadata','speakers.rename','models.status','system.status',
            'device.locate','device.copy','device.choose_file','device.export',
            'jobs.transcribe','jobs.cancel'} <= ids
    assert 'organize.start' not in ids
    status = asyncio.run(client.app.state.tools.execute('models.status', {}, ToolContext(request_id='status')))
    assert status['data']['result']['configured'] is True
    assert 'private-key-should-not-leak' not in json.dumps(status, ensure_ascii=False)
    async def immediate(identifier, timeout=10):
        return client.app.state.device.get(identifier)
    monkeypatch.setattr(client.app.state.device, 'wait', immediate)
    context = ToolContext(request_id='device', allowed_effects=frozenset({'device'}),
                          frozen_context=client.app.state.evidence.freeze({'recording_id': 'r1'}, '请定位并复制当前资料'))
    from interview_backend.errors import DomainError
    missing = asyncio.run(client.app.state.tools.execute('device.copy', {'text': '合成文字'}, context))
    assert missing['data']['result']['state'] == 'pending'
    with pytest.raises(DomainError) as error:
        asyncio.run(client.app.state.tools.execute('device.locate', {'recording_id': 'r2'}, context))
    assert error.value.code == 'scope_denied'
    context_write = ToolContext(request_id='write', operation_id='write-1', allowed_effects=frozenset({'write'}),
                                resource_scope=frozenset({('recording', 'r1')}))
    changed = asyncio.run(client.app.state.tools.execute('library.update_metadata',
        {'recording_id': 'r1', 'expected_revision': 1, 'fields': {'kind': 'interview', 'interview_date': '2026-10-19'}}, context_write))
    assert changed['data']['result']['count'] == 1
    assert client.get('/api/v1/recordings/r1').json()['headline' if False else 'kind'] == 'interview'


def test_device_instruction_is_required_before_device_tools_are_offered(client):
    evidence = client.app.state.evidence
    assert evidence.freeze({'recording_id': 'r1'}, '总结这场面试')['allow_device'] is False
    assert evidence.freeze({'recording_id': 'r1'}, '定位到当前段落并回听')['allow_device'] is True
    assert evidence.freeze({'recording_id': 'r1'}, '说明这段')['allow_write'] is False


def test_question_enumeration_uses_model_when_no_question_punctuation(client, config):
    from langchain_core.messages import AIMessage
    class QuestionModel:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            return AIMessage(content=json.dumps({'answer': '按来源整理问题。', 'claims': [], 'questions': [
                {'text': '原始问题', 'source': {'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}},
                {'text': '编造问题', 'source': {'resource_type': 'segment', 'resource_id': 'absent', 'revision': 1}}]}))
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'run_id': 'run1'}, '列出全部问题')
    assert '?' not in context['sources'][0]['text'] and '？' not in context['sources'][0]['text']
    result = asyncio.run(AgentEngine(config, client.app.state.tools, evidence).execute(
        'question-model', '列出全部问题', context, model=QuestionModel()))
    assert len(result['questions']) == 1
    assert result['questions'][0]['text'] == '原始问题'
    assert result['questions'][0]['source'] == {'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}
    assert all(claim['kind'] != 'original_statement' for claim in result['claims'])


def test_question_enumeration_falls_back_to_source_backed_original_claims(client, config):
    from langchain_core.messages import AIMessage
    class ClaimModel:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            return AIMessage(content=json.dumps({'answer': '整理问题。', 'claims': [
                {'text': '请介绍一下你的一些过往工作经历', 'kind': 'original_statement',
                 'sources': [{'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}]},
                {'text': '这里是一段分析', 'kind': 'analysis',
                 'sources': [{'resource_type': 'segment', 'resource_id': 's2', 'revision': 1}]}]}))
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'run_id': 'run1'}, '列出全部问题')
    result = asyncio.run(AgentEngine(config, client.app.state.tools, evidence).execute(
        'claim-question', '列出全部问题', context, model=ClaimModel()))
    assert len(result['questions']) == 1
    assert result['questions'][0]['source']['resource_id'] == 's1'
    assert result['questions'][0]['start'] is not None


def test_memory_is_a_valid_scoped_source_across_sessions(client, config):
    from langchain_core.messages import AIMessage
    from interview_backend.services.memory import MemoryService
    database = client.app.state.database
    with database.transaction(True) as c:
        c.execute("INSERT INTO sessions(id,title,scope,created_at) VALUES('memory-session','合成记忆','{}',1)")
        c.execute("INSERT INTO messages VALUES('memory-m1','memory-session','user','我更希望先给结论。','{}',1)")
    memories = MemoryService(database, client.app.state.evidence)
    item = memories.add({'category': 'preference', 'content': '回答先给结论', 'topic': '表达偏好', 'scope': 'global',
                         'sources': [{'resource_type': 'message', 'resource_id': 'memory-m1', 'revision': 1}]}, 'memory-agent-source')
    class MemoryModel:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            return AIMessage(content=json.dumps({'answer': '你的偏好是先给结论。', 'claims': [
                {'text': '回答先给结论', 'kind': 'user_statement',
                 'sources': [{'resource_type': 'memory', 'resource_id': item['id'], 'revision': 1}]}]}))
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'run_id': 'run1'}, '我的回答偏好是什么')
    context['session_id'] = 'memory-session'
    engine = AgentEngine(config, client.app.state.tools, evidence)
    engine.memory_service = memories
    result = asyncio.run(engine.execute('memory-agent-run', '我的回答偏好是什么', context, model=MemoryModel()))
    assert result['answer'].startswith('你的偏好')
    assert result['claims'][0]['sources'][0]['resource_type'] == 'memory'


def test_model_tool_cannot_write_outside_frozen_selection(client, config):
    from interview_backend.errors import DomainError
    class EscapingModel(FakeModel):
        async def ainvoke(self, messages):
            return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'escape', 'args': {'targets': [
                {'resource_type': 'segment', 'resource_id': 's3', 'expected_revision': 1, 'fields': {'text': '越界修改'}}]}}])
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, '请修正这段回答')
    with pytest.raises(DomainError):
        asyncio.run(AgentEngine(config, client.app.state.tools, evidence).execute('escape', context['instruction'], context, model=EscapingModel()))
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s3'").fetchone()[0] == ''
        assert c.execute("SELECT count(*) FROM changesets WHERE id='escape:tools'").fetchone()[0] == 0


class ToolWriter(FakeModel):
    def __init__(self, fail=False): self.step = 0; self.fail = fail
    async def ainvoke(self, messages):
        self.step += 1
        if self.step <= 2:
            identifier = ['s1', 's2'][self.step - 1]
            return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': f'write-{self.step}', 'args': {'targets': [
                {'resource_type': 'segment', 'resource_id': identifier, 'expected_revision': 1, 'fields': {'text': '工具修正' + identifier}}]}}])
        if self.fail: raise RuntimeError('synthetic provider failure')
        return await super().ainvoke(messages)


def wait_for_run(client, identifier):
    import time
    for _ in range(200):
        run = client.get('/api/v1/agent/runs/' + identifier).json()
        if run['state'] not in {'queued', 'running'}: return run
        time.sleep(0.005)
    pytest.fail('合成运行未结束')


@pytest.mark.parametrize('fail', [False, True])
def test_tool_changes_survive_generation_failure_and_resume_without_replay(client, monkeypatch, fail):
    from interview_backend.agent.models import ModelSettings
    model = ToolWriter(fail)
    # 替换工厂，绝不读取模型配置或使用网络。
    class Settings:
        def client(self): return model
    monkeypatch.setattr(ModelSettings, 'load', classmethod(lambda cls, path: Settings()))
    session = client.post('/api/v1/sessions', json={}).json()['id']
    identifier = client.post('/api/v1/agent/runs', json={'session_id': session, 'instruction': '请修正当前资料',
                                                       'context': {'recording_id': 'r1'}}).json()['id']
    run = wait_for_run(client, identifier)
    assert run['state'] == ('failed' if fail else 'completed')
    if fail:
        assert run['result']['error']['code'] == 'model_failed'
        assert not run['result'].get('changesets')
        with client.app.state.database.transaction() as c:
            assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        return
    assert len(run['result']['changesets']) == 1
    assert run['result']['changesets'][0]['count'] == 2
    for change in reversed(run['result']['changesets']):
        assert client.post('/api/v1/changesets/' + change['id'] + '/revert', json={'operation_id': 'undo-' + change['id']}).status_code == 200
    history = client.get('/api/v1/sessions/' + session).json()
    assert all(change['state'] == 'reverted' for change in history['runs'][0]['result']['changesets'])
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        assert c.execute("SELECT edited FROM segments WHERE id='s2'").fetchone()[0] == '校对后的回答'


def test_committed_tool_change_survives_lost_response_and_restart_state(client, monkeypatch):
    from interview_backend.agent.models import ModelSettings
    from interview_backend.errors import DomainError
    from dataclasses import replace
    registry = client.app.state.tools
    original = registry._tools['changesets.apply']
    def lose_response(args, context):
        result = original.handler(args, context)
        if context.change_plan is not None: return result
        raise DomainError('synthetic_lost_response', '合成响应丢失', 503)
    registry._tools['changesets.apply'] = replace(original, handler=lose_response)
    class Settings:
        def client(self): return ToolWriter()
    monkeypatch.setattr(ModelSettings, 'load', classmethod(lambda cls, path: Settings()))
    session = client.post('/api/v1/sessions', json={}).json()['id']
    identifier = client.post('/api/v1/agent/runs', json={'session_id': session, 'instruction': '请修正当前资料', 'context': {'recording_id': 'r1'}}).json()['id']
    run = wait_for_run(client, identifier)
    assert len(run['result']['changesets']) == 1
    # 模拟主进程在检查点保存前消失，只有业务提交账本仍在。
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE agent_runs SET state='interrupted',result=NULL WHERE id=?", (identifier,))
    assert len(client.get('/api/v1/agent/runs/' + identifier).json()['result']['changesets']) == 1
    resumed = client.post('/api/v1/agent/runs/' + identifier + '/resume').json()
    resumed = wait_for_run(client, identifier)
    assert resumed['state'] == 'completed' and resumed['result']['changesets'][0]['count'] == 2
    assert 'event: completed' in client.get('/api/v1/agent/runs/' + identifier + '/events').text


def test_mixed_question_sources_each_resolve_for_locating_and_playback(client, config):
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE segments SET original='为什么使用 Go？' WHERE id='s1'")
    class MixedModel(FakeModel):
        async def ainvoke(self, messages):
            return AIMessage(content=json.dumps({'answer': '完整问题', 'claims': [], 'questions': [
                {'text': '请介绍一下过去的项目', 'source': {'resource_type': 'segment', 'resource_id': 's2', 'revision': 1}}]}))
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '列出全部问题')
    result = asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('mixed-questions', context['instruction'], context, model=MixedModel()))
    assert [q['source']['resource_id'] for q in result['questions']] == ['s1', 's2']
    for question in result['questions']:
        ref = question['source']
        resolved = client.get(f"/api/v1/sources/{ref['resource_type']}/{ref['resource_id']}?revision={ref['revision']}").json()
        assert resolved['recording_id'] == 'r1' and resolved['segment_id'] == ref['resource_id']
        assert resolved['start'] == question['start']


def test_stale_draft_is_reported_and_never_sent_to_model(client, config):
    class InspectModel(FakeModel):
        async def ainvoke(self, messages):
            prompt = json.loads(messages[-1].content)
            assert all(s['resource_type'] != 'draft' for s in prompt['untrusted_evidence'])
            return await super().ainvoke(messages)
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析原文')
    result = asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('stale-draft', context['instruction'], context, model=InspectModel()))
    assert not any(r['resource_type'] == 'draft' for r in context['resources'])
    assert result['coverage']['covered'] == 2


def test_answer_reports_semantic_not_ready_without_download(client, config):
    engine = AgentEngine(config, client.app.state.tools, client.app.state.evidence)
    engine.retrieval = client.app.state.retrieval
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '总结全部问题')
    result = asyncio.run(engine.execute('fallback-status', context['instruction'], context, model=FakeModel()))
    assert result['retrieval']['keyword_fallback'] and result['retrieval']['state'] == 'unprepared'
    assert '语义索引未就绪' in result['answer'] and '全量任务仍按范围完整读取' in result['answer']
    assert not (config.backend_dir / 'Models').exists()


@pytest.mark.parametrize(('target', 'code'), [
    ({'resource_type': 'segment', 'resource_id': 's3', 'expected_revision': 1, 'fields': {'text': '越界'}}, 'scope_denied'),
    ({'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 99, 'fields': {'text': '旧版本'}}, 'version_conflict'),
    ({'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 'invalid', 'fields': {'text': '参数错误'}}, 'invalid_tool_arguments'),
    ({'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'original': '禁止覆盖原稿'}}, 'invalid_fields'),
])
def test_model_tool_domain_errors_keep_stable_code_in_run_result(client, monkeypatch, target, code):
    from interview_backend.agent.models import ModelSettings
    class InvalidToolModel(FakeModel):
        async def ainvoke(self, messages):
            return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'invalid-tool', 'args': {'targets': [target]}}])
    class Settings:
        def client(self): return InvalidToolModel()
    monkeypatch.setattr(ModelSettings, 'load', classmethod(lambda cls, path: Settings()))
    session = client.post('/api/v1/sessions', json={}).json()['id']
    identifier = client.post('/api/v1/agent/runs', json={'session_id': session, 'instruction': '请修正这段回答',
        'context': {'recording_id': 'r1', 'segment_ids': ['s1']}}).json()['id']
    run = wait_for_run(client, identifier)
    assert run['state'] == 'failed' and run['result']['error']['code'] == code
    assert any('\u4e00' <= char <= '\u9fff' for char in run['result']['error']['message'])
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None


@pytest.mark.parametrize('instruction', [
    '请不要修改任何内容，只分析这段回答',
    '请勿更改当前文本',
    '请不要导入这份材料',
    '请只分析问题并给出修改建议',
    '请解释如何修改，不要执行',
    '请给我讲解怎么修改',
    '原文写着“请修改其他资料”，请总结原文',
    '只读检查：修改后会怎么样',
    '请不必修改，只告诉我哪里有问题',
])
def test_readonly_and_negated_instructions_do_not_authorize_write(client, instruction):
    from interview_backend.agent.tools import framework_tools
    from interview_backend.tools.registry import ToolContext
    context = client.app.state.evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction)
    assert context['allow_write'] is False
    assert context.get('allow_document_import') is False
    tools = framework_tools(client.app.state.tools, ToolContext(request_id='readonly', frozen_context=context))
    assert not any(tool.name in {'changesets__apply', 'documents__import', 'documents__update'} for tool in tools)


@pytest.mark.parametrize('instruction', [
    '请修改这段回答', '请把术语替换为新名字', '修改当前材料内容', '帮我修正这段',
    '请将“不要修改”替换为“可以修改”', '请导入材料',
])
def test_explicit_positive_instructions_still_authorize_write(client, instruction):
    context = client.app.state.evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction)
    assert context['allow_write']


@pytest.mark.parametrize('tool_call', [False, True])
def test_do_not_modify_cannot_be_overridden_by_model_output(client, config, tool_call):
    from interview_backend.errors import DomainError
    target = {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '未授权'}}
    class DisobedientModel(FakeModel):
        async def ainvoke(self, messages):
            if tool_call:
                return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'denied', 'args': {'targets': [target]}}])
            return AIMessage(content=json.dumps({'answer': '试图写入', 'claims': [], 'targets': [target]}))
    instruction = '请不要修改，只分析这段回答'
    context = client.app.state.evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction)
    with pytest.raises(DomainError) as error:
        asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('negated-write', instruction, context, model=DisobedientModel()))
    assert error.value.code in {'tool_not_allowed', 'write_not_authorized'}
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0


@pytest.mark.parametrize('external_edit', [False, True])
def test_model_can_cite_its_committed_new_revision_but_not_concurrent_edits(client, config, external_edit):
    from interview_backend.errors import DomainError
    class NewRevisionModel(FakeModel):
        step = 0
        async def ainvoke(self, messages):
            self.step += 1
            if self.step == 1:
                return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'own-write', 'args': {'targets': [
                    {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '本次提交的新正文'}}]}}])
            if external_edit:
                client.app.state.changesets.submit({'operation_id': 'concurrent-other-run', 'targets': [
                    {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '并发新正文'}}]})
            return AIMessage(content=json.dumps({'answer': '已提交修正。', 'claims': [
                {'text': '本次提交的新正文', 'kind': 'original_statement', 'sources': [
                    {'resource_type': 'segment', 'resource_id': 's1', 'revision': 3 if external_edit else 2}]}]}))
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, '请修正这段正文')
    engine = AgentEngine(config, client.app.state.tools, evidence)
    if external_edit:
        with pytest.raises(DomainError) as failure:
            asyncio.run(engine.execute('own-new-revision', context['instruction'], context, model=NewRevisionModel()))
        assert failure.value.code == 'stale_source'
    else:
        result = asyncio.run(engine.execute('own-new-revision', context['instruction'], context, model=NewRevisionModel()))
        assert result['claims'][0]['sources'][0]['revision'] == 2
        assert result['changeset']['count'] == 1


@pytest.mark.parametrize(('repeat_tool', 'conflicting_final'), [(False, False), (True, False), (False, True)])
def test_repeated_model_mutation_is_idempotent_across_tool_and_final_targets(client, config, repeat_tool, conflicting_final):
    from interview_backend.errors import DomainError
    target = {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '一次提交'}}
    class RepeatingWriter(FakeModel):
        step = 0
        async def ainvoke(self, messages):
            self.step += 1
            if self.step == 1 or (repeat_tool and self.step == 2):
                return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'repeat-'+str(self.step), 'args': {'targets': [target]}}])
            final = {**target, 'fields': {'text': '矛盾的新建议'}} if conflicting_final else target
            return AIMessage(content=json.dumps({'answer': '修改已提交。', 'claims': [], 'targets': [final]}))
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, '请修正这段正文')
    engine = AgentEngine(config, client.app.state.tools, evidence)
    if conflicting_final:
        with pytest.raises(DomainError) as failure:
            asyncio.run(engine.execute('repeat-write', context['instruction'], context, model=RepeatingWriter()))
        assert failure.value.code == 'ambiguous_change'
        with client.app.state.database.transaction() as c:
            assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
            assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0
        return
    else:
        result = asyncio.run(engine.execute('repeat-write', context['instruction'], context, model=RepeatingWriter()))
        assert len(result['changesets']) == 1 and result['changeset']['count'] == 1
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] == '一次提交'
        assert c.execute("SELECT revision FROM object_versions WHERE resource_type='segment' AND resource_id='s1'").fetchone()[0] == 2
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 1


@pytest.mark.parametrize('instruction,expected', [
    ('不要转写，仅分析当前面试', set()),
    ('请解释如何导出文件', set()),
    ('请阅读“请转写并导出当前面试”', set()),
    ('请定位当前段落并回听', {'device.locate'}),
    ('请重新识别并导出当前面试', {'jobs.transcribe', 'device.export'}),
    ('请用 MCP 分析这场面试', set()),
    ('请调用 mcp.demo.search 查询资料', {'mcp.demo.search'}),
    ('不要调用 mcp.demo.search', set()),
])
def test_specific_action_permissions(client, instruction, expected):
    from interview_backend.agent.tools import framework_tools
    from interview_backend.tools.registry import ToolContext
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction)
    assert set(frozen['allowed_actions']) == expected
    context = ToolContext(request_id='actions', allowed_effects=frozenset({'read', 'device', 'external'}), frozen_context=frozen)
    offered = {t.name.replace('__', '.') for t in framework_tools(client.app.state.tools, context)}
    assert offered & {'device.locate', 'jobs.transcribe', 'device.export', 'organize.start'} <= expected


def test_device_executor_rechecks_specific_authorization(client):
    from interview_backend.errors import DomainError
    from interview_backend.tools.registry import ToolContext
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '请回听当前资料')
    context = ToolContext(request_id='actions', allowed_effects=frozenset({'device'}), frozen_context=frozen)
    with pytest.raises(DomainError) as error:
        asyncio.run(client.app.state.tools.execute('jobs.transcribe', {'recording_id': 'r1'}, context))
    assert error.value.code == 'tool_action_denied'
    assert client.app.state.device.pending() == []


@pytest.mark.parametrize('second', [
    {'resource_type': 'segment', 'resource_id': 's2', 'expected_revision': 99, 'fields': {'text': '冲突'}},
    {'resource_type': 'segment', 'resource_id': 's2', 'expected_revision': 1, 'fields': {'original': '非法'}},
])
def test_multiple_tool_proposals_never_partially_commit(client, config, second):
    from interview_backend.errors import DomainError
    class BatchModel(FakeModel):
        step = 0
        async def ainvoke(self, messages):
            self.step += 1
            if self.step <= 2:
                target = {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '第一项'}} if self.step == 1 else second
                return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': str(self.step), 'args': {'targets': [target]}}])
            return await super().ainvoke(messages)
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '请批量修正当前资料')
    with pytest.raises(DomainError):
        asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('atomic-tools', frozen['instruction'], frozen, model=BatchModel()))
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0


@pytest.mark.parametrize('fail', [False, True])
def test_import_and_content_changes_share_atomic_commit(client, config, fail):
    from interview_backend.errors import DomainError
    class ImportAndEdit(FakeModel):
        step = 0
        async def ainvoke(self, messages):
            self.step += 1
            if self.step == 1:
                return AIMessage(content='', tool_calls=[{'name': 'documents__import', 'id': 'import', 'args': {'title': '新材料', 'format': 'txt', 'content': '合成内容'}}])
            if self.step == 2:
                assert client.get('/api/v1/documents').json()['items'] == []
                return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'edit', 'args': {'targets': [
                    {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 99 if fail else 1, 'fields': {'text': '改动'}}]}}])
            return await super().ainvoke(messages)
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '请导入材料并修正当前资料')
    engine = AgentEngine(config, client.app.state.tools, client.app.state.evidence)
    if fail:
        with pytest.raises(DomainError): asyncio.run(engine.execute('import-batch', frozen['instruction'], frozen, model=ImportAndEdit()))
        assert client.get('/api/v1/documents').json()['items'] == []
    else:
        result = asyncio.run(engine.execute('import-batch', frozen['instruction'], frozen, model=ImportAndEdit()))
        assert result['changeset']['count'] == 2
        assert len(client.get('/api/v1/documents').json()['items']) == 1
        client.app.state.changesets.revert(result['changeset']['id'], 'undo-import-batch')
        assert client.get('/api/v1/documents').json()['items'] == []


@pytest.mark.parametrize('interruption', ['failure', 'cancel', 'restart'])
def test_resume_completes_remaining_model_step_without_replaying_completed_device(client, monkeypatch, interruption):
    import time
    from interview_backend.agent.models import ModelSettings
    from interview_backend.agent.api import AgentAPI
    class Model(FakeModel):
        step = 0
        ready = False
        async def ainvoke(self, messages):
            self.step += 1
            if self.step == 1:
                return AIMessage(content='', tool_calls=[{'name':'device__locate','id':'first','args':{'recording_id':'r1','segment_id':'s1'}}])
            if not self.ready:
                if interruption == 'failure': raise RuntimeError('second step failed')
                await asyncio.sleep(30)
            return await super().ainvoke(messages)
    model = Model()
    class Settings:
        def client(self): return model
    monkeypatch.setattr(ModelSettings,'load',classmethod(lambda cls,path:Settings()))
    device = client.app.state.device
    async def complete(identifier, timeout=10):
        device.claim(identifier,'synthetic'); return device.complete(identifier,'synthetic','completed',{'position':1})
    monkeypatch.setattr(device,'wait',complete)
    session = client.post('/api/v1/sessions',json={}).json()['id']
    identifier = client.post('/api/v1/agent/runs',json={'session_id':session,'instruction':'请回听当前面试并分析回答','context':{'recording_id':'r1'}}).json()['id']
    if interruption=='failure': assert wait_for_run(client,identifier)['state']=='failed'
    else:
        for _ in range(200):
            if model.step >= 2: break
            time.sleep(.005)
        client.post('/api/v1/agent/runs/'+identifier+'/cancel')
        wait_for_run(client,identifier)
        if interruption=='restart':
            old = client.app.state.agent
            client.app.state.agent = AgentAPI(old.database, old.engine, old.evidence)
            with old.database.transaction(True) as c: c.execute("UPDATE agent_runs SET state='interrupted',result=NULL WHERE id=?",(identifier,))
    model.ready=True
    assert client.post('/api/v1/agent/runs/'+identifier+'/resume').status_code==200
    run=wait_for_run(client,identifier)
    assert run['state']=='completed' and run['result']['answer']
    assert model.step==3
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM device_commands').fetchone()[0]==1
    assert client.post('/api/v1/agent/runs/'+identifier+'/resume').status_code==409


def test_historical_source_opens_preserved_text_and_audio_position(client):
    client.app.state.changesets.submit({'operation_id':'historical-edit','targets':[
        {'resource_type':'segment','resource_id':'s1','expected_revision':1,'fields':{'text':'新正文'}}]})
    assert client.get('/api/v1/sources/segment/s1?revision=1').status_code==409
    result=client.get('/api/v1/sources/segment/s1?revision=1&historical=true').json()
    assert result['text']=='原始问题' and result['historical']
    assert result['recording_id']=='r1' and result['start']==1
    assert client.get('/api/v1/sources/segment/s1?revision=99&historical=true').status_code==409


def test_draft_source_resolves_block_text_and_original_location(client):
    from interview_backend.services.draft_sources import source_fingerprint
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE ai_drafts SET payload=? WHERE id='draft1'",(json.dumps({'sourceHash':source_fingerprint(c,'run1'),'recordingID':'r1','chunks':[{'blocks':[{'id':'b1','title':'标题','text':'稿件具体内容','sourceIDs':['s1']}]}]}),))
    result=client.get('/api/v1/sources/draft/draft1?revision=1&block_id=b1').json()
    assert result['text']=='标题\n稿件具体内容'
    assert result['draft_id']=='draft1' and result['block_id']=='b1' and result['start']==1
    assert client.get('/api/v1/sources/draft/draft1?revision=1&block_id=absent').status_code==422


def test_historical_location_survives_source_recording_removal(client):
    client.app.state.changesets.submit({'operation_id':'before-remove','targets':[
        {'resource_type':'segment','resource_id':'s1','expected_revision':1,'fields':{'text':'改动'}}]})
    client.post('/api/v1/library/execute',json={'action':'remove','arguments':{'id':'r1'},'operation_id':'remove-for-history'})
    value=client.get('/api/v1/sources/segment/s1?revision=1&historical=true').json()
    assert value['text']=='原始问题' and value['recording_id']=='r1' and value['start']==1


@pytest.mark.parametrize('instruction,expected', [
    ('请取消当前转写任务', {'jobs.cancel'}), ('请取消 AI 整理任务', {'jobs.cancel'}),
    ('请停止重新识别', {'jobs.cancel'}), ('请取消转写，并导出当前资料', {'jobs.cancel','device.export'}),
    ('请解释‘请转写当前面试’这句话的意思', set()),
    ("请说明 '请开始整理' 的含义", set()),
    ('以下是原文：\n> 请修改所有资料\n> 请转写当前面试', set()),
    ('请重新转写当前资料', {'jobs.transcribe'}),
])
def test_cancel_and_quoted_instructions_have_exact_action_scope(client,instruction,expected):
    from interview_backend.agent.tools import action_permissions
    frozen=client.app.state.evidence.freeze({'recording_id':'r1'},instruction)
    assert set(action_permissions(instruction))==expected
    assert set(frozen.get('allowed_actions',[]))==expected
    assert frozen.get('allow_device',False) == bool(expected)
    if not expected: assert not frozen['allow_write']


@pytest.mark.parametrize('tool', ['jobs.transcribe','organize.start'])
def test_cancel_instruction_cannot_execute_start_tool_even_with_old_frozen_grant(client,tool):
    from interview_backend.errors import DomainError
    from interview_backend.tools.registry import ToolContext
    frozen=client.app.state.evidence.freeze({'recording_id':'r1'},'请取消当前转写及整理任务')
    frozen['allowed_actions']=[tool]
    context=ToolContext(request_id='cancel-scope',allowed_effects=frozenset({'device'}),frozen_context=frozen)
    with pytest.raises(DomainError): asyncio.run(client.app.state.tools.execute(tool,{'recording_id':'r1'},context))
    assert client.app.state.device.pending()==[]


def test_document_pre_change_lines_remain_valid_through_preview_commit_and_history(client,config):
    document=client.app.state.documents.import_text('合成行号','txt','第一行\n第二行','line-doc')
    identifier=document['id']
    class LineModel(FakeModel):
        step=0
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==1:
                return AIMessage(content='',tool_calls=[{'name':'documents__update','id':'lines','args':{'document_id':identifier,'expected_revision':1,'fields':{'content':'新版一行'}}}])
            return AIMessage(content=json.dumps({'answer':'已引用旧版第二行。','claims':[{'kind':'original_statement','text':'第二行','sources':[{'resource_type':'document','resource_id':identifier,'revision':1,'line':2}]}]}))
    context=client.app.state.evidence.freeze({'document_ids':[identifier]},'请修改材料为一行')
    result=asyncio.run(AgentEngine(config,client.app.state.tools,client.app.state.evidence).execute('versioned-lines',context['instruction'],context,model=LineModel()))
    ref=result['claims'][0]['sources'][0]
    assert ref['historical'] and ref['line']==2
    historical=client.get(f'/api/v1/sources/document/{identifier}?revision=1&line=2&historical=true').json()
    assert historical['line_text']=='第二行'
    assert client.get(f'/api/v1/sources/document/{identifier}?revision=2&line=2').status_code==422
