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


@pytest.mark.parametrize('kind', ['recording', 'draft', 'document', 'memory'])
def test_manual_content_history_is_persistent_recoverable_and_conflict_checked(client, kind):
    import json
    from interview_backend.services.memory import MemoryService
    from interview_backend.services.documents import DocumentService
    from interview_backend.services.common import version
    db = client.app.state.database
    identifier = 'r1' if kind == 'recording' else 'draft1'
    fields = {'title':'手工名称'} if kind == 'recording' else {'blocks':{'block1':{'text':'手工稿件'}}}
    if kind == 'draft':
        with db.transaction(True) as c: c.execute("UPDATE ai_drafts SET payload=? WHERE id='draft1'", (json.dumps({'chunks':[{'blocks':[{'id':'block1','text':'原稿','sourceIDs':['s1']}]}]}),))
    if kind == 'document':
        identifier = DocumentService(db).import_text('材料','txt','旧内容','import-history')['id']; fields = {'removed':True}
    if kind == 'memory':
        identifier = MemoryService(db, client.app.state.evidence).add({'category':'analysis','content':'旧分析','topic':'历史','scope':'global','sources':[{'resource_type':'segment','resource_id':'s1','revision':1}]},'memory-history')['id']; fields = {'state':'disabled'}
    with db.transaction() as c: revision = version(c,kind,identifier)
    request = {'operation_id':'manual','targets':[{'resource_type':kind,'resource_id':identifier,'expected_revision':revision,'fields':fields}]}
    first = client.post('/api/v1/changesets',json=request).json()
    service = ChangeSetService(db)
    receipt = next(r for r in service.list()['items'] if r['id']=='manual')
    assert receipt['count'] == 1 and receipt['items'] == first['items']
    if kind == 'draft': assert json.loads(receipt['items'][0]['after']['payload'])['chunks'][0]['blocks'][0]['sourceIDs'] == ['s1']
    service.revert('manual','undo-manual')
    with db.transaction() as c:
        from interview_backend.services.changesets import read_object
        restored = read_object(c,kind,identifier)
        assert all(restored[k]==v for k,v in receipt['items'][0]['before'].items() if k!='revision')
        revision = version(c,kind,identifier)
    request['operation_id']='again'; request['targets'][0]['expected_revision']=revision
    service.submit(request)
    request['operation_id']='later'; request['targets'][0]['expected_revision']=revision+1
    request['targets'][0]['fields'] = {'title':'后来'} if kind=='recording' else {'blocks':{'block1':{'text':'后来'}}} if kind=='draft' else {'content':'后来'}
    service.submit(request)
    with pytest.raises(DomainError): service.revert('again','undo-conflict')


def test_recording_undo_preserves_playback_and_processing_state(client):
    from interview_backend.services.library import LibraryService,LibraryCommand
    db=client.app.state.database;service=ChangeSetService(db);library=LibraryService(db)
    service.submit({'operation_id':'content-rename','targets':[{'resource_type':'recording','resource_id':'r1','expected_revision':1,'fields':{'title':'新名称','company':'合成公司'}}]})
    row=next(r for r in library.execute(LibraryCommand(action='recordings'))['value'] if r['id']=='r1')
    row.update(playPosition=20,state='transcribing',error='合成进度',duration=70)
    library.execute(LibraryCommand(action='save',operation_id='runtime-progress',arguments={'recording':row}))
    ChangeSetService(db).revert('content-rename','undo-content')
    with db.transaction() as c:
        value=dict(c.execute("SELECT * FROM recordings WHERE id='r1'").fetchone())
    assert value['title']=='合成面试甲' and value['company'] is None
    assert value['play_position']==20 and value['state']=='transcribing' and value['duration']==70
    assert value['error']=='合成进度'
