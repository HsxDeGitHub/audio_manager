"""只读复制旧库，在临时副本验证后原子发布；不切换正式 Swift 应用。"""
import fcntl
import hashlib
import json
import os
import sqlite3
import time
import uuid
from contextlib import closing, contextmanager
from dataclasses import dataclass
from pathlib import Path
from alembic.util.exc import CommandError
from sqlalchemy.exc import SQLAlchemyError

from interview_backend.config import Settings
from interview_backend.database import upgrade_database
from interview_backend.errors import DomainError
from interview_backend.models import LEGACY_TABLES, SCHEMA_REVISION


@dataclass(frozen=True)
class ImportReport:
    legacy_imported: bool
    reused: bool
    counts: dict[str, int]


def _quote(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def _read_only(path: Path):
    return sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=5)


def _counts(connection) -> dict[str, int]:
    names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    return {table.name: connection.execute(f'SELECT count(*) FROM {_quote(table.name)}').fetchone()[0]
            for table in LEGACY_TABLES if table.name in names}


def _projections(connection) -> dict[str, tuple[list[str], str]]:
    result = {}
    for table in _counts(connection):
        columns = [row[1] for row in connection.execute(f'PRAGMA table_info({_quote(table)})')]
        result[table] = (columns, _content_hash(connection, table, columns))
    return result


def _validate_legacy_schema(projections):
    if not {'recordings', 'runs', 'segments', 'speakers'} <= projections.keys():
        raise DomainError('invalid_database', '来源不是受支持的听阅资料库。')
    added = {'recordings': {'kind', 'interview_date', 'company', 'role', 'revision'},
             'segments': {'reviewed'}}
    for table in LEGACY_TABLES:
        if table.name in projections:
            required = set(table.c.keys()) - added.get(table.name, set())
            if not required <= set(projections[table.name][0]):
                raise DomainError('invalid_database', '来源资料库结构不完整，迁移已停止。')


def _content_hash(connection, table, columns) -> str:
    digest = hashlib.sha256()
    fields = ','.join(_quote(column) for column in columns)
    for row in connection.execute(f'SELECT {fields} FROM {_quote(table)} ORDER BY rowid'):
        data = [({'blob': value.hex()} if isinstance(value, bytes) else value) for value in row]
        digest.update(json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode())
        digest.update(b'\n')
    return digest.hexdigest()


@contextmanager
def _initialization_lock(settings):
    settings.backend_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(settings.backend_dir / '.bootstrap.lock', os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def _validate(connection):
    if connection.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise DomainError('invalid_database', '资料库完整性校验失败。')
    if connection.execute('PRAGMA foreign_key_check').fetchone() is not None:
        raise DomainError('invalid_database', '资料库包含无效的关联，未发布迁移结果。')


def _existing_report(path, explicit_source):
    with closing(_read_only(path)) as check:
        old = check.execute('SELECT version_num FROM alembic_version').fetchone()
    if old and old[0] == '0001_backend_baseline':
        upgrade_database(path)
    with closing(_read_only(path)) as connection:
        revision = connection.execute('SELECT version_num FROM alembic_version').fetchone()
        if not revision or revision[0] not in {'0001_backend_baseline', SCHEMA_REVISION}:
            raise DomainError('unsupported_schema', '目标资料库版本不受当前后端支持。', 409)
        origin = connection.execute('SELECT source_path FROM backend_imports WHERE id=1').fetchone()
        if not origin:
            raise DomainError('invalid_database', '目标资料库缺少完整初始化记录。', 409)
        if explicit_source is not None and origin[0] != str(explicit_source):
            raise DomainError('target_exists', '目标资料库已经存在，不能用其他来源覆盖。', 409)
        _validate(connection)
        return ImportReport(origin[0] is not None, True, _counts(connection))


def initialize_database(settings: Settings, source: Path | None = None) -> ImportReport:
    explicit_source = Path(source).expanduser().resolve() if source is not None else None
    destination = settings.database_path
    if explicit_source == destination.resolve():
        raise DomainError('same_database', '迁移来源和目标不能是同一个资料库。')
    try:
        with _initialization_lock(settings):
            if destination.exists():
                return _existing_report(destination, explicit_source)
            selected_source = explicit_source or (settings.legacy_path if settings.legacy_path.is_file() else None)
            if selected_source is not None and not selected_source.is_file():
                raise DomainError('source_missing', '迁移来源不存在或不是文件。')
            staging = destination.with_name(destination.name + '.import-' + uuid.uuid4().hex)
            staging.touch(mode=0o600, exist_ok=False)
            try:
                source_version = None
                if selected_source is not None:
                    selected_source = selected_source.resolve()
                    with closing(_read_only(selected_source)) as original, closing(sqlite3.connect(staging)) as snapshot:
                        source_version = original.execute('PRAGMA user_version').fetchone()[0]
                        if source_version > 3:
                            raise DomainError('unsupported_schema', '旧库版本高于当前支持范围，迁移已停止。', 409)
                        started = time.monotonic()
                        def check_progress(*_):
                            if time.monotonic() - started > 30:
                                raise DomainError('source_busy', '来源资料库繁忙，请稍后重试。', 409)
                        original.backup(snapshot, pages=256, progress=check_progress, sleep=0.01)
                with closing(sqlite3.connect(staging)) as connection:
                    # backup 会继承源的 WAL 模式；发布前关闭所有连接并转换为单文件快照。
                    if connection.execute('PRAGMA journal_mode=DELETE').fetchone()[0] != 'delete':
                        raise DomainError('source_busy', '迁移副本尚未完成检查点，结果未发布。', 409)
                    original_content = _projections(connection)
                    if selected_source is not None:
                        _validate_legacy_schema(original_content)
                upgrade_database(staging)
                with closing(sqlite3.connect(staging)) as connection:
                    for table, (columns, before) in original_content.items():
                        if _content_hash(connection, table, columns) != before:
                            raise DomainError('migration_mismatch', '迁移前后内容不一致，结果未发布。')
                    counts = _counts(connection)
                    connection.execute('INSERT INTO backend_imports VALUES(1,?,?,?,?)',
                        (str(selected_source) if selected_source else None, source_version, time.time(), json.dumps(counts)))
                    connection.commit()
                    _validate(connection)
                os.replace(staging, destination)
                return ImportReport(selected_source is not None, False, counts)
            finally:
                for suffix in ['', '-wal', '-shm', '-journal']:
                    staging.with_name(staging.name + suffix).unlink(missing_ok=True)
    except DomainError:
        raise
    except (OSError, sqlite3.Error, RuntimeError, SQLAlchemyError, CommandError):
        raise DomainError('database_initialization_failed', '资料库初始化或迁移失败，原资料未修改。', 503) from None
