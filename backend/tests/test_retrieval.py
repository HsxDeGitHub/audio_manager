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
