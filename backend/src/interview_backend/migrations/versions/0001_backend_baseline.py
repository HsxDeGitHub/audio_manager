"""建立兼容既有资料的后端基线，仅在新库或快照副本执行。"""
from alembic import op
import sqlalchemy as sa
from interview_backend.models import metadata

revision = '0001_backend_baseline'
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    connection = op.get_bind()
    metadata.create_all(connection)
    existing = {column['name'] for column in sa.inspect(connection).get_columns('segments')}
    if 'reviewed' not in existing:
        op.add_column('segments', sa.Column('reviewed', sa.Integer, nullable=False, server_default='0'))
    existing = {column['name'] for column in sa.inspect(connection).get_columns('recordings')}
    columns = [sa.Column('kind', sa.String, nullable=False, server_default='unknown'),
               sa.Column('interview_date', sa.String), sa.Column('company', sa.Text), sa.Column('role', sa.Text),
               sa.Column('revision', sa.Integer, nullable=False, server_default='1')]
    for column in columns:
        if column.name not in existing:
            op.add_column('recordings', column)


def downgrade():
    raise RuntimeError('回退请恢复保留的旧库，不对用户资料执行破坏性降级。')
