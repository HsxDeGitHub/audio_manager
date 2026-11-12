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
from interview_backend.agent.pi_runtime import PiProviderError, run_session
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


@pytest.mark.parametrize('summary_limit', [None, 24000])
def test_provider_overflow_compacts_and_retries_same_step_without_replaying_tools(client, model_server, summary_limit):
    model = ModelSettings(baseURL=model_server.url, model='synthetic-pi').client()
    work = WorkLog(client.app.state.database, 'provider-overflow')
    normal_requests = []
    summary_requests = []
    turns = []
    executions = []
    events = []

    def respond(body):
        text = json.dumps(body['messages'], ensure_ascii=False)
        if 'context summarization assistant' in text:
            summary_requests.append(body)
            assert not body.get('tools')
            if summary_limit and len(text.encode()) > summary_limit:
                return {'status': 400, 'error': 'maximum context length exceeded synthetic-private-key'}
            return {'content': '# Goal\nSUMMARY_KEEP 保留原稿，只校对文字\n# Progress\n已读取两份结果，待输出。'}
        normal_requests.append(body)
        index = len(normal_requests)
        if index <= 2:
            return {'tool_calls': [{'id': f'read-{index}', 'name': 'synthetic_read', 'args': {'index': index}}]}
        if index == 3:
            return {'status': 400, 'error': 'maximum context length exceeded synthetic-private-key'}
        assert 'SUMMARY_KEEP' in text and 'B' * 1000 in text and 'A' * 1000 not in text
        return {'content': '{"answer":"上下文恢复完成","claims":[]}'}
    model_server.respond = respond

    async def execute_tool(arguments):
        executions.append(arguments['index'])
        return {'result': ('A' if arguments['index'] == 1 else 'B') * 50000}
    tool = PiTool('synthetic_read', '读取合成结果', ReadArguments.model_json_schema(), ReadArguments, execute_tool)
    bound = model.with_tools([tool])

    async def scenario():
        async def emit(kind, payload): events.append((kind, payload))
        async def model_step(turn, values):
            turns.append(turn)
            return await work.model(f'model:{turn}', bound, values, {'input_budget_bytes': 64000})
        async def summary_step(values):
            return await summarize(work, model, values, emit=emit)
        async def tool_step(turn, index, call):
            return await tool.execute(call['arguments'])
        return await run_session([tool], [Message(role='system', content='合成任务，保留原稿，只校对文字'),
            Message(role='user', content='读取两份结果并输出' + ('合成背景' * 5000 if summary_limit else ''))], model_step, tool_step,
            summary_step=summary_step, context_window=model.context_window)
    response, _ = asyncio.run(scenario())
    assert json.loads(response.text)['answer'] == '上下文恢复完成'
    assert executions == [1, 2] and turns == [0, 1, 2, 2]
    assert len(normal_requests) == 4 and summary_requests
    if summary_limit:
        assert len(summary_requests) > 2
    assert work.get('failure:model:2') is None
    assert 'synthetic-private-key' not in json.dumps(work.get('model_attempts:model:2'))
    assert all(kind == 'task_stage' for kind, _ in events)


def test_summary_splits_before_exceeding_configured_window_and_rejects_nonshrinking_output(client):
    class Model:
        context_window = 32768
        calls = []
        async def complete(self, messages):
            size = len(json.dumps([m.native() for m in messages], ensure_ascii=False).encode())
            self.calls.append(size)
            assert size < 64000
            return assistant_message(content='# Goal\n保留目标、范围和待处理步骤')
    model = Model()
    response = asyncio.run(summarize(WorkLog(client.app.state.database, 'bounded-summary'), model,
        [Message(role='system', content='合成摘要任务'), Message(role='user', content='合成上下文' * 40000)]))
    assert response.text.startswith('# Goal') and len(model.calls) > 2

    class NonshrinkingModel:
        context_window = 32768
        async def complete(self, _):
            return assistant_message(content='合成不可收敛摘要' * 10000)
    with pytest.raises(DomainError) as error:
        asyncio.run(summarize(WorkLog(client.app.state.database, 'nonshrinking-summary'), NonshrinkingModel(),
            [Message(role='user', content='合成上下文' * 5000)]))
    assert error.value.code == 'model_context_exceeded'


def test_api_resume_legacy_input_limit_failure_reuses_completed_batches(client, config, model_server, monkeypatch):
    from test_bounded_editing import seed
    seed(client, count=40)
    (config.data_dir / 'llm-settings.json').write_text(json.dumps({
        'baseURL': model_server.url, 'model': 'synthetic-pi', 'contextWindow': 1000000}))
    visited = []
    original_model = WorkLog.model
    blocked = False

    async def legacy_failure(self, key, *args, **kwargs):
        nonlocal blocked
        if key == 'chunk:1:model:0' and not blocked:
            blocked = True
            raise DomainError('model_input_too_large', '合成旧版64KB拦截', 422)
        return await original_model(self, key, *args, **kwargs)
    monkeypatch.setattr(WorkLog, 'model', legacy_failure)

    def respond(body):
        user = next(message for message in body['messages'] if message['role'] == 'user')
        text = user['content']
        if isinstance(text, list): text = ''.join(block.get('text', '') for block in text)
        payload = json.loads(text)
        if 'existing' in payload:
            return {'content': '{"memories":[]}'}
        assert len(json.dumps(body).encode()) > 64000
        sources = payload['untrusted_evidence']
        visited.extend(source['resource_id'] for source in sources)
        return {'content': json.dumps({'answer': '合成归属建议', 'claims': [], 'targets': [
            {'resource_type': 'segment', 'resource_id': source['resource_id'], 'fields': {'speaker': 1}}
            for source in sources]})}
    model_server.respond = respond

    def wait(identifier):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            value = client.get('/api/v1/agent/runs/' + identifier).json()
            if value['state'] not in {'queued', 'running'}: return value
            time.sleep(.02)
        pytest.fail('合成任务未完成')

    session = client.post('/api/v1/sessions', json={}).json()['id']
    started = client.post('/api/v1/agent/runs', json={'session_id': session, 'message_id': 'legacy-overflow',
        'instruction': '请整理整场说话人，正文不改。' + '合成背景。' * 3500, 'context': {'recording_id': 'r1'}})
    assert started.status_code == 200
    identifier = started.json()['id']
    failed = wait(identifier)
    assert failed['state'] == 'failed' and blocked
    assert failed['result']['error']['code'] == 'model_input_too_large'
    first_batch = list(visited)
    assert 0 < len(first_batch) < 40
    assert client.post('/api/v1/agent/runs/' + identifier + '/resume').status_code == 200
    completed = wait(identifier)
    assert completed['state'] == 'completed', completed['result']
    assert completed['result']['changeset']['count'] == 40
    assert len(visited) == len(set(visited)) == 40
    assert visited[:len(first_batch)] == first_batch


@pytest.mark.parametrize('status,detail,reason', [
    (400, 'maximum context length exceeded', 'context_overflow'),
    (413, 'request body too large', 'context_overflow'),
    (400, 'unsupported parameter', 'invalid_response'),
    (429, 'too many tokens per minute', 'invalid_response'),
])
def test_provider_context_error_classification_hides_response_body(model_server, status, detail, reason):
    model_server.respond = lambda _: {'status': status, 'error': detail + ' synthetic-private-key'}
    model = ModelSettings(baseURL=model_server.url, model='synthetic-pi').client()
    with pytest.raises(PiProviderError) as error:
        asyncio.run(model.complete([Message(role='user', content='合成请求')]))
    assert error.value.reason == reason and error.value.status_code == status
    assert 'synthetic-private-key' not in str(error.value)


def test_persistent_overflow_stops_after_native_compact_and_retry():
    turns = []
    summaries = []

    async def model_step(turn, _):
        turns.append(turn)
        raise DomainError('model_context_exceeded', '合成上下文超限', 503)
    async def summary_step(values):
        summaries.append(values)
        return assistant_message(content='# Goal\n合成任务仍待完成')
    async def tool_step(*_):
        raise AssertionError('失败模型步骤不可执行工具')
    async def scenario():
        return await asyncio.wait_for(run_session([], [Message(role='system', content='合成任务'),
            Message(role='user', content='合成内容' * 30000)], model_step, tool_step,
            summary_step=summary_step), timeout=5)
    with pytest.raises(DomainError) as error:
        asyncio.run(scenario())
    assert error.value.code == 'model_context_exceeded'
    assert turns == [0, 0] and summaries
