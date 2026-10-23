"""长任务在单个推理步骤恢复，不能重放工具、放宽引用或写入真实资料。"""
import asyncio
import json

import httpx
import pytest
from langchain_core.messages import AIMessage, AIMessageChunk

from interview_backend.agent import model_recovery as recovery
from interview_backend.agent.work import WorkLog
from interview_backend.errors import DomainError
from interview_backend.services.changesets import ChangeSetService
from test_bounded_editing import seed, ToolBatchModel, run


@pytest.fixture(autouse=True)
def quick_backoff(monkeypatch):
    monkeypatch.setattr(recovery,'BACKOFF_SECONDS',0)


def test_partial_stream_disconnect_retries_current_step_and_replaces_preview(client):
    events=[]
    class Model:
        calls=0
        async def astream(self,messages):
            self.calls+=1
            if self.calls==1:
                yield AIMessageChunk(content='{"answer":"无效的部分回答')
                raise httpx.ReadError('private-provider-body KEY=synthetic-secret')
            yield AIMessageChunk(content='{"answer":"完整的合成回答","claims":[]}')
    model=Model();work=WorkLog(client.app.state.database,'stream-retry')
    async def execute():
        async def emit(kind,payload):events.append((kind,payload))
        return await work.model('chunk:0:model:0',model,[],emit=emit,validator=recovery.parse_result)
    result=asyncio.run(execute())
    assert model.calls==2 and json.loads(result.content)['answer']=='完整的合成回答'
    preview=''
    for kind,payload in events:
        if kind=='answer_start':preview=''
        if kind=='answer_delta':preview+=payload['text']
    assert preview=='完整的合成回答'
    diagnostic=work.get('model_attempts:chunk:0:model:0')
    assert diagnostic['attempts'][0]['code']=='model_connection_failed'
    assert 'synthetic-secret' not in json.dumps(diagnostic)
    assert work.get('failure:chunk:0:model:0') is None


@pytest.mark.parametrize('first',[
    AIMessage(content='不是JSON'),
    AIMessage(content='{"answer":"截断但看似有效","claims":[]}',response_metadata={'finish_reason':'length'}),
    AIMessage(content='{"answer":3,"claims":[]}'),
    AIMessage(content='',invalid_tool_calls=[{'name':'changesets__apply','args':'{','id':'bad','error':'bad json'}]),
])
def test_bad_model_response_is_repaired_before_it_is_cached(client,first):
    class Model:
        calls=0
        async def ainvoke(self,messages):
            self.calls+=1
            if self.calls==1:return first
            assert messages[-1].type=='system' and '只返回完整 JSON' in messages[-1].content
            return AIMessage(content='{"answer":"修复后的合成输出","claims":[]}')
    work=WorkLog(client.app.state.database,'format-retry');model=Model()
    response=asyncio.run(work.model('model',model,[],validator=recovery.parse_result))
    assert model.calls==2 and response.content==work.get('model')['response']['content']


@pytest.mark.parametrize('kind,expected,calls',[
    ('timeout','model_timeout',3),('429','model_rate_limited',3),('503','model_unavailable',3),
    ('401','model_auth_failed',1),('400','model_request_rejected',1),
    ('format','model_invalid_output',3),
])
def test_retry_budget_and_safe_error_categories(client,kind,expected,calls):
    class Model:
        calls=0
        async def ainvoke(self,messages):
            self.calls+=1
            if kind=='format':return AIMessage(content='KEY=synthetic-secret')
            if kind=='timeout':raise httpx.ReadTimeout('KEY=synthetic-secret')
            from openai import APIStatusError
            response=httpx.Response(int(kind),request=httpx.Request('POST','https://synthetic.invalid/private'))
            raise APIStatusError('KEY=synthetic-secret',response=response,body={'secret':'synthetic-secret'})
    model=Model();work=WorkLog(client.app.state.database,'budget')
    with pytest.raises(DomainError) as error:
        asyncio.run(work.model('model',model,[],validator=recovery.parse_result))
    assert error.value.code==expected and model.calls==calls
    assert work.get('model') is None
    diagnostic=work.get('model_attempts:model')
    assert len(diagnostic['attempts'])==calls
    assert 'synthetic-secret' not in json.dumps(diagnostic)+error.value.message


def test_cancel_during_model_step_is_not_retried(client):
    class Model:
        calls=0
        async def ainvoke(self,messages):
            self.calls+=1
            raise asyncio.CancelledError()
    model=Model()
    with pytest.raises(asyncio.CancelledError):asyncio.run(WorkLog(client.app.state.database,'cancel-retry').model('model',model,[]))
    assert model.calls==1


def test_step_has_a_total_deadline_and_provider_retries_are_not_nested(client,monkeypatch):
    monkeypatch.setattr(recovery,'STEP_TIMEOUT',.02)
    class Model:
        calls=0
        async def ainvoke(self,messages):
            self.calls+=1
            await asyncio.Event().wait()
    model=Model()
    with pytest.raises(DomainError) as error:asyncio.run(WorkLog(client.app.state.database,'deadline').model('model',model,[]))
    assert error.value.code=='model_timeout' and model.calls==1
    from interview_backend.agent.models import ModelSettings
    real=ModelSettings(baseURL='https://synthetic.invalid/v1',apiKey='synthetic',model='synthetic').client()
    assert real.request_timeout.connect==10 and real.request_timeout.read==180 and real.max_retries==0


def test_retry_rechecks_actual_versions_before_sending_more_content(client):
    class Model:
        calls=0
        async def ainvoke(self,messages):
            self.calls+=1
            ChangeSetService(client.app.state.database).submit({'operation_id':'concurrent-edit','targets':[
                {'resource_type':'segment','resource_id':'s1','expected_revision':1,'fields':{'text':'并发校对'}}]})
            raise httpx.ReadTimeout('synthetic timeout')
    model=Model()
    with pytest.raises(DomainError) as error:
        asyncio.run(WorkLog(client.app.state.database,'version-retry').model('model',model,[],
            dependencies=[{'resource_type':'segment','resource_id':'s1','revision':1}]))
    assert error.value.code=='stale_source' and model.calls==1


def test_544_long_task_recovers_multiple_failures_without_replaying_writes(client,config):
    context=seed(client)
    context['model_step_policy']='recovery-v1'
    with client.app.state.database.transaction() as c:
        before=[dict(r) for r in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start")]
    class FlakyModel(ToolBatchModel):
        def __init__(self,client):super().__init__(client);self.faults=set();self.batch=0;self.receipts=0
        async def ainvoke(self,messages):
            if messages[-1].type=='tool' or messages[-1].type=='system':
                # 格式纠正追加system，原工具回执仍在同一模型步骤内。
                if any(m.type=='tool' for m in messages):
                    self.receipts+=1
                    if self.batch==8 and 'citation' not in self.faults:
                        self.faults.add('citation')
                        return AIMessage(content=json.dumps({'answer':'无效引用','claims':[{'kind':'analysis','text':'合成分析',
                            'sources':[{'resource_type':'segment','resource_id':'not-in-scope','revision':99}]}]}))
                    return AIMessage(content='{"answer":"本批已登记","claims":[]}')
            prompt=json.loads(messages[1].content);self.batch=prompt['chunk']
            assert 'batch_result_hint' in prompt
            if self.batch in {4,11} and self.batch not in self.faults:
                self.faults.add(self.batch)
                if self.batch==4:raise httpx.ReadTimeout('synthetic transient failure')
                return AIMessage(content='{"answer":"未完整","claims":[]}',response_metadata={'finish_reason':'length'})
            return await super().ainvoke(messages[:2])
    model=FlakyModel(client)
    result=run(client,config,context,model,identifier='long-retry')
    assert result['coverage']['covered']==544 and result['changeset']['count']==544
    assert model.faults=={4,11,'citation'} and len(model.calls)==result['coverage']['chunks']
    # 每一批写工具只执行一次；发生引用错误时仅重试工具之后的回答步骤。
    assert model.receipts==result['coverage']['chunks']+1
    work=WorkLog(client.app.state.database,'long-retry')
    assert work.get('model_attempts:chunk:7:model:1')['attempts'][0]['reason']=='invalid_citation'
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0]==2
    ChangeSetService(client.app.state.database).revert(result['changeset']['id'],'undo-retry')
    with client.app.state.database.transaction() as c:
        assert [dict(r) for r in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start")]==before


def test_resume_clears_previous_error_before_new_execution(client):
    class Engine:
        started=0
        async def execute(self,*args,**kwargs):
            self.started+=1
            if self.started==1:raise DomainError('model_timeout','合成失败',503)
            await asyncio.Event().wait()
    import time
    service=client.app.state.agent;service.engine=Engine()
    session=client.post('/api/v1/sessions',json={}).json()['id']
    identifier=client.post('/api/v1/agent/runs',json={'session_id':session,'instruction':'合成分析',
        'context':{'recording_id':'r1'}}).json()['id']
    for _ in range(200):
        value=client.get('/api/v1/agent/runs/'+identifier).json()
        if value['state']=='failed':break
        time.sleep(.005)
    assert value['result']['error']['code']=='model_timeout'
    assert client.post('/api/v1/agent/runs/'+identifier+'/resume').status_code==200
    resumed=client.get('/api/v1/agent/runs/'+identifier).json()
    assert resumed['state'] in {'queued','running'} and not resumed['result'].get('error')
    client.post('/api/v1/agent/runs/'+identifier+'/cancel')
