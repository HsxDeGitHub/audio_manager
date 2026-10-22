"""跨资料内容事务、乐观版本和整次撤销；检查点不能代替本账本。"""
import base64
from datetime import date
import json
import time
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from interview_backend.errors import DomainError
from interview_backend.services.common import require, version, bump, once, encode


class ChangeTarget(BaseModel):
    model_config = ConfigDict(extra='forbid')
    resource_type: Literal['recording', 'segment', 'draft', 'speaker', 'document', 'memory']
    resource_id: str = Field(min_length=1)
    expected_revision: int = Field(ge=1)
    fields: dict = Field(min_length=1)


class NewDocument(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    format: Literal['txt', 'md']
    content: str = Field(min_length=1)


class ChangeRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    operation_id: str = Field(min_length=1, max_length=200)
    new_documents: list[NewDocument] = Field(default_factory=list)
    targets: list[ChangeTarget] = Field(min_length=1, max_length=10000)


TABLES = {'recording': 'recordings', 'segment': 'segments', 'draft': 'ai_drafts', 'document': 'documents', 'memory': 'memories', 'message': 'messages'}


def read_object(c, kind, identifier):
    if kind == 'speaker':
        run, speaker = identifier.rsplit(':', 1)
        row = c.execute('SELECT * FROM speakers WHERE run_id=? AND speaker=?', (run, int(speaker))).fetchone()
        if row is None:
            raise DomainError('not_found', '说话人不存在。', 404)
        return dict(row)
    row = require(c, TABLES[kind], identifier)
    if isinstance(row.get('bookmark'), bytes):
        row['bookmark'] = base64.b64encode(row['bookmark']).decode()
    return row


def write_object(c, kind, identifier, row):
    if kind == 'speaker':
        c.execute('UPDATE speakers SET name=? WHERE run_id=? AND speaker=?', (row['name'], row['run_id'], row['speaker']))
        return
    table = TABLES[kind]
    row = dict(row)
    if row.get('bookmark') is not None:
        row['bookmark'] = base64.b64decode(row['bookmark'])
    # 字段来自固定数据库结构，不接受请求作为 SQL 列名。
    keys = [r[1] for r in c.execute(f'PRAGMA table_info({table})') if r[1] != 'id']
    c.execute(f'UPDATE {table} SET ' + ','.join(k + '=?' for k in keys) + ' WHERE id=?', [row[k] for k in keys] + [identifier])


def patch(kind, old, fields):
    value = dict(old)
    allowed = {'recording': {'title', 'kind', 'interview_date', 'company', 'role', 'speaker_count', 'active_run'},
               'segment': {'text', 'speaker', 'speaker_edited', 'needs_review', 'reviewed'}, 'draft': {'blocks'},
               'speaker': {'name'}, 'document': {'title', 'content', 'removed'}, 'memory': {'content', 'state'}}[kind]
    if not fields or set(fields) - allowed:
        raise DomainError('invalid_fields', '修改字段超出允许范围。', 422)
    for key, content in fields.items():
        if key in {'text', 'title', 'name', 'content'} and not isinstance(content, str):
            raise DomainError('invalid_fields', '文字字段格式不正确。', 422)
        if key in {'title', 'name'} and not content.strip():
            raise DomainError('invalid_fields', '名称不能为空。', 422)
        if key in {'speaker', 'speaker_count'} and content is not None and (type(content) is not int or content < 0):
            raise DomainError('invalid_fields', '说话人参数不正确。', 422)
        if key in {'speaker_edited', 'needs_review', 'reviewed', 'removed'} and type(content) is not bool:
            raise DomainError('invalid_fields', '状态字段格式不正确。', 422)
        if key == 'kind' and content not in {'unknown', 'interview', 'other'}:
            raise DomainError('invalid_fields', '资料类型不正确。', 422)
        if key == 'interview_date' and content is not None:
            try:
                if date.fromisoformat(content).isoformat() != content: raise ValueError()
            except (TypeError, ValueError):
                raise DomainError('invalid_date', '实际日期需为 YYYY-MM-DD。', 422) from None
        if key in {'company', 'role', 'active_run'} and content is not None and not isinstance(content, str):
            raise DomainError('invalid_fields', '资料信息格式不正确。', 422)
        if key == 'state' and content not in {'active', 'disabled', 'deleted', 'needs_review'}:
            raise DomainError('invalid_fields', '记忆状态不正确。', 422)
        if kind == 'draft':
            payload = json.loads(old['payload'])
            if not isinstance(content, dict):
                raise DomainError('invalid_fields', '整理稿修改需指定段落标识。', 422)
            blocks = {b['id']: b for chunk in payload.get('chunks', []) for b in chunk.get('blocks') or []}
            for block_id, edits in content.items():
                if block_id not in blocks or not isinstance(edits, dict) or set(edits) - {'title', 'text'} or not all(isinstance(v, str) for v in edits.values()):
                    raise DomainError('invalid_fields', '整理稿段落或字段不正确。', 422)
                blocks[block_id].update(edits)
            value['payload'] = encode(payload)
        else:
            value['edited' if kind == 'segment' and key == 'text' else key] = content
    if kind == 'segment' and 'speaker' in fields:
        value['speaker_edited'] = 1
    if kind == 'document' and 'content' in fields:
        import hashlib
        value['digest'] = hashlib.sha256(value['content'].encode()).hexdigest()
    return value


class ChangeSetService:
    def __init__(self, database):
        self.database = database

    def submit(self, request, allowed=None, plan=None):
        if plan is not None: return plan.stage(request['targets'], allowed)
        try:
            model = ChangeRequest.model_validate(request)
        except ValidationError:
            raise DomainError('invalid_request', '修改请求格式不正确。', 422) from None
        with self.database.transaction(True) as c:
            return once(c, model.operation_id, model.model_dump(exclude={'new_documents'} if not model.new_documents else set()), lambda: self._apply(c, model, allowed))

    def _apply(self, c, request, allowed):
        if any(not any(t.resource_type == 'document' and t.resource_id == d.id and t.fields.get('removed') is False for t in request.targets) for d in request.new_documents):
            raise DomainError('invalid_request', '新材料必须包含对应的可撤销导入目标。', 422)
        for document in request.new_documents:
            import hashlib
            if allowed is not None and ('document', document.id) not in allowed:
                raise DomainError('scope_denied', '导入目标未经授权。', 403)
            c.execute('INSERT INTO documents VALUES(?,?,?,?,?,?,1,1)', (document.id, document.title, document.format,
                      document.content, document.content, hashlib.sha256(document.content.encode()).hexdigest()))
        seen = set(); items = []
        for target in request.targets:
            key = (target.resource_type, target.resource_id)
            if key in seen:
                raise DomainError('duplicate_target', '同一对象需合并为一次修改。', 422)
            seen.add(key)
            if allowed is not None and key not in allowed:
                raise DomainError('scope_denied', '修改超出用户指定范围。', 403)
            old = read_object(c, *key)
            revision = version(c, *key)
            if revision != target.expected_revision:
                raise DomainError('version_conflict', '对象版本已变化，整次修改未提交。', 409)
            updated = patch(target.resource_type, old, target.fields)
            if target.resource_type == 'recording' and updated.get('active_run') and require(c, 'runs', updated['active_run'])['recording_id'] != target.resource_id:
                raise DomainError('scope_denied', '目标版本不属于该资料。', 409)
            if old == updated:
                continue
            write_object(c, *key, updated)
            after_revision = bump(c, *key)
            if target.resource_type in {'document', 'memory'}:
                c.execute(f'UPDATE {TABLES[target.resource_type]} SET revision=? WHERE id=?', (after_revision, target.resource_id))
            if target.resource_type == 'memory' and updated['state'] == 'deleted':
                for source in json.loads(updated['sources']):
                    c.execute('INSERT OR IGNORE INTO suppressions VALUES(?,?)', (updated['topic'], encode(source)))
                    c.execute('INSERT OR IGNORE INTO suppressions VALUES(?,?)', ('*', encode(source)))
            items.append({'resource_type': key[0], 'resource_id': key[1], 'before': old, 'after': read_object(c, *key),
                          'before_revision': revision, 'after_revision': after_revision})
        c.execute('INSERT INTO changesets VALUES(?,?,?,?,NULL)', (request.operation_id, 'committed', encode(items), time.time()))
        return {'id': request.operation_id, 'state': 'committed', 'count': len(items), 'items': items}

    def list(self, offset=0, limit=50):
        with self.database.transaction() as c:
            rows = c.execute('SELECT * FROM changesets ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?', (limit, offset)).fetchall()
            return {'items': [{'id': r['id'], 'state': r['state'], 'items': json.loads(r['items']), 'count': len(json.loads(r['items']))} for r in rows],
                    'total': c.execute('SELECT count(*) FROM changesets').fetchone()[0], 'offset': offset, 'limit': limit}

    def revert(self, changeset_id, operation_id):
        with self.database.transaction(True) as c:
            def execute():
                changeset = require(c, 'changesets', changeset_id)
                if changeset['state'] != 'committed':
                    raise DomainError('already_reverted', '该修改集已撤销。', 409)
                items = json.loads(changeset['items'])
                for item in items:
                    key = (item['resource_type'], item['resource_id'])
                    if version(c, *key) != item['after_revision'] or read_object(c, *key) != item['after']:
                        raise DomainError('revert_conflict', '对象存在后续修改，整次撤销未执行。', 409)
                for item in items:
                    key = (item['resource_type'], item['resource_id'])
                    write_object(c, *key, item['before']); bump(c, *key)
                c.execute("UPDATE changesets SET state='reverted',reverted_by=? WHERE id=?", (operation_id, changeset_id))
                return {'id': changeset_id, 'state': 'reverted', 'count': len(items)}
            return once(c, operation_id, {'revert': changeset_id}, execute)


class ChangePlan:
    """收集一条指令内的建议。预检使用短事务并回滚，绝不跨模型调用持锁。"""
    def __init__(self, service, operation_id, allowed):
        self.service, self.operation_id, self.allowed = service, operation_id, allowed
        self.targets = {}
        self.documents = {}
        self.preview = None

    def stage(self, targets, allowed=None):
        candidate = {key: {**value, 'fields': dict(value['fields'])} for key, value in self.targets.items()}
        try: values = [ChangeTarget.model_validate(t).model_dump() for t in targets]
        except ValidationError: raise DomainError('invalid_tool_arguments', '工具参数不合法。', 422) from None
        for target in values:
            key = (target['resource_type'], target['resource_id'])
            if (self.allowed is not None and key not in self.allowed) or (allowed is not None and key not in allowed):
                raise DomainError('scope_denied', '修改超出用户指定范围。', 403)
            prior = candidate.get(key)
            if prior:
                if prior['expected_revision'] != target['expected_revision'] or any(k in prior['fields'] and prior['fields'][k] != v for k, v in target['fields'].items()):
                    raise DomainError('ambiguous_change', '同一对象的修改建议存在矛盾，整次修改未提交。', 409)
                prior['fields'].update(target['fields'])
            else: candidate[key] = target
        request = ChangeRequest(operation_id=self.operation_id, targets=list(candidate.values()), new_documents=list(self.documents.values()))
        with self.service.database.transaction(True) as c:
            c.execute('SAVEPOINT preview_changes')
            try: preview = self.service._apply(c, request, self.allowed)
            finally:
                c.execute('ROLLBACK TO preview_changes'); c.execute('RELEASE preview_changes')
        self.targets = candidate
        self.preview = {**preview, 'state': 'planned', 'new_document_ids': list(self.documents)}
        return self.preview

    def import_document(self, title, format, content):
        import hashlib, uuid
        digest = hashlib.sha256(content.encode()).hexdigest()
        with self.service.database.transaction() as c:
            row = c.execute('SELECT * FROM documents WHERE digest=? AND removed=0', (digest,)).fetchone()
            if row: return {**dict(row), 'duplicate': True}
        identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, self.operation_id + ':' + digest))
        self.documents[identifier] = {'id': identifier, 'title': title, 'format': format, 'content': content}
        if self.allowed is not None: self.allowed = self.allowed | {('document', identifier)}
        self.stage([{'resource_type': 'document', 'resource_id': identifier, 'expected_revision': 1, 'fields': {'removed': False}}])
        return {**self.documents[identifier], 'revision': 2, 'duplicate': False, 'state': 'planned'}
