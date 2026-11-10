"""按转写版本保存可撤销的章节、书签和复听标记。"""
from alembic import op

revision = '0006_navigation'
down_revision = '0005_session_titles'
branch_labels = depends_on = None


def upgrade():
    op.execute('''CREATE TABLE navigation_marks (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        segment_id TEXT NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
        kind TEXT NOT NULL CHECK(kind IN ('chapter','bookmark','later')),
        title TEXT NOT NULL,
        removed INTEGER NOT NULL DEFAULT 1)''')
    op.execute('CREATE INDEX navigation_run ON navigation_marks(run_id,removed)')


def downgrade():
    raise RuntimeError('请从保留的备份恢复，不执行破坏性降级。')
