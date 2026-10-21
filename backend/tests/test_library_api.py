import base64

import pytest


def test_recording_page_has_stable_order_and_real_total(client):
    result = client.get('/api/v1/recordings?limit=1&offset=0').json()
    assert result['total'] == 2 and result['limit'] == 1 and result['offset'] == 0
    assert [item['id'] for item in result['items']] == ['r2']
    assert client.get('/api/v1/recordings?offset=2').json()['items'] == []
    recording = client.get('/api/v1/recordings/r1').json()
    assert recording['bookmark'] == base64.b64encode(b'bookmark-data').decode()
    assert recording['play_position'] == 8.5 and recording['active_run'] == 'run1'
    assert recording['kind'] == 'unknown' and recording['interview_date'] is None
    assert recording['company'] is None and recording['revision'] == 1


def test_runs_segments_and_speakers_preserve_corrections_and_timing(client):
    runs = client.get('/api/v1/recordings/r1/runs').json()
    assert runs['items'][0]['id'] == 'run1'
    result = client.get('/api/v1/transcripts/run1/segments').json()
    assert [item['id'] for item in result['items']] == ['s1', 's2']
    assert result['items'][1]['original'] == '原始回答'
    assert result['items'][1]['edited'] == result['items'][1]['text'] == '校对后的回答'
    assert result['items'][1]['start'] == 10.0 and result['items'][1]['speaker_edited'] is True
    assert client.get('/api/v1/transcripts/run2/segments').json()['items'][0]['text'] == ''
    assert client.get('/api/v1/transcripts/run1/speakers').json()['items'] == [
        {'speaker': 0, 'name': '提问者'}, {'speaker': 1, 'name': '回答者'}]


def test_drafts_keep_source_links_and_empty_collection_is_not_missing(client):
    draft = client.get('/api/v1/transcripts/run1/drafts').json()['items'][0]
    assert draft['id'] == 'draft1'
    assert draft['payload']['chunks'][0]['blocks'][0]['sourceIDs'] == ['s1']
    assert client.get('/api/v1/transcripts/run2/drafts').json()['items'] == []
    assert client.get('/api/v1/transcripts/run2/speakers').json()['items'] == []


@pytest.mark.parametrize('path', ['/recordings/absent', '/recordings/absent/runs',
    '/transcripts/absent/segments', '/transcripts/absent/speakers', '/transcripts/absent/drafts'])
def test_unknown_resources_return_safe_404(client, path):
    response = client.get('/api/v1' + path)
    assert response.status_code == 404
    assert response.json()['error']['code'] == 'not_found'
    assert 'SELECT' not in response.text


def test_existing_read_endpoints_do_not_allow_writes(client):
    before = client.get('/api/v1/recordings/r1').json()
    response = client.patch('/api/v1/recordings/r1', json={'title': '未实现的修改'})
    assert response.status_code == 422
    assert client.get('/api/v1/recordings/r1').json() == before


def test_invalid_stored_data_returns_safe_error(client):
    from sqlalchemy import text
    with client.app.state.database.engine.begin() as connection:
        connection.execute(text("UPDATE recordings SET revision=0, title='private-corrupted-content' WHERE id='r1'"))
    response = client.get('/api/v1/recordings/r1')
    assert response.status_code == 503
    assert response.json()['error']['code'] == 'invalid_stored_data'
    assert 'private-corrupted-content' not in response.text


def test_metadata_update_uses_changeset_versioning_and_unknown_date_stays_empty(client):
    before = client.get('/api/v1/recordings/r1').json()
    response = client.patch('/api/v1/recordings/r1', json={
        'operation_id': 'metadata-1', 'expected_revision': before['revision'],
        'fields': {'kind': 'interview', 'interview_date': '2026-10-19', 'company': '合成公司', 'role': '合成岗位'}})
    assert response.status_code == 200
    assert response.json()['count'] == 1
    updated = client.get('/api/v1/recordings/r1').json()
    assert (updated['kind'], updated['interview_date'], updated['company'], updated['role']) == (
        'interview', '2026-10-19', '合成公司', '合成岗位')
    assert updated['revision'] == before['revision'] + 1
    assert client.patch('/api/v1/recordings/r1', json={
        'operation_id': 'metadata-2', 'expected_revision': before['revision'],
        'fields': {'company': '过期修改'}}).status_code == 409
    assert client.get('/api/v1/recordings/r1').json()['company'] == '合成公司'
    assert client.patch('/api/v1/recordings/r1', json={
        'operation_id': 'metadata-3', 'expected_revision': updated['revision'],
        'fields': {'interview_date': '2026-02-30'}}).status_code == 422
    assert client.get('/api/v1/recordings/r1').json()['interview_date'] == '2026-10-19'
    cleared = client.patch('/api/v1/recordings/r1', json={
        'operation_id': 'metadata-4', 'expected_revision': updated['revision'],
        'fields': {'interview_date': None}})
    assert cleared.status_code == 200
    assert client.get('/api/v1/recordings/r1').json()['interview_date'] is None
