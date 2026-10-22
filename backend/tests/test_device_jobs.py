import pytest
from interview_backend.errors import DomainError


def test_worker_events_are_idempotent_and_cancelled_job_does_not_overwrite(client):
    jobs = client.app.state.jobs
    request = {'jobID': 'j1', 'recordingID': 'r1', 'runID': 'new', 'source': '/synthetic/a.wav'}
    jobs.start(request)
    event = {'jobID': 'j1', 'kind': 'transcript', 'segments': [{'id': 'fresh', 'start': 1, 'end': 2, 'original': '新稿'}]}
    assert jobs.event(request, event) == jobs.event(request, event)
    assert len(client.get('/api/v1/recordings/r1/runs').json()['items']) == 2
    jobs.stop('j1', 'cancelled')
    jobs.event(request, {'jobID': 'j1', 'kind': 'done'})
    assert client.get('/api/v1/recordings/r1').json()['state'] == 'cancelled'


def test_restart_interrupts_unfinished_work_and_preserves_transcript(client):
    jobs = client.app.state.jobs
    jobs.start({'jobID': 'j1', 'recordingID': 'r1', 'runID': 'new'})
    jobs.recover()
    assert client.get('/api/v1/recordings/r1').json()['active_run'] == 'run1'
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT state FROM jobs WHERE id=?', ('j1',)).fetchone()[0] == 'interrupted'


def test_device_commands_require_real_result_and_are_idempotent(client):
    from interview_backend.services.device import DeviceService
    from interview_backend.errors import DomainError
    device = DeviceService(client.app.state.database)
    command = device.enqueue('locate', 'r1', {'recording_id': 'r1', 'segment_id': 's1', 'play': True}, command_id='locate-1')
    assert command['state'] == 'pending'
    assert device.enqueue('locate', 'r1', {'recording_id': 'r1', 'segment_id': 's1', 'play': True}, command_id='locate-1')['id'] == 'locate-1'
    with pytest.raises(DomainError):
        device.enqueue('locate', 'r1', {'recording_id': 'r2'}, command_id='locate-1')
    assert client.get('/api/v1/device/commands').json()['items'][0]['id'] == 'locate-1'
    claimed = client.post('/api/v1/device/commands/locate-1/claim', json={'owner': 'synthetic-device'}).json()
    assert claimed['state'] == 'running' and claimed['owner'] == 'synthetic-device'
    assert client.post('/api/v1/device/commands/locate-1/claim', json={'owner': 'other'}).status_code == 409
    completed = client.post('/api/v1/device/commands/locate-1/result', json={
        'owner': 'synthetic-device', 'state': 'completed', 'result': {'position': 1.0}}).json()
    assert completed['state'] == 'completed' and completed['result'] == {'position': 1.0}
    assert client.post('/api/v1/device/commands/locate-1/result', json={
        'owner': 'synthetic-device', 'state': 'completed', 'result': {'position': 1.0}}).json()['state'] == 'completed'
    with pytest.raises(DomainError):
        device.complete('locate-1', 'synthetic-device', 'failed', {'message': '冲突覆盖'})


def test_device_tool_reports_actual_result_and_pending_is_not_success(client, monkeypatch):
    import asyncio
    from interview_backend.tools.registry import ToolContext
    from interview_backend.agent.tools import install_app_tools
    from interview_backend.services.device import DeviceService
    from interview_backend.services.changesets import ChangeSetService
    from interview_backend.services.common import encode

    class Omitted(Exception):
        pass
    device = DeviceService(client.app.state.database)
    context = ToolContext(request_id='device-run', operation_id='device-run:tools',
                          allowed_effects=frozenset({'device'}),
                          frozen_context={'allowed_actions': ['device.locate', 'device.copy'], 'recording_ids': ['r1'], 'resources': [{'resource_type': 'recording', 'resource_id': 'r1'}]})

    async def scenario():
        task = asyncio.create_task(client.app.state.tools.execute('device.locate',
            {'recording_id': 'r1', 'segment_id': 's1', 'start': 1.0, 'play': True}, context))
        for _ in range(100):
            await asyncio.sleep(0.02)
            pending = device.pending()
            if pending:
                device.claim(pending[0]['id'], 'synthetic-device')
                device.complete(pending[0]['id'], 'synthetic-device', 'completed',
                                {'recording_id': 'r1', 'segment_id': 's1', 'position': 1.0})
                break
        return await task
    result = asyncio.run(scenario())
    assert result['data']['result']['state'] == 'completed'
    assert result['data']['result']['result']['position'] == 1.0

    async def immediate(identifier, timeout=10):
        return client.app.state.device.get(identifier)
    monkeypatch.setattr(client.app.state.device, 'wait', immediate)

    async def no_device():
        return await client.app.state.tools.execute('device.locate', {'recording_id': 'r1'}, context)
    pending_result = asyncio.run(no_device())
    assert pending_result['data']['result']['state'] == 'pending'
    assert '不能视为完成' in pending_result['data']['result']['message']
    with pytest.raises(Exception):
        asyncio.run(client.app.state.tools.execute('device.locate', {'recording_id': 'r2'}, context))


def test_restart_never_reports_running_device_command_as_completed(client):
    device = client.app.state.device
    command = device.enqueue('export', 'r1', {'recording_id': 'r1', 'format': 'txt'}, command_id='export-restart')
    device.claim(command['id'], 'synthetic-device')
    client.app.state.jobs.recover()
    value = device.get(command['id'])
    assert value['state'] == 'unknown' and value['owner'] is None


def test_cancelled_file_choice_is_not_success(client):
    device = client.app.state.device
    command = device.enqueue('choose_file', '', {'purpose': '选择材料', 'extensions': ['txt', 'md']}, command_id='choose-file')
    device.claim(command['id'], 'synthetic-device')
    value = device.complete(command['id'], 'synthetic-device', 'cancelled', {'message': '用户取消'})
    assert value['state'] == 'cancelled' and value['result']['message'] == '用户取消'
