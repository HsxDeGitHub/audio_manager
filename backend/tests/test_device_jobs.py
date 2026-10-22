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
                          frozen_context=client.app.state.evidence.freeze({'recording_id': 'r1'}, '请定位并复制当前资料'))

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
        from dataclasses import replace
        return await client.app.state.tools.execute('device.locate', {'recording_id': 'r1'}, replace(context, operation_id='pending-locate'))
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


def device_context(client, instruction='请导出当前面试'):
    from interview_backend.tools.registry import ToolContext
    return ToolContext(request_id='frozen-device', allowed_effects=frozenset({'device'}),
                       frozen_context=client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction))


@pytest.mark.parametrize('arguments', [
    {'draft_id': 'other', 'run_id': 'run2', 'format': 'md'},
    {'recording_id': 'r1', 'run_id': 'run2', 'format': 'txt'},
])
def test_device_export_rejects_cross_recording_targets(client, arguments):
    import asyncio
    with client.app.state.database.transaction(True) as c:
        c.execute("INSERT INTO ai_drafts VALUES('other','run2',1,'{}')")
    with pytest.raises(DomainError):
        asyncio.run(client.app.state.tools.execute('device.export', arguments, device_context(client)))
    assert client.app.state.device.pending() == []


def test_device_freezes_run_and_checks_versions_before_claim(client, monkeypatch):
    import asyncio
    from interview_backend.services.common import bump
    context = device_context(client)
    async def immediate(identifier, timeout=10): return client.app.state.device.get(identifier)
    monkeypatch.setattr(client.app.state.device, 'wait', immediate)
    result = asyncio.run(client.app.state.tools.execute('device.export', {'recording_id': 'r1', 'format': 'txt'}, context))
    identifier = result['data']['result']['command_id']
    assert client.app.state.device.get(identifier)['arguments']['run_id'] == 'run1'
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE recordings SET active_run=NULL WHERE id='r1'")
    # 切换当前版本不改变消息冻结的版本。
    assert client.app.state.device.get(identifier)['arguments']['run_id'] == 'run1'
    with client.app.state.database.transaction(True) as c: bump(c, 'segment', 's1')
    with pytest.raises(DomainError) as error: client.app.state.device.claim(identifier, 'owner')
    assert error.value.code == 'stale_device_target'


def test_device_locate_rejects_mixed_segment_and_run(client):
    import asyncio
    with pytest.raises(DomainError):
        asyncio.run(client.app.state.tools.execute('device.locate', {'recording_id': 'r1', 'segment_id': 's3'}, device_context(client, '请回听当前面试')))
    assert client.app.state.device.pending() == []


def queued_agent(client):
    session=client.post('/api/v1/sessions',json={}).json()['id']
    with client.app.state.database.transaction(True) as c:
        c.execute("INSERT INTO agent_runs VALUES('cancel-parent',?,'cancel-msg','running','{}',NULL,1)",(session,))
    return 'cancel-parent'


def test_cancel_run_prevents_late_device_claim_and_restart_replay(client):
    parent=queued_agent(client)
    command=client.app.state.device.enqueue('clipboard','',{'text':'合成'},run_id=parent,command_id='late')
    client.post('/api/v1/agent/runs/'+parent+'/cancel')
    assert client.app.state.device.get(command['id'])['state']=='cancelled'
    assert client.post('/api/v1/device/commands/late/claim',json={'owner':'late-device'}).status_code==409
    client.app.state.jobs.recover()
    assert client.app.state.device.pending()==[]


def test_restart_pending_device_requires_explicit_resume_and_completed_never_requeues(client):
    parent=queued_agent(client); device=client.app.state.device
    device.enqueue('clipboard','',{'text':'待执行'},run_id=parent,command_id='pending-before-restart')
    device.enqueue('clipboard','',{'text':'已完成'},run_id=parent,command_id='already-done')
    device.claim('already-done','owner'); device.complete('already-done','owner','completed',{'characters':3})
    client.app.state.jobs.recover()
    assert device.pending()==[]
    assert device.get('already-done')['state']=='completed'
    with client.app.state.database.transaction(True) as c:
        device.resume_run(c,parent)
        c.execute("UPDATE agent_runs SET state='queued' WHERE id=?",(parent,))
    assert [r['id'] for r in device.pending()]==['pending-before-restart']
    assert device.get('already-done')['state']=='completed'


def test_cancel_claim_race_blocks_new_commands_and_keeps_running_result_truthful(client):
    parent=queued_agent(client); device=client.app.state.device
    device.enqueue('clipboard','',{'text':'已领取'},run_id=parent,command_id='claimed')
    device.claim('claimed','owner')
    client.post('/api/v1/agent/runs/'+parent+'/cancel')
    assert device.get('claimed')['result']['cancel_requested']
    with pytest.raises(DomainError): device.enqueue('clipboard','',{'text':'太晚'},run_id=parent,command_id='after-cancel')
    # 领取先发生，真实副作用已完成，必须保留实际结果。
    assert device.complete('claimed','owner','completed',{'characters':3})['state']=='completed'


def test_worker_queue_and_start_have_queryable_real_states(client):
    request={'jobID':'queued-worker','recordingID':'r1','runID':'queued-run','source':'/synthetic/a.wav'}
    assert client.post('/api/v1/jobs/queue',json=request).json()['state']=='queued'
    assert client.get('/api/v1/jobs/queued-worker').json()['state']=='queued'
    assert client.post('/api/v1/jobs/start',json=request).json()['state']=='running'
    assert client.get('/api/v1/jobs/queued-worker').json()['state']=='running'
    client.app.state.jobs.stop('queued-worker','failed')
    assert client.get('/api/v1/jobs/queued-worker').json()['state']=='failed'


def test_native_device_operation_retries_reuse_command_and_validate_request(client,monkeypatch):
    async def immediate(identifier,timeout=10):return client.app.state.device.get(identifier)
    monkeypatch.setattr(client.app.state.device,'wait',immediate)
    body={'arguments':{'text':'合成'},'operation_id':'native-stable-device'}
    first=client.post('/api/v1/tools/device.copy/invoke',json=body).json()['data']['result']
    second=client.post('/api/v1/tools/device.copy/invoke',json=body).json()['data']['result']
    assert first['command_id']==second['command_id']
    assert len(client.app.state.device.pending())==1
    body['arguments']['text']='不同'
    assert client.post('/api/v1/tools/device.copy/invoke',json=body).status_code==409
    body['operation_id']='different-device-operation'
    assert client.post('/api/v1/tools/device.copy/invoke',json=body).status_code==200
    assert len(client.app.state.device.pending())==2
