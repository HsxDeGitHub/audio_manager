"""组合指令先原子提交内容，再执行依赖该版本的设备步骤。"""
import asyncio,json
import pytest
from langchain_core.messages import AIMessage
from interview_backend.errors import DomainError

class EditAndExport:
    def __init__(self,fail=False):self.step=0;self.fail=fail
    def bind_tools(self,tools):return self
    async def ainvoke(self,messages):
        self.step+=1
        if self.step==1:
            return AIMessage(content='',tool_calls=[
                {'name':'changesets__apply','id':'edit','args':{'targets':[{'resource_type':'segment','resource_id':'s1','expected_revision':1,'fields':{'text':'提交后的正文'}}]}},
                {'name':'device__export','id':'export','args':{'recording_id':'r1','format':'txt'}}])
        if self.fail:raise RuntimeError('合成模型失败')
        return AIMessage(content=json.dumps({'answer':'提出修改与导出步骤。','claims':[]}))


def test_export_reads_committed_content_and_can_resume_without_rewriting(client,monkeypatch):
    db=client.app.state.database;device=client.app.state.device;engine=client.app.state.agent.engine
    captured=[];ready={'value':False}
    async def receipt(identifier,timeout=10):
        if not ready['value']:return device.get(identifier)
        device.claim(identifier,'device')
        with db.transaction() as c:captured.append(c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0])
        return device.complete(identifier,'device','completed',{'characters':7})
    monkeypatch.setattr(device,'wait',receipt)
    context=client.app.state.evidence.freeze({'recording_id':'r1'},'请修正当前资料，并导出修改后的正文')
    first=asyncio.run(engine.execute('ordered',context['instruction'],context,model=EditAndExport()))
    assert first.get('incomplete') and first['changeset']['count']==1
    assert captured==[]
    ready['value']=True
    second=asyncio.run(engine.execute('ordered',context['instruction'],context,model=EditAndExport()))
    assert not second.get('incomplete') and captured==['提交后的正文']
    assert second['device_results'][0]['state']=='completed'
    with db.transaction() as c:
        assert c.execute("SELECT revision FROM object_versions WHERE resource_type='segment' AND resource_id='s1'").fetchone()[0]==2
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0]==1


def test_generation_failure_before_commit_never_starts_dependent_export(client,monkeypatch):
    device=client.app.state.device;engine=client.app.state.agent.engine;calls=[]
    async def receipt(*args,**kwargs):calls.append(args);raise AssertionError('不应提前导出')
    monkeypatch.setattr(device,'wait',receipt)
    context=client.app.state.evidence.freeze({'recording_id':'r1'},'请修正当前资料，并导出修改后的正文')
    with pytest.raises(DomainError):asyncio.run(engine.execute('before-fail',context['instruction'],context,model=EditAndExport(True)))
    assert calls==[] and device.pending()==[]
    with client.app.state.database.transaction() as c:assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None


@pytest.mark.parametrize('state',['cancelled','failed'])
def test_post_commit_failure_or_cancel_survives_restart_and_resumes_only_device(client,monkeypatch,state):
    import time
    from interview_backend.agent.models import ModelSettings
    from interview_backend.agent.api import AgentAPI
    model=EditAndExport(); device=client.app.state.device;ready={'value':False};exports=[]
    class Settings:
        def client(self):return model
    monkeypatch.setattr(ModelSettings,'load',classmethod(lambda cls,path:Settings()))
    async def receipt(identifier,timeout=10):
        device.claim(identifier,'owner')
        if not ready['value']:return device.complete(identifier,'owner',state,{'retry_safe':True,'message':'合成设备中断'})
        with client.app.state.database.transaction() as c:exports.append(c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0])
        return device.complete(identifier,'owner','completed',{'characters':7})
    monkeypatch.setattr(device,'wait',receipt)
    session=client.post('/api/v1/sessions',json={}).json()['id']
    identifier=client.post('/api/v1/agent/runs',json={'session_id':session,'instruction':'请修正当前资料，并导出修改后的正文','context':{'recording_id':'r1'}}).json()['id']
    def wait():
        for _ in range(200):
            run=client.get('/api/v1/agent/runs/'+identifier).json()
            if run['state'] not in {'queued','running'}:return run
            time.sleep(.005)
        pytest.fail('任务未结束')
    failed=wait();assert failed['state']=='failed' and failed['result']['changeset']['count']==1
    assert failed['result']['device_results'][0]['state']==state
    old=client.app.state.agent;client.app.state.agent=AgentAPI(old.database,old.engine,old.evidence)
    ready['value']=True
    monkeypatch.setattr(ModelSettings,'load',classmethod(lambda cls,path:(_ for _ in ()).throw(AssertionError('不应重跑模型步骤'))))
    assert client.post('/api/v1/agent/runs/'+identifier+'/resume').status_code==200
    completed=wait();assert completed['state']=='completed' and exports==['提交后的正文'] and model.step==2
    with old.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0]==1
        assert c.execute('SELECT count(*) FROM device_commands').fetchone()[0]==1
