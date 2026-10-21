"""与 AudioCore.AISource 的快照及 JSONEncoder(.sortedKeys) 指纹兼容。"""
import hashlib
import json
from interview_backend.services.library import default_name


def source_fingerprint(c, run_id):
    names = {r['speaker']: r['name'] for r in c.execute('SELECT * FROM speakers WHERE run_id=?', (run_id,))}
    sources = []
    for i, row in enumerate(c.execute('SELECT * FROM segments WHERE run_id=? ORDER BY start,end,id', (run_id,))):
        # Foundation 把整数形式的 Double 编码为整数；保留实际小数和指数形式。
        def time_value(value):
            return int(value) if value == int(value) and abs(value) < 1e16 else value
        sources.append({'id': row['id'], 'reference': f'S{i+1}', 'start': time_value(row['start']),
                        'end': time_value(row['end']), 'speaker': names.get(row['speaker'], default_name(row['speaker'])),
                        'text': row['edited'] if row['edited'] is not None else row['original']})
    wire = json.dumps(sources, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).replace('/', '\\/')
    return hashlib.sha256(wire.encode()).hexdigest()


def draft_current(c, row):
    try:
        payload = json.loads(row['payload'])
        return isinstance(payload, dict) and payload.get('sourceHash') == source_fingerprint(c, row['run_id'])
    except (ValueError, TypeError, KeyError):
        return False
