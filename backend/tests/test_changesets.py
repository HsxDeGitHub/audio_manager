import pytest
from interview_backend.services.changesets import ChangeSetService
from interview_backend.errors import DomainError


def test_batch_rollback_idempotency_and_revert_conflict(client):
    service = ChangeSetService(client.app.state.database)
    request = {'operation_id': 'batch', 'targets': [
        {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '甲'}},
        {'resource_type': 'segment', 'resource_id': 's3', 'expected_revision': 1, 'fields': {'text': '乙'}}]}
    result = service.submit(request)
    assert result['count'] == 2
    assert service.submit(request) == result
    assert client.get('/api/v1/transcripts/run1/segments').json()['items'][0]['original'] == '原始问题'
    request['targets'][0]['fields']['text'] = '不同请求'
    with pytest.raises(DomainError) as e: service.submit(request)
    assert e.value.status_code == 409
    service.submit({'operation_id': 'later', 'targets': [{'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 2, 'fields': {'text': '后来修改'}}]})
    with pytest.raises(DomainError): service.revert('batch', 'undo')
    assert client.get('/api/v1/transcripts/run2/segments').json()['items'][0]['text'] == '乙'


def test_invalid_second_target_rolls_back_first_and_operation_is_not_saved(client):
    service = ChangeSetService(client.app.state.database)
    with pytest.raises(DomainError): service.submit({'operation_id': 'invalid', 'targets': [
        {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '不能生效'}},
        {'resource_type': 'segment', 'resource_id': 'absent', 'expected_revision': 1, 'fields': {'text': '丢失'}}]})
    assert client.get('/api/v1/transcripts/run1/segments').json()['items'][0]['text'] == '原始问题'
    assert service.submit({'operation_id': 'invalid', 'targets': [{'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '可重试'}}]})['count'] == 1


def test_revert_is_atomic_and_retry_returns_saved_result(client):
    service = ChangeSetService(client.app.state.database)
    service.submit({'operation_id': 'edit', 'targets': [{'resource_type': 'recording', 'resource_id': 'r1', 'expected_revision': 1, 'fields': {'title': '改名'}}]})
    result = service.revert('edit', 'undo')
    assert service.revert('edit', 'undo') == result
    assert client.get('/api/v1/recordings/r1').json()['title'] == '合成面试甲'


def test_concurrent_edit_only_one_expected_revision_can_commit(client):
    from concurrent.futures import ThreadPoolExecutor
    service = ChangeSetService(client.app.state.database)
    def attempt(i):
        try:
            service.submit({'operation_id':f'concurrent-{i}','targets':[{'resource_type':'segment','resource_id':'s1','expected_revision':1,'fields':{'text':str(i)}}]})
            return 200
        except DomainError as error: return error.status_code
    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(attempt,[1,2])) == [200,409]
