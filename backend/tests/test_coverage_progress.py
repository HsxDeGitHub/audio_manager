import json,time
import pytest
from langchain_core.messages import AIMessage
from interview_backend.agent.models import ModelSettings


def prepare(client,monkeypatch,cancel=False):
    with client.app.state.database.transaction(True) as c:
        c.execute("DELETE FROM segments WHERE id='s2'")
        c.execute("UPDATE segments SET original=?,edited=NULL WHERE id='s1'",('合成'*9000,))
    class Model:
        count=0
        ready=False
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            import asyncio
            self.count+=1
            if self.count==2 and not self.ready:
                if cancel:await asyncio.sleep(30)
                else:raise RuntimeError('第二块合成失败')
            return AIMessage(content=json.dumps({'answer':'已保留的合成分块分析','claims':[]}))
    model=Model()
    class Settings:
        def client(self):return model
    monkeypatch.setattr(ModelSettings,'load',classmethod(lambda cls,path:Settings()))
    session=client.post('/api/v1/sessions',json={}).json()['id']
    identifier=client.post('/api/v1/agent/runs',json={'session_id':session,'instruction':'分析全部资料','context':{'recording_id':'r1'}}).json()['id']
    return model,identifier


def wait(client,identifier):
    for _ in range(300):
        run=client.get('/api/v1/agent/runs/'+identifier).json()
        if run['state'] not in {'queued','running'}:return run
        time.sleep(.005)
    pytest.fail('合成任务未结束')


def test_long_source_failure_and_resume_preserve_exact_unfinished_ranges(client,monkeypatch):
    model,identifier=prepare(client,monkeypatch)
    failed=wait(client,identifier)
    coverage=failed['result']['coverage']
    assert coverage['unit']=='parts' and coverage['covered']==1 and coverage['total']==3
    assert coverage['source_covered']==0 and coverage['source_total']==1
    assert [p['char_start'] for p in coverage['parts']]==[0,6000,12000]
    assert [p['state'] for p in coverage['parts']]==['completed','failed','pending']
    assert failed['result']['partial_results'][0]['answer']=='已保留的合成分块分析'
    ids=[p['id'] for p in coverage['parts']]
    model.ready=True
    assert client.post('/api/v1/agent/runs/'+identifier+'/resume').status_code==200
    completed=wait(client,identifier)
    assert completed['state']=='completed' and completed['result']['coverage']['covered']==3
    assert completed['result']['coverage']['source_covered']==1 and model.count==4
    assert [p['id'] for p in completed['result']['coverage']['parts']]==ids


def test_cancelled_long_source_does_not_claim_complete_source(client,monkeypatch):
    model,identifier=prepare(client,monkeypatch,True)
    for _ in range(200):
        if model.count>=2:break
        time.sleep(.005)
    run=client.post('/api/v1/agent/runs/'+identifier+'/cancel').json()
    coverage=run['result']['coverage']
    assert coverage['covered']==1 and coverage['total']==3 and coverage['source_covered']==0
    assert coverage['parts'][1]['state']=='cancelled'


def test_mixed_sources_count_only_fully_processed_sources(client,monkeypatch):
    import asyncio
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE segments SET original=?,edited=NULL WHERE id='s1'",('合成'*6000,))
        c.execute("UPDATE segments SET original='另一个短来源',edited=NULL WHERE id='s2'")
    class Model:
        count=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.count+=1
            if self.count==2:raise RuntimeError('合成后块失败')
            return AIMessage(content=json.dumps({'answer':'第一组','claims':[]}))
    from interview_backend.errors import DomainError
    engine=client.app.state.agent.engine;context=client.app.state.evidence.freeze({'recording_id':'r1'},'分析全部资料')
    with pytest.raises(DomainError):asyncio.run(engine.execute('mixed-coverage',context['instruction'],context,model=Model()))
    from interview_backend.agent.work import WorkLog
    coverage=WorkLog(client.app.state.database,'mixed-coverage').get('coverage_progress')['coverage']
    assert coverage['covered']==1 and coverage['total']==3
    assert coverage['source_covered']==0 and coverage['source_total']==2
    assert {p['resource_id'] for p in coverage['parts'] if p['state']=='failed'}=={'s1','s2'}
