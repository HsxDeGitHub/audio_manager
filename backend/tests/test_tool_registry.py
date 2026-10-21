import asyncio
from dataclasses import replace

import pytest
from pydantic import BaseModel

from interview_backend.errors import DomainError
from interview_backend.tools.registry import ToolContext, ToolRegistry, ToolSpec


class Input(BaseModel):
    value: int


class Output(BaseModel):
    doubled: int


def example_spec():
    return ToolSpec(tool_id='example.double', version='1.0', title='合成工具', description='只读取合成参数',
        input_model=Input, output_model=Output, handler=lambda args, context: {'doubled': args.value * 2})


def run(registry, name, args, context=None):
    return asyncio.run(registry.execute(name, args, context or ToolContext(request_id='fixture-request')))


def test_registration_discovery_and_native_result():
    registry = ToolRegistry()
    registry.register(example_spec())
    entry = registry.list()[0]
    assert entry['id'] == 'example.double' and entry['effect'] == 'read'
    assert entry['input_schema']['properties']['value']['type'] == 'integer'
    assert entry['framework_name'] == 'example__double'
    result = run(registry, 'example.double', {'value': 4})
    assert result == {'tool_id': 'example.double', 'tool_version': '1.0',
                      'request_id': 'fixture-request', 'data': {'doubled': 8}}


def test_duplicate_names_and_framework_alias_collisions_are_rejected():
    registry = ToolRegistry()
    spec = example_spec()
    registry.register(spec)
    with pytest.raises(ValueError):
        registry.register(spec)
    with pytest.raises(ValueError):
        registry.register(replace(spec, tool_id='example__double'))


def test_disabled_and_unknown_tools_are_checked_at_execution():
    registry = ToolRegistry()
    registry.register(example_spec())
    registry.set_enabled('example.double', False)
    assert registry.list() == []
    assert registry.list(include_disabled=True)[0]['enabled'] is False
    with pytest.raises(DomainError) as error:
        run(registry, 'example.double', {'value': 1})
    assert error.value.code == 'tool_disabled'
    with pytest.raises(DomainError) as error:
        run(registry, 'unknown.tool', {})
    assert error.value.code == 'tool_not_found'


def test_argument_and_output_errors_do_not_leak_data():
    registry = ToolRegistry()
    registry.register(example_spec())
    with pytest.raises(DomainError) as error:
        run(registry, 'example.double', {'value': 'private-content'})
    assert error.value.code == 'invalid_tool_arguments'
    assert 'private-content' not in str(error.value)
    registry.register(replace(example_spec(), tool_id='example.invalid', handler=lambda *_: {'doubled': 'private-output'}))
    with pytest.raises(DomainError) as error:
        run(registry, 'example.invalid', {'value': 1})
    assert error.value.code == 'invalid_tool_result'
    assert 'private-output' not in str(error.value)


def test_read_context_cannot_authorize_a_write_tool():
    registry = ToolRegistry()
    called = []
    registry.register(replace(example_spec(), effect='write', handler=lambda *_: called.append(True)))
    with pytest.raises(DomainError) as error:
        run(registry, 'example.double', {'value': 1})
    assert error.value.code == 'tool_effect_denied' and called == []
    context = ToolContext(request_id='fixture', allowed_effects=frozenset({'write'}))
    with pytest.raises(DomainError) as error:
        run(registry, 'example.double', {'value': 1}, context)
    assert error.value.code == 'operation_id_required' and called == []


def test_api_and_native_catalog_return_equivalent_business_data(client):
    listing = client.get('/api/v1/tools').json()
    ids = {item['id'] for item in listing['items']}
    assert ids == {'library.list_recordings', 'library.get_recording', 'transcript.list_segments'}
    assert all(item['effect'] == 'read' for item in listing['items'])
    response = client.post('/api/v1/tools/library.get_recording/invoke', json={'arguments': {'recording_id': 'r1'}})
    assert response.status_code == 200
    assert response.json()['data'] == client.get('/api/v1/recordings/r1').json()
    native = run(client.app.state.tools, 'transcript.list_segments', {'run_id': 'run1', 'limit': 1})
    api = client.post('/api/v1/tools/transcript.list_segments/invoke',
                      json={'arguments': {'run_id': 'run1', 'limit': 1}})
    assert native['data'] == api.json()['data']
    assert api.json()['data']['total'] == 2


def test_api_arguments_cannot_override_host_context(client):
    response = client.post('/api/v1/tools/library.get_recording/invoke',
        json={'arguments': {'recording_id': 'r1', 'allowed_effects': ['write']}})
    assert response.status_code == 422
    assert response.json()['error']['code'] == 'invalid_tool_arguments'


def test_timeout_and_cancellation_are_not_successes():
    async def slow(*_):
        await asyncio.sleep(60)
        return {'doubled': 1}
    registry = ToolRegistry()
    registry.register(replace(example_spec(), handler=slow, timeout_seconds=0.01))
    with pytest.raises(DomainError) as error:
        run(registry, 'example.double', {'value': 1})
    assert error.value.code == 'tool_timeout'

    async def cancel():
        task = asyncio.create_task(registry.execute('example.double', {'value': 1}, ToolContext(request_id='cancel')))
        await asyncio.sleep(0)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    asyncio.run(cancel())


def test_disabled_tool_cannot_be_invoked_after_discovery(client):
    client.app.state.tools.set_enabled('library.get_recording', False)
    assert 'library.get_recording' not in {item['id'] for item in client.get('/api/v1/tools').json()['items']}
    response = client.post('/api/v1/tools/library.get_recording/invoke', json={'arguments': {'recording_id': 'r1'}})
    assert response.status_code == 409 and response.json()['error']['code'] == 'tool_disabled'
