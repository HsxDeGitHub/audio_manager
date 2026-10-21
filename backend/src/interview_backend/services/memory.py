import json
import uuid
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal
from interview_backend.errors import DomainError
from interview_backend.services.common import require, encode, version, once, bump


class MemoryCandidate(BaseModel):
    model_config = ConfigDict(extra='forbid')
    category: Literal['user_statement','preference','analysis']
    content: str = Field(min_length=1)
    topic: str = Field(min_length=1, max_length=200)
    scope: str = 'global'
    sources: list[dict] = Field(min_length=1)
    supersedes: str | None = None


def canonical(source):
    return {key: source[key] for key in ('resource_type','resource_id','revision')}


class MemoryService:
    def __init__(self, database, evidence): self.database, self.evidence = database, evidence

    def add(self, candidate, operation_id):
        item = MemoryCandidate.model_validate(candidate)
        item.sources = [canonical(s) for s in item.sources]
        if item.category in {'user_statement','preference'} and any(s['resource_type'] != 'message' for s in item.sources):
            raise DomainError('identity_unconfirmed', '个人陈述或偏好只能来自用户消息，自动聚类不代表本人。', 422)
        if not all(self.evidence.valid(s) for s in item.sources):
            raise DomainError('invalid_source', '记忆来源已失效。', 409)
        with self.database.transaction(True) as c:
            if item.category in {'user_statement','preference'} and any(require(c, 'messages', source['resource_id'])['role'] != 'user' for source in item.sources):
                raise DomainError('identity_unconfirmed', '助手建议不能保存成用户陈述。', 422)
            def execute():
                if any(c.execute('SELECT 1 FROM suppressions WHERE topic IN (?,?) AND source=?', (item.topic,'*',encode(s))).fetchone() for s in item.sources):
                    return {'suppressed': True}
                existing = c.execute("SELECT * FROM memories WHERE topic=? AND scope=? AND state='active'", (item.topic,item.scope)).fetchall()
                same = next((r for r in existing if r['content'] == item.content and r['category'] == item.category), None)
                if same: return self._decode(same)
                state = 'active'
                if item.supersedes:
                    old = require(c, 'memories', item.supersedes)
                    if old['topic'] != item.topic or old['scope'] != item.scope:
                        raise DomainError('memory_scope_conflict', '纠正记忆的主题或范围不一致。', 409)
                    c.execute("UPDATE memories SET state='superseded' WHERE id=?", (item.supersedes,))
                    bump(c, 'memory', item.supersedes)
                elif existing:
                    state = 'needs_review'
                    for prior in existing:
                        c.execute("UPDATE memories SET state='needs_review' WHERE id=?", (prior['id'],))
                        bump(c, 'memory', prior['id'])
                identifier = str(uuid.uuid4())
                c.execute('INSERT INTO memories VALUES(?,?,?,?,?,?,?,?,1)', (identifier,item.category,item.content,item.scope,encode(item.sources),item.topic,state,item.supersedes))
                return self._decode(require(c, 'memories', identifier))
            return once(c, operation_id, item.model_dump(), execute)

    @staticmethod
    def _decode(row):
        row = dict(row); row['sources'] = json.loads(row['sources']); return row

    def list(self):
        with self.database.transaction() as c:
            return {'items': [self._decode(r) for r in c.execute('SELECT * FROM memories ORDER BY rowid DESC')]}

    def active(self, scopes=('global',)):
        items = self.list()['items']
        return [r for r in items if r['state'] == 'active' and r['scope'] in scopes and all(self.evidence.valid(s) for s in r['sources'])]

    def update(self, identifier, fields, expected_revision, operation_id):
        from interview_backend.services.changesets import ChangeSetService
        return ChangeSetService(self.database).submit({'operation_id': operation_id, 'targets': [{'resource_type':'memory','resource_id':identifier,'expected_revision':expected_revision,'fields':fields}]})
