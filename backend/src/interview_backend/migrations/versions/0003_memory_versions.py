"""修复旧版记忆失效时行版本与统一账本不一致。"""
from alembic import op

revision = '0003_memory_versions'
down_revision = '0002_application'
branch_labels = depends_on = None


def upgrade():
    op.execute("""INSERT INTO object_versions(resource_type,resource_id,revision)
        SELECT 'memory',id,revision FROM memories WHERE 1
        ON CONFLICT(resource_type,resource_id) DO UPDATE SET revision=max(object_versions.revision,excluded.revision)""")
    op.execute("""UPDATE memories SET revision=(SELECT revision FROM object_versions
        WHERE resource_type='memory' AND resource_id=memories.id)""")
    op.execute("""INSERT INTO index_queue(resource_type,resource_id,revision,state)
        SELECT 'memory',id,revision,'pending' FROM memories WHERE 1
        ON CONFLICT(resource_type,resource_id) DO UPDATE SET revision=excluded.revision,state='pending'""")


def downgrade():
    raise RuntimeError('请从保留的备份恢复，不执行破坏性降级。')
