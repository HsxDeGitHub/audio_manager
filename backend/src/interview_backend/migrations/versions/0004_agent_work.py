"""持久化模型步骤与工具回执，续跑只推进剩余工作。"""
from alembic import op
revision = '0004_agent_work'
down_revision = '0003_memory_versions'
branch_labels = depends_on = None


def upgrade():
    op.execute('CREATE TABLE agent_work (run_id TEXT NOT NULL, step_key TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(run_id,step_key))')


def downgrade():
    raise RuntimeError('请从保留的备份恢复，不执行破坏性降级。')
