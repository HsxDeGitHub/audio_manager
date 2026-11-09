"""本轮问题决定读取策略，问候和普通对话不进入资料分批流程。"""
import asyncio
import json
from types import SimpleNamespace

import pytest
from pi_fakes import assistant_message

from interview_backend.agent.intent import apply, resolve
from interview_backend.errors import DomainError
from test_semantic_intent import IntentModel, intent


@pytest.mark.parametrize('instruction', ['你好', '你好！', '您好呀', 'Hello', '谢谢', '在吗', '你能做什么'])
def test_social_message_ignores_selected_material_and_previous_tasks(client, config, monkeypatch, instruction):
    evidence = client.app.state.evidence
    def forbidden(*_):
        raise AssertionError('普通问候不应读取资料版本')
    monkeypatch.setattr(evidence, 'ref', forbidden)
    context = evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction, semantic=True)
    context['conversation_history'] = [{'role': 'user', 'content': '请整理整场面试'}]
    model = IntentModel(intent())
    resolved = asyncio.run(resolve(config, client.app.state.tools, context, model))
    value = apply(context, resolved)
    assert model.calls == 0
    assert resolved['reading'] == 'none' and resolved['mode'] == 'read'
    assert value['sources'] == value['resources'] == value['write_resources'] == []
    assert value['conversation_history'] == []
    assert not value['allow_write'] and not value['allow_device'] and not value['allow_external']


@pytest.mark.parametrize('instruction,reading', [
    ('Go 的接口是什么', 'none'),
    ('查一下这次面试里关于接口的回答', 'search'),
    ('你好，帮我总结整场面试', 'full'),
    ('谢谢，再整理一下全文', 'full'),
])
def test_question_drives_semantic_reading_strategy(client, config, instruction, reading):
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction, semantic=True)
    model = IntentModel(intent('read', reading))
    resolved = asyncio.run(resolve(config, client.app.state.tools, context, model))
    value = apply(context, resolved)
    assert model.calls == 1 and resolved['reading'] == reading
    assert bool(value['sources']) == (reading != 'none')


@pytest.mark.parametrize('value', [intent('edit', 'none'), intent('read', 'none', ['device.export'])])
def test_no_material_intent_cannot_grant_operations(client, config, value):
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '聊聊接口', semantic=True)
    with pytest.raises(DomainError, match='暂时无法确定任务意图'):
        asyncio.run(resolve(config, client.app.state.tools, context, IntentModel(value)))


def test_general_conversation_uses_one_pi_session_without_material_or_tools(client):
    engine = client.app.state.agent.engine
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, 'Go 的接口是什么', semantic=True)
    context = apply(context, intent('read', 'none'))
    calls = []
    events = []
    class Model:
        async def complete(self, messages):
            payload = json.loads(messages[-1].text)
            calls.append(payload)
            assert payload['instruction'] == 'Go 的接口是什么'
            assert 'untrusted_evidence' not in payload and 'scope' not in payload
            return assistant_message(content='{"answer":"接口用于描述行为。","claims":[],"coverage":{"total":42},"incomplete":true}')
    async def execute():
        async def emit(kind, payload):
            events.append((kind, payload))
        return await engine.execute('general-conversation', context['instruction'], context, model=Model(), emit=emit)
    result = asyncio.run(execute())
    assert len(calls) == 1 and result['answer'] == '接口用于描述行为。'
    assert 'coverage' not in result and 'retrieval' not in result
    assert 'incomplete' not in result
    assert not any(kind in {'coverage', 'tool_start', 'tool_end'} for kind, _ in events)


def test_search_without_hits_never_falls_back_to_full_material(client):
    engine = client.app.state.agent.engine
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '查找不存在的内容', semantic=True)
    context = apply(context, intent('read', 'search'))
    class Model:
        def with_tools(self, _): return self
        async def complete(self, _):
            raise AssertionError('零命中不应把全部资料发送给模型')
    engine.retrieval = SimpleNamespace(search=lambda *_: [], semantic=SimpleNamespace(status=lambda: {'ready': True}))
    result = asyncio.run(engine.execute('no-search-hits', context['instruction'], context, model=Model()))
    assert '未检索到相关内容' in result['answer']
    assert result['coverage']['total'] == 0


@pytest.mark.parametrize('kind', ['targets', 'source', 'tool'])
def test_conversation_rejects_material_sources_and_mutations(client, monkeypatch, kind):
    from interview_backend.agent import model_recovery
    monkeypatch.setattr(model_recovery, 'BACKOFF_SECONDS', 0)
    engine = client.app.state.agent.engine
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, 'Go 的接口是什么', semantic=True)
    context = apply(context, intent('read', 'none'))
    class Model:
        async def complete(self, _):
            if kind == 'tool':
                return assistant_message(tool_calls=[{'name':'evidence__read','id':'read','args':{}}])
            result = {'answer': '合成错误输出', 'claims': []}
            if kind == 'targets':
                result['targets'] = [{'resource_type':'segment','resource_id':'s1','fields':{'text':'不得修改'}}]
            else:
                result['claims'] = [{'text':'伪造资料引用','kind':'analysis','sources':[
                    {'resource_type':'segment','resource_id':'s1','revision':1}]}]
            return assistant_message(content=json.dumps(result))
    with pytest.raises(DomainError):
        asyncio.run(engine.execute('invalid-conversation-' + kind, context['instruction'], context, model=Model()))
    with client.app.state.database.transaction() as connection:
        assert connection.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0
