"""取消面向具体任务身份，任务进度与内容版本不构成取消冲突。"""
import json
from interview_backend.errors import DomainError
from interview_backend.services.common import require

ACTIVE={'queued','running'}


def task(c,kind,identifier):
    if kind=='audio':
        row=require(c,'jobs',identifier)
        if row['kind']!='audio': raise DomainError('wrong_task','任务类型不符。',409)
        return {'id':identifier,'task_type':kind,'recording_id':row['target'],'state':row['state']}
    if kind=='organize':
        row=require(c,'ai_drafts',identifier); run=require(c,'runs',row['run_id'])
        state=json.loads(row['payload']).get('state','unknown')
        return {'id':identifier,'task_type':kind,'recording_id':run['recording_id'],'state':'interrupted' if state in ACTIVE else state}
    raise DomainError('invalid_task','任务类型不正确。',422)


def active_tasks(c,recording_id):
    values=[task(c,'audio',r[0]) for r in c.execute("SELECT id FROM jobs WHERE kind='audio' AND target=? AND state IN ('queued','running')",(recording_id,))]
    return values


def prepare_cancel(c,args,context):
    identifier=args['recording_id'];require(c,'recordings',identifier)
    if context is not None:
        if identifier not in context.get('recording_ids',[]):raise DomainError('scope_denied','取消目标超出固定范围。',403)
        values=[t for t in context.get('cancel_tasks',[]) if t['recording_id']==identifier]
    else: values=active_tasks(c,identifier)
    if args.get('task_type'):values=[t for t in values if t['task_type']==args['task_type']]
    if args.get('task_id'):values=[t for t in values if t['id']==args['task_id']]
    if not values:raise DomainError('no_active_task','固定范围没有可取消的活动任务；目标可能已结束或被替换。',409)
    if len(values)!=1:raise DomainError('ambiguous_task','存在多个任务，请指定转写任务标识。',409)
    chosen=values[0]; current=task(c,chosen['task_type'],chosen['id'])
    if current['recording_id']!=identifier:raise DomainError('scope_denied','任务已不属于固定资料。',403)
    return {**args,'task_type':chosen['task_type'],'task_id':chosen['id'],
            'frozen_target':{'recording_id':identifier,'run_id':None,'versions':[],
                             'task':{'task_type':chosen['task_type'],'id':chosen['id']}}}
