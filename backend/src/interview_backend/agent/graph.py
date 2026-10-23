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

    async def prepare_context(self, run_id, context, emit=None):
        from interview_backend.agent.intent import resolve, apply
        from interview_backend.agent.work import WorkLog
        # 无法定位资料或存在选区歧义时保留服务端澄清，先不发送资料。
        if context.get('clarification'):
            return context
        if emit:
            await emit('task_stage', {'message': '正在理解任务与操作限制…'})
        work = WorkLog(self.evidence.database, run_id)
        intent = work.get('task_intent')
        if intent is None:
            intent = await resolve(self.settings, self.registry, context, getattr(self, 'intent_model', None))
            work.save('task_intent', intent)
        value = apply(context, intent)
        selected = context.get('proposal_id') or intent.get('proposal_id')
        if selected and intent['mode'] == 'edit':
            from interview_backend.agent.proposals import select
            value = select(self.evidence, value, selected)
        if intent['reading'] == 'weekly' and hasattr(self, 'reports'):
            value['report_plan'] = self.reports.freeze(value, context['instruction'])
        if emit:
            await emit('task_stage', {'message': '任务范围已确定，正在读取资料…'})
        return value

    async def execute(self, run_id, instruction, context, model=None, emit=None, change_plan=None):
        from langgraph.graph import StateGraph, START, END
        from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
        from interview_backend.agent.work import WorkLog
        from interview_backend.agent.finalization import resume
        finalization=WorkLog(self.evidence.database,run_id).finalization()
        if finalization is not None: return await resume(self,run_id,finalization,emit)
        if context.get('clarification'):
            return {'answer': context['clarification'], 'clarification': context['clarification'], 'claims': [], 'coverage': {'total': 0, 'covered': 0, 'excluded': context.get('excluded', [])}}
        weekly = context.get('task_intent', {}).get('reading') == 'weekly' if context.get('task_intent') else bool(re.search(r'本周|这周|周报', instruction))
        if hasattr(self, 'reports') and not context.get('report_subtask') and weekly:
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
        from interview_backend.agent.batching import bounded, make_chunks, batch_scope, short_history, bounded_memories, MAX_INPUT_BYTES
        compact = bounded(context)
        plan = change_plan or ChangePlan(ChangeSetService(self.evidence.database), run_id + ':changes',
                    frozenset((r['resource_type'], r['resource_id']) for r in context.get('write_resources', context['resources'])),
                    field_limits=context.get('write_field_limits'),
                    revisions={(r['resource_type'],r['resource_id']):r['revision'] for r in context.get('write_resources',context['resources'])} if compact else None)
        read_context = ToolContext(request_id=run_id, allowed_effects=frozenset(effects),
                                   operation_id=run_id + ':tools', frozen_context=context, change_plan=plan,
                                   resource_scope=frozenset((r['resource_type'], r['resource_id'])
                                                            for r in context.get('write_resources', context['resources'])))
        tools = framework_tools(self.registry, read_context)
        bound = model.bind_tools(tools) if tools else model
        configuration={'model':getattr(model,'model_name',type(model).__qualname__),'tools':[(t.name,t.args_schema.model_json_schema()) for t in tools]}
        if compact: configuration['input_budget_bytes'] = MAX_INPUT_BYTES
        sources = context.get('sources', [])
        strategy = context.get('task_intent', {}).get('reading')
        full = strategy in {'selection', 'full', 'weekly'} if strategy else context.get('allow_write') or bool(re.search(r'全部|所有|本周|周报',instruction))
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
        committed = await asyncio.to_thread(self.evidence.committed, run_id)
        if not await asyncio.to_thread(self.evidence.valid_many, sources, committed):
            raise DomainError('stale_source','来源已变化，未发送过期内容。',409)
        chunks = make_chunks(sources, compact, context.get('allow_write',False))
        def live_memories():
            scopes=['global','session:'+context.get('session_id','')]+['recording:'+identifier for identifier in context.get('recording_ids',[])]
            scopes+=['document:'+r['resource_id'] for r in context.get('write_resources',context.get('resources',[])) if r['resource_type']=='document']
            items=self.memory_service.active(scopes) if hasattr(self,'memory_service') else []
            return bounded_memories(items) if compact else items
        from interview_backend.agent.coverage import Coverage
        initial_dependencies=[{k:r[k] for k in ('resource_type','resource_id','revision')} for r in sources + context.get('speaker_catalog', [])]
        initial_dependencies += [{'resource_type':'memory','resource_id':m['id'],'revision':m['revision']} for m in await asyncio.to_thread(live_memories)]
        coverage=await asyncio.to_thread(Coverage,work,chunks,context.get('excluded',[]),initial_dependencies,configuration)
        answers = []; claims = []; targets = []; covered = set(); model_questions = []; proposals = []
        all_questions = bool(re.search(r'全部.*问题|所有.*问题|问题.*汇总|列出.*问题|哪些问题', instruction))
        for i, chunk in enumerate(chunks):
            await coverage.begin(i,chunk,emit)
            if compact and emit:
                await emit('task_stage',{'message':f'正在分析第 {i+1}/{len(chunks)} 批资料，完成后统一保存…' if context.get('allow_write') else f'正在分析第 {i+1}/{len(chunks)} 批资料…'})
            memory=await asyncio.to_thread(live_memories)
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
            scope, speakers = batch_scope(context,chunk) if compact else (context['resources'],context.get('speaker_catalog',[]))
            committed = await asyncio.to_thread(self.evidence.committed,run_id)
            pending_changes=committed+([plan.preview] if plan.preview else [])
            if not await asyncio.to_thread(self.evidence.valid_many,scope,pending_changes):
                raise DomainError('stale_source','本批资料或说话人版本已变化，请基于当前资料重新提问。',409)
            current_scope=scope
            batch_keys = frozenset((r['resource_type'],r['resource_id']) for r in current_scope)
            batch_context={**context,'sources':chunk,'resources':current_scope,'speaker_catalog':speakers,'bounded_evidence':True} if compact else context
            dependencies=[{k:r[k] for k in ('resource_type','resource_id','revision')} for r in sources + context.get('speaker_catalog', [])]+[{'resource_type':'memory','resource_id':m['id'],'revision':m['revision']} for m in memory]
            prompt = {'selected_proposal':context.get('selected_proposal'), 'pending_proposals':context.get('pending_proposals',[]), 'task_intent':context.get('task_intent'), 'conversation_history':context.get('conversation_history',[]), 'history_omitted':context.get('history_omitted',False), 'selected_quotes':context.get('quotes',[]), 'device_tasks':context.get('cancel_tasks',[]), 'speaker_catalog':context.get('speaker_catalog',[]), 'write_field_limits':context.get('write_field_limits',{}), 'current_valid_memories': memory, 'instruction': instruction, 'scope': current_scope, 'untrusted_evidence': chunk,
                      'allow_write': context.get('allow_write', False), 'transcript_organization': context.get('transcript_organization', False), 'chunk': i+1, 'chunks': len(chunks)}
            if compact:
                history=short_history(context.get('conversation_history',[]))
                prompt.update(speaker_catalog=speakers,conversation_history=history,
                    history_omitted=context.get('history_omitted',False) or len(history)<len(context.get('conversation_history',[])),
                    pending_proposals=[],host_bound_revisions=True,
                    selected_quotes=[q for q in context.get('quotes',[]) if any((r['resource_type'],r['resource_id']) in batch_keys for r in q.get('sources',[]))],
                    adjacent_evidence=[{k:s[k] for k in ('text','speaker','speaker_name','start','end','run_id') if k in s}
                        for s in ((chunks[i-1][-2:] if i else [])+(chunks[i+1][:2] if i+1<len(chunks) else []))],
                    pending_speaker_names=[{'resource_id':t['resource_id'],'name':t['fields']['name']} for t in plan.targets.values() if t['resource_type']=='speaker' and 'name' in t['fields']])
                if prompt.get('selected_proposal'):
                    prompt['selected_proposal']={**prompt['selected_proposal'],'sources':[s for s in prompt['selected_proposal']['sources'] if (s['resource_type'],s['resource_id']) in batch_keys]}
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
                        call_scope=plan.allowed & (batch_keys | frozenset(('document',identifier) for identifier in plan.documents)) if compact else plan.allowed
                        call_context = replace(read_context, operation_id=f'{run_id}:tool:{digest}', resource_scope=call_scope, frozen_context=batch_context)
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
                        model_output=output
                        if compact and effect=='write' and isinstance(output.get('result'),dict) and 'items' in output['result']:
                            receipt=output['result']
                            model_output={'result':{k:receipt[k] for k in ('id','state','count') if k in receipt}}
                            model_output['result']['message']='本批建议已登记，全部批次完成后统一提交；请勿重复登记。'
                        messages.append(ToolMessage(content=encode(model_output), tool_call_id=call['id']))
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
            except DomainError as error:
                work.save('failure:'+model_key,{'code':error.code, 'details':getattr(error,'details',{})})
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
            if compact and result.get('targets'):
                try:
                    await asyncio.to_thread(plan.stage,result['targets'],batch_keys | frozenset(('document',identifier) for identifier in plan.documents))
                except DomainError as error:
                    work.save('failure:'+model_key,{'code':error.code,'details':getattr(error,'details',{})})
                    work.discard(model_key)
                    await coverage.fail(chunk,'failed',emit)
                    raise
            else: targets += result.get('targets', [])
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
            proposals += result.get('proposals') or []
            covered.update((s['resource_type'], s['resource_id']) for s in chunk)
            await coverage.complete(chunk,result,context,dependencies,emit)
        if not await asyncio.to_thread(self.evidence.valid_many,sources,await asyncio.to_thread(self.evidence.committed,run_id)):
            raise DomainError('stale_source', '运行中资料发生变化，请基于当前版本重新执行。', 409)
        result = {'answer': '\n\n'.join(answers), 'claims': claims, 'coverage':coverage.snapshot()}
        if proposals:
            from interview_backend.agent.proposals import prepare
            result['proposals'] = prepare(self.evidence, run_id, proposals, context)
        if len(answers) > 1 and context.get('task_intent') and not context.get('allow_write'):
            from interview_backend.agent.synthesis import synthesize
            summary = await synthesize(self, run_id, instruction, context,
                [{'answer': answer, 'claims': claims if i == 0 else []} for i, answer in enumerate(answers)], model, emit)
            if summary:
                result.update(summary)
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
            if not context.get('task_intent'):
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
