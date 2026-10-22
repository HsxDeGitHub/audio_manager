import asyncio
from interview_backend.services.reports import ReportService
from interview_backend.agent.tools import EvidenceService


def test_week_uses_actual_dates_type_and_complete_target_list(client):
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute("UPDATE recordings SET kind='interview', interview_date='2026-10-19' WHERE id='r1'")
        c.execute("UPDATE recordings SET kind='interview', interview_date=NULL WHERE id='r2'")
        for i, day in enumerate(['2026-10-18','2026-10-25','2026-10-26']):
            c.execute('INSERT INTO recordings(id,title,path,fingerprint,duration,created_at,state,play_position,kind,interview_date) VALUES(?,?,?,?,?,?,?,?,?,?)', (f'w{i}', f'合成{i}', '/synthetic',str(i),1,1,'idle',0,'interview',day))
    report = ReportService(db, EvidenceService(db))
    plan = report.plan('2026-10-21')
    assert plan['start'] == '2026-10-19' and plan['end_exclusive'] == '2026-10-26'
    assert {r['id'] for r in plan['targets']} == {'r1','w1'}
    assert plan['excluded'][0]['reason'] == '实际面试日期未知'
    class Engine:
        async def execute(self, *args, **kwargs): return {'answer': '合成分析', 'claims': []}
    result = asyncio.run(report.render('weekly', '逐份分析本周面试', Engine(), '2026-10-21'))
    assert result['coverage']['total'] == 2 and result['coverage']['covered'] == 1
    assert len(result['coverage']['excluded']) == 2


def week_fixture(client):
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE recordings SET kind='interview',interview_date='2026-10-19',state='completed'")


def test_weekly_context_freezes_read_targets_without_expanding_write_scope(client):
    week_fixture(client)
    service = client.app.state.agent.engine.reports
    parent = client.app.state.evidence.freeze({'recording_id': 'r1'}, '本周仅修改当前面试，并分析全部面试')
    frozen = service.freeze(parent, parent['instruction'], '2026-10-21')
    assert [r['id'] for r in frozen['targets']] == ['r1', 'r2']
    assert frozen['contexts']['r1']['allow_write']
    assert not frozen['contexts']['r2']['allow_write']
    with client.app.state.database.transaction(True) as c: c.execute("UPDATE recordings SET active_run=NULL WHERE id='r1'")
    assert frozen['contexts']['r1']['device_targets'][0]['run_id'] == 'run1'


def test_weekly_batch_has_one_parent_receipt_and_rolls_back_if_later_child_fails(client, config):
    import json, pytest
    from langchain_core.messages import AIMessage
    from interview_backend.agent.graph import AgentEngine
    from interview_backend.errors import DomainError
    week_fixture(client)
    evidence = client.app.state.evidence
    service = client.app.state.agent.engine.reports
    class Model:
        def __init__(self, fail): self.fail = fail
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            prompt = json.loads(messages[-1].content)
            identifier = prompt['untrusted_evidence'][0]['resource_id']
            if self.fail and identifier == 's3': raise RuntimeError('later child failure')
            return AIMessage(content=json.dumps({'answer':'建议', 'claims':[], 'targets':[
                {'resource_type':'segment','resource_id':identifier,'expected_revision':1,'fields':{'text':'周批量'}}]}))
    parent = evidence.freeze({'scope':'all'}, '请修改本周全部面试')
    parent['report_plan'] = service.freeze(parent, parent['instruction'], '2026-10-21')
    engine = AgentEngine(config, client.app.state.tools, evidence); engine.reports = service
    with pytest.raises(DomainError): asyncio.run(engine.execute('week-batch', parent['instruction'], parent, model=Model(True)))
    assert evidence.committed('week-batch') == []
    assert client.get('/api/v1/transcripts/run1/segments').json()['items'][0]['edited'] is None
    result = asyncio.run(engine.execute('week-batch', parent['instruction'], parent, model=Model(False)))
    assert len(result['changesets']) == 1 and result['changesets'][0]['count'] == 2
    assert client.post('/api/v1/changesets/week-batch:changes/revert', json={'operation_id':'undo-week'}).status_code == 200


def test_weekly_subtasks_cannot_write_outside_parent_or_use_changed_source(client, config):
    import json, pytest
    from langchain_core.messages import AIMessage
    from interview_backend.errors import DomainError
    week_fixture(client)
    evidence = client.app.state.evidence
    engine = client.app.state.agent.engine
    class Model:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            prompt = json.loads(messages[-1].content)
            identifier = prompt['untrusted_evidence'][0]['resource_id']
            return AIMessage(content=json.dumps({'answer':'建议','claims':[], 'targets':[
                {'resource_type':'segment','resource_id':identifier,'expected_revision':1,'fields':{'text':'修改'}}]}))
    parent = evidence.freeze({'recording_id':'r1'}, '本周仅修改当前面试，并分析全部面试')
    parent['report_plan'] = engine.reports.freeze(parent, parent['instruction'], '2026-10-21')
    with pytest.raises(DomainError): asyncio.run(engine.execute('week-scope', parent['instruction'], parent, model=Model()))
    assert evidence.committed('week-scope') == []
    from interview_backend.services.common import bump
    with client.app.state.database.transaction(True) as c: bump(c,'segment','s3')
    with pytest.raises(DomainError) as error: asyncio.run(engine.execute('week-stale', parent['instruction'], parent, model=Model()))
    assert error.value.code == 'stale_context'
    assert evidence.committed('week-stale') == []


def test_weekly_result_rechecks_earlier_child_after_later_child_runs(client):
    import pytest
    from interview_backend.errors import DomainError
    from interview_backend.services.common import bump
    week_fixture(client)
    service=client.app.state.agent.engine.reports
    parent=client.app.state.evidence.freeze({'scope':'all'},'分析本周全部面试')
    parent['report_plan']=service.freeze(parent,parent['instruction'],'2026-10-21')
    class Engine:
        async def execute(self,child_id,*args,**kwargs):
            if child_id.endswith(':r2'):
                with client.app.state.database.transaction(True) as c: bump(c,'segment','s1')
            return {'answer':'合成分析','claims':[]}
    with pytest.raises(DomainError) as error:
        asyncio.run(service.render('week-recheck',parent['instruction'],Engine(),context=parent))
    assert error.value.code=='stale_context'
