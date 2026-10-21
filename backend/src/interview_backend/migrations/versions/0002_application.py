"""业务操作、运行任务及有来源内容的持久化基础。"""
from alembic import op

revision = '0002_application'
down_revision = '0001_backend_baseline'
branch_labels = depends_on = None


def upgrade():
    statements = [
        'CREATE TABLE object_versions (resource_type TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0), PRIMARY KEY(resource_type,resource_id))',
        'CREATE TABLE operations (id TEXT PRIMARY KEY, digest TEXT NOT NULL, result TEXT NOT NULL)',
        'CREATE TABLE changesets (id TEXT PRIMARY KEY, state TEXT NOT NULL, items TEXT NOT NULL, created_at REAL NOT NULL, reverted_by TEXT)',
        'CREATE TABLE jobs (id TEXT PRIMARY KEY, kind TEXT NOT NULL, target TEXT NOT NULL, state TEXT NOT NULL, payload TEXT NOT NULL, result TEXT, revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0))',
        'CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, scope TEXT NOT NULL, created_at REAL NOT NULL)',
        'CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, role TEXT NOT NULL, content TEXT NOT NULL, context TEXT NOT NULL, created_at REAL NOT NULL)',
        'CREATE TABLE agent_runs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), message_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL, context TEXT NOT NULL, result TEXT, created_at REAL NOT NULL)',
        'CREATE UNIQUE INDEX one_active_run ON agent_runs(session_id) WHERE state IN (\'running\',\'queued\',\'awaiting_input\')',
        'CREATE TABLE events (run_id TEXT NOT NULL REFERENCES agent_runs(id) ON DELETE CASCADE, seq INTEGER NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(run_id,seq))',
        'CREATE TABLE documents (id TEXT PRIMARY KEY, title TEXT NOT NULL, format TEXT NOT NULL, original TEXT NOT NULL, content TEXT NOT NULL, digest TEXT NOT NULL, removed INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0))',
        'CREATE UNIQUE INDEX document_digest ON documents(digest) WHERE removed=0',
        'CREATE TABLE memories (id TEXT PRIMARY KEY, category TEXT NOT NULL, content TEXT NOT NULL, scope TEXT NOT NULL, sources TEXT NOT NULL, topic TEXT NOT NULL, state TEXT NOT NULL, supersedes TEXT, revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0))',
        'CREATE TABLE suppressions (topic TEXT NOT NULL, source TEXT NOT NULL, PRIMARY KEY(topic,source))',
        'CREATE TABLE index_queue (resource_type TEXT NOT NULL, resource_id TEXT NOT NULL, revision INTEGER NOT NULL, state TEXT NOT NULL, PRIMARY KEY(resource_type,resource_id))',
        'CREATE TABLE device_commands (id TEXT PRIMARY KEY, run_id TEXT, kind TEXT NOT NULL, target TEXT NOT NULL, arguments TEXT NOT NULL, state TEXT NOT NULL, result TEXT, owner TEXT, updated_at REAL NOT NULL)',
        'CREATE TABLE tool_settings (id TEXT PRIMARY KEY, enabled INTEGER NOT NULL)',
        'CREATE TABLE mcp_connections (id TEXT PRIMARY KEY, config TEXT NOT NULL)',
    ]
    for statement in statements:
        op.execute(statement)
    for table, kind in [('recordings', 'recording'), ('segments', 'segment'), ('ai_drafts', 'draft')]:
        op.execute(f"INSERT INTO object_versions SELECT '{kind}',id,1 FROM {table}")
    op.execute("INSERT INTO object_versions SELECT 'speaker',run_id||':'||speaker,1 FROM speakers")


def downgrade():
    raise RuntimeError('请从保留的备份恢复，不执行破坏性降级。')
