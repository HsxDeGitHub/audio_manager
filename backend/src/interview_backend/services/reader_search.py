"""按连续发言筛选候选并分页；客户端保留与阅读排版相同的精确高亮映射。"""
import json
from interview_backend.services.library import visible_segment


def canonical(text):
    return ''.join(c for c in text.casefold() if c.isalnum())


def search(database, term, recording_id=None, offset=0, limit=50):
    needle = canonical(term)
    candidates = []
    if not term.strip():
        return {'items':[], 'total':0, 'offset':offset, 'limit':limit}
    with database.transaction() as c:
        recordings = c.execute('SELECT id,title,active_run FROM recordings WHERE active_run IS NOT NULL' +
            (' AND id=?' if recording_id is not None else '') + ' ORDER BY created_at DESC,id',
            (recording_id,) if recording_id is not None else ()).fetchall()
        for recording in recordings:
            run = recording['active_run']
            rows = c.execute('SELECT * FROM segments WHERE run_id=? ORDER BY start,end,id',(run,)).fetchall()
            names = {str(r['speaker']):r['name'] for r in c.execute('SELECT * FROM speakers WHERE run_id=?',(run,))}
            cache = {r['cache_key']:json.loads(r['rendered']) for r in c.execute('SELECT * FROM reading_cache WHERE run_id=?',(run,))}
            groups = []
            for row in rows:
                if groups and groups[-1][-1]['speaker'] == row['speaker'] and row['start'] - groups[-1][-1]['end'] <= 8:
                    groups[-1].append(row)
                else:
                    groups.append([row])
            for group in groups:
                values = [visible_segment(row) for row in group]
                ids = {s['id'] for s in values}
                relevant = {k:v for k,v in cache.items() if ids.intersection(v)}
                variants = [''.join(s['text'] for s in values)]
                variants += [''.join(v.get(s['id'],s['text']) for s in values) for v in relevant.values()]
                # 只做候选过滤；补标点、空格和智能标点不会造成跨句漏检。
                if needle and not any(needle in canonical(text) for text in variants):
                    continue
                candidates.append({'recordingID':recording['id'],'recordingTitle':recording['title'],
                                   'segments':values,'names':names,'cache':relevant})
    return {'items':candidates[offset:offset+limit], 'total':len(candidates), 'offset':offset, 'limit':limit}
