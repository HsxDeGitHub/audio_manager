"""复现纠错被身份断言卡住、口头登记未执行及重试场景，不使用个人资料。"""
import asyncio
import json

from langchain_core.messages import AIMessage
import pytest

from interview_backend.agent.graph import AgentEngine
from interview_backend.agent.work import WorkLog
from interview_backend.errors import DomainError
from interview_backend.services.changesets import ChangePlan


def correction(client):
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE segments SET original='你好，测试甲是吧？',edited=NULL WHERE id='s1'")
    instruction = '把左侧原文里的姓名改成“测试乙”'
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction)
    target = {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1,
              'fields': {'text': '你好，测试乙是吧？'}}
    claim = {'kind': 'user_statement', 'text': '用户的名字是测试乙',
             'sources': [{'resource_type': 'segment', 'resource_id': 's1', 'revision': 1}]}
    return instruction, context, target, claim


def snapshot(client):
    with client.app.state.database.transaction() as c:
        return ([dict(row) for row in c.execute('SELECT * FROM segments ORDER BY id')],
                [dict(row) for row in c.execute('SELECT * FROM speakers ORDER BY run_id,speaker')])


@pytest.mark.parametrize('tool_call', [False, True])
def test_text_correction_is_not_blocked_by_unconfirmed_identity(client, config, tool_call):
    instruction, context, target, claim = correction(client)
    before = snapshot(client)
    class Model:
        calls = 0
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            self.calls += 1
            if tool_call and self.calls == 1:
                return AIMessage(content='', tool_calls=[{'name': 'changesets__apply', 'id': 'edit', 'args': {'targets': [target]}}])
            return AIMessage(content=json.dumps({'answer': '已登记为 planned，待提交；说话人身份未确认。',
                'claims': [claim], **({} if tool_call else {'targets': [target]})}))
    model = Model()
    engine = AgentEngine(config, client.app.state.tools, client.app.state.evidence)
    result = asyncio.run(engine.execute('identity-correction', instruction, context, model=model))
    assert result['claims'] == []
    assert result['answer'] == '已更新左侧正文 1 处，可在修改记录中撤销。'
    assert result['changeset']['count'] == 1
    rows = client.get('/api/v1/transcripts/run1/segments').json()['items']
    assert next(row for row in rows if row['id'] == 's1')['text'] == target['fields']['text']
    expected = json.loads(json.dumps(before))
    expected[0][0]['edited'] = target['fields']['text']
    assert json.loads(json.dumps(snapshot(client))) == expected
    repeated = asyncio.run(engine.execute('identity-correction', instruction, context, model=model))
    assert repeated['answer'] == result['answer'] and model.calls == (2 if tool_call else 1)
    undo = client.post('/api/v1/changesets/' + result['changeset']['id'] + '/revert', json={'operation_id': 'undo-identity-correction'})
    assert undo.status_code == 200 and snapshot(client) == before


def test_identity_assertion_still_rejected_for_qa_without_an_edit(client, config):
    _, _, _, claim = correction(client)
    instruction = '分析这次对话中的身份'
    context = client.app.state.evidence.freeze({'recording_id': 'r1'}, instruction)
    class Model:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages): return AIMessage(content=json.dumps({'answer': '未经证实的身份断言', 'claims': [claim]}))
    with pytest.raises(DomainError) as error:
        asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('identity-qa', instruction, context, model=Model()))
    assert error.value.code == 'identity_unconfirmed'


@pytest.mark.parametrize('source', [
    {'resource_type': 'segment', 'resource_id': 's3', 'revision': 1},
    {'resource_type': 'segment', 'resource_id': 's1', 'revision': 99},
])
def test_edit_claim_filter_keeps_source_scope_and_version_checks(client, config, source):
    instruction, context, target, claim = correction(client)
    claim['sources'] = [source]
    before = snapshot(client)
    class Model:
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages): return AIMessage(content=json.dumps({'answer': '待提交', 'claims': [claim], 'targets': [target]}))
    with pytest.raises(DomainError) as error:
        asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('identity-bad-source', instruction, context, model=Model()))
    assert error.value.code == 'stale_source' and snapshot(client) == before


@pytest.mark.parametrize('bad_retry', [False, True])
def test_prose_only_planned_edit_is_repaired_before_reporting_success(client, config, bad_retry):
    instruction, context, target, _ = correction(client)
    before = snapshot(client)
    class Model:
        calls = 0
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            self.calls += 1
            if self.calls == 1 or (bad_retry and self.calls == 2):
                return AIMessage(content=json.dumps({'answer': '正文纠错已登记为 planned，尚未提交。', 'claims': []}))
            assert '没有返回可执行目标' in messages[-1].content
            return AIMessage(content=json.dumps({'answer': '准备修改', 'claims': [], 'targets': [target]}))
    model = Model()
    engine = AgentEngine(config, client.app.state.tools, client.app.state.evidence)
    if bad_retry:
        with pytest.raises(DomainError) as error: asyncio.run(engine.execute('repair-text', instruction, context, model=model))
        assert error.value.code == 'edit_not_applied' and snapshot(client) == before
    result = asyncio.run(engine.execute('repair-text', instruction, context, model=model))
    assert result['changeset']['count'] == 1 and result['answer'].startswith('已更新左侧正文')
    assert model.calls == (3 if bad_retry else 2)


def test_repair_with_no_matching_text_does_not_create_a_change(client, config):
    instruction, context, _, _ = correction(client)
    before = snapshot(client)
    class Model:
        calls = 0
        def bind_tools(self, tools): return self
        async def ainvoke(self, messages):
            self.calls += 1
            return AIMessage(content=json.dumps({'answer': '正文已修改' if self.calls == 1 else '未找到匹配文字，正文没有变化。',
                                                'claims': [], **({} if self.calls == 1 else {'no_match': True})}))
    result = asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('no-text-match', instruction, context, model=Model()))
    assert '没有变化' in result['answer'] and not result.get('changesets') and snapshot(client) == before


def test_old_finalization_with_misclassified_identity_can_resume_text_edit(client, config):
    instruction, context, target, claim = correction(client)
    plan = ChangePlan(client.app.state.changesets, 'old-text:changes', frozenset({('segment', 's1')}))
    plan.stage([target])
    WorkLog(client.app.state.database, 'old-text').save('finalization', {
        'result': {'answer': '待提交', 'claims': [claim]}, 'context': context, 'allowed': [['segment', 's1']],
        'request': {'operation_id': 'old-text:changes', 'targets': [target], 'new_documents': []},
        'preview': plan.preview, 'steps': []})
    result = asyncio.run(AgentEngine(config, client.app.state.tools, client.app.state.evidence).execute('old-text', instruction, context))
    assert result['claims'] == [] and result['changeset']['count'] == 1
    assert result['answer'].startswith('已更新左侧正文')
