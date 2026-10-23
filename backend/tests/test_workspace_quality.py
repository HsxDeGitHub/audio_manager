"""工作区、分页与长任务优化；全部资料为独立临时合成数据。"""
import asyncio
import json
import pytest
from langchain_core.messages import AIMessage, AIMessageChunk
from interview_backend.errors import DomainError


def test_workspace_is_consistent_and_reader_search_crosses_segment_boundaries(client):
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute("UPDATE segments SET edited='数据库',speaker=0 WHERE id='s1'")
        c.execute("UPDATE segments SET edited='事务与幂等',speaker=0 WHERE id='s2'")
    response = client.post('/api/v1/library/execute', json={'action':'workspace','arguments':{'recordingID':'r1'}})
    assert response.status_code == 200
    snapshot = response.json()['value']
    assert len(snapshot['recordings']) == 2
    assert len(snapshot['segments']) == 2 and snapshot['names']['0'] == '提问者'
    page = client.get('/api/v1/library/reader-search', params={'q':'数据库事务','limit':1}).json()
    assert page['total'] == 1 and page['items'][0]['recordingID'] == 'r1'
    assert [s['id'] for s in page['items'][0]['segments']] == ['s1','s2']
    assert client.get('/api/v1/library/reader-search', params={'q':'数据库事务','recording_id':'r2'}).json()['total'] == 0
    assert client.get('/api/v1/library/reader-search', params={'q':'事务','offset':1,'limit':1}).json()['items'] == []
    assert client.get('/api/v1/library/reader-search', params={'q':'x','offset':-1}).status_code == 422


def test_history_pages_have_no_duplicate_rounds_and_reject_other_session_cursor(client):
    from interview_backend.services.common import encode
    session = client.post('/api/v1/sessions', json={}).json()['id']
    with client.app.state.database.transaction(True) as c:
        for i in range(7):
            c.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)',(f'm{i}',session,'user',f'问题{i}','{}',i))
            c.execute('INSERT INTO agent_runs VALUES(?,?,?,?,?,?,?)',(f'run{i}',session,f'm{i}','completed','{}',encode({'answer':f'回答{i}','claims':[]}),i))
            c.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)',(f'a{i}',session,'assistant',f'回答{i}',encode({'run_id':f'run{i}'}),i+.1))
    first = client.get('/api/v1/sessions/'+session,params={'limit':3}).json()
    assert first['has_more'] and [r['id'] for r in first['runs']] == ['run4','run5','run6']
    assert len(first['items']) == 6
    second = client.get('/api/v1/sessions/'+session,params={'limit':3,'before':first['before']}).json()
    assert [r['id'] for r in second['runs']] == ['run1','run2','run3']
    last = client.get('/api/v1/sessions/'+session,params={'limit':3,'before':second['before']}).json()
    assert not last['has_more'] and [r['id'] for r in last['runs']] == ['run0']
    other = client.post('/api/v1/sessions', json={}).json()['id']
    assert client.get('/api/v1/sessions/'+other,params={'before':'run0'}).status_code == 422


def test_synthesis_reduces_parts_and_rejects_new_sources_or_side_effects(client, config):
    from interview_backend.agent.graph import AgentEngine
    from interview_backend.agent.synthesis import synthesize
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id':'r1'},'完整总结')
    context['task_intent'] = {'mode':'read'}
    engine = AgentEngine(config, client.app.state.tools, evidence)
    parts = [{'answer':'共同问题：缺少例子。','claims':[]},{'answer':'第二段也缺少例子，但给出了边界。','claims':[]}]
    class Model:
        calls = 0
        async def ainvoke(self, messages):
            self.calls += 1
            payload = json.loads(messages[-1].content)
            assert len(payload['untrusted_parts']) == 2
            return AIMessage(content=json.dumps({'answer':'共同问题是缺少例子，第二段的边界说明较好。','claims':[]}))
    model = Model()
    value = asyncio.run(synthesize(engine,'synth-read','完整总结',context,parts,model))
    assert value['answer'].startswith('共同问题') and model.calls == 1
    assert asyncio.run(synthesize(engine,'synth-read','完整总结',context,parts,model)) == value
    assert model.calls == 1
    class Invalid:
        async def ainvoke(self,messages):
            return AIMessage(content=json.dumps({'answer':'越界','claims':[{'text':'不存在的依据','kind':'analysis','sources':[{'resource_type':'segment','resource_id':'s3','revision':1}]}]}))
    with pytest.raises(DomainError):
        asyncio.run(synthesize(engine,'synth-invalid','完整总结',context,parts,Invalid()))
    class Writer:
        async def ainvoke(self,messages): return AIMessage(content='{"answer":"修改","claims":[],"targets":[]}')
    with pytest.raises(DomainError):
        asyncio.run(synthesize(engine,'synth-write','完整总结',context,parts,Writer()))
    assert evidence.committed('synth-write') == []


def test_proposal_selection_preserves_scope_and_rejects_stale_plan(client):
    from interview_backend.agent.proposals import prepare, select
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id':'r1'},'请给修改建议')
    proposal = prepare(evidence,'proposal-test',[{'title':'修正第一句','instruction':'只修正第一句','sources':[{'resource_type':'segment','resource_id':'s1','revision':1}]}],context)[0]
    context['pending_proposals'] = [proposal]
    context['write_resources'] = context['resources']
    selected = select(evidence,context,proposal['id'])
    assert [(r['resource_type'],r['resource_id']) for r in selected['write_resources']] == [('segment','s1')]
    with pytest.raises(DomainError): select(evidence,context,'another-session:proposal:1')
    from interview_backend.services.common import bump
    with client.app.state.database.transaction(True) as c: bump(c,'segment','s1')
    with pytest.raises(DomainError): select(evidence,context,proposal['id'])


def test_capability_tests_do_not_persist_credentials_or_return_provider_errors(client, monkeypatch):
    from interview_backend.agent.models import ModelSettings
    class Model:
        def bind_tools(self, *args, **kwargs): return self
        async def ainvoke(self, messages):
            if messages[-1].content.startswith('这是合成的 JSON'): return AIMessage(content='{"ok":true}')
            if len(messages)==1: raise ValueError('synthetic-secret private upstream body')
            return AIMessage(content='准备就绪')
        async def astream(self,messages): yield AIMessageChunk(content='合成增量')
    monkeypatch.setattr(ModelSettings,'client',lambda self:Model())
    response = client.post('/api/v1/models/test-capabilities',json={'baseURL':'https://synthetic.test/v1','model':'synthetic','apiKey':'synthetic-secret'})
    assert response.status_code == 200
    checks = {v['id']:v for v in response.json()['checks']}
    assert checks['text']['supported'] and checks['structured']['supported'] and checks['streaming']['supported']
    assert not checks['tools']['supported']
    assert 'synthetic-secret' not in response.text and 'upstream body' not in response.text
    assert not (client.app.state.agent.engine.settings.data_dir/'llm-settings.json').exists()
