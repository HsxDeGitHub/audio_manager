"""记录手动命名与会话移除状态，保留业务操作追溯。"""
from alembic import op

revision = '0005_session_titles'
down_revision = '0004_agent_work'
branch_labels = depends_on = None


def upgrade():
    op.execute('ALTER TABLE sessions ADD COLUMN title_edited INTEGER NOT NULL DEFAULT 0')
    op.execute('ALTER TABLE sessions ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0')


def downgrade():
    raise RuntimeError('请从保留的备份恢复，不执行破坏性降级。')
