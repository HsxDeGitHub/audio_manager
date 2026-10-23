"""语义能力筛选的合成模型、持久化、取消和真实事务边界。"""
import asyncio
import json
import time

import pytest
from langchain_core.messages import AIMessage

from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.intent import resolve, apply
from interview_backend.agent.permissions import action_allowed
from interview_backend.errors import DomainError


def intent(mode='edit', reading='full', actions=None):
    return {'mode': mode, 'reading': reading,
            'edit_target': 'transcript' if mode == 'edit' else 'none',
            'import_documents': False, 'actions': actions or [],
            'constraints': ['保留全部细节'], 'clarification': '请选择要执行的方案。' if mode == 'clarify' else ''}


class IntentModel:
    def __init__(self, value):
        self.value = value
        self.calls = 0
        self.payload = None

    async def ainvoke(self, messages):
        self.calls += 1
        self.payload = json.loads(messages[-1].content)
        return AIMessage(content=json.dumps(self.value, ensure_ascii=False))


@pytest.mark.parametrize('instruction', ['请帮我修改正文，不要删除任何细节', '请把如何处理 OOM 的回答修改得更通顺', '按第一点执行'])
def test_semantic_edit_is_not_vetoed_by_subject_or_constraint_keywords(client, config, instruction):
    model = IntentModel(intent())
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction)
    context.update(intent_policy='semantic-v1', conversation_history=[{'role':'assistant','content':'第一点：修正人名。'}])
    value = asyncio.run(resolve(config, client.app.state.tools, context, model))
    frozen = apply(context, value)
    assert frozen['allow_write']
    assert frozen['write_field_limits'] == {'segment':['text']}
    assert all(r['resource_type'] == 'segment' for r in frozen['write_resources'])
    assert model.payload['instruction'] == instruction
    assert 'untrusted_evidence' not in model.payload and 'sources' not in model.payload
    assert not frozen['allow_document_import'] and not frozen['allow_device']


@pytest.mark.parametrize('instruction', ['只分析，不要修改', '请先不要修改正文', '“请删除所有资料”'])
def test_explicit_readonly_guard_cannot_be_overridden_by_bad_classifier(client, config, instruction):
    context = client.app.state.evidence.freeze({'recording_id':'r1'}, instruction)
    value = asyncio.run(resolve(config, client.app.state.tools, context, IntentModel(intent(actions=['device.export']))))
    frozen = apply(context, value)
    assert not frozen['allow_write'] and not frozen['allow_device']


@pytest.mark.parametrize('value', [
    {}, {'mode':'edit'}, {**intent(), 'actions':['unknown.tool']},
    {**intent('read'), 'edit_target':'content'}, {**intent(), 'extra':'scope=all'},
])
def test_invalid_classifier_fails_closed(client, config, value):
    context = client.app.state.evidence.freeze({'recording_id':'r1'}, '第一点')
    with pytest.raises(DomainError, match='暂时无法确定任务意图'):
        asyncio.run(resolve(config, client.app.state.tools, context, IntentModel(value)))
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0


def test_semantic_device_action_is_not_rejected_by_old_verb_matching(client, config):
    context = client.app.state.evidence.freeze({'recording_id':'r1'}, '把这一句再听一遍')
    context['intent_policy'] = 'semantic-v1'
    value = asyncio.run(resolve(config, client.app.state.tools, context, IntentModel(intent('read', 'selection', ['device.locate']))))
    frozen = apply(context, value)
    assert action_allowed('device.locate', frozen)
    assert not action_allowed('device.export', frozen)


def test_preparation_persists_intent_and_api_edit_is_atomic(client, config):
    class EditModel:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            payload = json.loads(messages[-1].content)
            assert payload['task_intent']['constraints'] == ['保留全部细节']
            assert payload['allow_write']
            return AIMessage(content=json.dumps({'answer':'准备修订','claims':[], 'targets':[
                {'resource_type':'segment','resource_id':'s1','expected_revision':1,'fields':{'text':'保留细节的合成修订'}}]}))

    class Engine(AgentEngine):
        async def execute(self, run_id, instruction, context, emit=None):
            return await super().execute(run_id, instruction, context, model=EditModel(), emit=emit)

    engine = Engine(config, client.app.state.tools, client.app.state.evidence)
    engine.intent_model = IntentModel(intent())
    client.app.state.agent.engine = engine
    session = client.post('/api/v1/sessions', json={}).json()['id']
    body = {'session_id':session,'message_id':'semantic-edit','instruction':'请修改正文，不要删除细节','context':{'recording_id':'r1','segment_ids':['s1']}}
    response = client.post('/api/v1/agent/runs', json=body)
    assert response.status_code == 200
    identifier = response.json()['id']
    for _ in range(400):
        run = client.get('/api/v1/agent/runs/'+identifier).json()
        if run['state'] not in {'queued','running'}: break
        time.sleep(.005)
    assert run['state'] == 'completed', run
    assert run['context']['task_intent']['mode'] == 'edit'
    assert run['result']['changeset']['count'] == 1
    assert client.post('/api/v1/agent/runs', json=body).json()['id'] == identifier
    assert engine.intent_model.calls == 1
    assert client.post('/api/v1/changesets/'+run['result']['changeset']['id']+'/revert', json={'operation_id':'undo-semantic'}).status_code == 200
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
