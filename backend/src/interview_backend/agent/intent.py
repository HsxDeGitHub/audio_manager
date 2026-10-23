"""模型理解任务；服务端限制能力、对象与字段。分类失败不会回退为可写。"""
import json
import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from interview_backend.agent.models import ModelSettings
from interview_backend.agent.permissions import command_text
from interview_backend.errors import DomainError
from interview_backend.prompt_catalog import load_text
from interview_backend.services.common import encode


class TaskIntent(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    mode: Literal['read', 'edit', 'clarify']
    reading: Literal['selection', 'search', 'full', 'weekly']
    edit_target: Literal['none', 'transcript', 'content']
    import_documents: bool
    actions: list[str] = Field(max_length=12)
    constraints: list[str] = Field(max_length=12)
    clarification: str = Field(max_length=1000)
    proposal_id: str = Field(default='', max_length=200)


def explicit_readonly(instruction):
    """只拦截独立的明确只读声明，不把主题里的疑问词或保留细节当成禁写。"""
    text = command_text(instruction).strip()
    if not text:
        return True
    if re.fullmatch(r'(?:以下|下面|上述)?(?:是|为)?(?:原文|资料|正文|转写|引用|内容)[：:\s]*', text):
        return True
    clauses = re.split(r'[，,。；;\n]|但(?:是)?', text)
    return any(re.fullmatch(
        r'\s*(?:(?:请|本轮|这次|现在|先|暂时|暂|仅|只)\s*)*'
        r'(?:只读|(?:只|仅)(?:需|需要|要)?(?:分析|阅读|讨论|检查|提供方案)(?:即可|就好)?|'
        r'(?:不要|不需要|禁止|先不|暂不)(?:执行|应用|实施|提交|进行)?(?:任何)?(?:修改|编辑|写入|改动)(?:正文|内容|原文|资料|代码)?(?:操作)?)\s*[！!？?]?\s*',
        clause) is not None for clause in clauses)


async def resolve(settings, registry, context, model=None):
    from langchain_core.messages import HumanMessage, SystemMessage
    catalog = [{k: t[k] for k in ('id', 'title', 'effect')}
               for t in registry.list() if t['effect'] in {'device', 'external'}]
    # 分类不接收资料正文、选区文字、记忆或工具结果，只使用本轮指令及受限历史。
    payload = {'instruction': context['instruction'],
               'conversation_history': [{k: m[k] for k in ('role', 'content') if k in m}
                                        for m in context.get('conversation_history', [])],
               'has_selection': bool(context.get('segment_ids') or context.get('quotes')),
               'pending_proposals': context.get('pending_proposals', []),
               'selected_proposal_id': context.get('proposal_id'),
               'available_actions': catalog,
               'schema': TaskIntent.model_json_schema()}
    try:
        client = model or ModelSettings.load(settings.data_dir).client()
        response = await client.ainvoke([SystemMessage(content=load_text('agent/intent.md')),
                                       HumanMessage(content=encode(payload))])
        if getattr(response, 'tool_calls', None):
            raise ValueError()
        raw = response.content
        if not isinstance(raw, str):
            raise ValueError()
        raw = re.sub(r'^```(?:json)?\s*|\s*```$', '', raw.strip())
        intent = TaskIntent.model_validate(json.loads(raw))
        allowed = {item['id'] for item in catalog}
        if any(action not in allowed for action in intent.actions):
            raise ValueError()
        if any(len(item) > 500 for item in intent.constraints):
            raise ValueError()
        if intent.mode != 'edit' and intent.edit_target != 'none':
            raise ValueError()
        if intent.mode == 'edit' and intent.edit_target == 'none':
            raise ValueError()
        if intent.import_documents and (intent.mode != 'edit' or intent.edit_target != 'content'):
            raise ValueError()
        if intent.mode == 'clarify' and not intent.clarification.strip():
            raise ValueError()
    except DomainError:
        raise
    except Exception:
        # 不传播服务商正文、凭据或分类原始输出。
        raise DomainError('intent_unavailable', '暂时无法确定任务意图，尚未执行任何操作；请检查模型配置后重试。', 503) from None
    if explicit_readonly(context['instruction']):
        intent = TaskIntent(mode='read', reading=intent.reading, edit_target='none',
                            import_documents=False, actions=[], constraints=intent.constraints, clarification='')
    return intent.model_dump()


def apply(context, intent):
    value = {**context, 'task_intent': TaskIntent.model_validate(intent).model_dump()}
    value['allow_write'] = intent['mode'] == 'edit'
    value['transcript_organization'] = intent['edit_target'] == 'transcript'
    value['write_resources'] = [r for r in context['resources'] if r['resource_type'] == 'segment'] if value['transcript_organization'] else list(context['resources'])
    value['write_field_limits'] = {'segment': ['text']} if value['transcript_organization'] else {}
    if value['transcript_organization'] and context.get('intent_policy') == 'semantic-v2':
        # 新消息可校对发言归属、名称和核对状态；旧运行继续使用已冻结的文字边界。
        value['write_resources'] = [r for r in context['resources'] if r['resource_type'] in {'segment', 'speaker'}]
        value['write_field_limits'] = {'segment': ['text', 'speaker', 'needs_review', 'reviewed'], 'speaker': ['name']}
    value['allowed_actions'] = list(dict.fromkeys(intent['actions'])) if intent['mode'] != 'clarify' else []
    value['allow_device'] = any(a.startswith(('device.', 'jobs.')) for a in value['allowed_actions'])
    value['allow_external'] = any(a.startswith('mcp.') for a in value['allowed_actions'])
    # 导入仍需当前明确任务；模型只决定是否属于内容任务，不能从材料正文扩权。
    value['allow_document_import'] = value['allow_write'] and intent['edit_target'] == 'content' and intent['import_documents']
    if intent['mode'] == 'clarify':
        value['clarification'] = intent['clarification']
    return value
