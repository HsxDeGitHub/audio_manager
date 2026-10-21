import hashlib
import json
from interview_backend.errors import DomainError


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def require(c, table, resource_id):
    # 表名仅允许代码内固定常量，外部调用不能选择 SQL 标识符。
    if table not in {'recordings', 'runs', 'segments', 'ai_drafts', 'documents', 'memories', 'jobs', 'sessions', 'agent_runs', 'device_commands', 'changesets', 'messages'}:
        raise ValueError('不支持的资源表。')
    row = c.execute(f'SELECT * FROM {table} WHERE id=?', (resource_id,)).fetchone()
    if row is None:
        raise DomainError('not_found', '指定资料或任务不存在。', 404)
    return dict(row)


def version(c, kind, resource_id):
    row = c.execute('SELECT revision FROM object_versions WHERE resource_type=? AND resource_id=?', (kind, resource_id)).fetchone()
    return row[0] if row else 1


def bump(c, kind, resource_id):
    revision = version(c, kind, resource_id) + 1
    c.execute('INSERT INTO object_versions VALUES(?,?,?) ON CONFLICT(resource_type,resource_id) DO UPDATE SET revision=excluded.revision', (kind, resource_id, revision))
    if kind in {'recording', 'document', 'memory'}:
        table = {'recording':'recordings', 'document':'documents', 'memory':'memories'}[kind]
        c.execute(f'UPDATE {table} SET revision=? WHERE id=?', (revision, resource_id))
    c.execute('INSERT INTO index_queue VALUES(?,?,?,?) ON CONFLICT(resource_type,resource_id) DO UPDATE SET revision=excluded.revision,state=excluded.state', (kind, resource_id, revision, 'pending'))
    for row in c.execute("SELECT id,sources FROM memories WHERE state='active'").fetchall():
        if any(s.get('resource_type') == kind and s.get('resource_id') == resource_id for s in json.loads(row['sources'])):
            c.execute("UPDATE memories SET state='needs_review',revision=revision+1 WHERE id=?", (row['id'],))
    return revision


def once(c, operation_id, request, execute):
    if not isinstance(operation_id, str) or not 1 <= len(operation_id) <= 200:
        raise DomainError('operation_id_required', '需要稳定的操作标识。', 422)
    digest = hashlib.sha256(encode(request).encode()).hexdigest()
    prior = c.execute('SELECT digest,result FROM operations WHERE id=?', (operation_id,)).fetchone()
    if prior:
        if prior['digest'] != digest:
            raise DomainError('operation_mismatch', '同一操作标识不能用于不同请求。', 409)
        return json.loads(prior['result'])
    result = execute()
    c.execute('INSERT INTO operations VALUES(?,?,?)', (operation_id, digest, encode(result)))
    return result
