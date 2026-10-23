import asyncio,json
import pytest
from langchain_core.messages import AIMessage
from interview_backend.errors import DomainError
from interview_backend.services.memory import MemoryService


def memory_fixture(client):
    db=client.app.state.database
    with db.transaction(True) as c:
        c.execute("INSERT INTO sessions(id,title,scope,created_at) VALUES('integrity-session','合成','{}',1)")
        c.execute("INSERT INTO messages VALUES('integrity-message','integrity-session','user','合成旧偏好唯一标记','{}',1)")
    service=MemoryService(db,client.app.state.evidence)
    item=service.add({'category':'preference','content':'合成旧偏好唯一标记','scope':'global','topic':'表达',
                      'sources':[{'resource_type':'message','resource_id':'integrity-message','revision':1}]},'integrity-memory')
    return service,item


@pytest.mark.parametrize('field,value',[('state','deleted'),('state','disabled'),('content','纠正后的内容')])
@pytest.mark.parametrize('question',[False,True])
def test_final_readonly_result_rechecks_all_earlier_memory_references(client,field,value,question):
    service,item=memory_fixture(client)
    with client.app.state.database.transaction(True) as c:c.execute("UPDATE segments SET original=?,edited=NULL WHERE run_id='run1'",('合成'*3000,))
    class Model:
        step=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==1:
                ref={'resource_type':'memory','resource_id':item['id'],'revision':1}
                return AIMessage(content=json.dumps({'answer':'第一块','claims':[] if question else [{'kind':'analysis','text':'分析','sources':[ref]}],
                    'questions':[{'text':'合成问题','source':ref}] if question else []}))
            service.update(item['id'],{field:value},1,'change-memory')
            return AIMessage(content=json.dumps({'answer':'第二块','claims':[]}))
    instruction='列出全部问题' if question else '分析全部资料'
    context=client.app.state.evidence.freeze({'recording_id':'r1'},instruction)
    with pytest.raises(DomainError) as error:
        asyncio.run(client.app.state.agent.engine.execute('final-memory',instruction,context,model=Model()))
    assert error.value.code=='stale_source'


@pytest.mark.parametrize('change',[{'state':'deleted'},{'state':'disabled'},{'content':'纠正后的偏好'}])
def test_resumed_model_input_never_reinjects_old_memory_from_cached_messages(client,change):
    service,item=memory_fixture(client);engine=client.app.state.agent.engine
    class First:
        step=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==1:return AIMessage(content='旧偏好为合成旧偏好唯一标记',tool_calls=[{'name':'evidence__read','id':'read','args':{}}])
            raise RuntimeError('合成中断')
    original=client.app.state.evidence.freeze({'recording_id':'r1'},'分析当前资料')
    with pytest.raises(DomainError):asyncio.run(engine.execute('cache-integrity',original['instruction'],json.loads(json.dumps(original)),model=First()))
    service.update(item['id'],change,1,'change-before-resume')
    seen=[]
    class Resumed:
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            seen.append(messages)
            assert all('合成旧偏好唯一标记' not in str(message.content) for message in messages)
            return AIMessage(content=json.dumps({'answer':'基于当前资料完成。','claims':[]}))
    result=asyncio.run(engine.execute('cache-integrity',original['instruction'],json.loads(json.dumps(original)),model=Resumed()))
    assert result['answer'] and seen


def test_memory_change_does_not_reexecute_completed_device_when_model_cache_rebuilds(client,monkeypatch):
    service,item=memory_fixture(client);engine=client.app.state.agent.engine;device=client.app.state.device;calls=[]
    async def receipt(identifier,timeout=10):
        calls.append(identifier);device.claim(identifier,'owner');return device.complete(identifier,'owner','completed',{'characters':6})
    monkeypatch.setattr(device,'wait',receipt)
    class Model:
        step=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==2:raise RuntimeError('合成模型中断')
            if self.step>=3:assert all('合成旧偏好唯一标记' not in str(m.content) for m in messages)
            if self.step in {1,3}:return AIMessage(content='合成旧偏好唯一标记' if self.step==1 else '',tool_calls=[{'name':'device__copy','id':'copy','args':{'text':'固定合成内容'}}])
            return AIMessage(content=json.dumps({'answer':'剩余分析完成。','claims':[]}))
    model=Model();context=client.app.state.evidence.freeze({'recording_id':'r1'},'请复制文字并分析回答')
    with pytest.raises(DomainError):asyncio.run(engine.execute('effect-rebuild',context['instruction'],json.loads(json.dumps(context)),model=model))
    service.update(item['id'],{'state':'deleted'},1,'forget-effect-memory')
    asyncio.run(engine.execute('effect-rebuild',context['instruction'],json.loads(json.dumps(context)),model=model))
    assert len(calls)==1 and model.step==4


@pytest.mark.parametrize('unknown,legacy',[(False,False),(False,True),(True,False)])
def test_external_effect_receipt_is_preserved_without_reinjecting_stale_output(client,unknown,legacy):
    from interview_backend.tools.registry import ToolSpec
    from interview_backend.agent.tools import EmptyArguments,ResultEnvelope
    service,item=memory_fixture(client);engine=client.app.state.agent.engine;calls=[]
    def effect(args,context):
        calls.append(1)
        if unknown:raise DomainError('external_result_unknown','合成结果未知',504)
        return {'result':{'echo':'合成旧偏好唯一标记'}}
    client.app.state.tools.register(ToolSpec(tool_id='mcp.fixture.effect',version='1',title='合成',description='合成副作用',effect='external',input_model=EmptyArguments,output_model=ResultEnvelope,handler=effect))
    class Model:
        step=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==2 and not unknown:raise RuntimeError('合成中断')
            if self.step>1 and (unknown or self.step>2):assert all('合成旧偏好唯一标记' not in str(m.content) for m in messages)
            if self.step in ({1,2} if unknown else {1,3}):return AIMessage(content='',tool_calls=[{'name':'mcp__fixture__effect','id':'effect','args':{}}])
            return AIMessage(content=json.dumps({'answer':'继续完成。','claims':[]}))
    model=Model();context=client.app.state.evidence.freeze({'recording_id':'r1'},'请使用 mcp.fixture.effect 并分析当前资料')
    with pytest.raises(DomainError):asyncio.run(engine.execute('external-rebuild',context['instruction'],json.loads(json.dumps(context)),model=model))
    if legacy:
        with client.app.state.database.transaction(True) as c:c.execute("DELETE FROM agent_work WHERE run_id='external-rebuild' AND step_key LIKE 'effect:%'")
    service.update(item['id'],{'state':'deleted'},1,'forget-external-memory')
    if unknown:
        with pytest.raises(DomainError) as error:asyncio.run(engine.execute('external-rebuild',context['instruction'],json.loads(json.dumps(context)),model=model))
        assert error.value.code=='external_result_unknown'
    else:asyncio.run(engine.execute('external-rebuild',context['instruction'],json.loads(json.dumps(context)),model=model))
    assert len(calls)==1


def test_api_resume_recomputes_invalid_readonly_finalization_without_write_lock(client,monkeypatch):
    import time
    from interview_backend.agent.models import ModelSettings
    service,item=memory_fixture(client)
    with client.app.state.database.transaction(True) as c:c.execute("UPDATE segments SET original=?,edited=NULL WHERE run_id='run1'",('合成'*3000,))
    class Model:
        step=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==1:return AIMessage(content=json.dumps({'answer':'旧分析','claims':[{'kind':'analysis','text':'偏好','sources':[{'resource_type':'memory','resource_id':item['id'],'revision':1}]}]}))
            if self.step==2:service.update(item['id'],{'state':'deleted'},1,'forget-finalization')
            if self.step>2:assert all('合成旧偏好唯一标记' not in str(m.content) for m in messages)
            return AIMessage(content=json.dumps({'answer':'当前有效资料分析','claims':[]}))
    model=Model()
    class Settings:
        def client(self):return model
    monkeypatch.setattr(ModelSettings,'load',classmethod(lambda cls,path:Settings()))
    session=client.post('/api/v1/sessions',json={}).json()['id']
    identifier=client.post('/api/v1/agent/runs',json={'session_id':session,'instruction':'分析全部资料','context':{'recording_id':'r1'}}).json()['id']
    def wait():
        for _ in range(200):
            run=client.get('/api/v1/agent/runs/'+identifier).json()
            if run['state'] not in {'queued','running'}:return run
            time.sleep(.005)
        pytest.fail('任务未结束')
    assert wait()['state']=='failed'
    assert client.post('/api/v1/agent/runs/'+identifier+'/resume').status_code==200
    resumed=wait()
    assert resumed['state']=='completed' and model.step==2+resumed['result']['coverage']['chunks']
