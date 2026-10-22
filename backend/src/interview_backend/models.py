"""保留旧表结构；新增列通过 Alembic 显式补齐。"""
from sqlalchemy import (MetaData, Table, Column, String, Text, Integer, Float, LargeBinary, ForeignKey, Index)

metadata = MetaData()
recordings = Table('recordings', metadata,
    Column('id', String, primary_key=True), Column('title', Text, nullable=False),
    Column('path', Text, nullable=False), Column('bookmark', LargeBinary),
    Column('fingerprint', Text, nullable=False), Column('duration', Float, nullable=False),
    Column('created_at', Float, nullable=False), Column('state', String, nullable=False),
    Column('error', Text), Column('speaker_count', Integer), Column('play_position', Float, nullable=False),
    Column('active_run', String), Column('kind', String, nullable=False, server_default='unknown'),
    Column('interview_date', String), Column('company', Text), Column('role', Text),
    Column('revision', Integer, nullable=False, server_default='1'))
runs = Table('runs', metadata,
    Column('id', String, primary_key=True),
    Column('recording_id', String, ForeignKey('recordings.id', ondelete='CASCADE'), nullable=False),
    Column('created_at', Float, nullable=False))
segments = Table('segments', metadata,
    Column('id', String, primary_key=True),
    Column('run_id', String, ForeignKey('runs.id', ondelete='CASCADE'), nullable=False),
    Column('start', Float, nullable=False), Column('end', Float, nullable=False),
    Column('original', Text, nullable=False), Column('edited', Text), Column('speaker', Integer),
    Column('speaker_edited', Integer, nullable=False, server_default='0'),
    Column('needs_review', Integer, nullable=False, server_default='0'),
    Column('reviewed', Integer, nullable=False, server_default='0'))
Index('segments_run_time', segments.c.run_id, segments.c.start)
speakers = Table('speakers', metadata,
    Column('run_id', String, ForeignKey('runs.id', ondelete='CASCADE'), primary_key=True),
    Column('speaker', Integer, primary_key=True), Column('name', Text, nullable=False))
edit_history = Table('edit_history', metadata,
    Column('id', Integer, primary_key=True, autoincrement=True),
    Column('run_id', String, ForeignKey('runs.id', ondelete='CASCADE'), nullable=False),
    Column('label', Text, nullable=False), Column('before_json', Text, nullable=False),
    Column('after_json', Text, nullable=False), Column('applied', Integer, nullable=False, server_default='1'))
reading_cache = Table('reading_cache', metadata,
    Column('run_id', String, ForeignKey('runs.id', ondelete='CASCADE'), primary_key=True),
    Column('cache_key', String, primary_key=True), Column('rendered', Text, nullable=False))
ai_drafts = Table('ai_drafts', metadata,
    Column('id', String, primary_key=True),
    Column('run_id', String, ForeignKey('runs.id', ondelete='CASCADE'), nullable=False),
    Column('created_at', Float, nullable=False), Column('payload', Text, nullable=False))
backend_imports = Table('backend_imports', metadata,
    Column('id', Integer, primary_key=True), Column('source_path', Text), Column('source_version', Integer),
    Column('created_at', Float, nullable=False), Column('counts_json', Text, nullable=False))

LEGACY_TABLES = (recordings, runs, segments, speakers, edit_history, reading_cache, ai_drafts)
SCHEMA_REVISION = '0004_agent_work'
