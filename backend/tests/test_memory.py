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


def test_analysis_formed_from_scoped_cited_result_and_never_becomes_personal_fact(client, config):
    import asyncio
    from interview_backend.agent.memory import AutomaticMemory
    service = seed(client)
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析面试表现')
    context.update(message_id='m1', session_id='memory-session')
    source = {'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}
    result = {'claims': [
        {'text': '问题回答可能缺少验证步骤，这是分析判断。', 'kind': 'analysis', 'sources': [source]},
        {'text': '无来源推测', 'kind': 'analysis', 'sources': []},
        {'text': '其他场次的分析', 'kind': 'analysis', 'sources': [{'resource_type': 'segment', 'resource_id': 's3', 'revision': 1}]},
        {'text': '建议练习', 'kind': 'suggestion', 'sources': [source]}]}
    items = asyncio.run(AutomaticMemory(config, service).extract(context, result=result))
    assert len(items) == 1 and items[0]['category'] == 'analysis' and items[0]['scope'] == 'recording:r1'
    assert service.active() == []
    assert service.active(('recording:r1',))[0]['sources'] == [source]
    # 重启创建新服务，分析记忆仍可用，但不能作为用户事实引用。
    reopened = MemoryService(client.app.state.database, client.app.state.evidence)
    item = reopened.active(('recording:r1',))[0]
    claim = {'kind': 'user_statement', 'text': '我确认这项分析是我的事实', 'sources': [{'resource_type': 'memory', 'resource_id': item['id'], 'revision': 1}]}
    context['resources'].append(claim['sources'][0])
    with pytest.raises(DomainError) as error:
        client.app.state.evidence.validate_result({'claims': [claim]}, context)
    assert error.value.code == 'analysis_not_user_fact'
    reopened.update(item['id'], {'state': 'deleted'}, 1, 'delete-analysis')
    again = asyncio.run(AutomaticMemory(config, service).extract({**context, 'message_id': 'm2'}, result=result))
    assert again[0]['suppressed']


def test_analysis_memory_is_invalidated_when_its_evidence_changes(client, config):
    service = seed(client)
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析表现')
    context.update(message_id='m1', session_id='memory-session')
    items = service.remember_analysis(context, {'claims': [{'kind': 'analysis', 'text': '需复核的分析',
                              'sources': [{'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}]}]})
    client.app.state.changesets.submit({'operation_id': 'change-analysis-source', 'targets': [
        {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '已修正原文'}}]})
    assert not service.active(('recording:r1',))
    assert next(item for item in service.list()['items'] if item['id'] == items[0]['id'])['state'] == 'needs_review'


def test_analysis_is_reused_only_for_the_recording_scope(client, config):
    import asyncio
    import json
    from langchain_core.messages import AIMessage
    from interview_backend.agent.graph import AgentEngine
    from interview_backend.agent.tools import EvidenceService
    service = seed(client)
    evidence = client.app.state.evidence
    context = evidence.freeze({'recording_id': 'r1'}, '分析表现')
    context.update(message_id='m1', session_id='memory-session')
    service.remember_analysis(context, {'claims': [{'kind': 'analysis', 'text': '需补充验证依据',
        'sources': [{'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}]}]})
    class InspectModel:
        def __init__(self, expected): self.expected = expected
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            memories = json.loads(messages[-1].content)['current_valid_memories']
            assert len(memories) == self.expected
            assert all(item['category'] == 'analysis' for item in memories)
            return AIMessage(content=json.dumps({'answer': '按当前证据分析', 'claims': []}))
    engine = AgentEngine(config, client.app.state.tools, evidence)
    engine.memory_service = service
    asyncio.run(engine.execute('analysis-same-recording', '分析表现', context, model=InspectModel(1)))
    other = evidence.freeze({'recording_id': 'r2'}, '分析表现')
    asyncio.run(engine.execute('analysis-other-recording', '分析表现', other, model=InspectModel(0)))


@pytest.mark.parametrize('fields', [{'state':'deleted'}, {'state':'disabled'}, {'content':'用户纠正'}])
def test_invalidated_memory_versions_and_latest_user_changes_stay_consistent(client, fields):
    from interview_backend.services.memory import MemoryService
    from interview_backend.services.common import bump, version
    from interview_backend.errors import DomainError
    db = client.app.state.database
    service = MemoryService(db, client.app.state.evidence)
    item = service.add({'category':'analysis','content':'旧分析','topic':'失效','scope':'global',
                        'sources':[{'resource_type':'segment','resource_id':'s1','revision':1}]},'add-versioned-memory')
    with db.transaction(True) as c: bump(c,'segment','s1')
    latest = MemoryService(db, client.app.state.evidence).list()['items'][0]
    assert latest['state']=='needs_review'
    with db.transaction() as c:
        assert version(c,'memory',item['id']) == latest['revision']
        assert c.execute("SELECT revision FROM index_queue WHERE resource_type='memory' AND resource_id=?",(item['id'],)).fetchone()[0] == latest['revision']
    with pytest.raises(DomainError) as error: service.update(item['id'],{'state':'active'},item['revision'],'stale-memory')
    assert error.value.code=='version_conflict'
    assert service.update(item['id'],fields,latest['revision'],'latest-memory')['count']==1


def test_upgrade_repairs_preexisting_memory_version_drift(client):
    from interview_backend.database import upgrade_database
    from interview_backend.services.common import version
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute("INSERT INTO memories VALUES('drift','analysis','保留内容','global','[]','版本','needs_review',NULL,5)")
        c.execute("INSERT INTO object_versions VALUES('memory','drift',1)")
        c.execute("UPDATE alembic_version SET version_num='0002_application'")
    upgrade_database(db.path)
    with db.transaction() as c:
        assert version(c,'memory','drift')==5
        assert c.execute("SELECT revision FROM index_queue WHERE resource_type='memory' AND resource_id='drift'").fetchone()[0]==5
        assert c.execute("SELECT content FROM memories WHERE id='drift'").fetchone()[0]=='保留内容'
