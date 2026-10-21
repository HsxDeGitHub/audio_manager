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

    async def render(self, run_id, instruction, engine, as_of=None, emit=None):
        plan = self.plan(as_of); items = []; claims = []; failed = []
        for recording in plan['targets']:
            if not recording['active_run'] or recording['state'] != 'completed':
                failed.append({'id': recording['id'], 'title': recording['title'], 'reason': '转写或处理未完成'}); continue
            try:
                context = self.evidence.freeze({'recording_id': recording['id']}, instruction)
                context['report_subtask'] = True
                value = await engine.execute(run_id + ':' + recording['id'], instruction, context)
                items.append({'id': recording['id'], 'title': recording['title'], 'date': recording['interview_date'], 'result': value})
                claims += value.get('claims', [])
            except DomainError as error:
                failed.append({'id': recording['id'], 'title': recording['title'], 'reason': error.message})
            if emit: await emit('coverage', {'covered': len(items), 'total': len(plan['targets'])})
        description = f"本周面试（{plan['start']} 至 {plan['end_exclusive']} 前）：共 {len(plan['targets'])} 场，完成分析 {len(items)} 场。"
        answer = '\n\n'.join([description] + [f"{r['date']} · {r['title']}\n{r['result']['answer']}" for r in items])
        if failed or plan['excluded']:
            answer += '\n\n未纳入或未完成：\n' + '\n'.join(f"{r['title']}：{r['reason']}" for r in failed + plan['excluded'])
        return {'answer': answer, 'claims': claims, 'report': {**plan, 'items': items}, 'coverage': {'total': len(plan['targets']), 'covered': len(items), 'excluded': failed + plan['excluded']}}
