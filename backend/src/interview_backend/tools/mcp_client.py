"""外部 MCP 连接：命名空间、凭据引用、停用与断连状态；不承载第二套业务规则。"""
import asyncio
from contextlib import asynccontextmanager
from datetime import timedelta
import json
import os
import re
import sys
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, create_model, model_validator

from interview_backend.errors import DomainError
from interview_backend.tools.registry import ToolSpec


class MCPConnection(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(pattern=r'^[a-z][a-z0-9_-]{0,31}$')
    transport: Literal['stdio', 'streamable_http'] = 'stdio'
    command: str | None = Field(default=None, max_length=500)
    args: list[str] = Field(default_factory=list, max_length=50)
    url: str | None = Field(default=None, max_length=1000)
    environment: dict[str, str] = Field(default_factory=dict)
    credential_env: str | None = Field(default=None, pattern=r'^[A-Z][A-Z0-9_]{0,63}$')
    enabled: bool = True

    @model_validator(mode='after')
    def validate_transport(self):
        if self.transport == 'stdio':
            if not self.command or not self.command.strip():
                raise ValueError('stdio 连接必须提供启动命令。')
            if any('\x00' in part for part in [self.command, *self.args]):
                raise ValueError('启动命令不合法。')
        else:
            if not self.url or not re.match(r'^https?://', self.url):
                raise ValueError('HTTP 连接必须提供 http(s) 地址。')
        for key, value in self.environment.items():
            if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,63}', key) or '\x00' in value:
                raise ValueError('环境变量名称或值不合法。')
        return self


class ExternalOutput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    result: dict


def _schema_model(server, tool_name, schema):
    properties = schema.get('properties') or {}
    required = set(schema.get('required') or [])
    fields = {}
    kinds = {'string': str, 'integer': int, 'number': float, 'boolean': bool,
             'array': list, 'object': dict}
    for key, prop in properties.items():
        if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,63}', key):
            continue
        kind = kinds.get(prop.get('type')) if isinstance(prop, dict) else None
        base = kind or Any
        if key in required:
            fields[key] = (base, Field(..., description=str(prop.get('description', ''))[:500]))
        else:
            fields[key] = (base | None, Field(None, description=str(prop.get('description', ''))[:500]))
    name = 'External' + re.sub(r'[^A-Za-z0-9]', '_', f'{server}_{tool_name}')[:48]
    return create_model(name, __config__=ConfigDict(extra='allow'), **fields)


def _tool_id(server, tool_name):
    cleaned = re.sub(r'[^a-z0-9_.-]', '_', tool_name.lower())
    identifier = f'mcp.{server}.{cleaned}'[:64]
    return identifier if re.fullmatch(r'[a-z][a-z0-9_.-]{0,63}', identifier) else identifier[:63] + 'x'


class MCPClientManager:
    def __init__(self, database, registry, connector=None):
        self.database, self.registry = database, registry
        self.connector = connector or self._connect
        self.registered: dict[str, list[str]] = {}
        self.status: dict[str, dict] = {}

    @staticmethod
    def _decode(row):
        try:
            return MCPConnection.model_validate(json.loads(row['config']))
        except (ValueError, TypeError):
            return None

    def connection(self, identifier):
        with self.database.transaction() as c:
            row = c.execute('SELECT * FROM mcp_connections WHERE id=?', (identifier,)).fetchone()
            if row is None:
                raise DomainError('mcp_not_configured', '外部 MCP 连接不存在。', 404)
            config = self._decode(row)
            if config is None:
                raise DomainError('invalid_mcp_config', '外部 MCP 配置结构不合法。', 503)
            return config

    def list(self):
        with self.database.transaction() as c:
            configs = [self._decode(row) for row in c.execute('SELECT * FROM mcp_connections ORDER BY id')]
        values = []
        for config in configs:
            if config is None:
                continue
            status = self.status.get(config.id, {})
            values.append({**config.model_dump(), **{'connected': status.get('connected', False),
                                                     'error': status.get('error'), 'tools': status.get('tools', 0)}})
        return {'items': values}

    def save(self, value):
        try:
            config = MCPConnection.model_validate(value)
        except ValidationError:
            raise DomainError('invalid_mcp_config', '外部 MCP 配置不合法。', 422) from None
        with self.database.transaction(True) as c:
            c.execute('INSERT INTO mcp_connections VALUES(?,?) ON CONFLICT(id) DO UPDATE SET config=excluded.config',
                      (config.id, json.dumps(config.model_dump(), ensure_ascii=False, sort_keys=True)))
        return config

    async def remove(self, identifier):
        self.connection(identifier)
        self._unregister(identifier)
        with self.database.transaction(True) as c:
            c.execute('DELETE FROM mcp_connections WHERE id=?', (identifier,))
        self.status.pop(identifier, None)

    def _unregister(self, server):
        previous = {tool_id: self.registry._enabled.get(tool_id, True) for tool_id in self.registered.get(server, [])}
        for tool_id in self.registered.pop(server, []):
            self.registry.unregister(tool_id)
        return previous

    async def remove_all(self):
        for server in list(self.registered):
            self._unregister(server)

    async def refresh(self, identifier=None):
        if identifier is None:
            with self.database.transaction() as c:
                rows = c.execute('SELECT * FROM mcp_connections ORDER BY id').fetchall()
            for row in rows:
                config = self._decode(row)
                if config is not None:
                    await self._refresh_one(config)
            return self.list()
        config = self.connection(identifier)
        await self._refresh_one(config)
        return self.list()

    async def _refresh_one(self, config):
        previous = self._unregister(config.id)
        if not config.enabled:
            self.status[config.id] = {'connected': False, 'error': None, 'tools': 0, 'disabled': True}
            return
        try:
            async with asyncio.timeout(20):
                async with self.connector(config) as session:
                    listed = await session.list_tools()
            tools = []
            error = None
            for tool in listed.tools:
                tool_id = _tool_id(config.id, tool.name)
                if tool_id in self.registry._tools:
                    error = '工具名称冲突，已跳过冲突项。'
                    continue
                input_model = _schema_model(config.id, tool.name, tool.inputSchema or {'type': 'object'})
                spec = ToolSpec(tool_id=tool_id, version='external', title=tool.title or tool.name,
                                description=(tool.description or '外部 MCP 工具')[:2000],
                                input_model=input_model, output_model=ExternalOutput,
                                effect='external', idempotent=False, timeout_seconds=30,
                                handler=self._handler(config, tool.name))
                try:
                    self.registry.register(spec)
                except ValueError:
                    error = '工具名称冲突，已跳过冲突项。'
                    continue
                tools.append(tool_id)
                if previous.get(tool_id) is False:
                    self.registry.set_enabled(tool_id, False)
            self.registered[config.id] = tools
            self.status[config.id] = {'connected': True, 'error': error, 'tools': len(tools)}
        except (asyncio.TimeoutError, Exception) as failure:
            self.registered[config.id] = []
            self.status[config.id] = {'connected': False,
                                      'error': '外部 MCP 连接失败或已断开，未注册任何工具。', 'tools': 0}

    def _handler(self, config, tool_name):
        async def execute(args, context):
            return await self.call(config, tool_name, args.model_dump(exclude_none=True))
        return execute

    async def call(self, config, tool_name, arguments):
        try:
            async with asyncio.timeout(30):
                async with self.connector(config) as session:
                    result = await session.call_tool(tool_name, arguments)
            content = [block.model_dump(mode='json', exclude_none=True) for block in result.content]
            if result.isError:
                raise DomainError('external_tool_failed', '外部 MCP 工具返回失败，不能视为成功。', 409)
            return {'result': {'content': content, 'structured': result.structuredContent}}
        except DomainError:
            raise
        except asyncio.TimeoutError:
            raise DomainError('external_result_unknown', '外部 MCP 工具超时，结果未知，请勿自动重试。', 504) from None
        except Exception:
            raise DomainError('external_disconnected', '外部 MCP 连接已断开，未获得可信结果。', 503) from None

    @asynccontextmanager
    async def _connect(self, config):
        from mcp import ClientSession, StdioServerParameters
        from mcp.client.stdio import stdio_client
        from mcp.client.streamable_http import streamablehttp_client
        if config.transport == 'stdio':
            environment = {**os.environ, **config.environment}
            command, arguments = config.command, config.args
            if os.name == 'posix':
                command = sys.executable
                arguments = ['-m', 'interview_backend.tools.mcp_supervisor', '--parent-pid', str(os.getpid()),
                             '--', config.command, *config.args]
            params = StdioServerParameters(command=command, args=arguments, env=environment)
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=30)) as session:
                    await session.initialize(); yield session
        else:
            headers = {}
            token = os.environ.get(config.credential_env) if config.credential_env else None
            if token:
                headers['Authorization'] = 'Bearer ' + token
            async with streamablehttp_client(config.url, headers=headers, timeout=20) as (read, write, _):
                async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=30)) as session:
                    await session.initialize(); yield session
