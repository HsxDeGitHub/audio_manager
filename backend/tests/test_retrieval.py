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
