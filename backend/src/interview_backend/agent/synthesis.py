"""对已校验的分块结论做分层综合，任何一层都不能执行工具或扩展来源。"""
import json
import re

from interview_backend.agent.work import WorkLog
from interview_backend.agent.models import ModelSettings
from interview_backend.errors import DomainError
from interview_backend.prompt_catalog import load_text
from interview_backend.services.common import encode


async def synthesize(engine, run_id, instruction, context, parts, model=None, emit=None):
    if len(parts) < 2 or not context.get('task_intent') or context.get('allow_write'):
        return None
    from langchain_core.messages import HumanMessage, SystemMessage
    work = WorkLog(engine.evidence.database, run_id)
    dependencies = [{k:r[k] for k in ('resource_type','resource_id','revision')} for r in context['resources']]
    notes = []
    for result in parts:
        engine.evidence.validate_result(result, context, engine.evidence.committed(run_id))
        # 正文和依据都完整参与综合；过长单项拆为多个节点，不静默截断。
        answer = result.get('answer', '')
        notes += [{'answer':answer[i:i+6000], 'claims':[]} for i in range(0,len(answer),6000)]
        notes += [{'answer':'', 'claims':[claim]} for claim in result.get('claims', [])]
    if not notes:
        return None
    client = getattr(engine, 'synthesis_model', None) or model or ModelSettings.load(engine.settings.data_dir).client()
    if emit:
        await emit('task_stage', {'message':'正在去重并综合各部分结论…'})
    for level in range(10):
        groups = []; group = []; size = 0
        for note in notes:
            length = len(encode(note))
            if length > 24000:
                raise DomainError('synthesis_too_large','单项依据过长，分块结果已保留；请缩小汇总范围。',409)
            if group and size + length > 24000:
                groups.append(group); group = []; size = 0
            group.append(note); size += length
        if group:
            groups.append(group)
        reduced = []
        for index, values in enumerate(groups):
            key = f'synthesis:{level}:{index}'
            try:
                response = await work.model(key, client, [SystemMessage(content=load_text('agent/synthesis.md')),
                    HumanMessage(content=encode({'instruction':instruction,'untrusted_parts':values}))],
                    {'stage':'synthesis','level':level}, dependencies, emit=emit)
                if response.tool_calls or not isinstance(response.content, str):
                    raise ValueError()
                result = json.loads(re.sub(r'^```(?:json)?\s*|\s*```$', '', response.content.strip()))
                if set(result) != {'answer','claims'} or not isinstance(result['answer'],str) or not isinstance(result['claims'],list):
                    raise ValueError()
                engine.evidence.validate_result(result, context, engine.evidence.committed(run_id))
            except DomainError:
                work.discard(key)
                raise
            except Exception:
                work.discard(key)
                raise DomainError('synthesis_failed','综合结论未通过校验，已完成的分块分析保留，可继续任务。',503) from None
            reduced.append(result)
        if len(reduced) == 1:
            return reduced[0]
        if len(reduced) >= len(notes):
            raise DomainError('synthesis_too_large','汇总内容仍过长，分块分析已保留；请缩小任务范围。',409)
        notes = reduced
    raise DomainError('synthesis_too_large','汇总层级超过限制，分块分析已保留。',409)
