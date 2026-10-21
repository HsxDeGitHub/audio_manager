"""迁移只使用调用者传入的事务连接，不读取全局用户配置。"""
from alembic import context
from interview_backend.models import metadata

connection = context.config.attributes.get('connection')
if connection is None:
    raise RuntimeError('迁移必须经由后端资料库初始化入口运行。')
context.configure(connection=connection, target_metadata=metadata,
                  transactional_ddl=True, render_as_batch=True)
with context.begin_transaction():
    context.run_migrations()
