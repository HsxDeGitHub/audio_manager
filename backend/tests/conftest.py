"""只使用合成资料，不读取个人资料库。"""
import sqlite3
from pathlib import Path

import pytest


def make_legacy(path: Path, *, reviewed: bool = True, version: int = 3) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path) as connection:
        connection.executescript('''
        PRAGMA foreign_keys=ON;
        CREATE TABLE recordings (id TEXT PRIMARY KEY, title TEXT NOT NULL, path TEXT NOT NULL,
          bookmark BLOB, fingerprint TEXT NOT NULL, duration REAL NOT NULL, created_at REAL NOT NULL,
          state TEXT NOT NULL, error TEXT, speaker_count INTEGER, play_position REAL NOT NULL, active_run TEXT);
        CREATE TABLE runs (id TEXT PRIMARY KEY, recording_id TEXT NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
          created_at REAL NOT NULL);
        CREATE TABLE segments (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
          start REAL NOT NULL, end REAL NOT NULL, original TEXT NOT NULL, edited TEXT, speaker INTEGER,
          speaker_edited INTEGER NOT NULL DEFAULT 0, needs_review INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE speakers (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
          speaker INTEGER NOT NULL, name TEXT NOT NULL, PRIMARY KEY(run_id,speaker));
        CREATE TABLE edit_history (id INTEGER PRIMARY KEY AUTOINCREMENT,
          run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE, label TEXT NOT NULL,
          before_json TEXT NOT NULL, after_json TEXT NOT NULL, applied INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE reading_cache (run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
          cache_key TEXT NOT NULL, rendered TEXT NOT NULL, PRIMARY KEY(run_id,cache_key));
        CREATE TABLE ai_drafts (id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
          created_at REAL NOT NULL, payload TEXT NOT NULL);
        ''')
        if reviewed:
            connection.execute('ALTER TABLE segments ADD COLUMN reviewed INTEGER NOT NULL DEFAULT 0')
        connection.execute(f'PRAGMA user_version={version}')
        connection.executemany('INSERT INTO recordings VALUES(?,?,?,?,?,?,?,?,?,?,?,?)', [
            ('r1', '合成面试甲', '/synthetic/a.wav', b'bookmark-data', 'hash-a', 60.0, 100.0, 'completed', None, 2, 8.5, 'run1'),
            ('r2', '合成面试乙', '/synthetic/b.wav', None, 'hash-b', 30.0, 200.0, 'interrupted', '合成中断', None, 0.0, 'run2'),
        ])
        connection.executemany('INSERT INTO runs VALUES(?,?,?)', [('run1', 'r1', 101.0), ('run2', 'r2', 201.0)])
        connection.executemany('''INSERT INTO segments
          (id,run_id,start,end,original,edited,speaker,speaker_edited,needs_review) VALUES(?,?,?,?,?,?,?,?,?)''', [
            ('s2', 'run1', 10.0, 12.0, '原始回答', '校对后的回答', 1, 1, 0),
            ('s1', 'run1', 1.0, 3.0, '原始问题', None, 0, 0, 1),
            ('s3', 'run2', 2.0, 5.0, '另一场对话', '', None, 0, 1),
        ])
        connection.executemany('INSERT INTO speakers VALUES(?,?,?)', [('run1', 0, '提问者'), ('run1', 1, '回答者')])
        connection.execute("INSERT INTO edit_history(run_id,label,before_json,after_json,applied) VALUES('run1','修改文字','{}','{}',0)")
        connection.execute("INSERT INTO reading_cache VALUES('run1','cache-key','{\"s1\":\"问题？\"}')")
        connection.execute('INSERT INTO ai_drafts VALUES(?,?,?,?)', ('draft1', 'run1', 102.0,
            '{"id":"draft1","state":"completed","chunks":[{"blocks":[{"text":"合成整理稿","sourceIDs":["s1"]}]}]}'))
    return path


@pytest.fixture
def legacy_path(tmp_path):
    return make_legacy(tmp_path / 'source' / 'library.sqlite')


@pytest.fixture
def config(tmp_path):
    from interview_backend.config import Settings
    return Settings(data_dir=tmp_path / 'data', token='synthetic-test-token')


@pytest.fixture
def client(config):
    from fastapi.testclient import TestClient
    from interview_backend.app import create_app
    make_legacy(config.data_dir / 'library.sqlite')
    with TestClient(create_app(config)) as test_client:
        test_client.headers['Authorization'] = 'Bearer synthetic-test-token'
        yield test_client
