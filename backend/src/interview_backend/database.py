from pathlib import Path
import sqlite3
from contextlib import contextmanager

from alembic import command
from alembic.config import Config
from sqlalchemy import URL, create_engine, event


def make_engine(path: Path):
    engine = create_engine(URL.create('sqlite+pysqlite', database=str(path)),
                           connect_args={'autocommit': False, 'check_same_thread': False})

    @event.listens_for(engine, 'connect')
    def configure(connection, _):
        previous = connection.autocommit
        connection.autocommit = True
        try:
            connection.execute('PRAGMA foreign_keys=ON')
            connection.execute('PRAGMA busy_timeout=5000')
        finally:
            connection.autocommit = previous
    return engine


def upgrade_database(path: Path):
    config = Config()
    config.set_main_option('script_location', str(Path(__file__).parent / 'migrations'))
    engine = make_engine(path)
    try:
        with engine.begin() as connection:
            config.attributes['connection'] = connection
            command.upgrade(config, 'head')
    finally:
        engine.dispose()


class Database:
    def __init__(self, path: Path):
        self.path = path
        connection = sqlite3.connect(path, autocommit=True)
        try:
            connection.execute('PRAGMA journal_mode=WAL')
            connection.execute('PRAGMA busy_timeout=5000')
        finally:
            connection.close()
        self.engine = make_engine(path)

    @contextmanager
    def transaction(self, write=False):
        connection = sqlite3.connect(self.path, isolation_level=None, timeout=5)
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA foreign_keys=ON')
        try:
            connection.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def close(self):
        self.engine.dispose()
