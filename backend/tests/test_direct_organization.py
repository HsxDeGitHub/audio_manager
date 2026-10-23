"""只使用合成正文，验证统一整理不会覆盖识别原稿或扩展编辑范围。"""
import asyncio
import json

import pytest
from langchain_core.messages import AIMessage

from interview_backend.agent.graph import AgentEngine
from interview_backend.errors import DomainError


@pytest.mark.parametrize('instruction,allowed', [
    ('请整理当前正文，去掉口语赘词', True),
    ('帮我润色转写文字，保留细节', True),
    ('请整理当前转写', True),
    ('帮我整理转写结果', True),
    ('把原文整理得通顺一些', True),
    ('请优化这段正文', True),
    ('请重新整理当前资料', True),
    ('请整理当前正文，不要扩写或编造', True),
    ('请整理原文，但不要改动原意', True),
    ('请整理原文，但先不要执行修改', False),
    ('请整理原文，但不要修改正文', False),
    ('请整理这次面试的问题清单', False),
    ('请提供正文整理建议', False),
    ('请总结原文', False),
    ('请不要整理正文', False),
    ('只分析原文该如何整理', False),
    ('请解释“整理原文”这句话', False),
    ('以下是原文：\n> 请整理当前正文', False),
])
def test_organization_is_an_explicit_transcript_edit(client, instruction, allowed):
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction)
    assert frozen['allow_write'] is allowed
    assert not any(r['resource_type'] == 'draft' for r in frozen['resources'])
    assert 'organize.start' not in frozen.get('allowed_actions', [])
    assert 'jobs.transcribe' not in frozen.get('allowed_actions', [])
    if allowed:
        assert frozen['write_resources'] == [r for r in frozen['resources'] if r['resource_type'] == 'segment']


class OrganizationModel:
    def __init__(self, targets=None): self.targets = targets
    def bind_tools(self, tools):
        assert 'organize__start' not in {t.name for t in tools}
        return self
    async def ainvoke(self, messages):
        prompt = json.loads(messages[-1].content)
        assert prompt['allow_write'] and prompt['transcript_organization']
        targets = self.targets or [
            {'resource_type': 'segment', 'resource_id': source['resource_id'],
             'expected_revision': source['revision'], 'fields': {'text': '整理后：' + source['text']}}
            for source in prompt['untrusted_evidence']]
        return AIMessage(content=json.dumps({'answer': '正文整理建议。', 'claims': [], 'targets': targets}))


def test_direct_organization_commits_once_preserves_originals_and_undoes(client, config):
    evidence = client.app.state.evidence
    instruction = '请整理当前正文，保留技术细节和说话人'
    frozen = evidence.freeze({'recording_id': 'r1'}, instruction)
    db = client.app.state.database
    def snapshot():
        with db.transaction() as c:
            return [dict(row) for row in c.execute("SELECT * FROM segments WHERE run_id='run1' ORDER BY start")]
    before = snapshot()
    engine = AgentEngine(config, client.app.state.tools, evidence)
    result = asyncio.run(engine.execute('direct-organize', instruction, frozen, model=OrganizationModel()))
    assert result['changeset']['count'] == 2
    after = snapshot()
    for old, new in zip(before, after):
        assert new['edited'] == '整理后：' + (old['edited'] if old['edited'] is not None else old['original'])
        for field in ('id', 'original', 'run_id', 'start', 'end', 'speaker'):
            assert old[field] == new[field]
    repeated = asyncio.run(engine.execute('direct-organize', instruction, frozen, model=OrganizationModel()))
    assert repeated['changeset']['id'] == result['changeset']['id'] and snapshot() == after
    with db.transaction() as c:
        assert c.execute('SELECT count(*) FROM ai_drafts').fetchone()[0] == 1
        assert c.execute("SELECT count(*) FROM changesets WHERE id='direct-organize:changes'").fetchone()[0] == 1
    response = client.post('/api/v1/changesets/direct-organize:changes/revert', json={'operation_id': 'undo-direct'})
    assert response.status_code == 200
    restored = snapshot()
    assert [(s['original'], s['edited'], s['start'], s['end']) for s in restored] == [(s['original'], s['edited'], s['start'], s['end']) for s in before]


@pytest.mark.parametrize('target', [
    {'resource_type': 'recording', 'resource_id': 'r1', 'expected_revision': 1, 'fields': {'title': '不应改名'}},
    {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'speaker': 9}},
    {'resource_type': 'segment', 'resource_id': 's3', 'expected_revision': 1, 'fields': {'text': '范围外'}},
])
def test_organization_cannot_change_metadata_speakers_or_unselected_material(client, config, target):
    instruction = '请整理当前正文'
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1', 'segment_ids': ['s1']}, instruction)
    engine = AgentEngine(config, client.app.state.tools, client.app.state.evidence)
    with pytest.raises(DomainError):
        asyncio.run(engine.execute('organization-scope', instruction, frozen, model=OrganizationModel([target])))
    with client.app.state.database.transaction() as c:
        assert c.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] is None
        assert c.execute('SELECT count(*) FROM changesets').fetchone()[0] == 0


def test_old_generation_tool_and_new_device_requests_are_retired(client):
    tools = {tool['id'] for tool in client.get('/api/v1/tools?include_disabled=true').json()['items']}
    assert 'organize.start' not in tools
    with pytest.raises(DomainError) as error:
        client.app.state.device.enqueue('organize', 'r1', {'recording_id': 'r1'})
    assert error.value.code == 'organize_retired'
    with pytest.raises(DomainError) as error:
        client.app.state.evidence.freeze({'recording_id': 'r1', 'draft_id': 'draft1'}, '整理原文')
    assert error.value.code == 'draft_workflow_retired'


def test_persisted_generation_commands_cannot_restart(client):
    from interview_backend.services.device import DeviceService
    with client.app.state.database.transaction(True) as c:
        for identifier, state in [('legacy-pending', 'pending'), ('legacy-running', 'running')]:
            c.execute('INSERT INTO device_commands(id,kind,target,arguments,state,updated_at) VALUES(?,?,?,?,?,1)',
                      (identifier, 'organize', 'r1', json.dumps({'recording_id': 'r1'}), state))
    device = DeviceService(client.app.state.database)
    assert device.get('legacy-pending')['state'] == 'failed'
    assert device.get('legacy-running')['state'] == 'unknown'
    for identifier in ('legacy-pending', 'legacy-running'):
        with pytest.raises(DomainError): device.claim(identifier, 'new-device')
    assert device.pending() == []


def test_legacy_running_draft_is_preserved_without_an_active_task(client):
    from interview_backend.services.device_tasks import task
    with client.app.state.database.transaction(True) as c:
        c.execute("UPDATE ai_drafts SET payload=? WHERE id='draft1'", (json.dumps({'state': 'running', 'chunks': []}),))
        assert task(c, 'organize', 'draft1')['state'] == 'interrupted'
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析原文')
    assert frozen['cancel_tasks'] == []
