import json
import pytest


def invoke(client, action, args=None, operation='test-operation', versions=None):
    return client.post('/api/v1/library/execute', json={'action': action, 'arguments': args or {}, 'operation_id': operation, 'expected_versions': versions or {}})


def test_read_parity_and_no_original_database_write(client, config):
    assert invoke(client, 'recordings').json()['value'][0]['id'] == 'r2'
    segments = invoke(client, 'segments', {'runID': 'run1'}).json()['value']
    assert segments[1]['edited'] == '校对后的回答' and segments[1]['start'] == 10
    assert invoke(client, 'speakerNames', {'runID': 'run1'}).json()['value']['1'] == '回答者'
    assert invoke(client, 'historyLabel', {'runID': 'run1', 'redo': True}).json()['value'] == '修改文字'


def test_edits_undo_redo_and_restart_preserve_evidence(client):
    response = invoke(client, 'editTexts', {'edits': {'s1': '人工修正'}}, 'edit-1')
    assert response.status_code == 200
    assert invoke(client, 'restoreEdit', {'runID': 'run1'}, 'undo-1').json()['value'] is True
    assert invoke(client, 'segments', {'runID': 'run1'}).json()['value'][0]['edited'] is None
    assert invoke(client, 'restoreEdit', {'runID': 'run1', 'redo': True}, 'redo-1').json()['value'] is True
    assert invoke(client, 'segments', {'runID': 'run1'}).json()['value'][0]['text'] == '人工修正'


def test_transaction_idempotency_scope_and_version_conflicts(client):
    args = {'edits': {'s1': '第一次'}}
    first = invoke(client, 'editTexts', args, 'same')
    assert first.status_code == 200
    assert invoke(client, 'editTexts', args, 'same').json()['value'] == first.json()['value']
    assert invoke(client, 'editTexts', {'edits': {'s1': '另一次'}}, 'same').status_code == 409
    assert invoke(client, 'editTexts', {'edits': {'s1': '错误覆盖'}}, 'conflict', {'segment:s1': 1}).status_code == 409
    assert invoke(client, 'editTexts', {'edits': {'s1': '应回滚', 'absent': '无目标'}}, 'invalid').status_code == 404
    assert invoke(client, 'segments', {'runID': 'run1'}).json()['value'][0]['text'] == '第一次'


def test_speaker_merge_undo_and_automatic_retry_protect_manual_work(client):
    assert invoke(client, 'mergeSpeakers', {'runID': 'run1', 'sources': [0], 'target': 1}, 'merge').status_code == 200
    assert invoke(client, 'speakerNames', {'runID': 'run1'}).json()['value'] == {'1': '回答者'}
    assert invoke(client, 'restoreEdit', {'runID': 'run1'}, 'undo').json()['value']
    assert invoke(client, 'speakerNames', {'runID': 'run1'}).json()['value']['0'] == '提问者'
    assert invoke(client, 'applySpeakers', {'runID': 'run1', 'turns': [{'start': 0, 'end': 60, 'speaker': 9}]}, 'auto').status_code == 200
    segments = invoke(client, 'segments', {'runID': 'run1'}).json()['value']
    assert segments[1]['speaker'] == 1 and segments[1]['speakerEdited']
    assert invoke(client, 'historyLabel', {'runID': 'run1'}).json()['value'] is None


def test_new_transcript_preserves_edited_active_run_and_duplicate_events(client):
    args = {'recordingID': 'r1', 'runID': 'run-new', 'segments': [{'id': 'fresh', 'start': 0, 'end': 2, 'original': '新识别'}], 'duration': 61}
    assert invoke(client, 'addTranscript', args, 'worker-event').json()['value'] is False
    assert invoke(client, 'addTranscript', args, 'worker-event').json()['value'] is False
    assert invoke(client, 'recordings').json()['value'][1]['activeRun'] == 'run1'
    assert len(invoke(client, 'runs', {'recordingID': 'r1'}).json()['value']) == 2


def test_cache_draft_and_removal_cascade_without_deleting_source(client):
    assert invoke(client, 'saveReadingCache', {'runID': 'run1', 'key': 'new', 'rendered': {'s1': '问题？'}}, 'cache').status_code == 200
    assert invoke(client, 'readingCache', {'runID': 'run1'}).json()['value']['new']['s1'] == '问题？'
    draft = {'id': 'd2', 'runID': 'run1', 'createdAt': 105, 'chunks': [{'blocks': [{'sourceIDs': ['s1'], 'text': '新稿'}]}]}
    assert invoke(client, 'saveAIDraft', {'draft': draft}, 'draft').status_code == 200
    assert invoke(client, 'aiDrafts', {'runID': 'run1'}).json()['value'][0]['chunks'][0]['blocks'][0]['sourceIDs'] == ['s1']
    assert invoke(client, 'remove', {'id': 'r1'}, 'remove').status_code == 200
    assert client.get('/api/v1/recordings/r1').status_code == 404


@pytest.mark.parametrize('action,args', [('editTexts', {'edits': {'s1': 42}}), ('renameSpeaker', {'runID': 'run1', 'speaker': -1, 'name': '错误'}), ('unsupported', {})])
def test_invalid_operations_are_rejected(client, action, args):
    assert invoke(client, action, args).status_code == 422
