"""导航在临时合成资料库测试，不访问正式录音。"""
import pytest


def create(client, operation='mark-1', **fields):
    mark = {'id': 'n1', 'segment_id': 's1', 'expected_revision': 1, 'kind': 'chapter', 'title': '开场提问', **fields}
    return client.post('/api/v1/recordings/r1/navigation', json={'operation_id': operation, 'marks': [mark]})


def items(client, run='run1'):
    response = client.get('/api/v1/recordings/r1/navigation', params={'run_id': run})
    assert response.status_code == 200
    return response.json()['items']


def test_create_is_idempotent_and_creation_can_be_reverted(client):
    first = create(client)
    assert first.status_code == 200
    assert create(client).json() == first.json()
    assert len(items(client)) == 1
    mark = items(client)[0]
    assert mark['start'] == 1 and mark['segment_id'] == 's1' and mark['revision'] == 2
    assert first.json()['items'][0]['source_location']['recording_id'] == 'r1'
    assert create(client, title='另一个标题').status_code == 409
    assert client.post('/api/v1/changesets/mark-1/revert', json={'operation_id': 'undo-mark'}).status_code == 200
    assert items(client) == []


@pytest.mark.parametrize('kind', ['chapter', 'bookmark', 'later'])
def test_rename_relocate_remove_and_undo(client, kind):
    assert create(client, kind=kind).status_code == 200
    response = client.patch('/api/v1/navigation/n1', json={'operation_id': 'rename', 'expected_revision': 2,
        'fields': {'title': '深入讨论', 'segment_id': 's2'}})
    assert response.status_code == 200
    assert items(client)[0]['start'] == 10
    assert client.patch('/api/v1/navigation/n1', json={'operation_id': 'stale', 'expected_revision': 2, 'fields': {'title': '过期修改'}}).status_code == 409
    assert client.post('/api/v1/changesets/rename/revert', json={'operation_id': 'undo-rename'}).status_code == 200
    mark = items(client)[0]
    assert mark['title'] == '开场提问' and mark['start'] == 1
    response = client.patch('/api/v1/navigation/n1', json={'operation_id': 'remove', 'expected_revision': mark['revision'], 'fields': {'removed': True}})
    assert response.status_code == 200 and items(client) == []
    assert client.post('/api/v1/changesets/remove/revert', json={'operation_id': 'undo-remove'}).status_code == 200
    assert len(items(client)) == 1


def test_references_are_versioned_and_scoped_and_creation_is_atomic(client):
    assert create(client, segment_id='s3').status_code == 409
    assert create(client, expected_revision=99).status_code == 409
    assert create(client, kind='invented').status_code == 422
    assert create(client, title=' ').status_code == 422
    assert items(client) == []
    response = client.post('/api/v1/recordings/r1/navigation', json={'operation_id': 'batch', 'marks': [
        {'id': 'n1', 'segment_id': 's1', 'expected_revision': 1, 'kind': 'chapter', 'title': '问题'},
        {'id': 'n2', 'segment_id': 's3', 'expected_revision': 1, 'kind': 'chapter', 'title': '其他录音'}]})
    assert response.status_code == 409 and items(client) == []
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM navigation_marks').fetchone()[0] == 0
    assert create(client).status_code == 200
    assert client.patch('/api/v1/navigation/n1', json={'operation_id': 'cross-run', 'expected_revision': 2,
        'fields': {'segment_id': 's3'}}).status_code == 409
    assert client.get('/api/v1/recordings/r1/navigation?run_id=run2').status_code == 409


def test_changed_source_refuses_chapters_and_persistence_survives_restart(client, config):
    assert create(client).status_code == 200
    client.post('/api/v1/changesets', json={'operation_id': 'edit', 'targets': [
        {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '已变化'}}]})
    assert create(client, operation='old-question', id='n2').status_code == 409
    from interview_backend.database import Database, upgrade_database
    from interview_backend.services.navigation import NavigationService
    database = client.app.state.database
    upgrade_database(database.path)
    reopened = Database(database.path)
    try:
        assert NavigationService(reopened).list('r1')['items'][0]['id'] == 'n1'
    finally:
        reopened.close()


def test_generic_navigation_fields_cannot_change_kind_or_version(client):
    assert create(client).status_code == 200
    for fields in [{'run_id': 'run2'}, {'kind': 'later'}, {'removed': 1}, {'segment_id': 42}, {'title': '字' * 201}]:
        response = client.patch('/api/v1/navigation/n1', json={'operation_id': str(fields), 'expected_revision': 2, 'fields': fields})
        assert response.status_code == 422
    assert items(client)[0]['revision'] == 2


def test_switching_transcript_versions_keeps_separate_navigation(client):
    assert create(client).status_code == 200
    with client.app.state.database.transaction(True) as c:
        c.execute("INSERT INTO runs(id,recording_id,created_at) VALUES('new-run','r1',999)")
        c.execute("INSERT INTO segments(id,run_id,start,end,original) VALUES('new-segment','new-run',15,18,'新版本的句子')")
        c.execute("UPDATE recordings SET active_run='new-run' WHERE id='r1'")
    assert client.get('/api/v1/recordings/r1/navigation').json()['items'] == []
    assert len(items(client)) == 1
    assert create(client, operation='old-run-mark', id='old-run').status_code == 409
    assert create(client, operation='new-run-mark', id='new-mark', segment_id='new-segment').status_code == 200
    assert items(client, 'new-run')[0]['start'] == 15
