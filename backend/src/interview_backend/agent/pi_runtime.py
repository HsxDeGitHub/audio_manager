"""Pi SDK 的本地 JSONL 桥，工具执行始终回到绑定业务上下文的 Python 闭包。"""
import asyncio
from contextlib import suppress
from contextvars import ContextVar
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

from interview_backend.errors import DomainError


ACTIVE_BRIDGE = ContextVar('pi_bridge', default=None)
MAX_RECORD_BYTES = 8 * 1024 * 1024


def runtime_paths():
    packaged = Path(sys.prefix).parent / 'pi-agent'
    source = Path(__file__).resolve().parents[3] / 'pi-agent'
    runtime = packaged if (packaged / 'runner.mjs').is_file() else source
    bundled_node = packaged.parent / 'node' / 'bin' / 'node'
    node = str(bundled_node) if bundled_node.is_file() else shutil.which('node')
    return runtime, node


def available():
    runtime, node = runtime_paths()
    return bool(node and (runtime / 'runner.mjs').is_file()
                and (runtime / 'node_modules/@earendil-works/pi-coding-agent/dist/index.js').is_file())


class PiProviderError(Exception):
    """仅保留可分类的错误，不跨进程返回上游响应和凭据。"""
    def __init__(self, reason, status=None):
        super().__init__('Pi model request failed')
        self.reason = reason
        self.status_code = status


class PiBridge:
    def __init__(self):
        self.process = None
        self.pending = {}
        self.callbacks = {}
        self.callback_errors = {}
        self.handlers = set()
        self.sequence = 0
        self.reader = None

    async def __aenter__(self):
        runtime, node = runtime_paths()
        if not available():
            raise DomainError('pi_runtime_unavailable', 'Pi 运行时未就绪，请安装助手依赖或重新构建应用。', 503)
        self.workspace = tempfile.TemporaryDirectory(prefix='tingyue-pi-')
        environment = {k: v for k, v in os.environ.items() if k in {
            'PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY',
            'NO_PROXY', 'https_proxy', 'http_proxy', 'all_proxy', 'no_proxy', 'NODE_EXTRA_CA_CERTS',
        }}
        try:
            self.process = await asyncio.create_subprocess_exec(
                node, str(runtime / 'runner.mjs'), self.workspace.name,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, env=environment, limit=MAX_RECORD_BYTES)
        except OSError:
            self.workspace.cleanup()
            raise DomainError('pi_runtime_unavailable', '无法启动 Pi 运行时，请检查应用安装。', 503) from None
        self.context_token = ACTIVE_BRIDGE.set(self)
        self.reader = asyncio.create_task(self._read())
        return self

    async def __aexit__(self, *_):
        ACTIVE_BRIDGE.reset(self.context_token)
        try:
            for task in list(self.handlers):
                task.cancel()
            if self.handlers:
                await asyncio.gather(*self.handlers, return_exceptions=True)
            self.process.stdin.close()
            if self.process.returncode is None:
                try:
                    await asyncio.wait_for(self.process.wait(), 2)
                except TimeoutError:
                    with suppress(ProcessLookupError):
                        self.process.kill()
                    await self.process.wait()
        finally:
            # 再次取消清理任务时也先终止所属进程，临时配置同步回收。
            if self.process.returncode is None:
                with suppress(ProcessLookupError):
                    self.process.kill()
            self.reader.cancel()
            self.workspace.cleanup()
        await asyncio.gather(self.reader, return_exceptions=True)

    async def send(self, value):
        data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode() + b'\n'
        if len(data) > MAX_RECORD_BYTES:
            raise DomainError('pi_message_too_large', '助手通信内容超过处理上限，请缩小任务范围。', 422)
        self.process.stdin.write(data)
        await self.process.stdin.drain()

    async def request(self, method, payload, callback=None, events=None):
        self.sequence += 1
        identifier = str(self.sequence)
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = (future, events)
        if callback:
            self.callbacks[identifier] = callback
        try:
            await self.send({'id': identifier, 'method': method, 'payload': payload})
            # 会话中的每个模型/工具步骤由业务执行器分别限时。
            async with asyncio.timeout(None if callback else 660):
                result = await future
            if identifier in self.callback_errors:
                raise self.callback_errors[identifier]
            return result
        except asyncio.CancelledError:
            with suppress(BrokenPipeError, ConnectionResetError):
                await self.send({'type': 'cancel', 'id': identifier})
            raise
        except Exception:
            if identifier in self.callback_errors:
                raise self.callback_errors[identifier]
            raise
        finally:
            self.pending.pop(identifier, None)
            self.callbacks.pop(identifier, None)
            self.callback_errors.pop(identifier, None)

    async def _callback(self, record):
        owner = record['owner']
        try:
            result = await self.callbacks[owner](record['method'], record['payload'])
            await self.send({'type': 'callback_result', 'id': record['id'], 'result': result})
        except asyncio.CancelledError as error:
            self.callback_errors.setdefault(owner, error)
            with suppress(BrokenPipeError, ConnectionResetError):
                await self.send({'type': 'callback_result', 'id': record['id'], 'error': True})
            raise
        except Exception as error:
            self.callback_errors.setdefault(owner, error)
            await self.send({'type': 'callback_result', 'id': record['id'], 'error': True})

    async def _read(self):
        try:
            while line := await self.process.stdout.readline():
                record = json.loads(line)
                if record.get('type') == 'callback':
                    task = asyncio.create_task(self._callback(record))
                    self.handlers.add(task)
                    task.add_done_callback(self.handlers.discard)
                    continue
                entry = self.pending.get(record.get('id'))
                if entry is None:
                    continue
                future, events = entry
                if record.get('type') == 'event':
                    if events is not None:
                        events.put_nowait(record['event'])
                elif not future.done():
                    error = record.get('error')
                    if error:
                        if record.get('method') == 'complete':
                            future.set_exception(PiProviderError(error.get('reason'), error.get('status')))
                        else:
                            future.set_exception(DomainError('pi_runtime_failed', 'Pi 助手运行失败，已完成的操作回执已保留。', 503))
                    else:
                        future.set_result(record['result'])
        except asyncio.CancelledError:
            raise
        except (ValueError, OSError):
            pass
        finally:
            for future, _ in list(self.pending.values()):
                if not future.done():
                    future.set_exception(DomainError('pi_runtime_failed', 'Pi 进程连接已中断，已完成的操作回执已保留。', 503))


def host_messages(system_prompt, messages):
    from interview_backend.agent.protocol import Message
    return [Message(role='system', content=system_prompt)] + [Message.model_validate(value) for value in messages]


async def run_session(tools, messages, model_step, tool_step):
    """Pi 执行工具循环，业务步骤仍使用稳定编号和原有回执。"""
    from interview_backend.agent.protocol import Message
    turn = -1
    call_index = 0
    tool_names = {tool.name for tool in tools}
    originals = []

    async def callback(method, payload):
        nonlocal turn, call_index
        if method == 'model':
            turn += 1
            call_index = 0
            if turn > 8:
                raise DomainError('tool_limit_reached', '当前任务的工具调用轮次超过上限，请缩小范围后继续。', 409)
            values = host_messages(payload['systemPrompt'], payload['messages'])
            response = await model_step(turn, values)
            if turn == 8 and response.tool_calls:
                raise DomainError('tool_limit_reached', '当前任务的工具调用轮次超过上限，请缩小范围后继续。', 409)
            if any(call['name'] not in tool_names for call in response.tool_calls):
                raise DomainError('tool_not_allowed', '该工具在当前用户消息范围内不可用。', 403)
            from pydantic import ValidationError
            native = response.native()
            originals.clear()
            for call, block in zip(response.tool_calls, [b for b in native['content'] if b['type'] == 'toolCall']):
                tool = next(t for t in tools if t.name == call['name'])
                try:
                    arguments = tool.input_model.model_validate(call['arguments'])
                except ValidationError:
                    raise DomainError('invalid_tool_arguments', '工具参数不合法。', 422) from None
                block['arguments'] = arguments.model_dump(mode='json', exclude_unset=True)
                originals.append(call)
            return native
        index = call_index
        call_index += 1
        from interview_backend.services.common import encode
        output = await tool_step(turn, index, originals[index])
        return {'text': encode(output)}

    async with PiBridge() as bridge:
        value = await bridge.request('agent', {
            'systemPrompt': messages[0].text, 'prompt': messages[-1].text,
            'tools': [{'name': t.name, 'description': t.description, 'parameters': t.parameters}
                      for t in tools],
        }, callback=callback)
        return Message.model_validate(value['response']), host_messages(value['systemPrompt'], value['messages'])[:-1]
