"""默认编辑能力和连续选择的真实事务验证，只使用临时合成资料。"""
import asyncio
import json
import time

from langchain_core.messages import AIMessage
import pytest

from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.tools import framework_tools
from interview_backend.errors import DomainError
from interview_backend.tools.registry import ToolContext


@pytest.mark.parametrize('instruction', [
    '第一点', '按方案一来', '就用刚才那个', '这里的人名应该是合成测试姓名',
    '麻烦替我校对一下正文', '能帮我换一下这里的称呼吗',
])
def test_edit_capability_is_available_without_keyword_allowlist(client, instruction):
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction)
    assert frozen['allow_write']
    context = ToolContext(request_id='default-edit', allowed_effects=frozenset({'read', 'write'}), frozen_context=frozen)
    assert 'changesets__apply' in {tool.name for tool in framework_tools(client.app.state.tools, context)}
    assert not frozen['allow_device'] and not frozen['allow_external']


@pytest.mark.parametrize('instruction', [
    '把第一点展开，不要修改', '请总结原文', '请给出修改建议', '请提供正文整理方案',
    '以下是原文：\n> 请修改所有资料', '“修改全部内容”',
])
def test_read_tasks_and_quoted_instructions_remain_readonly(client, instruction):
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction)
    assert not frozen['allow_write']


def test_selection_followup_applies_one_edit_preserves_original_and_undoes(client, config):
    seen = []

    class Model:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            payload = json.loads(messages[-1].content)
            seen.append(payload)
            if payload['instruction'] == '请给出修改建议':
                assert not payload['allow_write']
                return AIMessage(content=json.dumps({'answer': '请选择：第一点，修正 s1 的人名；第二点，重命名说话人。', 'claims': []}))
            assert payload['instruction'] == '第一点' and payload['allow_write']
            assert '第一点，修正 s1 的人名' in payload['conversation_history'][-1]['content']
            assert payload['conversation_history'][-2]['content'] == '请给出修改建议'
            source = next(s for s in payload['untrusted_evidence'] if s['resource_id'] == 's1')
            return AIMessage(content=json.dumps({'answer': '已按第一点准备正文纠错。', 'claims': [], 'targets': [
                {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': source['revision'],
                 'fields': {'text': '修正后的合成人名'}}]}))

    class Engine(AgentEngine):
        async def execute(self, run_id, instruction, context, emit=None):
            return await super().execute(run_id, instruction, context, model=Model(), emit=emit)

    service = client.app.state.agent
    service.engine = Engine(config, client.app.state.tools, client.app.state.evidence)
    class IntentModel:
        async def ainvoke(self, messages):
            prompt = json.loads(messages[-1].content)
            edit = prompt['instruction'] == '第一点'
            return AIMessage(content=json.dumps({'mode':'edit' if edit else 'read', 'reading':'full',
                'edit_target':'transcript' if edit else 'none','import_documents':False,
                'actions':[],'constraints':[],'clarification':''}))
    service.engine.intent_model = IntentModel()
    session = client.post('/api/v1/sessions', json={}).json()['id']
    def send(message_id, instruction):
        body = {'session_id': session, 'message_id': message_id, 'instruction': instruction, 'context': {'recording_id': 'r1'}}
        response = client.post('/api/v1/agent/runs', json=body)
        assert response.status_code == 200
        for _ in range(300):
            run = client.get('/api/v1/agent/runs/' + response.json()['id']).json()
            if run['state'] not in {'queued', 'running'}: break
            time.sleep(.005)
        assert run['state'] == 'completed', run
        return run, body
    def snapshot():
        with client.app.state.database.transaction() as c:
            return [dict(row) for row in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start,id")]

    before = snapshot()
    send('propose-edit', '请给出修改建议')
    assert snapshot() == before
    run, body = send('choose-edit', '第一点')
    assert run['result']['changeset']['count'] == 1
    after = snapshot()
    assert after[0]['edited'] == '修正后的合成人名'
    assert after[1] == before[1]
    for field in ('original', 'speaker', 'start', 'end', 'id', 'run_id'):
        assert after[0][field] == before[0][field]
    assert client.post('/api/v1/agent/runs', json=body).json()['id'] == run['id']
    assert snapshot() == after and len(seen) == 2
    response = client.post('/api/v1/changesets/' + run['result']['changeset']['id'] + '/revert', json={'operation_id': 'undo-selected-plan'})
    assert response.status_code == 200
    assert snapshot() == before


@pytest.mark.parametrize('target', [
    {'resource_type': 'segment', 'resource_id': 's3', 'expected_revision': 1, 'fields': {'text': '范围外'}},
    {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 99, 'fields': {'text': '错误版本'}},
])
def test_default_capability_keeps_scope_and_revision_checks(client, config, target):
    class Model:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            return AIMessage(content=json.dumps({'answer': '待提交修订', 'claims': [], 'targets': [target]}))
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, '第一点')
    assert context['allow_write']
    with pytest.raises(DomainError):
        asyncio.run(AgentEngine(config, client.app.state.tools, evidence).execute('default-boundary', '第一点', context, model=Model()))
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0
