"""Pi 原生摘要使用独立的只读模型步骤，不进入业务答案与工具计划。"""
import hashlib

from interview_backend.agent.model_recovery import OutputError
from interview_backend.agent.protocol import Message
from interview_backend.errors import DomainError
from interview_backend.prompt_catalog import load_text
from interview_backend.services.common import encode


async def summarize(work, model, messages, dependencies=(), emit=None):
    def validate(response):
        if response.tool_calls or not response.text.strip():
            raise OutputError('invalid_structure')

    configuration = {'stage': 'compaction', 'model': getattr(model, 'model_name', type(model).__qualname__),
                     'context_window': getattr(model, 'context_window', 1_000_000)}
    part_instruction = load_text('agent/compaction-parts.md')

    def serialized(values):
        return encode([{'role': message.role, 'content': message.content} for message in values])

    async def reduce(values, budget, depth=0):
        signature = serialized(values)
        input_bytes = len(signature.encode())
        if input_bytes <= budget:
            key = 'compaction:' + hashlib.sha256(signature.encode()).hexdigest()
            try:
                return await work.model(key, model, values, configuration, dependencies, validator=validate,
                    repair_instruction='上次摘要不完整。请按当前摘要任务的结构输出完整、简洁的上下文摘要，保留关键约束与未完成步骤，不调用工具。')
            except DomainError as error:
                if error.code != 'model_context_exceeded':
                    raise
                budget = min(budget // 2, input_bytes // 2)
        if depth >= 8:
            raise DomainError('model_context_exceeded', '上下文摘要仍超过模型接口限制，已完成批次保留，请核对模型窗口配置。', 503)
        system = [message for message in values if message.role == 'system']
        # SDK 的摘要任务已把会话序列化成文本，分段仅生成只读检查点。
        if not any(message.text == part_instruction for message in system):
            system.append(Message(role='system', content=part_instruction))
        content = serialized([message for message in values if message.role != 'system'])
        overhead = len(serialized(system).encode()) + 512
        part_size = (budget - overhead) // 4
        if part_size < 256:
            raise DomainError('model_context_exceeded', '模型接口的可用上下文不足以生成摘要，已完成批次保留，请核对模型窗口配置。', 503)
        checkpoints = []
        for start in range(0, len(content), part_size):
            part = Message(role='user', content=encode({'untrusted_conversation_part': content[start:start + part_size]}))
            result = await reduce(system + [part], budget, depth + 1)
            checkpoints.append(result.text)
        merged = system + [Message(role='user', content=encode({'untrusted_checkpoints': checkpoints}))]
        if len(serialized(merged).encode()) >= input_bytes:
            raise DomainError('model_context_exceeded', '摘要未能缩小上下文，已完成批次保留，请核对模型窗口配置。', 503)
        return await reduce(merged, budget, depth + 1)

    if emit:
        await emit('task_stage', {'message': '正在压缩上下文…'})
    settings = getattr(model, 'settings', None)
    reserve = max(8192, getattr(settings, 'max_output_tokens', 8192)) + 4096
    # 字节预算仅控制摘要分段，保守估算并为输出与提示词预留空间。
    budget = max(4096, (configuration['context_window'] - reserve) * 3)
    response = await reduce(messages, budget)
    if emit:
        await emit('task_stage', {'message': '上下文已压缩，继续处理…'})
    return response
