"""通过 Pi AI 调用用户模型，输入输出直接使用 Pi 原生消息和事件。"""
import asyncio
from contextlib import suppress

from interview_backend.agent.pi_runtime import ACTIVE_BRIDGE, PiBridge
from interview_backend.agent.protocol import Message


class PiModel:
    def __init__(self, settings, tools=(), tool_choice=None):
        self.settings = settings
        self.tools = tools
        self.tool_choice = tool_choice
        self.model_name = settings.model.strip()

    def with_tools(self, tools, tool_choice=None):
        definitions = []
        for tool in tools:
            if isinstance(tool, dict):
                definitions.append(tool.get('function', tool))
            else:
                definitions.append({'name': tool.name, 'description': tool.description,
                                    'parameters': tool.parameters})
        return PiModel(self.settings, definitions, tool_choice)

    def payload(self, messages):
        base = self.settings.base_url.strip().rstrip('/')
        if base.endswith('/chat/completions'):
            base = base[:-len('/chat/completions')]
        return {'configuration': {'baseURL': base, 'model': self.model_name,
                                 'apiKey': self.settings.api_key.get_secret_value(),
                                 'maxOutputTokens': self.settings.max_output_tokens},
                'context': {'messages': [message.native() for message in messages], 'tools': list(self.tools)},
                'toolChoice': self.tool_choice}

    async def complete(self, messages):
        result = None
        async for event in self.stream(messages):
            if event['type'] == 'done':
                result = event['message']
        if result is None:
            raise ValueError('Empty Pi model response')
        return result

    async def stream(self, messages):
        bridge = ACTIVE_BRIDGE.get()
        if bridge is not None:
            async for event in self._stream(bridge, messages):
                yield event
        else:
            async with PiBridge() as bridge:
                async for event in self._stream(bridge, messages):
                    yield event

    async def _stream(self, bridge, messages):
        events = asyncio.Queue()

        async def request():
            try:
                return await bridge.request('complete', self.payload(messages), events=events)
            finally:
                events.put_nowait(None)

        task = asyncio.create_task(request())
        try:
            while (event := await events.get()) is not None:
                yield event
            yield {'type': 'done', 'message': Message.model_validate(await task)}
        finally:
            if not task.done():
                task.cancel()
            with suppress(asyncio.CancelledError, Exception):
                await task
