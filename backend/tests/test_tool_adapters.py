import asyncio
from contextlib import asynccontextmanager
import pytest

from mcp import types
from mcp.server.lowlevel import Server
from mcp.shared.memory import create_connected_server_and_client_session

from interview_backend.agent.tools import framework_tools
from interview_backend.errors import DomainError
from interview_backend.tools.mcp_client import MCPClientManager
from interview_backend.tools.mcp_server import build_server
from interview_backend.tools.registry import ToolContext


class NativeAPI:
    """把 MCP 服务端薄客户端对接到同一业务目录，不直接打开数据库。"""
    def __init__(self, app):
        self.app = app

    def list_tools(self):
        return self.app.state.tools.list()

    def invoke(self, tool_id, arguments, operation_id=None):
        context = ToolContext(request_id='mcp-test', operation_id=operation_id,
                              allowed_effects=frozenset({'read'}))
        return asyncio.run(self.app.state.tools.execute(tool_id, arguments, context))


def test_mcp_server_uses_same_catalog_results_and_disabled_state(client):
    api = NativeAPI(client.app)

    async def scenario():
        server = build_server(api)
        async with create_connected_server_and_client_session(server) as session:
            listed = await session.list_tools()
            names = {tool.name for tool in listed.tools}
            assert 'library__get_recording' in names
            result = await session.call_tool('library__get_recording', {'recording_id': 'r1'})
            assert not result.isError
            native = await client.app.state.tools.execute(
                'library.get_recording', {'recording_id': 'r1'}, ToolContext(request_id='native'))
            assert result.structuredContent['data'] == native['data']
            assert result.structuredContent['tool_id'] == native['tool_id']
            client.app.state.tools.set_enabled('library.get_recording', False)
            assert 'library__get_recording' not in {tool.name for tool in (await session.list_tools()).tools}
            disabled = await session.call_tool('library__get_recording', {'recording_id': 'r1'})
            assert disabled.isError
    asyncio.run(scenario())


def test_native_langchain_and_mcp_adapters_return_equivalent_data(client):
    async def scenario():
        context = ToolContext(request_id='adapters')
        tools = {tool.name: tool for tool in framework_tools(client.app.state.tools, context)}
        adapted = await tools['library__get_recording'].ainvoke({'recording_id': 'r1'})
        native = await client.app.state.tools.execute('library.get_recording', {'recording_id': 'r1'}, context)
        assert adapted == native['data']
        server = build_server(NativeAPI(client.app))
        async with create_connected_server_and_client_session(server) as session:
            result = await session.call_tool('library__get_recording', {'recording_id': 'r1'})
            assert result.structuredContent['data'] == native['data']
            assert result.structuredContent['tool_id'] == native['tool_id']
    asyncio.run(scenario())


def test_external_mcp_tools_are_namespaced_and_disconnect_is_not_success(client):
    synthetic = Server('synthetic-external')

    @synthetic.list_tools()
    async def list_tools():
        return [types.Tool(name='echo', title='合成回声', description='只回显合成文字',
                           inputSchema={'type': 'object', 'properties': {'text': {'type': 'string'}},
                                        'required': ['text'], 'additionalProperties': False})]

    @synthetic.call_tool()
    async def call_tool(name, arguments):
        return {'echo': arguments['text']}

    broken = {'value': False}

    @asynccontextmanager
    async def connector(config):
        if broken['value']:
            raise ConnectionError('synthetic disconnect')
        async with create_connected_server_and_client_session(synthetic) as session:
            yield session

    manager = MCPClientManager(client.app.state.database, client.app.state.tools, connector=connector)

    async def scenario():
        manager.save({'id': 'synthetic', 'transport': 'stdio', 'command': 'synthetic-server', 'enabled': True})
        listed = await manager.refresh('synthetic')
        assert listed['items'][0]['connected'] is True and listed['items'][0]['tools'] == 1
        tool_id = 'mcp.synthetic.echo'
        assert tool_id in {entry['id'] for entry in client.app.state.tools.list()}
        context = ToolContext(request_id='external', allowed_effects=frozenset({'external'}))
        value = await client.app.state.tools.execute(tool_id, {'text': '合成输入'}, context)
        assert value['data']['result']['structured'] == {'echo': '合成输入'}
        broken['value'] = True
        listed = await manager.refresh('synthetic')
        assert listed['items'][0]['connected'] is False
        assert tool_id not in {entry['id'] for entry in client.app.state.tools.list()}
        with pytest.raises(DomainError) as error:
            await client.app.state.tools.execute(tool_id, {'text': '不会执行'}, context)
        assert error.value.code == 'tool_not_found'
    asyncio.run(scenario())


def test_external_timeout_is_unknown_not_success():
    from interview_backend.tools.registry import ToolRegistry, ToolSpec
    from pydantic import BaseModel

    class Input(BaseModel):
        pass

    class Output(BaseModel):
        result: dict

    class FakeSession:
        async def call_tool(self, name, arguments):
            raise TimeoutError()

    @asynccontextmanager
    async def connector(config):
        yield FakeSession()

    registry = ToolRegistry()
    manager = MCPClientManager(None, registry, connector=connector)
    # 连接器和数据库解耦后，直接验证超时不会被包装成成功结果。
    try:
        asyncio.run(manager.call(type('Config', (), {'id': 'synthetic', 'transport': 'stdio', 'command': 'x',
                                                     'args': [], 'environment': {}, 'credential_env': None})(),
                                 'slow', {}))
    except DomainError as error:
        assert error.code == 'external_result_unknown'
    else:
        raise AssertionError('超时不能返回成功')


def test_tool_toggle_and_mcp_configuration_api_persist_without_secrets(client):
    disabled = client.post('/api/v1/tools/library.get_recording/enabled', json={'enabled': False})
    assert disabled.status_code == 200
    assert 'library.get_recording' not in {item['id'] for item in client.get('/api/v1/tools').json()['items']}
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT enabled FROM tool_settings WHERE id='library.get_recording'").fetchone()[0] == 0
    assert client.post('/api/v1/tools/library.get_recording/enabled', json={'enabled': 'yes'}).status_code == 422
    assert client.post('/api/v1/mcp/connections', json={
        'id': 'Bad Name', 'transport': 'stdio', 'command': 'synthetic'}).status_code == 422
    assert client.post('/api/v1/mcp/connections', json={
        'id': 'synthetic', 'transport': 'stdio', 'command': 'synthetic-server', 'enabled': False}).status_code == 200
    listed = client.get('/api/v1/mcp/connections').json()['items']
    assert len(listed) == 1 and listed[0]['id'] == 'synthetic' and listed[0]['connected'] is False
    assert client.delete('/api/v1/mcp/connections/synthetic').status_code == 200
    assert client.get('/api/v1/mcp/connections').json()['items'] == []


def test_external_tool_name_conflict_is_rejected_without_overwriting_local_tools(client):
    from pydantic import BaseModel
    from interview_backend.tools.registry import ToolSpec

    class Input(BaseModel):
        pass

    class Output(BaseModel):
        result: dict

    local = ToolSpec(tool_id='mcp.synthetic.echo', version='1.0', title='本地同名工具',
                     description='不能被外部连接覆盖', input_model=Input, output_model=Output,
                     handler=lambda args, context: {'result': {}})
    client.app.state.tools.register(local)
    synthetic = Server('conflicting-external')

    @synthetic.list_tools()
    async def list_tools():
        return [types.Tool(name='echo', description='冲突工具',
                           inputSchema={'type': 'object', 'properties': {}})]

    @synthetic.call_tool()
    async def call_tool(name, arguments):
        return {'replaced': True}

    @asynccontextmanager
    async def connector(config):
        async with create_connected_server_and_client_session(synthetic) as session:
            yield session

    manager = MCPClientManager(client.app.state.database, client.app.state.tools, connector=connector)

    async def scenario():
        manager.save({'id': 'synthetic', 'transport': 'stdio', 'command': 'synthetic-server', 'enabled': True})
        listed = await manager.refresh('synthetic')
        assert listed['items'][0]['tools'] == 0
        assert '冲突' in listed['items'][0]['error']
        context = ToolContext(request_id='conflict', allowed_effects=frozenset({'read'}))
        # 同名本地工具仍按自身规则执行，没有被外部结果替换。
        assert await client.app.state.tools.execute('mcp.synthetic.echo', {}, context) is not None
    asyncio.run(scenario())
