"""真实 Pi SDK 自动压缩和可配置窗口，只使用本机合成模型与临时数据。"""
import asyncio
import json
from pathlib import Path
import shutil
import time

import pytest
from pydantic import BaseModel, Field, ValidationError
from pi_fakes import assistant_message
from test_pi_runtime import model_server

from interview_backend.agent.compaction import summarize
from interview_backend.agent.models import ModelSettings
from interview_backend.agent.pi_runtime import run_session
from interview_backend.agent.protocol import Message
from interview_backend.agent.tools import PiTool
from interview_backend.agent.work import WorkLog
from interview_backend.errors import DomainError


@pytest.fixture(autouse=True)
def source_pi_runtime(monkeypatch):
    from interview_backend.agent import pi_runtime
    source = Path(__file__).resolve().parents[1] / 'pi-agent'
    monkeypatch.setattr(pi_runtime, 'runtime_paths', lambda: (source, shutil.which('node')))


class ReadArguments(BaseModel):
    index: int = Field(ge=1, le=2)


def test_context_window_defaults_and_custom_value_round_trip(config):
    default = ModelSettings(baseURL='http://127.0.0.1:1/v1', model='synthetic')
    assert default.context_window == default.client().context_window == 1_000_000
    assert default.client().payload([])['configuration']['contextWindow'] == 1_000_000
    config.data_dir.mkdir(parents=True, exist_ok=True)
    (config.data_dir / 'llm-settings.json').write_text(json.dumps({
        'baseURL':'http://127.0.0.1:1/v1', 'model':'synthetic', 'contextWindow':131072}))
    assert ModelSettings.load(config.data_dir).client().context_window == 131072
    with pytest.raises(ValidationError):
        ModelSettings(baseURL='http://127.0.0.1:1/v1', model='synthetic', contextWindow=1024)


def test_summary_repair_keeps_native_summary_format_and_hides_preview(client, monkeypatch):
    from interview_backend.agent import model_recovery
    monkeypatch.setattr(model_recovery, 'BACKOFF_SECONDS', 0)
    work = WorkLog(client.app.state.database, 'summary-repair')
    class Model:
        calls = 0
        async def complete(self, messages):
            self.calls += 1
            if self.calls == 1:
                return assistant_message(content='')
            assert '摘要' in messages[-1].text and '只返回完整 JSON' not in messages[-1].text
            return assistant_message(content='# Goal\n合成摘要保留关键约束')
    model = Model()
    events = []
    async def execute():
        async def emit(kind, payload): events.append((kind, payload))
        return await summarize(work, model, [Message(role='user', content='合成会话')], emit=emit)
    response = asyncio.run(execute())
    assert response.text.startswith('# Goal') and model.calls == 2
    assert all(kind == 'task_stage' for kind, _ in events)


def test_summary_checks_source_versions_before_model_call(client):
    work = WorkLog(client.app.state.database, 'summary-stale-source')
    class Model:
        async def complete(self, _):
            raise AssertionError('过期来源不可发送给摘要模型')
    with pytest.raises(DomainError) as error:
        asyncio.run(summarize(work, Model(), [Message(role='user', content='合成资料')],
            [{'resource_type':'segment','resource_id':'s1','revision':999}]))
    assert error.value.code == 'stale_source'


def test_native_auto_compaction_summarizes_and_continues_without_replaying_tools(client, model_server):
    calls = []
    normal_requests = []
    summary_requests = []
    events = []
    settings = ModelSettings(baseURL=model_server.url, model='synthetic-pi', contextWindow=32768)
    model = settings.client()
    work = WorkLog(client.app.state.database, 'native-auto-compaction')

    async def execute_tool(arguments):
        index = arguments['index']
        calls.append(index)
        return {'result': ('A' if index == 1 else 'B') * 50_000}
    tool = PiTool('synthetic_read', '读取合成长结果', ReadArguments.model_json_schema(), ReadArguments, execute_tool)
    bound = model.with_tools([tool])

    def respond(body):
        texts = []
        for item in body['messages']:
            content = item.get('content') or ''
            texts.append(content if isinstance(content, str) else ''.join(b.get('text','') for b in content))
        if any('context summarization assistant' in text for text in texts):
            summary_requests.append(body)
            assert not body.get('tools')
            return {'content':'# Goal\nSUMMARY_KEEP 继续完成任务\n# Progress\n已读取第一份合成结果。'}
        normal_requests.append(body)
        index = len(normal_requests)
        if index <= 2:
            return {'tool_calls':[{'id':f'read-{index}','name':'synthetic_read','args':{'index':index}}]}
        assert 'SUMMARY_KEEP' in '\n'.join(texts)
        assert 'A' * 1000 not in '\n'.join(texts)
        assert 'B' * 1000 in '\n'.join(texts)
        return {'content':'{"answer":"合成压缩后完成","claims":[]}'}
    model_server.respond = respond

    async def scenario():
        async def emit(kind, payload): events.append((kind, payload))
        async def model_step(turn, messages):
            return await work.model(f'model:{turn}', bound, messages,
                {'input_budget_bytes':64000}, emit=emit)
        async def summary_step(messages):
            return await summarize(work, model, messages, emit=emit)
        async def tool_step(turn, index, call):
            return await tool.execute(call['arguments'])
        return await run_session([tool], [Message(role='system', content='合成任务'),
            Message(role='user', content='依次读取两份结果并保留必要进展')],
            model_step, tool_step, summary_step=summary_step, context_window=model.context_window)
    response, _ = asyncio.run(scenario())
    assert json.loads(response.text)['answer'] == '合成压缩后完成'
    assert calls == [1, 2] and len(normal_requests) == 3 and summary_requests
    assert any('压缩上下文' in payload.get('message', '') for kind, payload in events if kind == 'task_stage')
    assert not any('SUMMARY_KEEP' in payload.get('text', '') for kind, payload in events if kind == 'answer_delta')


def test_cancel_during_native_compaction_cleans_owned_process(monkeypatch):
    from interview_backend.agent import pi_runtime
    instances = []
    class TrackedBridge(pi_runtime.PiBridge):
        async def __aenter__(self):
            value = await super().__aenter__()
            instances.append(value)
            return value
    monkeypatch.setattr(pi_runtime, 'PiBridge', TrackedBridge)
    tool = PiTool('synthetic_read', '合成长结果', ReadArguments.model_json_schema(), ReadArguments, None)

    async def scenario():
        summary_started = asyncio.Event()
        async def model_step(turn, messages):
            response = assistant_message(tool_calls=[{'id':f'read-{turn}','name':'synthetic_read','args':{'index':turn + 1}}])
            response.timestamp = int(time.time() * 1000)
            return response
        async def tool_step(turn, index, call):
            return {'result':'X' * 50_000}
        async def summary_step(messages):
            summary_started.set()
            await asyncio.Event().wait()
        task = asyncio.create_task(run_session([tool], [Message(role='system', content='合成任务'),
            Message(role='user', content='依次读取')], model_step, tool_step,
            summary_step=summary_step, context_window=32768))
        await asyncio.wait_for(summary_started.wait(), 5)
        task.cancel()
        with pytest.raises(asyncio.CancelledError): await asyncio.wait_for(task, 3)
        assert instances and instances[0].process.returncode is not None
        assert not Path(instances[0].workspace.name).exists()
    asyncio.run(scenario())
