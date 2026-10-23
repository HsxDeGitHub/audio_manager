import pytest
from interview_backend.services.documents import DocumentService
from interview_backend.retrieval.index import RetrievalIndex
from interview_backend.retrieval.semantic import SemanticIndex


def test_import_duplicate_current_revision_and_removal(client, config):
    documents = DocumentService(client.app.state.database)
    first = documents.import_text('项目说明','md','我使用 Redis 与 Go 实现事务。','doc-1')
    assert documents.import_text('重复说明','md','我使用 Redis 与 Go 实现事务。','doc-2')['id'] == first['id']
    index = RetrievalIndex(client.app.state.database, config.backend_dir)
    assert index.search('事务')[0]['resource_id'] == first['id']
    documents.update(first['id'], {'content':'改用 MongoDB 存储。'}, 1, 'doc-edit')
    assert all(r['resource_id'] != first['id'] for r in index.search('Redis'))
    assert index.search('MongoDB')[0]['revision'] == 2
    documents.update(first['id'], {'removed':True}, 2, 'doc-remove')
    assert not any(r['resource_id'] == first['id'] for r in index.search('MongoDB'))


def test_short_chinese_technical_abbreviations_and_semantic_not_ready(client, config):
    documents = DocumentService(client.app.state.database)
    documents.import_text('缩写','txt','GMP 调度器使用 Go，索引采用 FTS5。','abbreviations')
    index = RetrievalIndex(client.app.state.database, config.backend_dir)
    assert index.search('GMP') and index.search('调度') and index.search('FTS5')
    semantic = SemanticIndex(config.backend_dir / 'Models')
    assert not semantic.status()['ready']
    assert not (config.backend_dir / 'Models').exists()
    assert index.search('Go')


def test_document_ui_and_agent_share_import_versions_removal_and_line_sources(client):
    import asyncio
    from interview_backend.tools.registry import ToolContext
    registry = client.app.state.tools
    write = ToolContext(request_id='doc-tool', operation_id='doc-import', allowed_effects=frozenset({'write'}),
                        frozen_context={'allow_document_import': True, 'resources': []})
    imported = asyncio.run(registry.execute('documents.import', {'title': '项目', 'format': 'md', 'content': '# 项目\n第二行 Redis\n第三行'}, write))['data']['result']
    duplicate = client.post('/api/v1/documents', json={'title': '重复', 'format': 'txt', 'content': '# 项目\n第二行 Redis\n第三行', 'operation_id': 'api-import'}).json()
    assert duplicate['duplicate'] and duplicate['id'] == imported['id']
    identifier = imported['id']
    assert client.get('/api/v1/documents/' + identifier).json()['content'] == '# 项目\n第二行 Redis\n第三行'
    source = client.get(f'/api/v1/sources/document/{identifier}?revision=1&line=2').json()
    assert source['line'] == 2 and source['line_text'] == '第二行 Redis'
    assert client.get(f'/api/v1/sources/document/{identifier}?revision=1&line=4').status_code == 422
    frozen = client.app.state.evidence.freeze({'document_ids': [identifier]}, '请修改材料')
    from dataclasses import replace
    context = replace(write, operation_id='doc-edit', resource_scope=frozenset({('document', identifier)}), frozen_context=frozen)
    changed = asyncio.run(registry.execute('documents.update', {'document_id': identifier, 'expected_revision': 1, 'fields': {'content': '新内容'}}, context))
    assert changed['data']['result']['count'] == 1
    assert client.get(f'/api/v1/sources/document/{identifier}?revision=1&line=2').status_code == 409
    assert client.patch('/api/v1/documents/' + identifier, json={'operation_id': 'doc-remove', 'expected_revision': 2, 'fields': {'removed': True}}).status_code == 200
    assert client.get('/api/v1/documents/' + identifier).status_code == 404
    assert not client.get('/api/v1/documents').json()['items']


def test_agent_document_update_cannot_escape_scope(client):
    import asyncio
    from interview_backend.errors import DomainError
    from interview_backend.tools.registry import ToolContext
    doc = client.app.state.documents.import_text('材料', 'txt', '合成文本', 'doc-private')
    context = ToolContext(request_id='deny', operation_id='deny-doc', allowed_effects=frozenset({'write'}),
                          resource_scope=frozenset(), frozen_context={'resources': []})
    with pytest.raises(DomainError) as error:
        asyncio.run(client.app.state.tools.execute('documents.update', {'document_id': doc['id'], 'expected_revision': 1,
                    'fields': {'removed': True}}, context))
    assert error.value.code == 'scope_denied'
    assert client.get('/api/v1/documents/' + doc['id']).status_code == 200


def test_draft_source_hash_tracks_text_speakers_and_exits_search(client, config):
    import json
    from interview_backend.services.draft_sources import source_fingerprint
    db = client.app.state.database
    with db.transaction(True) as c:
        fingerprint = source_fingerprint(c, 'run1')
        # 由 Foundation JSONEncoder(.sortedKeys) + CryptoKit 生成的合成快照金标准。
        assert fingerprint == '90e4c9db2e7cfe64836c621a7f5e351405329f9c110266ed8af810e761f99ca4'
        payload = {'sourceHash': fingerprint, 'chunks': [{'blocks': [{'id': 'b1', 'text': '整理稿独有术语', 'sourceIDs': ['s1']}]}]}
        c.execute("UPDATE ai_drafts SET payload=? WHERE id='draft1'", (json.dumps(payload),))
    index = RetrievalIndex(db, config.backend_dir)
    assert any(r['resource_type'] == 'draft' for r in index.search('独有术语'))
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析原文')
    assert not any(s['resource_type'] == 'draft' for s in frozen['sources'])
    assert client.app.state.evidence.valid({'resource_type': 'draft', 'resource_id': 'draft1', 'revision': 1})
    client.app.state.changesets.submit({'operation_id': 'change-draft-origin', 'targets': [
        {'resource_type': 'segment', 'resource_id': 's1', 'expected_revision': 1, 'fields': {'text': '原文变化'}}]})
    assert not client.app.state.evidence.valid({'resource_type': 'draft', 'resource_id': 'draft1', 'revision': 1})
    assert not any(r['resource_type'] == 'draft' for r in index.search('独有术语'))
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析原文')
    assert not any(s['resource_type'] == 'draft' for s in frozen['sources'])
    assert not any(r['resource_type'] == 'draft' for r in frozen['resources'])
    with db.transaction(True) as c:
        payload['sourceHash'] = source_fingerprint(c, 'run1')
        c.execute("UPDATE ai_drafts SET payload=? WHERE id='draft1'", (json.dumps(payload),))
    assert any(r['resource_type'] == 'draft' for r in index.search('独有术语'))
    client.app.state.changesets.submit({'operation_id': 'change-draft-speaker', 'targets': [
        {'resource_type': 'speaker', 'resource_id': 'run1:0', 'expected_revision': 1, 'fields': {'name': '新说话人'}}]})
    assert not any(r['resource_type'] == 'draft' for r in index.search('独有术语'))


def test_draft_without_source_hash_is_excluded(client):
    assert not client.app.state.evidence.valid({'resource_type': 'draft', 'resource_id': 'draft1', 'revision': 1})
    frozen = client.app.state.evidence.freeze({'recording_id': 'r1'}, '分析原文')
    assert not any(r['resource_type'] == 'draft' for r in frozen['resources'])


def test_draft_hash_matches_swift_unicode_slash_decimal_snapshot(client):
    from interview_backend.services.draft_sources import source_fingerprint
    with client.app.state.database.transaction(True) as c:
        c.execute("DELETE FROM segments WHERE run_id='run1'")
        c.execute("DELETE FROM speakers WHERE run_id='run1'")
        c.execute('INSERT INTO segments(id,run_id,start,end,original,speaker) VALUES(?,?,?,?,?,?)',
                  ('a/中', 'run1', 0.01, 100.125, '路径/a\n🙂', 0))
        assert source_fingerprint(c, 'run1') == 'cb13329a87c1fc00aacf3dd56bbb3f0ecd4618f45d02983116b4f41039249d25'


def test_explicit_preparation_reports_progress_failure_and_keyword_fallback(client, monkeypatch):
    import sys
    import threading
    from types import SimpleNamespace
    from concurrent.futures import ThreadPoolExecutor
    started, release = threading.Event(), threading.Event()
    def failing_model(**kwargs):
        started.set()
        assert release.wait(5)
        raise ValueError('synthetic preparation failure')
    monkeypatch.setitem(sys.modules, 'fastembed', SimpleNamespace(TextEmbedding=failing_model))
    monkeypatch.setitem(sys.modules, 'tokenizers', SimpleNamespace(Tokenizer=object))
    initial = client.get('/api/v1/retrieval/status').json()
    assert initial['state'] == 'unprepared' and initial['keyword_fallback']
    with ThreadPoolExecutor(1) as pool:
        pending = pool.submit(client.post, '/api/v1/retrieval/prepare')
        try:
            assert started.wait(3)
            progress = client.get('/api/v1/retrieval/status').json()
            assert progress['state'] == 'preparing' and not progress['ready']
        finally: release.set()
        assert pending.result().status_code == 503
    failed = client.get('/api/v1/retrieval/status').json()
    assert failed['state'] == 'failed' and failed['error']['code'] == 'semantic_prepare_failed'
    client.app.state.documents.import_text('回退材料', 'txt', '关键词回退仍能查找 Redis', 'fallback')
    response = client.get('/api/v1/retrieval/search?q=Redis').json()
    assert response['items'] and response['semantic']['keyword_fallback']


@pytest.mark.parametrize('kind,identifier,fields', [
    ('segment','s1',{'text':'原文发生变化'}), ('speaker','run1:0',{'name':'新名称'}),
])
def test_indirect_draft_memory_dependency_exits_injection_search_and_references(client, config, kind, identifier, fields):
    import json
    from interview_backend.services.memory import MemoryService
    from interview_backend.services.draft_sources import source_fingerprint
    db=client.app.state.database; evidence=client.app.state.evidence
    with db.transaction(True) as c:
        c.execute("UPDATE ai_drafts SET payload=? WHERE id='draft1'",(json.dumps({'sourceHash':source_fingerprint(c,'run1'),'chunks':[{'blocks':[{'id':'b','text':'依赖稿件记忆','sourceIDs':['s1']}]}]}),))
    service=MemoryService(db,evidence)
    first=service.add({'category':'analysis','content':'派生独有记忆','topic':'依赖','scope':'global','sources':[{'resource_type':'draft','resource_id':'draft1','revision':1}]},'derived-memory')
    second=service.add({'category':'analysis','content':'间接独有记忆','topic':'间接','scope':'global','sources':[{'resource_type':'memory','resource_id':first['id'],'revision':1}]},'indirect-memory')
    index=RetrievalIndex(db,config.backend_dir)
    assert any(r['resource_type']=='memory' for r in index.search('独有记忆'))
    client.app.state.changesets.submit({'operation_id':'dependency-change','targets':[{'resource_type':kind,'resource_id':identifier,'expected_revision':1,'fields':fields}]})
    for item in [first,second]: assert not evidence.valid({'resource_type':'memory','resource_id':item['id'],'revision':1})
    assert service.active()==[]
    assert not any(r['resource_type']=='memory' for r in index.search('独有记忆'))


def test_legacy_active_memory_with_stale_draft_and_cycles_is_rejected_consistently(client,config):
    import json
    from interview_backend.services.memory import MemoryService
    db=client.app.state.database; evidence=client.app.state.evidence
    with db.transaction(True) as c:
        c.execute("INSERT INTO memories VALUES('legacy','analysis','失效独有记忆','global',?,'旧版','active',NULL,1)",(json.dumps([{'resource_type':'draft','resource_id':'draft1','revision':1}]),))
        c.execute("INSERT INTO memories VALUES('cycle','analysis','循环独有记忆','global',?,'循环','active',NULL,1)",(json.dumps([{'resource_type':'memory','resource_id':'cycle','revision':1}]),))
    for identifier in ['legacy','cycle']:
        assert not evidence.valid({'resource_type':'memory','resource_id':identifier,'revision':1})
    assert MemoryService(db,evidence).active()==[]
    assert not any(r['resource_type']=='memory' for r in RetrievalIndex(db,config.backend_dir).search('独有记忆'))
