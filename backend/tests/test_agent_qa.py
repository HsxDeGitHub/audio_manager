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
