"""会话移除不会删除原始资料或破坏修改追溯。"""
import pytest

from interview_backend.database import Database
from interview_backend.errors import DomainError
from interview_backend.services.changesets import ChangeSetService


def seed_run(client, state='completed'):
    session = client.post('/api/v1/sessions', json={'title': '待删除话题'}).json()['id']
    with client.app.state.database.transaction(True) as c:
        c.execute('INSERT INTO messages VALUES(?,?,?,?,?,?)', ('delete-message', session, 'user', '合成消息', '{}', 1))
        c.execute('INSERT INTO agent_runs VALUES(?,?,?,?,?,?,?)', ('delete-run', session, 'delete-message', state, '{}', None, 1))
    return session


def test_delete_hides_history_and_keeps_materials_changes_and_other_sessions(client):
    session = seed_run(client)
    other = client.post('/api/v1/sessions', json={'title': '保留话题'}).json()['id']
    changes = ChangeSetService(client.app.state.database)
    changes.submit({'operation_id': 'keep-edit', 'targets': [{'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '应保留的校对'}}]})
    before = client.get('/api/v1/transcripts/run1/segments').json()
    for _ in range(2):
        response = client.delete('/api/v1/sessions/' + session)
        assert response.status_code == 200
        assert response.json() == {'id': session, 'deleted': True}
    assert [item['id'] for item in client.get('/api/v1/sessions').json()['items']] == [other]
    assert client.get('/api/v1/sessions/' + session).status_code == 404
    assert client.patch('/api/v1/sessions/' + session, json={'title': '不能复活'}).status_code == 404
    assert client.get('/api/v1/transcripts/run1/segments').json() == before
    assert client.get('/api/v1/recordings/r1').status_code == 200
    assert changes.revert('keep-edit', 'undo-after-delete')['count'] == 1
    reopened = Database(client.app.state.database.path)
    try:
        with reopened.transaction() as c:
            assert c.execute('SELECT deleted FROM sessions WHERE id=?', (session,)).fetchone()[0] == 1
            assert c.execute("SELECT count(*) FROM messages WHERE id='delete-message'").fetchone()[0] == 1
            assert c.execute('PRAGMA foreign_key_check').fetchall() == []
    finally:
        reopened.close()


@pytest.mark.parametrize('state', ['queued', 'running'])
def test_running_conversation_must_stop_before_delete(client, state):
    session = seed_run(client, state)
    response = client.delete('/api/v1/sessions/' + session)
    assert response.status_code == 409 and response.json()['error']['code'] == 'session_busy'
    assert client.get('/api/v1/sessions/' + session).status_code == 200
    assert client.post('/api/v1/agent/runs/delete-run/cancel').status_code == 200
    assert client.delete('/api/v1/sessions/' + session).status_code == 200


@pytest.mark.parametrize('state', ['completed', 'awaiting_input', 'cancelled', 'interrupted', 'failed'])
def test_deleted_conversation_cannot_start_resume_or_read_runs(client, state):
    session = seed_run(client, state)
    assert client.delete('/api/v1/sessions/' + session).status_code == 200
    assert client.get('/api/v1/agent/runs/delete-run').status_code == 404
    assert client.get('/api/v1/agent/runs/delete-run/events').status_code == 404
    assert client.post('/api/v1/agent/runs/delete-run/resume').status_code == 404
    assert client.post('/api/v1/agent/runs', json={'session_id': session, 'instruction': '继续', 'context': {'recording_id': 'r1'}}).status_code == 404


def test_delete_cancels_pending_device_commands_and_prevents_new_commands(client):
    session = seed_run(client)
    device = client.app.state.device
    command = device.enqueue('clipboard', '', {'text': '合成内容'}, run_id='delete-run')
    assert client.delete('/api/v1/sessions/' + session).status_code == 200
    assert device.get(command['id'])['state'] == 'cancelled'
    assert device.pending() == []
    with pytest.raises(DomainError):
        device.claim(command['id'], 'synthetic-owner')
    with pytest.raises(DomainError):
        device.enqueue('clipboard', '', {'text': '不会执行'}, run_id='delete-run')


def test_delete_requires_authentication_and_handles_missing_session(client):
    session = seed_run(client)
    assert client.delete('/api/v1/sessions/' + session, headers={'Authorization': 'Bearer invalid'}).status_code == 401
    assert client.get('/api/v1/sessions/' + session).status_code == 200
    assert client.delete('/api/v1/sessions/missing').status_code == 404
