import pytest
from interview_backend.services.memory import MemoryService
from interview_backend.errors import DomainError


def seed(client):
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute("INSERT INTO sessions VALUES('memory-session','合成','{}',1)")
        c.execute("INSERT INTO messages VALUES('m1','memory-session','user','这是隔壁团队的事，我没有处理过。','{}',1)")
        c.execute("INSERT INTO messages VALUES('m2','memory-session','user','更正：这是我处理过的。','{}',2)")
    return MemoryService(db, client.app.state.evidence)


def candidate(source='m1', content='隔壁团队事故非本人经历'):
    return {'category':'user_statement','content':content,'topic':'事故归属','scope':'global','sources':[{'resource_type':'message','resource_id':source,'revision':1}]}


def test_memory_correction_restart_disable_and_delete_suppression(client):
    service = seed(client)
    first = service.add(candidate(), 'memory-1')
    assert service.active()[0]['content'] == '隔壁团队事故非本人经历'
    corrected = service.add({**candidate('m2','本人处理过该事故'),'supersedes':first['id']}, 'memory-2')
    assert len(service.active()) == 1 and service.active()[0]['id'] == corrected['id']
    service.update(corrected['id'], {'state':'disabled'}, 1, 'disable')
    assert service.active() == []
    service.update(corrected['id'], {'state':'active'}, 2, 'enable')
    service.update(corrected['id'], {'state':'deleted'}, 3, 'forget')
    assert service.add(candidate('m2','本人处理过该事故'), 'relearn')['suppressed']
    assert service.active() == []


def test_unknown_speaker_and_model_analysis_cannot_become_user_statement(client):
    service = seed(client)
    with pytest.raises(DomainError):
        service.add({**candidate(), 'sources':[{'resource_type':'segment','resource_id':'s1','revision':1}]}, 'unsafe')
    analysis = service.add({**candidate(), 'category':'analysis','content':'这是分析推断，不是用户事实'}, 'analysis')
    assert analysis['category'] == 'analysis'


def test_conflicting_auto_memories_require_review(client):
    service = seed(client)
    service.add(candidate(), 'first')
    service.add(candidate('m2','与原记忆冲突'), 'second')
    assert service.active() == []
    assert all(r['state']=='needs_review' for r in service.list()['items'])


def test_memory_api_supports_disable_and_delete_without_rebuild(client):
    service = seed(client)
    item = service.add(candidate(), 'api-memory')
    listing = client.get('/api/v1/memories').json()['items']
    assert [row['id'] for row in listing] == [item['id']]
    assert listing[0]['sources'][0]['resource_type'] == 'message'
    disabled = client.patch('/api/v1/memories/' + item['id'], json={
        'operation_id': 'api-disable', 'expected_revision': 1, 'fields': {'state': 'disabled'}})
    assert disabled.status_code == 200
    assert client.get('/api/v1/memories').json()['items'][0]['state'] == 'disabled'
    removed = client.patch('/api/v1/memories/' + item['id'], json={
        'operation_id': 'api-delete', 'expected_revision': 2, 'fields': {'state': 'deleted'}})
    assert removed.status_code == 200
    assert service.add(candidate(), 'api-relearn')['suppressed']
    stale = client.patch('/api/v1/memories/' + item['id'], json={
        'operation_id': 'api-stale', 'expected_revision': 2, 'fields': {'state': 'active'}})
    assert stale.status_code == 409
