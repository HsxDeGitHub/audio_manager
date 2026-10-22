import hashlib
import json
import re
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field
from interview_backend.errors import DomainError
from interview_backend.services.common import require, version, encode
from interview_backend.services.draft_sources import draft_current
from interview_backend.tools.registry import ToolSpec


class MessageContext(BaseModel):
    model_config = ConfigDict(extra='forbid')
    scope: str = 'current'
    recording_id: str | None = None
    run_id: str | None = None
    segment_ids: list[str] = Field(default_factory=list)
    draft_id: str | None = None
    document_ids: list[str] = Field(default_factory=list)


from interview_backend.agent.permissions import ACTION_VERBS, action_allowed, action_permissions, write_permissions


class EvidenceService:
    def __init__(self, database): self.database = database

    def freeze(self, context, instruction):
        context = MessageContext.model_validate(context)
        mutation, importing = write_permissions(instruction)
        if context.scope not in {'current', 'all'}:
            raise DomainError('invalid_scope', '资料范围不正确。', 422)
        with self.database.transaction() as c:
            recordings = [dict(r) for r in c.execute('SELECT * FROM recordings ORDER BY created_at,id')] if context.scope == 'all' else [require(c, 'recordings', context.recording_id)] if context.recording_id else []
            resources = []; excluded = []; sources = []; device_targets = []; cancel_tasks = []
            if context.scope == 'current' and not recordings and not context.document_ids and not importing:
                return {**context.model_dump(), 'resources': [], 'sources': [], 'excluded': [], 'allow_write': False, 'clarification': '请指定当前资料，或切换为全部资料。'}
            for recording in recordings:
                from interview_backend.services.device_tasks import active_tasks
                cancel_tasks += active_tasks(c,recording['id'])
                resources.append(self.ref(c, 'recording', recording['id']))
                run_id = context.run_id if context.scope == 'current' and context.run_id else recording['active_run']
                if not run_id:
                    from interview_backend.services.device_targets import snapshot
                    device_targets.append(snapshot(c, recording['id'], None))
                    excluded.append({'id': recording['id'], 'reason': '暂无转写'}); continue
                if require(c, 'runs', run_id)['recording_id'] != recording['id']:
                    raise DomainError('wrong_scope', '转写版本不属于当前资料。', 409)
                from interview_backend.services.device_targets import snapshot
                device_targets.append(snapshot(c, recording['id'], run_id, context.draft_id))
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
                    if not draft_current(c, draft):
                        excluded.append({'id': draft['id'], 'code': 'stale_draft',
                                         'reason': '整理稿来源已变化或缺少来源快照，已退出当前证据；请重新整理。'})
                        continue
                    ref = self.ref(c, 'draft', draft['id']); resources.append(ref)
                    if context.draft_id:
                        sources.append({**ref, 'recording_id': recording['id'], 'run_id': run_id,
                                        'text': draft['payload'], 'kind': 'generated_draft', 'speaker_confirmed': False})
            document_rows = c.execute('SELECT * FROM documents WHERE removed=0 ORDER BY id').fetchall() if context.scope == 'all' else [require(c, 'documents', identifier) for identifier in context.document_ids]
            for row in document_rows:
                if row['removed']: continue
                ref = self.ref(c, 'document', row['id']); resources.append(ref)
                sources.append({**ref, 'title': row['title'], 'text': row['content'], 'kind': 'personal_document', 'line': 1})
            if re.search(r'这段|这一段|这句话', instruction) and not context.segment_ids and not context.draft_id and len(sources) > 1:
                return {**context.model_dump(), 'resources': resources, 'sources': sources, 'excluded': excluded, 'allow_write': False, 'clarification': '请引用要处理的段落，避免误改其他内容。'}
            # 只有用户消息中的执行动词可允许写工具，资料正文永远不参与权限判断。
            actions = action_permissions(instruction)
            from interview_backend.agent.permissions import command_text
            command=command_text(instruction)
            if '整理' in command and not re.search('转写|识别',command):cancel_tasks=[t for t in cancel_tasks if t['task_type']=='organize']
            elif re.search('转写|识别',command) and '整理' not in command:cancel_tasks=[t for t in cancel_tasks if t['task_type']=='audio']
            device = any(a.startswith(('device.', 'jobs.', 'organize.')) for a in actions)
            external = any(a.startswith('mcp.') for a in actions)
            frozen = {**context.model_dump(), 'resources': resources, 'write_resources': list(resources), 'sources': sources, 'excluded': excluded, 'allow_write': mutation,
                    'allow_device': device, 'allow_external': external, 'allowed_actions': actions,
                    'allow_document_import': importing,
                    'cancel_tasks':cancel_tasks, 'device_targets': device_targets, 'instruction': instruction, 'recording_ids': [r['id'] for r in recordings]}
            if 'jobs.cancel' in actions and len(cancel_tasks)>1 and not re.search(r'全部|所有|都|一起|及|和|分别',command):
                frozen['clarification']='存在多个活动任务，请指定要取消的转写或整理任务，或明确要求取消全部。'
            return frozen

    @staticmethod
    def ref(c, kind, identifier):
        return {'resource_type': kind, 'resource_id': identifier, 'revision': version(c, kind, identifier)}

    def valid(self, reference):
        from interview_backend.services.source_validity import source_valid
        with self.database.transaction() as c: return source_valid(c, reference)

    def committed(self, run_id):
        """业务账本是提交事实；不依赖模型响应或另一个数据库的检查点。"""
        prefix = run_id + ':tool:'
        with self.database.transaction() as c:
            return [{'id': r['id'], 'state': r['state'], 'items': json.loads(r['items']),
                     'count': len(json.loads(r['items']))} for r in c.execute(
                'SELECT * FROM changesets WHERE id IN (?,?) OR substr(id,1,?)=? ORDER BY created_at,id',
                (run_id + ':changes', run_id + ':tools', len(prefix), prefix))]

    def valid_after_changes(self, reference, changes):
        if self.valid(reference): return True
        from interview_backend.services.changesets import read_object
        for change in changes:
            if change['state'] != 'planned': continue
            for item in change['items']:
                if (item['resource_type'], item['resource_id'], item['after_revision']) == (reference['resource_type'], reference['resource_id'], reference['revision']):
                    with self.database.transaction() as c:
                        if item['resource_type'] == 'document' and item['resource_id'] in change.get('new_document_ids', []) and not c.execute('SELECT 1 FROM documents WHERE id=?', (item['resource_id'],)).fetchone(): return True
                        if version(c, item['resource_type'], item['resource_id']) == item['before_revision'] and read_object(c, item['resource_type'], item['resource_id']) == item['before']: return True
        key = (reference['resource_type'], reference['resource_id'])
        items = [item for change in changes if change['state'] == 'committed' for item in change['items']
                 if (item['resource_type'], item['resource_id']) == key]
        if not any(item['before_revision'] == reference['revision'] for item in items): return False
        latest = max(items, key=lambda item: item['after_revision'])
        with self.database.transaction() as c:
            return version(c, *key) == latest['after_revision'] and read_object(c, *key) == latest['after']

    def fulfilled(self, target, changes):
        """模型重复申报已提交目标时复用事实；不同建议或并发修改仍走版本冲突。"""
        from interview_backend.services.changesets import ChangeTarget, patch
        from pydantic import ValidationError
        try:
            target = ChangeTarget.model_validate(target)
            items = [item for change in changes if change['state'] == 'committed' for item in change['items']
                     if (item['resource_type'], item['resource_id']) == (target.resource_type, target.resource_id)]
            if not items or target.expected_revision not in {v for item in items for v in (item['before_revision'], item['after_revision'])}: return False
            latest = max(items, key=lambda item: item['after_revision'])
            ref = {'resource_type': target.resource_type, 'resource_id': target.resource_id, 'revision': latest['before_revision']}
            return self.valid_after_changes(ref, changes) and patch(target.resource_type, latest['after'], target.fields) == latest['after']
        except (ValidationError, DomainError):
            return False

    def validate_result(self, result, context, changes=()):
        allowed = {(r['resource_type'], r['resource_id'], r['revision']) for r in context['resources']}
        frozen_keys = {(kind, identifier) for kind, identifier, _ in allowed}
        # 工具可能返回本次提交后的来源版本；只扩充引用版本，不扩大写入对象范围。
        allowed.update((item['resource_type'], item['resource_id'], item['after_revision'])
                       for change in changes if change['state'] in {'committed', 'planned'} for item in change['items']
                       if (item['resource_type'], item['resource_id']) in frozen_keys)
        for claim in result.get('claims', []):
            if claim.get('kind') not in {'original_statement', 'user_statement', 'analysis', 'suggestion', 'insufficient_evidence'}:
                raise DomainError('invalid_claim', '模型未区分原话、判断和建议。', 409)
            if claim['kind'] in {'original_statement', 'user_statement'} and not claim.get('sources'):
                raise DomainError('missing_source', '模型事实缺少来源，不能作为结果。', 409)
            for ref in claim.get('sources', []):
                if ref['resource_type'] == 'memory' and claim['kind'] in {'user_statement', 'original_statement'}:
                    with self.database.transaction() as c:
                        memory = require(c, 'memories', ref['resource_id'])
                    if memory['category'] == 'analysis':
                        raise DomainError('analysis_not_user_fact', '分析记忆必须标为分析，不能作为用户陈述或原话。', 409)
                if claim['kind'] == 'user_statement' and any(s['resource_type'] == ref['resource_type'] and s['resource_id'] == ref['resource_id'] and s.get('kind') == 'original_statement' and not s.get('speaker_confirmed') for s in context.get('sources', [])):
                    raise DomainError('identity_unconfirmed', '未确认的说话人不能作为用户经历来源。', 409)
                if (ref['resource_type'], ref['resource_id'], ref['revision']) not in allowed or not self.valid_after_changes(ref, changes):
                    raise DomainError('stale_source', '引用来源已变化或超出范围，请重新运行。', 409)
                if not self.valid(ref) and not any(change['state'] == 'planned' and any(item['resource_type'] == ref['resource_type'] and item['resource_id'] == ref['resource_id'] and item['after_revision'] == ref['revision'] for item in change['items']) for change in changes): ref['historical'] = True
                if ref['resource_type'] == 'document':
                    with self.database.transaction() as c:
                        preview = next((item['after'] for change in changes if change['state'] == 'planned' for item in change['items'] if item['resource_type'] == 'document' and item['resource_id'] == ref['resource_id']), None)
                        lines = (preview or require(c, 'documents', ref['resource_id']))['content'].split('\n')
                    if type(ref.get('line', 1)) is not int or not 1 <= ref.get('line', 1) <= len(lines):
                        raise DomainError('invalid_line', '引用行超出材料范围。', 422)
                    ref.setdefault('line', 1)
        return result


def framework_tools(registry, context):
    from langchain_core.tools import StructuredTool
    tools = []
    for metadata in registry.list():
        spec = registry._tools[metadata['id']]
        if spec.effect not in context.allowed_effects: continue
        if context.frozen_context is not None and spec.effect in {'device', 'external'} and not action_allowed(spec.tool_id, context.frozen_context): continue
        # 冻结范围时只允许固定证据读取；写和设工具由执行器再次校验范围。
        if context.frozen_context is not None and spec.effect == 'read' and spec.tool_id not in {'evidence.read', 'models.status', 'system.status'}: continue
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
    def apply(args, context):
        allowed = context.resource_scope
        if context.frozen_context is not None:
            frozen = frozenset((r['resource_type'], r['resource_id']) for r in
                               context.frozen_context.get('write_resources', context.frozen_context.get('resources', [])))
            allowed = frozen if allowed is None else frozen & allowed
        return {'result': changesets.submit({'operation_id': context.operation_id,
                    'targets': [t.model_dump() for t in args.targets], 'new_documents': list(context.prepared_documents)}, allowed, context.change_plan)}
    registry.register(ToolSpec(tool_id='changesets.apply', version='1.0', title='提交范围内修改',
        description='一次事务提交用户明确授权的全部目标，校验预期版本并记录差异和撤销。',
        input_model=ApplyArguments, output_model=ResultEnvelope, effect='write',
        handler=apply))
    def read(args, context):
        if context.frozen_context is None:
            raise DomainError('scope_required', '需要先确定资料范围。', 409)
        return {'result': {'sources': context.frozen_context['sources'], 'excluded': context.frozen_context.get('excluded', []), 'tasks':context.frozen_context.get('cancel_tasks',[])}}
    registry.register(ToolSpec(tool_id='evidence.read', version='1.0', title='读取固定范围证据',
        description='读取当前消息固定范围内的完整证据、版本和无法纳入项。', input_model=EmptyArguments, output_model=ResultEnvelope, handler=read))

    from interview_backend.services.documents import DocumentService
    documents = DocumentService(changesets.database)
    class ImportDocument(BaseModel):
        model_config = ConfigDict(extra='forbid')
        title: str = Field(min_length=1)
        format: Literal['txt', 'md']
        content: str = Field(min_length=1)
    class UpdateDocument(BaseModel):
        model_config = ConfigDict(extra='forbid')
        document_id: str = Field(min_length=1)
        expected_revision: int = Field(ge=1)
        fields: dict = Field(min_length=1)
    def import_document(args, context):
        if context.frozen_context is not None and not context.frozen_context.get('allow_document_import'):
            raise DomainError('write_not_authorized', '本次消息未授权导入材料。', 403)
        if context.change_plan is not None:
            return {'result': context.change_plan.import_document(args.title, args.format, args.content)}
        return {'result': documents.import_text(args.title, args.format, args.content, context.operation_id)}
    def update_document(args, context):
        target = ChangeTarget(resource_type='document', resource_id=args.document_id,
                              expected_revision=args.expected_revision, fields=args.fields)
        return apply(ApplyArguments(targets=[target]), context)
    registry.register(ToolSpec(tool_id='documents.import', version='1.0', title='导入个人材料',
        description='导入用户明确提供的 TXT/Markdown 文本，共用材料业务接口，返回内容去重结果。',
        input_model=ImportDocument, output_model=ResultEnvelope, effect='write', handler=import_document))
    registry.register(ToolSpec(tool_id='documents.update', version='1.0', title='修改或移除材料',
        description='修改范围内材料的 title/content，或以 removed=true 移除；校验版本并保留差异与撤销。',
        input_model=UpdateDocument, output_model=ResultEnvelope, effect='write', handler=update_document))


class MetadataFields(BaseModel):
    model_config = ConfigDict(extra='forbid')
    kind: Literal['unknown', 'interview', 'other'] | None = None
    interview_date: str | None = None
    company: str | None = None
    role: str | None = None


class MetadataArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str = Field(min_length=1)
    expected_revision: int = Field(ge=1)
    fields: MetadataFields


class SpeakerRenameArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    run_id: str = Field(min_length=1)
    speaker: int = Field(ge=0)
    name: str = Field(min_length=1, max_length=200)
    expected_revision: int = Field(ge=1)


class DeviceLocateArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str = Field(min_length=1)
    run_id: str | None = None
    segment_id: str | None = None
    start: float | None = Field(default=None, ge=0)
    play: bool = True


class DeviceClipboardArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    text: str = Field(min_length=1, max_length=100000)


class DeviceExportArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str | None = None
    run_id: str | None = None
    draft_id: str | None = None
    format: Literal['txt', 'srt', 'md'] = 'txt'
    suggested_name: str | None = Field(default=None, max_length=200)


class DeviceChooseFileArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    purpose: str = Field(default='选择文件', max_length=200)
    extensions: list[str] = Field(default_factory=list, max_length=10)


class RecordingActionArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str = Field(min_length=1)


class CancelTaskArguments(RecordingActionArguments):
    task_type: Literal['audio','organize'] | None = None
    task_id: str | None = None


class OrganizeArguments(BaseModel):
    model_config = ConfigDict(extra='forbid')
    recording_id: str = Field(min_length=1)
    mode: Literal['dialogue', 'topics', 'summary'] = 'dialogue'
    instructions: str = Field(default='', max_length=2000)


class DeviceResult(BaseModel):
    command_id: str
    state: str
    result: dict | None = None
    message: str


def install_app_tools(registry, changesets, device, settings, repository, retrieval):
    from interview_backend.agent.models import ModelSettings

    def scope(context, recording_id):
        if context.frozen_context is None:
            return
        allowed = set(context.frozen_context.get('recording_ids') or [])
        if recording_id not in allowed:
            raise DomainError('scope_denied', '操作目标超出当前用户消息确定的资料范围。', 403)

    def update_metadata(args, context):
        scope(context, args.recording_id)
        fields = args.fields.model_dump(exclude_unset=True)
        if not fields:
            raise DomainError('invalid_fields', '没有需要修改的资料信息。', 422)
        return {'result': changesets.submit({'operation_id': context.operation_id, 'targets': [
            {'resource_type': 'recording', 'resource_id': args.recording_id,
             'expected_revision': args.expected_revision, 'fields': fields}]}, context.resource_scope, context.change_plan)}

    def rename_speaker(args, context):
        if context.frozen_context is not None:
            allowed = {(r['resource_type'], r['resource_id']) for r in context.frozen_context.get('resources', [])}
            if ('speaker', f'{args.run_id}:{args.speaker}') not in allowed:
                raise DomainError('scope_denied', '说话人不在当前资料范围。', 403)
        return {'result': changesets.submit({'operation_id': context.operation_id, 'targets': [
            {'resource_type': 'speaker', 'resource_id': f'{args.run_id}:{args.speaker}',
             'expected_revision': args.expected_revision, 'fields': {'name': args.name}}]}, context.resource_scope, context.change_plan)}

    async def run_device(kind, target, arguments, context, request):
        digest = hashlib.sha256(encode({'kind': kind, 'target': target, 'arguments': arguments}).encode()).hexdigest()[:16]
        command_id = 'device:' + hashlib.sha256((context.operation_id or context.request_id+':'+digest).encode()).hexdigest()
        command = device.operation(context.operation_id,request) or device.enqueue(kind, target, arguments, run_id=context.request_id, command_id=command_id, operation_id=context.operation_id, request=request)
        value = await device.wait(command['id'], timeout=10)
        state = value['state']
        message = {
            'completed': '应用已回报实际执行结果。',
            'cancelled': '用户取消了该操作，没有继续执行。',
            'failed': '应用回报操作失败。',
            'unknown': '操作结果未知，不能视为成功；请核对应用中的实际状态。',
            'running': '应用已领取命令但尚未回报，不能视为完成。',
            'pending': '命令已登记，应用尚未领取；不能视为完成。',
        }.get(state, '设备命令状态未知。')
        return {'result': {'command_id': command['id'], 'state': state,
                           'result': value['result'], 'message': message}}

    def models_status(args, context):
        status = {'configured': False, 'semantic': retrieval.semantic.status()}
        try:
            model = ModelSettings.load(settings.data_dir)
            status.update({'configured': True, 'model': model.model, 'base_url': model.base_url})
        except DomainError:
            pass
        return {'result': status}

    def system_status(args, context):
        return {'result': repository.status()}

    registry.register(ToolSpec(tool_id='library.update_metadata', version='1.0', title='修改资料信息',
        description='修改资料类型、实际面试日期、公司或岗位，校验预期版本并记录可撤销修改。',
        input_model=MetadataArguments, output_model=ResultEnvelope, effect='write', handler=update_metadata))
    registry.register(ToolSpec(tool_id='speakers.rename', version='1.0', title='重命名说话人',
        description='为指定说话人设置业务名称；自动聚类编号不代表已确认身份。',
        input_model=SpeakerRenameArguments, output_model=ResultEnvelope, effect='write', handler=rename_speaker))
    registry.register(ToolSpec(tool_id='models.status', version='1.0', title='读取模型与索引状态',
        description='报告用户配置的模型是否可用及语义索引状态，不返回密钥或私人正文。',
        input_model=EmptyArguments, output_model=ResultEnvelope, handler=models_status))
    registry.register(ToolSpec(tool_id='system.status', version='1.0', title='读取应用能力状态',
        description='读取真实能力开关和数量，不把未实现能力报告为可用。',
        input_model=EmptyArguments, output_model=ResultEnvelope, handler=system_status))

    def device_tool(tool_id, title, description, input_model, kind, argument_builder, target_builder=None, timeout=20):
        async def handler(args, context):
            arguments = argument_builder(args)
            request={'kind':kind,'arguments':arguments}
            prior=device.operation(context.operation_id,request)
            if prior: return await run_device(kind,prior['target'],prior['arguments'],context,request)
            from interview_backend.services.device_targets import prepare
            with device.database.transaction() as c:
                arguments = prepare(c, kind, arguments, context.frozen_context)
            target = arguments.get('recording_id') or (target_builder(args) if target_builder else '')
            if target:
                scope(context, target)
            return await run_device(kind, target, arguments, context, request)
        registry.register(ToolSpec(tool_id=tool_id, version='1.0', title=title, description=description,
            input_model=input_model, output_model=ResultEnvelope, effect='device', handler=handler,
            timeout_seconds=timeout))

    device_tool('device.locate', '定位并回听', '在应用中打开指定资料和片段，并按实际播放结果回报。',
        DeviceLocateArguments, 'locate', lambda a: a.model_dump(mode='json'), lambda a: a.recording_id)
    device_tool('device.copy', '复制到剪贴板', '把用户要求的文字写入本机剪贴板并回报结果。',
        DeviceClipboardArguments, 'clipboard', lambda a: a.model_dump(mode='json'))
    device_tool('device.choose_file', '选择本机文件', '在应用中打开文件选择器，用户取消时返回取消而不是成功。',
        DeviceChooseFileArguments, 'choose_file', lambda a: a.model_dump(mode='json'))
    device_tool('device.export', '导出文字或整理稿', '在应用中让用户选择保存位置并导出，按真实保存或取消结果回报。',
        DeviceExportArguments, 'export', lambda a: a.model_dump(mode='json'), lambda a: a.recording_id or '')
    device_tool('jobs.transcribe', '开始或重试转写', '把资料加入应用现有转写队列；完成情况以任务事件为准。',
        RecordingActionArguments, 'transcribe', lambda a: a.model_dump(mode='json'), lambda a: a.recording_id)
    device_tool('jobs.cancel', '取消后台任务', '取消应用正在处理的该资料任务，保留已完成部分。',
        CancelTaskArguments, 'cancel', lambda a: a.model_dump(mode='json'), lambda a: a.recording_id)
    device_tool('organize.start', '开始 AI 整理', '使用应用现有整理流程生成独立整理稿；分块完成进度会持续保存。',
        OrganizeArguments, 'organize', lambda a: a.model_dump(mode='json'), lambda a: a.recording_id)
