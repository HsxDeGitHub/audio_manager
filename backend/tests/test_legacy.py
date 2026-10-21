import hashlib
import sqlite3

import pytest

from conftest import make_legacy
from interview_backend.errors import DomainError
from interview_backend.legacy import initialize_database


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_import_preserves_original_tables_and_never_changes_source(config, legacy_path):
    before = digest(legacy_path)
    result = initialize_database(config, source=legacy_path)
    assert result.legacy_imported and not result.reused
    assert result.counts['recordings'] == 2
    assert digest(legacy_path) == before
    with sqlite3.connect(config.database_path) as target, sqlite3.connect(legacy_path) as original:
        for table in ['recordings', 'runs', 'segments', 'speakers', 'edit_history', 'reading_cache', 'ai_drafts']:
            columns = [row[1] for row in original.execute(f'PRAGMA table_info({table})')]
            fields = ','.join('"' + column + '"' for column in columns)
            assert target.execute(f'SELECT {fields} FROM {table} ORDER BY rowid').fetchall() == original.execute(f'SELECT {fields} FROM {table} ORDER BY rowid').fetchall()
        assert target.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert target.execute('PRAGMA foreign_key_check').fetchall() == []


def test_repeated_import_is_idempotent_and_different_source_is_rejected(config, legacy_path, tmp_path):
    initialize_database(config, source=legacy_path)
    result = initialize_database(config, source=legacy_path)
    assert result.reused and result.counts['segments'] == 3
    another = make_legacy(tmp_path / 'different.sqlite')
    with pytest.raises(DomainError) as error:
        initialize_database(config, source=another)
    assert error.value.code == 'target_exists'
    assert initialize_database(config).counts['segments'] == 3


def test_wal_commits_are_included_in_snapshot(config, legacy_path):
    connection = sqlite3.connect(legacy_path)
    try:
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute('PRAGMA wal_autocheckpoint=0')
        connection.execute("UPDATE segments SET edited='WAL 中已提交的校对' WHERE id='s1'")
        connection.commit()
        initialize_database(config, source=legacy_path)
        with sqlite3.connect(config.database_path) as target:
            assert target.execute("SELECT edited FROM segments WHERE id='s1'").fetchone()[0] == 'WAL 中已提交的校对'
    finally:
        connection.close()


def test_old_review_schema_is_normalized_only_on_copy(config, tmp_path):
    source = make_legacy(tmp_path / 'old.sqlite', reviewed=False, version=1)
    initialize_database(config, source=source)
    with sqlite3.connect(source) as original, sqlite3.connect(config.database_path) as target:
        assert 'reviewed' not in [row[1] for row in original.execute('PRAGMA table_info(segments)')]
        assert target.execute('SELECT reviewed FROM segments').fetchall() == [(0,), (0,), (0,)]


def test_failed_upgrade_does_not_publish_or_modify_source(config, legacy_path, monkeypatch):
    before = digest(legacy_path)
    def fail(_):
        raise RuntimeError('synthetic migration failure')
    monkeypatch.setattr('interview_backend.legacy.upgrade_database', fail)
    with pytest.raises(DomainError):
        initialize_database(config, source=legacy_path)
    assert not config.database_path.exists()
    assert digest(legacy_path) == before
    assert not list(config.backend_dir.glob('*.import-*'))


@pytest.mark.parametrize('mode', ['future', 'corrupt', 'missing', 'invalid_fk', 'schema_mismatch'])
def test_invalid_sources_do_not_publish_target(config, tmp_path, mode):
    source = tmp_path / 'invalid.sqlite'
    if mode == 'future':
        make_legacy(source, version=999)
    elif mode == 'corrupt':
        source.write_bytes(b'not a database; private transcript')
    elif mode == 'invalid_fk':
        make_legacy(source)
        with sqlite3.connect(source) as connection:
            connection.execute("UPDATE segments SET run_id='missing'")
    elif mode == 'schema_mismatch':
        with sqlite3.connect(source) as connection:
            for name in ['recordings', 'runs', 'segments', 'speakers']:
                connection.execute(f'CREATE TABLE {name}(id TEXT PRIMARY KEY)')
    with pytest.raises(DomainError) as error:
        initialize_database(config, source=source)
    assert 'private transcript' not in str(error.value)
    assert not config.database_path.exists()


def test_source_and_target_alias_is_rejected(config):
    make_legacy(config.database_path)
    with pytest.raises(DomainError) as error:
        initialize_database(config, source=config.database_path)
    assert error.value.code == 'same_database'


def test_empty_store_can_restart_but_cannot_be_overwritten_by_import(config, legacy_path):
    first = initialize_database(config)
    assert not first.legacy_imported and first.counts['recordings'] == 0
    assert initialize_database(config).reused
    with pytest.raises(DomainError):
        initialize_database(config, source=legacy_path)
