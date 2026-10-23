import asyncio
import hashlib
from dataclasses import replace
import json
from pathlib import Path
import re
from typing import TypedDict
from interview_backend.errors import DomainError
from interview_backend.agent.models import ModelSettings
from interview_backend.agent.text_edits import needs_edit_result, validate_edit_claims
from interview_backend.prompt_catalog import load_text
from interview_backend.services.common import encode


class AgentState(TypedDict):
    instruction: str
    context: dict
    result: dict


SYSTEM = load_text('agent/system.md')


class AgentEngine:
    def __init__(self, settings, registry, evidence):
        self.settings, self.registry, self.evidence = settings, registry, evidence

    async def execute(self, run_id, instruction, context, model=None, emit=None, change_plan=None):
        from langgraph.graph import StateGraph, START, END
        from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
        from interview_backend.agent.work import WorkLog
        from interview_backend.agent.finalization import resume
        finalization=WorkLog(self.evidence.database,run_id).finalization()
        if finalization is not None: return await resume(self,run_id,finalization,emit)
        if context.get('clarification'):
            return {'answer': context['clarification'], 'clarification': context['clarification'], 'claims': [], 'coverage': {'total': 0, 'covered': 0, 'excluded': context.get('excluded', [])}}
        if hasattr(self, 'reports') and not context.get('report_subtask') and re.search(r'本周|这周|周报', instruction):
            return await self.reports.render(run_id, instruction, self, emit=emit, context=context, model=model)
        if model is None:
            model = ModelSettings.load(self.settings.data_dir).client()
        async def answer(state):
            value = await self._answer(run_id, state['instruction'], state['context'], model, emit, change_plan)
            return {'result': value}
        graph = StateGraph(AgentState)
        graph.add_node('answer', answer); graph.add_edge(START, 'answer'); graph.add_edge('answer', END)
        checkpoint_path = self.settings.backend_dir / 'checkpoints.sqlite'
        async with AsyncSqliteSaver.from_conn_string(str(checkpoint_path)) as saver:
            await saver.setup()
            compiled = graph.compile(checkpointer=saver)
            result = await compiled.ainvoke({'instruction': instruction, 'context': context, 'result': {}}, {'configurable': {'thread_id': run_id}})
            value = result['result']
            if hasattr(self, 'retrieval'):
                status = self.retrieval.semantic.status()
                value['retrieval'] = status
                if not status['ready']:
                    value['answer'] += '\n\n检索状态：' + status['message'] + ' 全量任务仍按范围完整读取。'
            return value

    async def _answer(self, run_id, instruction, context, model, emit, change_plan=None):
        from interview_backend.agent.work import WorkLog
        work = WorkLog(self.evidence.database, run_id, context.get('root_run_id',run_id))
        run_id = context.get('root_run_id', run_id)
        from langchain_core.messages import HumanMessage, SystemMessage, ToolMessage
        from interview_backend.agent.tools import framework_tools
        from interview_backend.tools.registry import ToolContext
        effects = {'read'}
        if context.get('allow_write'): effects.add('write')
        if context.get('allow_device'): effects.add('device')
        if context.get('allow_external'): effects.add('external')
        from interview_backend.services.changesets import ChangePlan, ChangeSetService
        plan = change_plan or ChangePlan(ChangeSetService(self.evidence.database), run_id + ':changes',
                    frozenset((r['resource_type'], r['resource_id']) for r in context.get('write_resources', context['resources'])),
                    field_limits=context.get('write_field_limits'))
        read_context = ToolContext(request_id=run_id, allowed_effects=frozenset(effects),
                                   operation_id=run_id + ':tools', frozen_context=context, change_plan=plan,
                                   resource_scope=frozenset((r['resource_type'], r['resource_id'])
                                                            for r in context.get('write_resources', context['resources'])))
        tools = framework_tools(self.registry, read_context)
        bound = model.bind_tools(tools) if tools else model
        configuration={'model':getattr(model,'model_name',type(model).__qualname__),'tools':[(t.name,t.args_schema.model_json_schema()) for t in tools]}
        sources = context.get('sources', [])
        full = context.get('allow_write') or bool(re.search(r'全部|所有|本周|周报',instruction))
        if hasattr(self,'retrieval') and not full and sources:
            allowed = {(r['resource_type'],r['resource_id']) for r in context['resources']}
            hits = await asyncio.to_thread(self.retrieval.search,instruction,8,allowed)
            selected = []
            for hit in hits:
                match = next((s for s in sources if s['resource_type']==hit['resource_type'] and s['resource_id']==hit['resource_id'] and s['revision']==hit['revision']),None)
                if match:
                    selected.append({**match,'text':hit['content'],'line':hit['line'],'char_start':hit['start'],'char_end':hit['end']})
                    if match['resource_type']=='segment':
                        index = sources.index(match)
                        for neighbor in sources[max(0,index-1):index+2]:
                            if neighbor.get('run_id')==match.get('run_id') and neighbor not in selected: selected.append(neighbor)
            if selected: sources = selected
        
        if not sources and not context.get('allow_document_import') and not context.get('allow_device'):
            reasons = '\n'.join(item['reason'] for item in context.get('excluded', []) if item.get('reason'))
            return {'answer': '当前范围没有可用正文，证据不足。' + ('\n' + reasons if reasons else ''), 'claims': [], 'coverage': {'total': 0, 'covered': 0, 'excluded': context.get('excluded', [])}}
        if any(not self.evidence.valid_after_changes(s,self.evidence.committed(run_id)) for s in sources):
            raise DomainError('stale_source','来源已变化，未发送过期内容。',409)
        chunks = []; current = []; length = 0
        for source in sources:
            text = source['text']
            for start in range(0, max(1, len(text)), 6000):
                part = {**source, 'text': text[start:start+6000], 'char_start':source.get('char_start',0)+start,
                        'char_end':source.get('char_start',0)+min(start+6000,len(text))}
                if source['resource_type']=='document':part['line']=source.get('line',1)+text[:start].count('\n')
                if current and length + len(part['text']) > 10000:
                    chunks.append(current); current = []; length = 0
                current.append(part); length += len(part['text'])
        if current: chunks.append(current)
        if not chunks: chunks = [[]]
        def live_memories():
            scopes=['global','session:'+context.get('session_id','')]+['recording:'+identifier for identifier in context.get('recording_ids',[])]
            scopes+=['document:'+r['resource_id'] for r in context.get('write_resources',context.get('resources',[])) if r['resource_type']=='document']
            return self.memory_service.active(scopes) if hasattr(self,'memory_service') else []
        from interview_backend.agent.coverage import Coverage
        initial_dependencies=[{k:r[k] for k in ('resource_type','resource_id','revision')} for r in sources]
        initial_dependencies += [{'resource_type':'memory','resource_id':m['id'],'revision':m['revision']} for m in live_memories()]
        coverage=Coverage(work,chunks,context.get('excluded',[]),initial_dependencies,configuration)
        answers = []; claims = []; targets = []; covered = set(); model_questions = []
        all_questions = bool(re.search(r'全部.*问题|所有.*问题|问题.*汇总|列出.*问题|哪些问题', instruction))
        for i, chunk in enumerate(chunks):
            await coverage.begin(i,chunk,emit)
            memory=live_memories()
            if memory:
                known = {(r['resource_type'], r['resource_id'], r['revision']) for r in context['resources']}
                for item in memory:
                    references = [{'resource_type': 'memory', 'resource_id': item['id'], 'revision': item['revision']}]
                    references += [{'resource_type': source['resource_type'], 'resource_id': source['resource_id'],
                                    'revision': source['revision']} for source in (item.get('sources') or [])]
                    for reference in references:
                        key = (reference['resource_type'], reference['resource_id'], reference['revision'])
                        if key not in known:
                            context['resources'].append(reference); known.add(key)
            current_scope=[r for r in context['resources'] if self.evidence.valid_after_changes(r,self.evidence.committed(run_id)+([plan.preview] if plan.preview else []))]
            dependencies=[{k:r[k] for k in ('resource_type','resource_id','revision')} for r in sources]+[{'resource_type':'memory','resource_id':m['id'],'revision':m['revision']} for m in memory]
            prompt = {'conversation_history':context.get('conversation_history',[]), 'history_omitted':context.get('history_omitted',False), 'selected_quotes':context.get('quotes',[]), 'device_tasks':context.get('cancel_tasks',[]), 'current_valid_memories': memory, 'instruction': instruction, 'scope': current_scope, 'untrusted_evidence': chunk,
                      'allow_write': context.get('allow_write', False), 'transcript_organization': context.get('transcript_organization', False), 'chunk': i+1, 'chunks': len(chunks)}
            try:
                messages = [SystemMessage(content=SYSTEM), HumanMessage(content=encode(prompt))]
                model_key = f'chunk:{i}:model:0'
                response = await work.model(model_key,bound,messages,configuration,dependencies,emit=emit)
                for turn in range(8):
                    if not response.tool_calls: break
                    messages.append(response)
                    for call_index,call in enumerate(response.tool_calls):
                        spec = next((t for t in tools if t.name == call['name']), None)
                        if spec is None:
                            raise DomainError('tool_not_allowed', '该工具在当前用户消息范围内不可用。', 403)
                        if emit: await emit('tool_start', {'tool': call['name']})
                        digest = hashlib.sha256(encode({'tool': call['name'], 'arguments': call['args']}).encode()).hexdigest()[:24]
                        call_context = replace(read_context, operation_id=f'{run_id}:tool:{digest}', resource_scope=plan.allowed)
                        # 模型只看到同源 Schema；执行仍经过统一执行器，保留参数及业务错误。
                        tool_id = next(t.tool_id for t in self.registry._tools.values() if t.framework_name == call['name'])
                        step_key = f'chunk:{i}:tool:{turn}:{digest}'
                        effect = self.registry._tools[tool_id].effect
                        business=effect in {'device','external'}
                        cached=work.effect(digest) if business else None
                        slot=f'chunk:{i}:slot:{turn}:{call_index}'
                        if business and cached is not None:
                            work.reserve(slot,tool_id,digest)
                            output=cached['output']
                            if effect=='device' and output.get('result',{}).get('command_id'):
                                from interview_backend.services.device import DeviceService
                                from interview_backend.agent.tools import command_result
                                output={'result':command_result(DeviceService(self.evidence.database).get(output['result']['command_id']))}
                            elif cached.get('legacy') or not work.valid(cached.get('dependencies',[])):
                                output={'result':{'state':'completed','operation_id':call_context.operation_id,'message':'操作已完成；旧输出的证据依赖已失效，未重新注入，也未重复执行。'}}
                        else:
                            deferred=effect=='device' and context.get('allow_write') and tool_id in {'device.export','device.copy','jobs.transcribe'}
                            if business and not deferred: work.reserve(slot,tool_id,digest)
                            if effect=='external' and work.started(digest):raise DomainError('external_result_unknown','外部工具结果未知，不能自动重复执行。',409)
                            if effect=='external':work.save('external_started:'+digest,{'state':'started'})
                            output=(await self.registry.execute(tool_id,call['args'],call_context))['data']
                            if business and output.get('result',{}).get('state')!='planned':
                                work.save('effect:'+digest,{'output':output,'dependencies':dependencies})
                            work.save(step_key,output)
                        if call['name'] == 'documents__import':
                            doc = output['result']
                            reference = {'resource_type': 'document', 'resource_id': doc['id'], 'revision': doc['revision']}
                            context['resources'].append(reference)
                            context.setdefault('write_resources', []).append(reference)
                        if emit:
                            for change in self.evidence.committed(run_id):
                                if change['id'] == call_context.operation_id: await emit('changeset', change)
                        messages.append(ToolMessage(content=encode(output), tool_call_id=call['id']))
                        if emit: await emit('tool_end', {'tool': call['name']})
                    model_key = f'chunk:{i}:model:{turn+1}'
                    response = await work.model(model_key,bound,messages,configuration,dependencies,emit=emit)
                if response.tool_calls: raise ValueError()
                content = response.content if isinstance(response.content, str) else ''.join(b.get('text', '') for b in response.content if isinstance(b, dict))
                content = re.sub(r'^```(?:json)?\s*|\s*```$', '', content.strip())
                result = json.loads(content)
                if not isinstance(result.get('answer'), str) or not isinstance(result.get('claims'), list): raise ValueError()
                if needs_edit_result(result, context, plan):
                    # 不能把自然语言里的“已登记”当作修改操作。最多补取一次结构化目标。
                    messages += [response, SystemMessage(content=load_text('agent/text-edit-result.md'))]
                    model_key += ':edit-result'
                    response = await work.model(model_key,model,messages,configuration,dependencies,emit=emit)
                    content = response.content if isinstance(response.content,str) else ''.join(b.get('text','') for b in response.content if isinstance(b,dict))
                    result = json.loads(re.sub(r'^```(?:json)?\s*|\s*```$', '', content.strip()))
                    if response.tool_calls or not isinstance(result.get('answer'),str) or not isinstance(result.get('claims'),list): raise ValueError()
                    if not result.get('targets') and not result.get('clarification') and not result.get('no_match'):
                        work.discard(model_key)
                        raise DomainError('edit_not_applied','正文尚未修改：模型没有返回可执行的修改内容。',409)
            except asyncio.CancelledError:
                await coverage.fail(chunk,'cancelled',emit)
                raise
            except DomainError:
                work.discard(model_key)
                await coverage.fail(chunk,'failed',emit)
                raise
            except Exception:
                await coverage.fail(chunk,'failed',emit)
                work.discard(model_key)
                raise DomainError('model_failed', '模型调用失败或结果结构不合法；已完成业务操作可从运行记录恢复。', 503) from None
            if result.get('clarification'):
                await coverage.fail(chunk,'pending',emit)
                return {'answer':result['clarification'],'clarification':result['clarification'],'claims':[],'coverage':coverage.snapshot()}
            try:validate_edit_claims(self.evidence,result,context,self.evidence.committed(run_id)+([plan.preview] if plan.preview else []),
                                    list(plan.targets.values())+(result.get('targets') or []))
            except DomainError:
                work.discard(model_key)
                await coverage.fail(chunk,'failed',emit)
                raise
            if result.get('targets') and not context.get('allow_write'):
                await coverage.fail(chunk,'failed',emit)
                raise DomainError('write_not_authorized', '本轮要求只读或不修改，已阻止内容写入；需要应用修改时请直接说明要执行的任务。', 403)
            targets += result.get('targets', [])
            if all_questions:
                allowed = {(r['resource_type'], r['resource_id'], r['revision']) for r in context['resources']}
                chunk_questions=[]
                pending_changes=self.evidence.committed(run_id)+([plan.preview] if plan.preview else [])
                frozen_keys={(r['resource_type'],r['resource_id']) for r in context['resources']}
                allowed.update((item['resource_type'],item['resource_id'],item['after_revision']) for change in pending_changes for item in change['items'] if (item['resource_type'],item['resource_id']) in frozen_keys)
                for question in result.get('questions') or []:
                    if not isinstance(question, dict) or not isinstance(question.get('text'), str) or not question['text'].strip():
                        continue
                    source = question.get('source')
                    if not isinstance(source, dict):
                        continue
                    reference = {key: source.get(key) for key in ('resource_type', 'resource_id', 'revision')}
                    reference.update({key:source[key] for key in ('line','block_id') if key in source})
                    if any(reference[key] is None for key in reference) or (reference['resource_type'], reference['resource_id'], reference['revision']) not in allowed:
                        continue
                    try:self.evidence.validate_result({'claims':[],'questions':[{'text':question['text'],'source':reference}]},context,pending_changes)
                    except DomainError:continue
                    start = next((s.get('start') for s in sources if s['resource_type'] == reference['resource_type'] and s['resource_id'] == reference['resource_id']), None)
                    chunk_questions.append({'text': question['text'].strip()[:2000], 'source': reference, 'start': start})
                result['questions']=chunk_questions
                model_questions += chunk_questions
            answers.append(result['answer']); claims += result['claims']
            covered.update((s['resource_type'], s['resource_id']) for s in chunk)
            await coverage.complete(chunk,result,context,dependencies,emit)
        for source in sources:
            if not self.evidence.valid_after_changes(source, self.evidence.committed(run_id)):
                raise DomainError('stale_source', '运行中资料发生变化，请基于当前版本重新执行。', 409)
        result = {'answer': '\n\n'.join(answers), 'claims': claims, 'coverage':coverage.snapshot()}
        if all_questions:
            # 标点问句做确定性兜底；模型识别结果必须再核对来源，未标点的真实录音也能进入清单。
            deterministic = [{'text': s['text'].strip(), 'source': {k: s[k] for k in ('resource_type','resource_id','revision')}, 'start': s.get('start')}
                             for s in sources if s['resource_type'] == 'segment' and re.search(r'[?？]', s['text'])]
            merged = {}
            for question in deterministic + model_questions:
                key = re.sub(r'[\W_]+', '', question['text']) + ':' + question['source']['resource_id']
                if key and key not in merged:
                    merged[key] = question
            if not merged:
                # 某些模型会把问题写进 original_statement 陈述而不填 questions；用已校验来源补全清单。
                question_hint = re.compile(r'吗|呢|什么|怎么|怎样|如何|为什么|为何|哪|谁|多少|是否|能否|能不能|可不可以|介绍一下|介绍下|说说|谈谈|讲讲|举个例子|有没有|是不是')
                for claim in claims:
                    text = claim.get('text') if isinstance(claim, dict) else None
                    sources_list = claim.get('sources') if isinstance(claim, dict) else None
                    if claim.get('kind') != 'original_statement' or not isinstance(text, str) or not text.strip() or not sources_list:
                        continue
                    if not question_hint.search(text):
                        continue
                    reference = sources_list[0]
                    start = next((s.get('start') for s in sources if s['resource_type'] == reference['resource_type'] and s['resource_id'] == reference['resource_id']), None)
                    key = re.sub(r'[\W_]+', '', text) + ':' + reference['resource_id']
                    if key and key not in merged:
                        merged[key] = {'text': text.strip()[:2000], 'source': {k: reference[k] for k in ('resource_type','resource_id','revision')}, 'start': start}
            result['questions'] = sorted(merged.values(), key=lambda q: (q.get('start') is None, q.get('start') or 0, q['source']['resource_id']))
        if result.get('questions'):
            result['answer'] += '\n\n原文问题清单：\n' + '\n'.join(f"{i+1}. {q['text']}" for i,q in enumerate(result['questions']))
            deterministic_keys = {(re.sub(r'[\W_]+', '', q['text']), q['source']['resource_id']) for q in deterministic}
            result['claims'] += [{'text':q['text'],'kind':'original_statement','sources':[q['source']]}
                                 for q in result['questions'] if (re.sub(r'[\W_]+', '', q['text']), q['source']['resource_id']) in deterministic_keys]
        committed = self.evidence.committed(run_id)
        targets = [target for target in targets if not self.evidence.fulfilled(target, committed)]
        if targets: plan.stage(targets)
        if not context.get('defer_changes'):
            from interview_backend.agent.finalization import finalize
            result = await finalize(self,run_id,result,context,plan,emit)
        work.save('answer', result)
        warnings = list(dict.fromkeys(item['reason'] for item in context.get('excluded', []) if item.get('code') == 'stale_draft'))
        if warnings: result['answer'] += '\n\n资料状态：' + '；'.join(warnings)
        return result
