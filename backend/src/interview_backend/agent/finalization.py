"""内容事务与提交后设备步骤各自持久化，模型及设备等待不占用写事务。"""
import copy
from interview_backend.errors import DomainError
from interview_backend.agent.work import WorkLog
from interview_backend.agent.text_edits import text_only_targets, transcript_targets, validate_edit_claims
from interview_backend.tools.registry import ToolContext


def device_context(evidence, context, changes):
    value=copy.deepcopy(context)
    after={(i['resource_type'],i['resource_id']):i['after_revision'] for change in changes if change['state']=='committed' for i in change['items']}
    for target in value.get('device_targets',[]):
        for ref in target['versions']:
            key=(ref['resource_type'],ref['resource_id'])
            if key in after:
                if not evidence.valid_after_changes(ref,changes): raise DomainError('stale_context','提交后目标存在外部修改，设备步骤未执行。',409)
                ref['revision']=after[key]
    return value


def describe(result):
    if not result.get('device_results'): return result
    labels={'device.export':'导出','device.copy':'复制','organize.start':'整理','jobs.transcribe':'转写'}
    states={'completed':'已完成','pending':'等待应用领取','running':'已领取，等待实际结果','cancelled':'已取消','failed':'失败','unknown':'结果未知，未重放','planned':'尚未执行'}
    changes=result.get('changesets',[])
    lines=[f"内容修改已提交 {sum(c['count'] for c in changes if c['state']=='committed')} 项。" if changes else '内容分析已完成。']
    lines += [f"{labels.get(item['tool_id'],'设备操作')}：{states.get(item['state'],item['state'])}" for item in result['device_results']]
    result['answer']='\n'.join(lines)
    return result


async def finalize(engine,run_id,result,context,plan,emit=None):
    work=WorkLog(engine.evidence.database,run_id)
    payload={'result':result,'context':context,'allowed':[list(k) for k in plan.allowed] if plan.allowed is not None else None,
             'request':{'operation_id':plan.operation_id,'targets':list(plan.targets.values()),'new_documents':list(plan.documents.values())} if plan.targets else None,
             'preview':plan.preview,'steps':list(plan.device_actions.values())}
    work.save('finalization',payload)
    return await resume(engine,run_id,payload,emit)


async def resume(engine,run_id,payload,emit=None):
    evidence=engine.evidence; work=WorkLog(evidence.database,run_id)
    result=copy.deepcopy(payload['result']); context=payload['context']; request=payload['request']
    changes=evidence.committed(run_id)
    prior=next((c for c in changes if request and c['id']==request['operation_id']),None)
    if prior and prior['state']=='reverted': raise DomainError('reverted_operation','本次修改已撤销，未重复提交或执行后续步骤。',409)
    if any(not evidence.valid_after_changes(s,changes) for s in context.get('sources',[]) + context.get('speaker_catalog',[])):
        raise DomainError('stale_source','运行来源已有外部变化，请重新指定任务。',409)
    validate_edit_claims(evidence,result,context,changes+([payload['preview']] if payload.get('preview') else []),request['targets'] if request else [])
    if request and not prior:
        evidence.validate_result(result,context,changes+([payload['preview']] if payload['preview'] else []))
        call=ToolContext(request_id=run_id,operation_id=request['operation_id'],allowed_effects=frozenset({'write'}),
                         resource_scope=frozenset(tuple(k) for k in payload['allowed']) if payload['allowed'] is not None else None,
                         prepared_documents=tuple(request['new_documents']))
        await engine.registry.execute('changesets.apply',{'targets':request['targets']},call)
        changes=evidence.committed(run_id)
        if emit:
            for change in changes: await emit('changeset',change)
    evidence.validate_result(result,context,changes)
    if changes:
        result['changesets']=changes
        if len(changes)==1:result['changeset']=changes[0]
        result['historical_sources']=[{**{k:s[k] for k in ('resource_type','resource_id','revision')},'historical':True}
                                      for s in context.get('sources',[]) if not evidence.valid(s)]
    steps=payload['steps']
    if steps: result['device_results']=[{'tool_id':s['tool_id'],'step_id':s['operation_id'],'state':'planned'} for s in steps]
    for index,step in enumerate(steps):
        if emit:await emit('tool_start',{'tool':step['tool_id']})
        frozen=device_context(evidence,context,changes)
        call=ToolContext(request_id=run_id,operation_id=step['operation_id'],allowed_effects=frozenset({'device'}),frozen_context=frozen)
        output=(await engine.registry.execute(step['tool_id'],step['arguments'],call))['data']['result']
        result['device_results'][index]={**output,'tool_id':step['tool_id'],'step_id':step['operation_id']}
        work.save('finalization_result',describe(result))
        if emit:await emit('tool_end',{'tool':step['tool_id'],'state':output['state']})
        if output['state'] in {'pending','running'}:
            result['incomplete']=True;work.save('finalization_result',describe(result));return result
        if output['state']!='completed':
            raise DomainError('device_step_'+output['state'],'内容结果已保留；设备步骤'+{'cancelled':'已取消，可继续未完成步骤。','failed':'失败，请检查后继续。','unknown':'结果未知，请先核对实际状态，不会自动重放。'}.get(output['state'],'未完成。'),409)
    evidence.validate_result(result,context,changes)
    result.pop('incomplete',None)
    if request and text_only_targets(request['targets']) and not steps:
        count=sum(change['count'] for change in changes if change['state']=='committed')
        result['answer']=f'已更新左侧正文 {count} 处，可在修改记录中撤销。'
    elif request and transcript_targets(request['targets']) and not steps:
        items = [i for change in changes if change['state']=='committed' for i in change['items']]
        counts = [('发言归属', sum(i['resource_type']=='segment' and i['before']['speaker']!=i['after']['speaker'] for i in items)),
                  ('说话人名称', sum(i['resource_type']=='speaker' for i in items)),
                  ('正文', sum(i['resource_type']=='segment' and i['before']['edited']!=i['after']['edited'] for i in items)),
                  ('核对状态', sum(i['resource_type']=='segment' and any(i['before'][k]!=i['after'][k] for k in ('needs_review','reviewed')) for i in items))]
        summary = '、'.join(f'{label} {count} 处' for label,count in counts if count)
        status = f'已更新{summary}，可在修改记录中整次撤销。' if summary else '本次没有需要保存的差异。'
        result['answer'] = status + ('\n\n' + result['answer'] if result.get('answer') else '')
    work.save('finalization_result',describe(result))
    return result
