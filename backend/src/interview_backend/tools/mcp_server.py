"""官方 SDK 的 stdio MCP 入口：只作为本地业务 API 的薄客户端，不直接打开数据库。"""
import asyncio
import json
import os
import uuid
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

from mcp import types
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server


class LocalAPIError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


class LocalAPI:
    """通过认证的本地 HTTP API 读取目录并执行工具；不导入业务写库模块。"""

    def __init__(self, base_url, token):
        parsed = urlsplit(base_url)
        if parsed.scheme != 'http' or parsed.hostname != '127.0.0.1' or parsed.port is None or parsed.path not in {'', '/'}:
            raise ValueError('MCP 服务端只接受本机回环业务 API 地址。')
        if not token or not token.isascii() or any(character.isspace() for character in token):
            raise ValueError('MCP 服务端需要有效的本地会话令牌。')
        self.base_url = base_url.rstrip('/')
        self.token = token

    def request(self, method, path, body=None):
        data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
        request = Request(self.base_url + path, data=data, method=method,
                          headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'})
        try:
            with urlopen(request, timeout=20) as response:
                return json.loads(response.read())
        except HTTPError as error:
            try:
                value = json.loads(error.read()).get('error', {})
            except (ValueError, OSError):
                value = {}
            raise LocalAPIError(value.get('code', 'backend_error'), value.get('message', '本地业务接口失败。')) from None
        except (URLError, OSError, ValueError):
            raise LocalAPIError('backend_unavailable', '本地业务服务暂时不可用。') from None

    def list_tools(self):
        return self.request('GET', '/api/v1/tools')['items']

    def invoke(self, tool_id, arguments, operation_id=None):
        body = {'arguments': arguments}
        if operation_id:
            body['operation_id'] = operation_id
        return self.request('POST', f'/api/v1/tools/{tool_id}/invoke', body)


def build_server(api, name='interview-audio-local'):
    server = Server(name)

    @server.list_tools()
    async def list_tools():
        entries = await asyncio.to_thread(api.list_tools)
        return [types.Tool(name=entry['framework_name'], title=entry['title'],
                           description=entry['description'], inputSchema=entry['input_schema'])
                for entry in entries]

    @server.call_tool()
    async def call_tool(tool_name, arguments):
        entries = await asyncio.to_thread(api.list_tools)
        entry = next((value for value in entries if value['framework_name'] == tool_name), None)
        if entry is None:
            return types.CallToolResult(content=[types.TextContent(type='text', text='工具不存在或已停用。')], isError=True)
        try:
            operation_id = 'mcp:' + uuid.uuid4().hex
            try:
                meta=server.request_context.meta
                explicit=meta.model_dump().get('operation_id') if meta is not None else None
                if explicit is not None:
                    if not isinstance(explicit,str) or not 1<=len(explicit)<=200:
                        raise LocalAPIError('invalid_operation_id','业务操作标识不合法。')
                    operation_id=explicit
            except LookupError: pass
            return await asyncio.to_thread(api.invoke, entry['id'], arguments, operation_id)
        except LocalAPIError as error:
            return types.CallToolResult(content=[types.TextContent(type='text', text=json.dumps(
                {'code': error.code, 'message': error.message}, ensure_ascii=False))], isError=True)

    return server


async def run(api):
    server = build_server(api)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


def main():
    try:
        api = LocalAPI(os.environ.get('INTERVIEW_BACKEND_URL', ''), os.environ.get('INTERVIEW_BACKEND_TOKEN', ''))
    except ValueError as error:
        raise SystemExit(str(error)) from None
    asyncio.run(run(api))


if __name__ == '__main__':
    main()
