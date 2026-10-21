import asyncio
from interview_backend.services.reports import ReportService
from interview_backend.agent.tools import EvidenceService


def test_week_uses_actual_dates_type_and_complete_target_list(client):
    db = client.app.state.database
    with db.transaction(True) as c:
        c.execute("UPDATE recordings SET kind='interview', interview_date='2026-10-19' WHERE id='r1'")
        c.execute("UPDATE recordings SET kind='interview', interview_date=NULL WHERE id='r2'")
        for i, day in enumerate(['2026-10-18','2026-10-25','2026-10-26']):
            c.execute('INSERT INTO recordings(id,title,path,fingerprint,duration,created_at,state,play_position,kind,interview_date) VALUES(?,?,?,?,?,?,?,?,?,?)', (f'w{i}', f'合成{i}', '/synthetic',str(i),1,1,'idle',0,'interview',day))
    report = ReportService(db, EvidenceService(db))
    plan = report.plan('2026-10-21')
    assert plan['start'] == '2026-10-19' and plan['end_exclusive'] == '2026-10-26'
    assert {r['id'] for r in plan['targets']} == {'r1','w1'}
    assert plan['excluded'][0]['reason'] == '实际面试日期未知'
    class Engine:
        async def execute(self, *args, **kwargs): return {'answer': '合成分析', 'claims': []}
    result = asyncio.run(report.render('weekly', '逐份分析本周面试', Engine(), '2026-10-21'))
    assert result['coverage']['total'] == 2 and result['coverage']['covered'] == 1
    assert len(result['coverage']['excluded']) == 2
