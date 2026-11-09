"""Pi 原生摘要使用独立的只读模型步骤，不进入业务答案与工具计划。"""
import hashlib

from interview_backend.agent.model_recovery import OutputError
from interview_backend.services.common import encode


async def summarize(work, model, messages, dependencies=(), emit=None):
    signature = encode([{'role': message.role, 'content': message.content} for message in messages])
    key = 'compaction:' + hashlib.sha256(signature.encode()).hexdigest()

    def validate(response):
        if response.tool_calls or not response.text.strip():
            raise OutputError('invalid_structure')

    if emit:
        await emit('task_stage', {'message': '正在压缩上下文…'})
    response = await work.model(key, model, messages,
        {'stage': 'compaction', 'model': getattr(model, 'model_name', type(model).__qualname__),
         'context_window': getattr(model, 'context_window', 1_000_000)},
        dependencies, validator=validate,
        repair_instruction='上次摘要不完整。请按当前摘要任务的结构输出完整、简洁的上下文摘要，保留关键约束与未完成步骤，不调用工具。')
    if emit:
        await emit('task_stage', {'message': '上下文已压缩，继续处理…'})
    return response
