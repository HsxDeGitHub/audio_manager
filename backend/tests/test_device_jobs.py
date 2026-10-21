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
