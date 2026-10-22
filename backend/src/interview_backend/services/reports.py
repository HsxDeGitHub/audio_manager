from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from interview_backend.errors import DomainError


class ReportService:
    def __init__(self, database, evidence): self.database, self.evidence = database, evidence

    def plan(self, as_of=None):
        try:
            day = date.fromisoformat(as_of) if as_of else datetime.now(ZoneInfo('Asia/Shanghai')).date()
        except ValueError:
            raise DomainError('invalid_date', '周报日期需为 YYYY-MM-DD。', 422) from None
        start = day - timedelta(days=day.weekday()); end = start + timedelta(days=7)
        targets = []; excluded = []
        with self.database.transaction() as c:
            for row in c.execute('SELECT * FROM recordings ORDER BY interview_date,id'):
                r = {key:row[key] for key in ['id','title','kind','interview_date','company','role','state','active_run','revision']}
                if r['kind'] != 'interview': excluded.append({'id': r['id'], 'title': r['title'], 'reason': '尚未分类' if r['kind'] == 'unknown' else '非面试资料'})
                elif r['interview_date'] is None: excluded.append({'id': r['id'], 'title': r['title'], 'reason': '实际面试日期未知'})
                elif start.isoformat() <= r['interview_date'] < end.isoformat(): targets.append(r)
        return {'start': start.isoformat(), 'end_exclusive': end.isoformat(), 'timezone': 'Asia/Shanghai', 'targets': targets, 'excluded': excluded}

    def freeze(self, parent, instruction, as_of=None):
        plan = self.plan(as_of)
        contexts = {}
        allowed = {(r['resource_type'], r['resource_id']) for r in parent.get('write_resources', [])}
        for recording in plan['targets']:
            child = self.evidence.freeze({'recording_id': recording['id'], 'run_id': recording['active_run']}, '完整读取资料')
            child['write_resources'] = [r for r in child['resources'] if (r['resource_type'], r['resource_id']) in allowed]
            child['allow_write'] = bool(parent.get('allow_write') and child['write_resources'])
            child['allow_device'] = parent.get('allow_device', False) and recording['id'] in parent.get('recording_ids', [])
            child['allowed_actions'] = parent.get('allowed_actions', []) if child['allow_device'] else []
            child.update(report_subtask=True, defer_changes=True, instruction=instruction)
            contexts[recording['id']] = child
        return {**plan, 'contexts': contexts}

    async def render(self, run_id, instruction, engine, as_of=None, emit=None, context=None, model=None):
        from interview_backend.services.changesets import ChangePlan, ChangeSetService
        from interview_backend.tools.registry import ToolContext
        parent = context or self.evidence.freeze({'scope': 'all'}, instruction)
        frozen = parent.get('report_plan') or self.freeze(parent, instruction, as_of)
        plan = {k: v for k, v in frozen.items() if k != 'contexts'}
        allowed = frozenset((r['resource_type'], r['resource_id']) for r in parent.get('write_resources', []))
        batch = ChangePlan(ChangeSetService(self.database), run_id + ':changes', allowed)
        items = []; claims = []; failed = []
        for recording in plan['targets']:
            if not recording['active_run'] or recording['state'] != 'completed':
                failed.append({'id': recording['id'], 'title': recording['title'], 'reason': '转写或处理未完成'}); continue
            child = {**frozen['contexts'][recording['id']], 'root_run_id': run_id}
            try:
                if any(not self.evidence.valid_after_changes(r, self.evidence.committed(run_id)) for r in child['resources']):
                    raise DomainError('stale_context', '周目标内容已变化，请基于当前资料重新执行。', 409)
                value = await engine.execute(run_id + ':' + recording['id'], instruction, child, model=model, emit=emit, change_plan=batch)
                if value.get('clarification') and parent.get('allow_write'):
                    raise DomainError('ambiguous_change', value['clarification'], 409)
                items.append({'id': recording['id'], 'title': recording['title'], 'date': recording['interview_date'], 'result': value})
                claims += value.get('claims', [])
            except DomainError as error:
                if parent.get('allow_write'): raise
                failed.append({'id': recording['id'], 'title': recording['title'], 'reason': error.message})
            if emit: await emit('coverage', {'covered': len(items), 'total': len(plan['targets']), 'completed_ids': [i['id'] for i in items], 'failed': failed})
        description = f"本周面试（{plan['start']} 至 {plan['end_exclusive']} 前）：共 {len(plan['targets'])} 场，完成分析 {len(items)} 场。"
        answer = '\n\n'.join([description] + [f"{r['date']} · {r['title']}\n{r['result']['answer']}" for r in items])
        if failed or plan['excluded']:
            answer += '\n\n未纳入或未完成：\n' + '\n'.join(f"{r['title']}：{r['reason']}" for r in failed + plan['excluded'])
        result = {'answer': answer, 'claims': claims, 'report': {**plan, 'items': items}, 'coverage': {'total': len(plan['targets']), 'covered': len(items), 'excluded': failed + plan['excluded']}}
        read_resources = [r for child in frozen['contexts'].values() for r in child.get('resources', [])]
        if any(not self.evidence.valid_after_changes(r, self.evidence.committed(run_id)) for r in read_resources):
            raise DomainError('stale_context', '周报运行中来源发生变化，请基于当前资料重新执行。', 409)
        if batch.targets:
            if failed: raise DomainError('incomplete_batch', '批量目标尚未全部完成，整次修改未提交。', 409)
            call = ToolContext(request_id=run_id, operation_id=batch.operation_id, allowed_effects=frozenset({'write'}), resource_scope=batch.allowed, prepared_documents=tuple(batch.documents.values()))
            await engine.registry.execute('changesets.apply', {'targets': list(batch.targets.values())}, call)
        changes = self.evidence.committed(run_id)
        self.evidence.validate_result(result, {'resources':read_resources, 'sources':[s for child in frozen['contexts'].values() for s in child.get('sources', [])]}, changes)
        if changes:
            result['changesets'] = changes
            if len(changes) == 1: result['changeset'] = changes[0]
            if emit:
                for change in changes: await emit('changeset', change)
        return result
