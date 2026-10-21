import base64
import json

from sqlalchemy import select, func, text
from interview_backend import models, schemas
from interview_backend.errors import DomainError


class LibraryRepository:
    def __init__(self, database):
        self.database = database

    def _require(self, table, resource_id):
        with self.database.engine.connect() as connection:
            result = connection.execute(select(table).where(table.c.id == resource_id)).mappings().first()
        if result is None:
            raise DomainError('not_found', '指定资料或转写版本不存在。', 404)
        return dict(result)

    def _page(self, table, schema, *, condition=None, order, offset=0, limit=50, convert=None):
        statement = select(table)
        count = select(func.count()).select_from(table)
        if condition is not None:
            statement = statement.where(condition)
            count = count.where(condition)
        with self.database.engine.connect() as connection:
            total = connection.scalar(count)
            rows = connection.execute(statement.order_by(*order).offset(offset).limit(limit)).mappings().all()
        items = [schema.model_validate(convert(dict(row)) if convert else dict(row)) for row in rows]
        return schemas.Page[schema](items=items, total=total, offset=offset, limit=limit)

    @staticmethod
    def _recording(row):
        if row['bookmark'] is not None:
            row['bookmark'] = base64.b64encode(row['bookmark']).decode('ascii')
        return row

    def recordings(self, offset=0, limit=50):
        table = models.recordings
        return self._page(table, schemas.Recording, order=[table.c.created_at.desc(), table.c.id],
                          offset=offset, limit=limit, convert=self._recording)

    def recording(self, resource_id):
        return schemas.Recording.model_validate(self._recording(self._require(models.recordings, resource_id)))

    def runs(self, recording_id, offset=0, limit=50):
        self._require(models.recordings, recording_id)
        table = models.runs
        return self._page(table, schemas.TranscriptRun, condition=table.c.recording_id == recording_id,
                          order=[table.c.created_at.desc(), table.c.id], offset=offset, limit=limit)

    def segments(self, run_id, offset=0, limit=50):
        self._require(models.runs, run_id)
        table = models.segments
        def convert(row):
            row['text'] = row['edited'] if row['edited'] is not None else row['original']
            return row
        return self._page(table, schemas.Segment, condition=table.c.run_id == run_id,
                          order=[table.c.start, table.c.id], offset=offset, limit=limit, convert=convert)

    def speakers(self, run_id, offset=0, limit=50):
        self._require(models.runs, run_id)
        table = models.speakers
        return self._page(table, schemas.Speaker, condition=table.c.run_id == run_id,
                          order=[table.c.speaker], offset=offset, limit=limit)

    def drafts(self, run_id, offset=0, limit=50):
        self._require(models.runs, run_id)
        table = models.ai_drafts
        def convert(row):
            try:
                row['payload'] = json.loads(row['payload'])
                if not isinstance(row['payload'], dict):
                    raise ValueError()
            except (ValueError, TypeError):
                raise DomainError('invalid_stored_data', '整理稿存储结构无效，请检查资料备份。', 503) from None
            return row
        return self._page(table, schemas.Draft, condition=table.c.run_id == run_id,
                          order=[table.c.created_at.desc(), table.c.id], offset=offset, limit=limit, convert=convert)

    def status(self):
        import importlib.util
        with self.database.engine.connect() as connection:
            counts = {table.name: connection.scalar(select(func.count()).select_from(table)) for table in models.LEGACY_TABLES}
            origin = connection.execute(select(models.backend_imports.c.source_path)).first()
            revision = connection.scalar(text('SELECT version_num FROM alembic_version'))
        return {'schema_revision': revision, 'legacy_imported': bool(origin and origin[0] is not None),
                'counts': counts, 'capabilities': {'library_read': True, 'legacy_migration': True,
                'tool_registry': True, 'mcp': importlib.util.find_spec('mcp') is not None,
                'keyword_search': True, 'business_write': True, 'device_commands': True, 'observability': True,
                'agent': importlib.util.find_spec('langchain') is not None,
                'memory': True, 'semantic_search': __import__('interview_backend.retrieval.semantic', fromlist=['SemanticIndex']).SemanticIndex(self.database.path.parent / 'Models').status()['ready']}}
