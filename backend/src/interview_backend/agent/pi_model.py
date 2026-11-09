"""通过 Pi AI 使用用户配置的兼容模型，保留已有消息与缓存契约。"""
import asyncio
from contextlib import suppress

from interview_backend.agent.pi_runtime import ACTIVE_BRIDGE, PiBridge, assistant_message


class PiModel:
    def __init__(self, settings, tools=(), tool_choice=None):
        from httpx import Timeout
        self.settings = settings
        self.tools = tools
        self.tool_choice = tool_choice
        self.model_name = settings.model.strip()
        self.max_retries = 0
        self.request_timeout = Timeout(connect=10, read=180, write=30, pool=10)

    def bind_tools(self, tools, tool_choice=None):
        definitions = []
        for tool in tools:
            if isinstance(tool, dict):
                definitions.append(tool.get('function', tool))
            else:
                definitions.append({'name': tool.name, 'description': tool.description,
                                    'parameters': tool.args_schema.model_json_schema()})
        return PiModel(self.settings, definitions, tool_choice)

    def payload(self, messages):
        native = []
        names = {}
        for message in messages:
            if message.type == 'system':
                native.append({'role': 'system', 'content': message.content, 'timestamp': 0})
            elif message.type == 'human':
                native.append({'role': 'user', 'content': message.content, 'timestamp': 0})
            elif message.type == 'ai':
                native.append(assistant_message(message))
                names.update((call['id'], call['name']) for call in message.tool_calls)
            elif message.type == 'tool':
                native.append({'role': 'toolResult', 'toolCallId': message.tool_call_id,
                               'toolName': names.get(message.tool_call_id, 'tool'),
                               'content': [{'type': 'text', 'text': message.content}],
                               'isError': False, 'timestamp': 0})
            else:
                raise ValueError('Unsupported model message')
        base = self.settings.base_url.strip().rstrip('/')
        if base.endswith('/chat/completions'):
            base = base[:-len('/chat/completions')]
        return {'configuration': {'baseURL': base, 'model': self.model_name,
                                 'apiKey': self.settings.api_key.get_secret_value(),
                                 'maxOutputTokens': self.settings.max_output_tokens},
                'context': {'messages': native, 'tools': list(self.tools)},
                'toolChoice': self.tool_choice}

    async def ainvoke(self, messages):
        from langchain_core.messages import message_chunk_to_message
        aggregate = None
        async for chunk in self.astream(messages):
            aggregate = chunk if aggregate is None else aggregate + chunk
        return message_chunk_to_message(aggregate)

    async def astream(self, messages):
        bridge = ACTIVE_BRIDGE.get()
        if bridge is not None:
            async for chunk in self._stream(bridge, messages):
                yield chunk
        else:
            async with PiBridge() as bridge:
                async for chunk in self._stream(bridge, messages):
                    yield chunk

    async def _stream(self, bridge, messages):
        from langchain_core.messages import AIMessageChunk
        events = asyncio.Queue()

        async def request():
            try:
                return await bridge.request('complete', self.payload(messages), events=events)
            finally:
                events.put_nowait(None)

        task = asyncio.create_task(request())
        try:
            while (event := await events.get()) is not None:
                if event['type'] == 'text_delta':
                    yield AIMessageChunk(content=event['delta'])
                else:
                    yield AIMessageChunk(content='', response_metadata={'pi_non_streaming': True})
            response = await task
            calls = [{'id': b['id'], 'name': b['name'], 'args': b['arguments']}
                     for b in response['content'] if b['type'] == 'toolCall']
            finish = {'toolUse': 'tool_calls'}.get(response['stopReason'], response['stopReason'])
            yield AIMessageChunk(content='', tool_calls=calls, response_metadata={'finish_reason': finish})
        finally:
            if not task.done():
                task.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await task
