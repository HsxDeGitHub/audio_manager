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


class ChangeRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    operation_id: str = Field(min_length=1, max_length=200)
    targets: list[ChangeTarget] = Field(min_length=1, max_length=10000)


TABLES = {'recording': 'recordings', 'segment': 'segments', 'draft': 'ai_drafts', 'document': 'documents', 'memory': 'memories'}


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

    def submit(self, request, allowed=None):
        try:
            model = ChangeRequest.model_validate(request)
        except ValidationError:
            raise DomainError('invalid_request', '修改请求格式不正确。', 422) from None
        with self.database.transaction(True) as c:
            return once(c, model.operation_id, model.model_dump(), lambda: self._apply(c, model, allowed))

    def _apply(self, c, request, allowed):
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
            items.append({'resource_type': key[0], 'resource_id': key[1], 'before': old, 'after': read_object(c, *key),
                          'before_revision': revision, 'after_revision': after_revision})
        c.execute('INSERT INTO changesets VALUES(?,?,?,?,NULL)', (request.operation_id, 'committed', encode(items), time.time()))
        return {'id': request.operation_id, 'state': 'committed', 'count': len(items), 'items': items}

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
