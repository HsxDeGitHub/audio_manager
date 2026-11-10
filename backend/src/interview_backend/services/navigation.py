"""导航仅定位既有句子，所有用户修改进入统一可撤销事务。"""
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field
from interview_backend.errors import DomainError
from interview_backend.services.common import require, version, once
from interview_backend.services.changesets import ChangeRequest, ChangeSetService


class NavigationMark(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(min_length=1, max_length=200)
    segment_id: str = Field(min_length=1)
    expected_revision: int = Field(ge=1)
    kind: Literal['chapter', 'bookmark', 'later']
    title: str = Field(min_length=1, max_length=200)


class NavigationCreate(BaseModel):
    model_config = ConfigDict(extra='forbid')
    operation_id: str = Field(min_length=1, max_length=200)
    marks: list[NavigationMark] = Field(min_length=1, max_length=200)


class NavigationService:
    def __init__(self, database):
        self.database = database

    def list(self, recording_id, run_id=None):
        with self.database.transaction() as c:
            recording = require(c, 'recordings', recording_id)
            selected_run = run_id or recording['active_run']
            if not selected_run:
                return {'items': []}
            if require(c, 'runs', selected_run)['recording_id'] != recording_id:
                raise DomainError('scope_denied', '转写版本不属于当前录音。', 409)
            rows = c.execute('''SELECT n.*,s.start,s.end FROM navigation_marks n
                JOIN segments s ON s.id=n.segment_id WHERE n.run_id=? AND n.removed=0
                ORDER BY s.start,n.kind,n.id''', (selected_run,))
            return {'items': [{**dict(row), 'revision': version(c, 'navigation', row['id'])} for row in rows]}

    def create(self, recording_id, request: NavigationCreate):
        with self.database.transaction(True) as c:
            def execute():
                recording = require(c, 'recordings', recording_id)
                targets = []
                for mark in request.marks:
                    if not mark.title.strip():
                        raise DomainError('invalid_fields', '导航标题不能为空。', 422)
                    segment = require(c, 'segments', mark.segment_id)
                    if segment['run_id'] != recording['active_run']:
                        raise DomainError('stale_source', '引用不是当前转写版本，请重新选择位置。', 409)
                    if version(c, 'segment', mark.segment_id) != mark.expected_revision:
                        raise DomainError('stale_source', '引用文字已经变化，请重新生成章节。', 409)
                    if c.execute('SELECT 1 FROM navigation_marks WHERE id=?', (mark.id,)).fetchone():
                        raise DomainError('duplicate_target', '导航标识已经存在。', 409)
                    c.execute('INSERT INTO navigation_marks VALUES(?,?,?,?,?,1)',
                              (mark.id, segment['run_id'], mark.segment_id, mark.kind, mark.title.strip()))
                    targets.append({'resource_type': 'navigation', 'resource_id': mark.id,
                                    'expected_revision': 1, 'fields': {'removed': False}})
                model = ChangeRequest(operation_id=request.operation_id, targets=targets)
                return ChangeSetService(self.database)._apply(c, model, None)
            return once(c, request.operation_id, {'recording_id': recording_id, **request.model_dump()}, execute)

    def update(self, identifier, fields, revision, operation_id):
        return ChangeSetService(self.database).submit({'operation_id': operation_id, 'targets': [
            {'resource_type': 'navigation', 'resource_id': identifier,
             'expected_revision': revision, 'fields': fields}]})
