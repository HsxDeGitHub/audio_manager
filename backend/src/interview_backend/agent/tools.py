import json
import re
from pydantic import BaseModel, ConfigDict, Field
from interview_backend.errors import DomainError
from interview_backend.services.common import require, version, encode
from interview_backend.tools.registry import ToolSpec


class MessageContext(BaseModel):
    model_config = ConfigDict(extra='forbid')
    scope: str = 'current'
    recording_id: str | None = None
    run_id: str | None = None
    segment_ids: list[str] = Field(default_factory=list)
    draft_id: str | None = None
    document_ids: list[str] = Field(default_factory=list)


class EvidenceService:
    def __init__(self, database): self.database = database

    def freeze(self, context, instruction):
        context = MessageContext.model_validate(context)
        if context.scope not in {'current', 'all'}:
            raise DomainError('invalid_scope', '资料范围不正确。', 422)
        with self.database.transaction() as c:
            recordings = [dict(r) for r in c.execute('SELECT * FROM recordings ORDER BY created_at,id')] if context.scope == 'all' else [require(c, 'recordings', context.recording_id)] if context.recording_id else []
            resources = []; excluded = []; sources = []
            if context.scope == 'current' and not recordings and not context.document_ids:
                return {**context.model_dump(), 'resources': [], 'sources': [], 'excluded': [], 'allow_write': False, 'clarification': '请指定当前资料，或切换为全部资料。'}
            for recording in recordings:
                resources.append(self.ref(c, 'recording', recording['id']))
                run_id = context.run_id if context.scope == 'current' and context.run_id else recording['active_run']
                if not run_id:
                    excluded.append({'id': recording['id'], 'reason': '暂无转写'}); continue
                if require(c, 'runs', run_id)['recording_id'] != recording['id']:
                    raise DomainError('wrong_scope', '转写版本不属于当前资料。', 409)
                rows = c.execute('SELECT * FROM segments WHERE run_id=? ORDER BY start,id', (run_id,)).fetchall()
                available = {r['id'] for r in rows}
                if context.segment_ids and context.scope == 'current':
                    if not set(context.segment_ids) <= available:
                        raise DomainError('wrong_selection', '所选段落已不在该版本，请重新引用。', 409)
                    rows = [r for r in rows if r['id'] in context.segment_ids]
                for row in rows:
                    ref = self.ref(c, 'segment', row['id'])
                    resources.append(ref)
                    sources.append({**ref, 'recording_id': recording['id'], 'run_id': run_id, 'start': row['start'], 'end': row['end'],
                                    'text': row['edited'] if row['edited'] is not None else row['original'], 'kind': 'original_statement', 'speaker_confirmed': False})
                for speaker in c.execute('SELECT speaker FROM speakers WHERE run_id=?', (run_id,)):
                    resources.append(self.ref(c, 'speaker', f"{run_id}:{speaker[0]}"))
                drafts = c.execute('SELECT * FROM ai_drafts WHERE run_id=?', (run_id,)).fetchall()
                for draft in drafts:
                    if context.draft_id and context.draft_id != draft['id']:
                        continue
                    ref = self.ref(c, 'draft', draft['id']); resources.append(ref)
                    if context.draft_id:
                        sources.append({**ref, 'recording_id': recording['id'], 'run_id': run_id,
                                        'text': draft['payload'], 'kind': 'generated_draft', 'speaker_confirmed': False})
            document_rows = c.execute('SELECT * FROM documents WHERE removed=0 ORDER BY id').fetchall() if context.scope == 'all' else [require(c, 'documents', identifier) for identifier in context.document_ids]
            for row in document_rows:
                if row['removed']: continue
                ref = self.ref(c, 'document', row['id']); resources.append(ref)
                sources.append({**ref, 'text': row['content'], 'kind': 'personal_document', 'line': 1})
            if re.search(r'这段|这一段|这句话', instruction) and not context.segment_ids and not context.draft_id and len(sources) > 1:
                return {**context.model_dump(), 'resources': resources, 'sources': sources, 'excluded': excluded, 'allow_write': False, 'clarification': '请引用要处理的段落，避免误改其他内容。'}
            # 只有用户消息中的执行动词可允许写工具，资料正文永远不参与权限判断。
            mutation = bool(re.search(r'(帮我|请|把|将|直接).{0,40}(修改|修正|替换|改成|改为|删除|忘记|停用|重命名|撤销|合并|设置|更正)|^(修改|修正|删除|撤销|忘记|停用|设置|记住)', instruction))
            return {**context.model_dump(), 'resources': resources, 'sources': sources, 'excluded': excluded, 'allow_write': mutation,
                    'instruction': instruction, 'recording_ids': [r['id'] for r in recordings]}

    @staticmethod
    def ref(c, kind, identifier):
        return {'resource_type': kind, 'resource_id': identifier, 'revision': version(c, kind, identifier)}

    def valid(self, reference):
        from interview_backend.services.changesets import read_object
        with self.database.transaction() as c:
            try:
                obj = read_object(c, reference['resource_type'], reference['resource_id'])
                return version(c, reference['resource_type'], reference['resource_id']) == reference['revision'] and not obj.get('removed') and (reference['resource_type'] != 'memory' or obj.get('state') == 'active')
            except (DomainError, KeyError, ValueError):
                return False

    def validate_result(self, result, context):
        allowed = {(r['resource_type'], r['resource_id'], r['revision']) for r in context['resources']}
        for claim in result.get('claims', []):
            if claim.get('kind') not in {'original_statement', 'user_statement', 'analysis', 'suggestion', 'insufficient_evidence'}:
                raise DomainError('invalid_claim', '模型未区分原话、判断和建议。', 409)
            if claim['kind'] in {'original_statement', 'user_statement'} and not claim.get('sources'):
                raise DomainError('missing_source', '模型事实缺少来源，不能作为结果。', 409)
            for ref in claim.get('sources', []):
                if claim['kind'] == 'user_statement' and any(s['resource_type'] == ref['resource_type'] and s['resource_id'] == ref['resource_id'] and s.get('kind') == 'original_statement' and not s.get('speaker_confirmed') for s in context.get('sources', [])):
                    raise DomainError('identity_unconfirmed', '未确认的说话人不能作为用户经历来源。', 409)
                if (ref['resource_type'], ref['resource_id'], ref['revision']) not in allowed or not self.valid(ref):
                    raise DomainError('stale_source', '引用来源已变化或超出范围，请重新运行。', 409)
        return result


def framework_tools(registry, context):
    from langchain_core.tools import StructuredTool
    tools = []
    for metadata in registry.list():
        spec = registry._tools[metadata['id']]
        if spec.effect not in context.allowed_effects: continue
        if context.frozen_context is not None and spec.tool_id != 'evidence.read': continue
        async def execute(_tool_id=spec.tool_id, **arguments):
            result = await registry.execute(_tool_id, arguments, context)
            return result['data']
        tools.append(StructuredTool.from_function(coroutine=execute, name=spec.framework_name, description=spec.description, args_schema=spec.input_model))
    return tools


class EmptyArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')


class ResultEnvelope(BaseModel):
    result: dict


def install_agent_tools(registry, changesets):
    from interview_backend.services.changesets import ChangeTarget
    class ApplyArguments(BaseModel):
        model_config = ConfigDict(extra='forbid')
        targets: list[ChangeTarget]
    registry.register(ToolSpec(tool_id='changesets.apply', version='1.0', title='提交范围内修改',
        description='一次事务提交用户明确授权的全部目标，校验预期版本并记录差异和撤销。',
        input_model=ApplyArguments, output_model=ResultEnvelope, effect='write',
        handler=lambda args, context: {'result': changesets.submit({'operation_id': context.operation_id, 'targets': [t.model_dump() for t in args.targets]}, context.resource_scope)}))
    def read(args, context):
        if context.frozen_context is None:
            raise DomainError('scope_required', '需要先确定资料范围。', 409)
        return {'result': {'sources': context.frozen_context['sources'], 'excluded': context.frozen_context.get('excluded', [])}}
    registry.register(ToolSpec(tool_id='evidence.read', version='1.0', title='读取固定范围证据',
        description='读取当前消息固定范围内的完整证据、版本和无法纳入项。', input_model=EmptyArguments, output_model=ResultEnvelope, handler=read))
