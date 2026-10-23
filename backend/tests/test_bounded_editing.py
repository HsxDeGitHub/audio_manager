"""整场544片段、混合版本与中途恢复；仅使用生成的合成文字和本机临时库。"""
import asyncio
import json
import threading
import uuid

import pytest
from langchain_core.messages import AIMessage

from interview_backend.agent.batching import MAX_PARTS, MAX_INPUT_BYTES, make_chunks, bounded_memories
from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.intent import apply
from interview_backend.agent.work import WorkLog
from interview_backend.errors import DomainError
from interview_backend.services.changesets import ChangeSetService


def seed(client, count=544):
    database=client.app.state.database
    identifiers=[str(uuid.uuid5(uuid.NAMESPACE_URL,f'listen-synthetic-{i}')) for i in range(count)]
    with database.transaction(True) as c:
        c.execute("DELETE FROM segments WHERE run_id='run1'")
        c.executemany("INSERT INTO segments(id,run_id,start,end,original,speaker,needs_review) VALUES(?,'run1',?,?,?,0,1)",
            [(identifier,i*2,i*2+1,'合成候选人的发言'+str(i)) for i,identifier in enumerate(identifiers)])
    # 模拟上次已校对37处；新任务不能假定全为版本1，也不能覆盖旧校对。
    ChangeSetService(database).submit({'operation_id':'previous-corrections','targets':[
        {'resource_type':'segment','resource_id':identifier,'expected_revision':1,'fields':{'text':'既有校对'+str(i)}}
        for i,identifier in enumerate(identifiers[:min(37,count)])]})
    value=client.app.state.evidence.freeze({'recording_id':'r1'},'请整理整场说话人，正文不改',semantic=True)
    value['intent_policy']='semantic-v2'
    value=apply(value,{'mode':'edit','reading':'full','edit_target':'transcript','import_documents':False,
                       'actions':[],'constraints':['正文不改'],'clarification':''})
    return value


class BatchModel:
    def __init__(self, client, *, fail_at=None, wrong_revision=False, mutate=None):
        self.client,self.fail_at,self.wrong_revision,self.mutate=client,fail_at,wrong_revision,mutate
        self.calls=[]; self.bytes=[]

    def bind_tools(self,tools):
        apply=next(t for t in tools if t.name=='changesets__apply')
        schema=apply.args_schema.model_json_schema()
        assert 'expected_revision' not in schema['$defs']['ProposedTarget']['required']
        return self

    async def ainvoke(self,messages):
        prompt=json.loads(messages[-1].content)
        sources=prompt['untrusted_evidence']; self.calls.append([s['resource_id'] for s in sources])
        self.bytes.append(len(messages[-1].content.encode()))
        assert len(sources)<=MAX_PARTS and self.bytes[-1]<MAX_INPUT_BYTES
        assert len(prompt['scope'])<=MAX_PARTS+3
        assert prompt['host_bound_revisions'] and not prompt['pending_proposals']
        assert len(prompt['adjacent_evidence'])<=4
        with self.client.app.state.database.transaction() as c:
            assert c.execute('SELECT count(*) FROM changesets').fetchone()[0]==1
        if self.fail_at==len(self.calls): raise RuntimeError('synthetic temporary failure')
        if self.mutate:
            self.mutate(sources[0]); self.mutate=None
        targets=[{'resource_type':'segment','resource_id':s['resource_id'],'fields':{'speaker':1},
                  **({'expected_revision':1} if self.wrong_revision else {})} for s in sources]
        return AIMessage(content=json.dumps({'answer':'合成发言归属建议','claims':[],'targets':targets}))


class ToolBatchModel(BatchModel):
    async def ainvoke(self,messages):
        if messages[-1].type=='tool':
            receipt=json.loads(messages[-1].content)['result']
            assert receipt['state']=='planned' and 'items' not in receipt
            assert len(messages[-1].content.encode())<1000
            return AIMessage(content=json.dumps({'answer':'本批已登记','claims':[]}))
        result=json.loads((await super().ainvoke(messages)).content)
        return AIMessage(content='',tool_calls=[{'name':'changesets__apply','args':{'targets':result['targets']},'id':'batch'}])


def run(client,config,context,model,identifier='bounded-edit'):
    engine=AgentEngine(config,client.app.state.tools,client.app.state.evidence)
    return asyncio.run(engine.execute(identifier,context['instruction'],context,model=model))


@pytest.mark.parametrize('wrong_revision',[False,True])
def test_544_mixed_revisions_are_bounded_commit_once_and_undo(client,config,wrong_revision):
    context=seed(client)
    with client.app.state.database.transaction() as c:
        before=[dict(r) for r in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start")]
    model=(ToolBatchModel if wrong_revision else BatchModel)(client,wrong_revision=wrong_revision)
    result=run(client,config,context,model)
    assert result['coverage']['covered']==result['coverage']['total']==544
    assert result['coverage']['chunks']>=17 and len(model.calls)==result['coverage']['chunks']
    assert len({identifier for batch in model.calls for identifier in batch})==544
    assert result['changeset']['count']==544
    assert WorkLog(client.app.state.database,'bounded-edit').get('chunk:0:model:0')['input_bytes']<MAX_INPUT_BYTES
    revisions={i['before_revision'] for i in result['changeset']['items']}
    assert revisions=={1,2}
    with client.app.state.database.transaction() as c:
        after=[dict(r) for r in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start")]
    assert all(s['speaker']==1 for s in after)
    for old,new in zip(before,after):
        assert all(old[k]==new[k] for k in ('id','original','edited','start','end','run_id'))
    assert client.post('/api/v1/changesets/'+result['changeset']['id']+'/revert',json={'operation_id':'undo-batch'}).status_code==200
    with client.app.state.database.transaction() as c:
        assert [dict(r) for r in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start")]==before


def test_resume_reuses_completed_batches_without_partial_commits(client,config):
    context=seed(client)
    model=BatchModel(client,fail_at=4)
    with pytest.raises(DomainError) as error: run(client,config,context,model)
    assert error.value.code=='model_failed'
    progress=WorkLog(client.app.state.database,'bounded-edit').get('coverage_progress')['coverage']
    assert 0<progress['covered']<544
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT count(*) FROM segments WHERE run_id='run1' AND speaker=1").fetchone()[0]==0
    retry=BatchModel(client)
    result=run(client,config,context,retry)
    assert result['changeset']['count']==544
    assert retry.calls[0]==model.calls[3]
    assert len(retry.calls)==result['coverage']['chunks']-3


def test_real_concurrent_change_still_fails_and_retains_safe_diagnostics(client,config):
    context=seed(client,40)
    def mutate(source):
        ChangeSetService(client.app.state.database).submit({'operation_id':'external-edit','targets':[
            {'resource_type':'segment','resource_id':source['resource_id'],'expected_revision':source['revision'],
             'fields':{'text':'外部新校对'}}]})
    with pytest.raises(DomainError) as error:run(client,config,context,BatchModel(client,mutate=mutate))
    assert error.value.code=='version_conflict'
    diagnostic=WorkLog(client.app.state.database,'bounded-edit').get('failure:chunk:0:model:0')
    assert diagnostic['details']['expected_revision']+1==diagnostic['details']['actual_revision']
    assert '外部新校对' not in json.dumps(diagnostic,ensure_ascii=False)
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT count(*) FROM segments WHERE run_id='run1' AND speaker=1").fetchone()[0]==0


def test_bulk_dependency_validation_runs_outside_event_loop(client,config,monkeypatch):
    context=seed(client,80)
    evidence=client.app.state.evidence; original=evidence.valid_many; loop_thread=threading.get_ident(); checked=[]
    def check(references,changes=()):
        if references:
            checked.append(len(references)); assert threading.get_ident()!=loop_thread
        return original(references,changes)
    monkeypatch.setattr(evidence,'valid_many',check)
    assert run(client,config,context,BatchModel(client))['changeset']['count']==80
    assert checked


def test_repeated_read_does_not_duplicate_the_frozen_library(client,config):
    context=seed(client,40)
    class ReadAgain(BatchModel):
        def __init__(self,client):super().__init__(client);self.current=None;self.reads=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            if messages[-1].type=='tool':
                result=json.loads(messages[-1].content)['result'];self.reads+=1
                assert result['already_provided'] and 'sources' not in result
                return AIMessage(content=json.dumps({'answer':'本批只作分析','claims':[]}))
            self.current=json.loads(messages[-1].content)
            if 'untrusted_parts' in self.current:
                return AIMessage(content=json.dumps({'answer':'合成综合','claims':[]}))
            return AIMessage(content='',tool_calls=[{'name':'evidence__read','id':'r','args':{}}])
    context['allow_write']=False
    model=ReadAgain(client);result=run(client,config,context,model)
    assert model.reads==result['coverage']['chunks'] and result['coverage']['covered']==40


def test_request_budget_blocks_oversized_history_before_model_call(client,config):
    context=seed(client,2);context['instruction']='合成'*40000
    model=BatchModel(client)
    with pytest.raises(DomainError) as error:run(client,config,context,model)
    assert error.value.code=='model_input_too_large' and model.calls==[]


def test_editing_never_replaces_a_full_source_with_only_a_chunk():
    source={'resource_type':'segment','resource_id':'s','revision':1,'text':'合成'*10000}
    with pytest.raises(DomainError) as error:make_chunks([source],True,True)
    assert error.value.code=='source_too_large'
    chunks=make_chunks([source],True,False)
    assert ''.join(s['text'] for chunk in chunks for s in chunk)==source['text']


def test_a_batch_cannot_write_an_unread_later_batch(client,config):
    context=seed(client,80)
    last=context['sources'][-1]
    class EscapeModel(BatchModel):
        async def ainvoke(self,messages):
            return AIMessage(content=json.dumps({'answer':'不应跨批修改','claims':[], 'targets':[
                {'resource_type':'segment','resource_id':last['resource_id'],'fields':{'speaker':1}}]}))
    with pytest.raises(DomainError) as error:run(client,config,context,EscapeModel(client))
    assert error.value.code=='scope_denied'
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0]==1


def test_memory_budget_preserves_whole_records_and_prefers_user_preferences():
    memories=[{'id':str(i),'category':'analysis','content':'合成分析'*1000,'sources':[{'resource_id':'s'}]} for i in range(20)]
    preference={'id':'preference','category':'preference','content':'保留原话','sources':[{'resource_id':'user-message'}]}
    selected=bounded_memories(memories+[preference])
    assert selected==[preference]
    assert len(json.dumps(selected,ensure_ascii=False).encode())<6000
