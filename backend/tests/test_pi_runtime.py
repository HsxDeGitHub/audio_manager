"""真实 Pi SDK 与合成兼容模型服务的集成验收，不使用个人配置或远端模型。"""
import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time

from langchain_core.messages import HumanMessage
import pytest

from interview_backend.agent.models import ModelSettings
from interview_backend.agent.pi_runtime import PiBridge, PiProviderError


@pytest.fixture
def model_server():
    class State:
        requests = []
        started = threading.Event()
        release = threading.Event()
        status = 200
        streaming_supported = True

        def respond(self, body):
            return {'content': '{"answer":"合成回答","claims":[]}'}

    state = State()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            state.requests.append(body)
            state.started.set()
            response = state.respond(body)
            status = 501 if body.get('stream') and not state.streaming_supported else state.status
            self.send_response(status)
            self.send_header('Content-Type', 'text/event-stream' if status == 200 and body.get('stream') else 'application/json')
            self.end_headers()
            try:
                if status != 200:
                    self.wfile.write(json.dumps({'error': {'message': 'synthetic-private-key', 'code': status}}).encode())
                    return
                if not body.get('stream'):
                    self.wfile.write(json.dumps({'id': 'synthetic-response', 'object': 'chat.completion',
                        'created': 0, 'model': 'synthetic-pi', 'choices': [
                            {'index': 0, 'message': {'role': 'assistant', 'content': response['content']},
                             'finish_reason': 'stop'}]}).encode())
                    return
                if 'tool_calls' in response:
                    delta = {'role': 'assistant', 'tool_calls': [
                        {'index': index, 'id': call['id'], 'type': 'function',
                         'function': {'name': call['name'], 'arguments': json.dumps(call['args'])}}
                        for index, call in enumerate(response['tool_calls'])]}
                    values = [delta]
                    finish = 'tool_calls'
                else:
                    text = response['content']
                    values = [{'role': 'assistant', 'content': text[i:i + 12]} for i in range(0, len(text), 12)]
                    finish = 'stop'
                for delta in values + [{}]:
                    chunk = {'id': 'synthetic-response', 'object': 'chat.completion.chunk',
                             'created': 0, 'model': 'synthetic-pi',
                             'choices': [{'index': 0, 'delta': delta, 'finish_reason': finish if not delta else None}]}
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                    self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    state.url = f'http://127.0.0.1:{server.server_port}/v1'
    yield state
    state.release.set()
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)


def test_production_api_uses_pi_tools_and_atomic_undo(client, config, model_server, monkeypatch, tmp_path):
    engine = client.app.state.agent.engine
    del engine.intent_model
    del engine.synthesis_model
    config.data_dir.joinpath('llm-settings.json').write_text(json.dumps({
        'baseURL': model_server.url, 'apiKey': 'synthetic-pi-key', 'model': 'synthetic-pi'}))
    foreign = tmp_path / 'foreign-pi'
    extension = foreign / 'extensions' / 'untrusted.mjs'
    extension.parent.mkdir(parents=True)
    marker = tmp_path / 'unexpected-extension'
    extension.write_text(f'import fs from "node:fs"; fs.writeFileSync({json.dumps(str(marker))}, "loaded");')
    monkeypatch.setenv('PI_CODING_AGENT_DIR', str(foreign))
    seen_tools = []
    invalid_answer_sent = False

    def respond(body):
        nonlocal invalid_answer_sent
        user = next((m for m in body['messages'] if m['role'] == 'user'), None)
        payload = json.loads(user['content'])
        if 'schema' in payload:
            return {'content': json.dumps({'mode': 'edit', 'reading': 'full', 'edit_target': 'transcript',
                'import_documents': False, 'actions': [], 'constraints': [], 'clarification': ''})}
        if 'existing' in payload:
            return {'content': '{"memories":[]}'}
        seen_tools.extend(tool['function']['name'] for tool in body.get('tools', []))
        count = sum(message['role'] == 'tool' for message in body['messages'])
        if count == 0:
            return {'tool_calls': [{'id': 'read-1', 'name': 'evidence__read', 'args': {}}]}
        if count == 1:
            source = next(s for s in payload['untrusted_evidence'] if s['resource_id'] == 's1')
            speaker = next(s for s in payload['speaker_catalog'] if s['speaker'] == 0)
            return {'tool_calls': [
                {'id': 'edit-1', 'name': 'changesets__apply', 'args': {'targets': [
                    {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': source['revision'],
                     'fields': {'text': '修正后的合成问题'}}]}},
                {'id': 'speaker-1', 'name': 'speakers__rename', 'args': {
                    'run_id': 'run1', 'speaker': 0, 'expected_revision': speaker['revision'], 'name': '面试官'}},
            ]}
        if not invalid_answer_sent:
            invalid_answer_sent = True
            return {'content': '合成非法 JSON'}
        return {'content': '{"answer":"已完成合成修订","claims":[]}'}

    model_server.respond = respond
    session = client.post('/api/v1/sessions', json={}).json()['id']
    body = {'session_id': session, 'message_id': 'pi-production', 'instruction': '修正正文并将0号说话人标为面试官',
            'context': {'recording_id': 'r1'}}
    started = client.post('/api/v1/agent/runs', json=body)
    assert started.status_code == 200
    identifier = started.json()['id']
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        run = client.get('/api/v1/agent/runs/' + identifier).json()
        if run['state'] not in {'queued', 'running'}:
            break
        time.sleep(.02)
    assert run['state'] == 'completed', run
    assert run['result']['changeset']['count'] == 2
    with client.app.state.database.transaction() as connection:
        row = dict(connection.execute("SELECT * FROM segments WHERE id='s1'").fetchone())
        assert row['edited'] == '修正后的合成问题' and row['original'] == '原始问题'
        assert connection.execute("SELECT name FROM speakers WHERE run_id='run1' AND speaker=0").fetchone()[0] == '面试官'
        kinds = {r[0] for r in connection.execute('SELECT kind FROM events WHERE run_id=?', (identifier,))}
        assert connection.execute("SELECT count(*) FROM events WHERE run_id=? AND kind='tool_start'", (identifier,)).fetchone()[0] == 3
    assert {'answer_delta', 'tool_start', 'tool_end', 'completed'} <= kinds
    assert 'evidence__read' in seen_tools and 'changesets__apply' in seen_tools
    assert not {'read', 'write', 'edit', 'bash'} & set(seen_tools)
    assert not marker.exists()
    from interview_backend.agent.work import WorkLog
    attempts = WorkLog(client.app.state.database, identifier).get('model_attempts:chunk:0:model:2')
    assert attempts['attempts'][0]['code'] == 'model_invalid_output'
    assert client.post('/api/v1/agent/runs', json=body).json()['id'] == identifier
    reverted = client.post('/api/v1/changesets/' + run['result']['changeset']['id'] + '/revert',
                           json={'operation_id': 'pi-production-undo'})
    assert reverted.status_code == 200
    with client.app.state.database.transaction() as connection:
        assert connection.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        assert connection.execute("SELECT name FROM speakers WHERE run_id='run1' AND speaker=0").fetchone()[0] == '提问者'
    assert 'synthetic-pi-key' not in json.dumps(run)


def test_pi_provider_errors_are_classified_without_private_response(model_server):
    model_server.status = 401
    model = ModelSettings(baseURL=model_server.url, apiKey='synthetic-pi-key', model='synthetic-pi').client()
    with pytest.raises(PiProviderError) as error:
        asyncio.run(model.ainvoke([HumanMessage(content='合成测试')]))
    assert error.value.status_code == 401
    assert 'synthetic-private-key' not in str(error.value)


def test_cancel_stops_native_request_and_disposes_process(model_server):
    def blocked(_):
        model_server.release.wait(10)
        return {'content': '合成完成'}
    model_server.respond = blocked
    model = ModelSettings(baseURL=model_server.url, model='synthetic-pi').client()

    async def scenario():
        async with PiBridge() as bridge:
            workspace = Path(bridge.workspace.name)
            task = asyncio.create_task(model.ainvoke([HumanMessage(content='合成长请求')]))
            assert await asyncio.to_thread(model_server.started.wait, 5)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await asyncio.wait_for(task, 3)
        assert bridge.process.returncode is not None
        assert not workspace.exists()

    asyncio.run(scenario())


def test_unexpected_pi_exit_fails_pending_request():
    async def scenario():
        async with PiBridge() as bridge:
            task = asyncio.create_task(bridge.request('unknown', {}))
            await asyncio.sleep(.05)
            bridge.process.kill()
            from interview_backend.errors import DomainError
            with pytest.raises(DomainError) as error:
                await asyncio.wait_for(task, 3)
            assert error.value.code == 'pi_runtime_failed'
    asyncio.run(scenario())


def test_native_provider_falls_back_for_non_streaming_endpoint(model_server):
    model_server.streaming_supported = False
    model = ModelSettings(baseURL=model_server.url + '/chat/completions', model='synthetic-pi').client()
    result = asyncio.run(model.ainvoke([HumanMessage(content='合成非流式请求')]))
    assert json.loads(result.content)['answer'] == '合成回答'
    assert [request['stream'] for request in model_server.requests] == [True, False]


def test_cancelled_host_model_step_propagates_without_hanging():
    from interview_backend.agent.pi_runtime import run_session
    from langchain_core.messages import SystemMessage

    async def model_step(*_):
        raise asyncio.CancelledError()

    async def tool_step(*_):
        raise AssertionError('合成取消任务不能执行工具')

    async def scenario():
        with pytest.raises(asyncio.CancelledError):
            await asyncio.wait_for(run_session([], [SystemMessage(content='合成系统'),
                HumanMessage(content='合成任务')], model_step, tool_step), 3)
    asyncio.run(scenario())


def test_repeated_cancellation_cleans_owned_workspace_and_process():
    async def scenario():
        bridge = PiBridge()
        started = asyncio.Event()

        async def pending():
            async with bridge:
                started.set()
                await bridge.request('unknown', {})

        task = asyncio.create_task(pending())
        await started.wait()
        workspace = Path(bridge.workspace.name)
        task.cancel()
        await asyncio.sleep(0)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        await asyncio.wait_for(bridge.process.wait(), 3)
        assert not workspace.exists()
        assert bridge.process.returncode is not None
    asyncio.run(scenario())
