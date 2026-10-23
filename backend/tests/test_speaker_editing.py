"""发言归属校对使用合成资料；不把模型桩的分类当作真实模型准确率。"""
import asyncio
import json
import time

import pytest
from langchain_core.messages import AIMessage

from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.intent import apply
from interview_backend.errors import DomainError
from interview_backend.services.changesets import ChangeSetService


def context(client, *, segments=None, policy='semantic-v2', mode='edit'):
    value = client.app.state.evidence.freeze({'recording_id':'r1', 'segment_ids':segments or []},
        '请整理正文并纠正发言归属，自我介绍是我说的，保留文字', semantic=True)
    value['intent_policy'] = policy
    return apply(value, {'mode':mode, 'reading':'full', 'edit_target':'transcript' if mode=='edit' else 'none',
                         'import_documents':False, 'actions':[], 'constraints':['保留文字'], 'clarification':''})


def target(kind='segment', identifier='s1', fields=None, revision=1):
    return {'resource_type':kind, 'resource_id':identifier, 'expected_revision':revision,
            'fields':fields if fields is not None else {'speaker':1}}


class EditModel:
    def __init__(self, targets, mutate=None, tools=False):
        self.targets, self.mutate, self.tools = targets, mutate, tools
        self.payload = None
        self.calls = 0

    def bind_tools(self, tools): return self

    async def ainvoke(self, messages):
        self.calls += 1
        if self.calls == 1:
            self.payload = json.loads(messages[-1].content)
            if self.mutate: self.mutate()
        if self.tools and self.calls == 1:
            return AIMessage(content='', tool_calls=[{'name':'changesets__apply', 'args':{'targets':self.targets}, 'id':'speaker-fix'}])
        return AIMessage(content=json.dumps({'answer':'自我介绍归给回答者，保留原文字。', 'claims':[],
                                            'targets':[] if self.tools else self.targets}))


def execute(client, config, frozen, model, identifier='speaker-edit'):
    engine = AgentEngine(config, client.app.state.tools, client.app.state.evidence)
    return asyncio.run(engine.execute(identifier, frozen['instruction'], frozen, model=model))


def rows(client):
    with client.app.state.database.transaction() as c:
        return [dict(row) for row in c.execute('SELECT * FROM segments ORDER BY id')]


def test_v2_exposes_names_and_scoped_fields_but_old_context_stays_text_only(client):
    value = context(client, segments=['s1'])
    assert {r['resource_type'] for r in value['write_resources']} == {'segment','speaker'}
    assert value['write_field_limits'] == {'segment':['text','speaker','needs_review','reviewed'], 'speaker':['name']}
    source = value['sources'][0]
    assert (source['speaker'],source['speaker_name'],source['needs_review'],source['reviewed']) == (0,'提问者',True,False)
    assert not source['speaker_confirmed']
    assert [(s['speaker'],s['name']) for s in value['speaker_catalog']] == [(0,'提问者'),(1,'回答者')]
    assert all(s['run_id']=='run1' and s['recording_id']=='r1' and s['revision']==1 for s in value['speaker_catalog'])
    old = context(client, policy='semantic-v1', segments=['s1'])
    assert old['write_field_limits'] == {'segment':['text']}
    assert all(r['resource_type']=='segment' for r in old['write_resources'])


@pytest.mark.parametrize('tools',[False,True])
def test_local_attribution_commits_once_and_reverts_without_global_rename(client, config, tools):
    before = rows(client)
    frozen = context(client, segments=['s1'])
    model = EditModel([target()],tools=tools)
    result = execute(client,config,frozen,model)
    assert result['changeset']['count']==1
    assert '发言归属 1 处' in result['answer']
    assert model.payload['speaker_catalog']==frozen['speaker_catalog']
    assert model.payload['write_field_limits']==frozen['write_field_limits']
    item = result['changeset']['items'][0]
    assert item['speaker_names']=={'before':'提问者','after':'回答者'}
    after = rows(client)
    changed = next(s for s in after if s['id']=='s1')
    assert changed['speaker']==1 and changed['speaker_edited']==1
    for old,new in zip(before,after):
        for field in ('id','run_id','original','edited','start','end'):
            assert old[field]==new[field]
        if old['id']!='s1': assert old==new
    repeated = execute(client,config,frozen,EditModel([target()],tools=tools))
    assert repeated['changeset']['id']==result['changeset']['id'] and rows(client)==after
    with client.app.state.database.transaction() as c:
        assert [r[0] for r in c.execute("SELECT name FROM speakers WHERE run_id='run1' ORDER BY speaker")]==['提问者','回答者']
    assert client.post('/api/v1/changesets/'+result['changeset']['id']+'/revert', json={'operation_id':'undo-speaker'}).status_code==200
    assert rows(client)==before


def test_text_attribution_name_and_review_are_one_reversible_transaction(client, config):
    before = rows(client)
    targets = [target(fields={'text':'合成自我介绍','speaker':1,'needs_review':False,'reviewed':True}),
               target('speaker','run1:1',{'name':'我'})]
    result = execute(client,config,context(client),EditModel(targets))
    assert result['changeset']['count']==2
    item = next(i for i in result['changeset']['items'] if i['resource_type']=='segment')
    assert item['speaker_names']=={'before':'提问者','after':'我'}
    assert all(label in result['answer'] for label in ['发言归属 1 处','说话人名称 1 处','核对状态 1 处','正文 1 处'])
    assert client.post('/api/v1/changesets/'+result['changeset']['id']+'/revert',json={'operation_id':'undo-combined'}).status_code==200
    assert rows(client)==before
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT name FROM speakers WHERE run_id='run1' AND speaker=1").fetchone()[0]=='回答者'


@pytest.mark.parametrize('bad',[
    target(fields={'original':'禁止覆盖原稿'}), target(fields={'start':0}), target(fields={'end':500}),
    target(fields={'run_id':'run2'}), target(fields={'speaker_edited':False}),
    target(identifier='s2'), target(identifier='s3'),
    target('recording','r1',{'title':'不应更名'}), target('speaker','run2:0',{'name':'越界'}),
    target(fields={'speaker':9}), target(revision=9),
])
def test_invalid_field_scope_speaker_and_revision_never_commit_partial_changes(client,config,bad):
    before=rows(client)
    with pytest.raises(DomainError):
        execute(client,config,context(client,segments=['s1']),EditModel([target(fields={'text':'不能部分提交'}),bad]))
    assert rows(client)==before
    with client.app.state.database.transaction() as c:
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0]==0


def test_speaker_number_from_another_run_is_not_accepted(client,config):
    with client.app.state.database.transaction(True) as c:
        c.execute("INSERT INTO speakers VALUES('run2',9,'另一场的我')")
    with pytest.raises(DomainError) as error:
        execute(client,config,context(client),EditModel([target(fields={'speaker':9})]))
    assert error.value.code=='invalid_speaker'


def test_unknown_boundary_can_be_marked_pending_without_inventing_a_split(client,config):
    before=rows(client)
    result=execute(client,config,context(client),EditModel([target(fields={'needs_review':True,'reviewed':False},identifier='s2')]))
    assert '核对状态 1 处' in result['answer']
    after=rows(client)
    assert len(after)==len(before)
    for old,new in zip(before,after):
        for field in ('speaker','original','edited','start','end'):
            assert old[field]==new[field]
    assert next(s for s in after if s['id']=='s2')['needs_review']==1


def test_speaker_catalog_change_during_model_call_stops_stale_attribution(client,config):
    frozen=context(client)
    def rename():
        ChangeSetService(client.app.state.database).submit({'operation_id':'other-rename',
            'targets':[target('speaker','run1:1',{'name':'外部已修改'})]})
    with pytest.raises(DomainError) as error:
        execute(client,config,frozen,EditModel([target()],mutate=rename))
    assert error.value.code=='stale_source'
    assert next(s for s in rows(client) if s['id']=='s1')['speaker']==0


def test_readonly_still_rejects_speaker_targets(client,config):
    before=rows(client)
    with pytest.raises(DomainError):
        execute(client,config,context(client,mode='read'),EditModel([target()]))
    assert rows(client)==before


def test_new_api_message_uses_v2_and_persists_attribution(client,config):
    class Engine(AgentEngine):
        async def execute(self,run_id,instruction,context,emit=None):
            return await super().execute(run_id,instruction,context,emit=emit,model=EditModel([target()]))
    engine=Engine(config,client.app.state.tools,client.app.state.evidence)
    engine.intent_model=client.app.state.agent.engine.intent_model
    client.app.state.agent.engine=engine
    session=client.post('/api/v1/sessions',json={}).json()['id']
    body={'session_id':session,'message_id':'speaker-v2','instruction':'请整理正文并纠正说话人归属',
          'context':{'recording_id':'r1','segment_ids':['s1']}}
    response=client.post('/api/v1/agent/runs',json=body)
    assert response.status_code==200
    identifier=response.json()['id']
    for _ in range(400):
        run=client.get('/api/v1/agent/runs/'+identifier).json()
        if run['state'] not in {'queued','running'}: break
        time.sleep(.005)
    assert run['state']=='completed', run
    assert run['context']['intent_policy']=='semantic-v2'
    assert run['context']['write_field_limits']['speaker']==['name']
    assert run['result']['changeset']['items'][0]['after']['speaker']==1
