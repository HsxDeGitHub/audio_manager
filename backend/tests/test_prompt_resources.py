"""固定提示词资源与实际模型消息契约；只使用临时合成资料。"""
import asyncio
from importlib.resources import files
import json

from langchain_core.messages import AIMessage
import pytest

from interview_backend import prompt_catalog
from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.memory import AutomaticMemory
from interview_backend.agent.models import tool_call_self_test
from interview_backend.tools.catalog import Pagination, RecordingReference, SegmentQuery


def test_agent_uses_resource_and_preserves_dynamic_context(client, config, monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    instruction = '分析这次回答'
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1'}, instruction)
    expected = files('interview_backend').joinpath('prompts/agent/system.md').read_text(encoding='utf-8').removesuffix('\n')
    calls = []

    class Model:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            assert messages[0].content == expected
            payload = json.loads(messages[1].content)
            assert payload['instruction'] == instruction
            assert len(payload['untrusted_evidence']) == len(context['sources'])
            for source, original in zip(payload['untrusted_evidence'], context['sources']):
                assert all(source[key] == value for key, value in original.items())
            assert payload['scope'] == context['resources']
            calls.append(payload)
            return AIMessage(content=json.dumps({'answer': '合成分析', 'claims': []}))

    result = asyncio.run(AgentEngine(config, client.app.state.tools, evidence).execute('prompt-agent', instruction, context, model=Model()))
    assert calls and result['answer'] == '合成分析'


def test_memory_extraction_uses_resource_without_replacing_user_data(client, config):
    instruction = '我喜欢逐条核对证据'
    calls = []

    class Model:
        async def ainvoke(self, messages):
            assert messages[0].content == prompt_catalog.load_text('memory/extract.md')
            assert json.loads(messages[1].content) == {'user_message': instruction, 'existing': []}
            calls.append(messages)
            return AIMessage(content='{"memories": []}')

    result = asyncio.run(AutomaticMemory(config, client.app.state.memories).extract(
        {'instruction': instruction, 'message_id': 'prompt-memory'}, model=Model()))
    assert calls and result == []


def test_tool_connection_test_uses_managed_message_and_description():
    class Model:
        def client(self): return self
        def bind_tools(self, tools, tool_choice):
            assert tool_choice == 'verify_connection'
            assert tools[0]['function']['description'] == prompt_catalog.tool_description('verify_connection')
            return self
        async def ainvoke(self, messages):
            assert len(messages) == 1 and messages[0].content == prompt_catalog.load_text('connection/tool-user.md')
            return AIMessage(content='', tool_calls=[{'id': 'verify', 'name': 'verify_connection', 'args': {'value': 'ok'}}])

    assert asyncio.run(tool_call_self_test(Model())) == {'available': True, 'tool_calling': True}


def test_all_local_tool_and_parameter_descriptions_come_from_resources(client):
    catalog = json.loads(prompt_catalog.load_text('tools/descriptions.json'))
    entries = client.app.state.tools.list()
    assert {entry['id'] for entry in entries} == set(catalog['tools']) - {'verify_connection', 'mcp.fallback'}
    for entry in entries:
        assert entry['description'] == catalog['tools'][entry['id']]
    for model in (Pagination, RecordingReference, SegmentQuery):
        for name, field in model.model_fields.items():
            if name in model.__annotations__:
                assert field.description == catalog['fields'][model.__name__ + '.' + name]


@pytest.mark.parametrize('content,error', [(None, FileNotFoundError), (' \n', ValueError)])
def test_missing_or_empty_text_fails_explicitly(monkeypatch, tmp_path, content, error):
    resource = tmp_path / 'prompts' / 'test.md'
    resource.parent.mkdir()
    if content is not None: resource.write_text(content, encoding='utf-8')
    monkeypatch.setattr(prompt_catalog, 'files', lambda package: tmp_path)
    prompt_catalog.load_text.cache_clear()
    try:
        with pytest.raises(error): prompt_catalog.load_text('test.md')
    finally:
        prompt_catalog.load_text.cache_clear()


def test_invalid_or_missing_description_fails_explicitly(monkeypatch):
    monkeypatch.setattr(prompt_catalog, '_descriptions', lambda: {'tools': {'empty': ' ', 'invalid': 1}})
    for name in ('empty', 'invalid'):
        with pytest.raises(ValueError): prompt_catalog.tool_description(name)
    with pytest.raises(KeyError): prompt_catalog.tool_description('missing')
