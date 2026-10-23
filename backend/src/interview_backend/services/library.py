"""旧界面与新助手共用的业务接管；本模块只在后端执行写入。"""
import base64
import json
import time
from pydantic import BaseModel, ConfigDict, Field
from interview_backend.errors import DomainError
from interview_backend.services.common import require, version, bump, once, encode


class LibraryCommand(BaseModel):
    model_config = ConfigDict(extra='forbid')
    action: str
    arguments: dict = Field(default_factory=dict)
    operation_id: str | None = None
    expected_versions: dict[str, int] = Field(default_factory=dict)


def default_name(speaker):
    return '未识别' if speaker is None else '说话人 ' + (chr(65 + speaker) if 0 <= speaker < 26 else str(speaker + 1))


def visible_segment(row):
    d = dict(row)
    return dict(id=d['id'], start=d['start'], end=d['end'], original=d['original'], edited=d['edited'],
                text=d['edited'] if d['edited'] is not None else d['original'], speaker=d['speaker'],
                speakerEdited=bool(d['speaker_edited']), needsReview=bool(d['needs_review']), reviewed=bool(d['reviewed']))


def snapshot(c, run):
    require(c, 'runs', run)
    return {'items': [{k: v for k, v in visible_segment(r).items() if k in {'id', 'edited', 'speaker', 'speakerEdited', 'needsReview', 'reviewed'}}
                      for r in c.execute('SELECT * FROM segments WHERE run_id=? ORDER BY start,id', (run,))],
            'names': {str(r['speaker']): r['name'] for r in c.execute('SELECT * FROM speakers WHERE run_id=? ORDER BY speaker', (run,))}}


def restore(c, run, state):
    if not isinstance(state, dict) or 'items' not in state or 'names' not in state:
        raise DomainError('invalid_history', '撤销历史结构无效，未覆盖当前内容。', 409)
    for item in state['items']:
        c.execute('UPDATE segments SET edited=?,speaker=?,speaker_edited=?,needs_review=?,reviewed=? WHERE id=? AND run_id=?',
                  (item.get('edited'), item.get('speaker'), bool(item.get('speakerEdited')), bool(item.get('needsReview')), bool(item.get('reviewed')), item['id'], run))
        bump(c, 'segment', item['id'])
    c.execute('DELETE FROM speakers WHERE run_id=?', (run,))
    for speaker, name in state['names'].items():
        c.execute('INSERT INTO speakers VALUES(?,?,?)', (run, int(speaker), name))
        bump(c, 'speaker', f'{run}:{speaker}')


def record_edit(c, run, label, execute):
    before = snapshot(c, run)
    value = execute()
    after = snapshot(c, run)
    if before != after:
        c.execute('DELETE FROM edit_history WHERE run_id=? AND applied=0', (run,))
        c.execute('INSERT INTO edit_history(run_id,label,before_json,after_json) VALUES(?,?,?,?)', (run, label, encode(before), encode(after)))
        c.execute('DELETE FROM edit_history WHERE run_id=? AND id NOT IN (SELECT id FROM edit_history WHERE run_id=? ORDER BY id DESC LIMIT 50)', (run, run))
    return value


class LibraryService:
    reads = {'workspace', 'recordings', 'runs', 'segments', 'speakerNames', 'historyLabel', 'readingCache', 'aiDrafts', 'versions'}
    writes = {'save', 'remove', 'addTranscript', 'saveCorrection', 'editTexts', 'editSpeakers', 'markReviewed',
              'mergeSpeakers', 'restoreEdit', 'applySpeakers', 'renameSpeaker', 'saveReadingCache', 'saveAIDraft'}

    def __init__(self, database):
        self.database = database

    def execute(self, command):
        if command.action not in self.reads | self.writes:
            raise DomainError('invalid_request', '不支持的业务操作。', 422)
        try:
            with self.database.transaction(command.action in self.writes) as c:
                def apply():
                    for key, expected in command.expected_versions.items():
                        kind, identifier = key.split(':', 1)
                        if version(c, kind, identifier) != expected:
                            raise DomainError('version_conflict', '内容已发生后续修改，请刷新后重试。', 409)
                    return self._execute(c, command.action, command.arguments, command.operation_id)
                value = once(c, command.operation_id, {'action': command.action, 'arguments': command.arguments,
                             'expected_versions': command.expected_versions}, apply) if command.action in self.writes else apply()
                versions = {r['resource_type'] + ':' + r['resource_id']: r['revision'] for r in c.execute('SELECT * FROM object_versions')}
                return {'value': value, 'versions': versions}
        except (KeyError, TypeError, ValueError, OverflowError):
            raise DomainError('invalid_request', '请求参数不合法。', 422) from None

    def _execute(self, c, action, a, operation_id=None):
        run = a.get('runID')
        if action in {'runs'}:
            require(c, 'recordings', a['recordingID'])
        if action in {'segments', 'speakerNames', 'historyLabel', 'readingCache', 'aiDrafts', 'mergeSpeakers', 'restoreEdit', 'applySpeakers', 'renameSpeaker', 'saveReadingCache'}:
            require(c, 'runs', run)
        if action == 'workspace':
            recordings = self._execute(c, 'recordings', {})
            recording = next((r for r in recordings if r['id'] == a.get('recordingID')), None)
            current = {'runID': recording['activeRun']} if recording and recording['activeRun'] else None
            return {'recordings': recordings,
                    'runs': self._execute(c, 'runs', {'recordingID':recording['id']}) if recording else [],
                    'segments': self._execute(c, 'segments', current) if current else [],
                    'names': self._execute(c, 'speakerNames', current) if current else {},
                    'undo': self._execute(c, 'historyLabel', current) if current else None,
                    'redo': self._execute(c, 'historyLabel', {**current, 'redo':True}) if current else None}
        if action == 'versions':
            return None
        if action == 'recordings':
            result = []
            for r in c.execute('SELECT * FROM recordings ORDER BY created_at DESC,id'):
                result.append(dict(id=r['id'], title=r['title'], path=r['path'], bookmark=base64.b64encode(r['bookmark']).decode() if r['bookmark'] is not None else None,
                    fingerprint=r['fingerprint'], duration=r['duration'], createdAt=r['created_at'], state=r['state'], error=r['error'],
                    speakerCount=r['speaker_count'], playPosition=r['play_position'], activeRun=r['active_run'], kind=r['kind'], interviewDate=r['interview_date'],company=r['company'],role=r['role'],revision=r['revision']))
            return result
        if action == 'runs':
            return [dict(id=r['id'], createdAt=r['created_at'], hasEdits=any(s.get('edited') is not None or s['speakerEdited'] or s['reviewed'] for s in snapshot(c, r['id'])['items'])
                    or any(v != default_name(int(k)) for k, v in snapshot(c, r['id'])['names'].items()))
                    for r in c.execute('SELECT * FROM runs WHERE recording_id=? ORDER BY created_at DESC,id', (a['recordingID'],))]
        if action == 'segments':
            return [visible_segment(r) for r in c.execute('SELECT * FROM segments WHERE run_id=? ORDER BY start,id', (run,))]
        if action == 'speakerNames':
            return snapshot(c, run)['names']
        if action == 'historyLabel':
            row = c.execute('SELECT label FROM edit_history WHERE run_id=? AND applied=? ORDER BY id ' + ('ASC' if a.get('redo') else 'DESC') + ' LIMIT 1', (run, 0 if a.get('redo') else 1)).fetchone()
            return row[0] if row else None
        if action == 'readingCache':
            return {r['cache_key']: json.loads(r['rendered']) for r in c.execute('SELECT * FROM reading_cache WHERE run_id=?', (run,))}
        if action == 'aiDrafts':
            return [json.loads(r[0]) for r in c.execute('SELECT payload FROM ai_drafts WHERE run_id=? ORDER BY created_at DESC,id', (run,))]
        if action == 'save':
            r = a['recording']
            if not isinstance(r['title'], str) or not r['title'].strip():
                raise ValueError()
            old = c.execute('SELECT * FROM recordings WHERE id=?', (r['id'],)).fetchone()
            active = r.get('activeRun')
            if active and require(c, 'runs', active)['recording_id'] != r['id']:
                raise DomainError('wrong_scope', '转写版本不属于此资料。', 409)
            c.execute('''INSERT INTO recordings(id,title,path,bookmark,fingerprint,duration,created_at,state,error,speaker_count,play_position,active_run)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,path=excluded.path,bookmark=excluded.bookmark,
                fingerprint=excluded.fingerprint,duration=excluded.duration,state=excluded.state,error=excluded.error,
                speaker_count=excluded.speaker_count,play_position=excluded.play_position,active_run=excluded.active_run''',
                (r['id'], old['title'] if old else r['title'], r['path'], base64.b64decode(r['bookmark'], validate=True) if r.get('bookmark') is not None else None, r['fingerprint'],
                 r['duration'], r['createdAt'], r['state'], r.get('error'), r.get('speakerCount'), r['playPosition'], active))
            if old is None or any(old[k] != r.get(v) for k, v in [('path','path'), ('active_run','activeRun'), ('speaker_count','speakerCount')]):
                bump(c, 'recording', r['id'])
            if old and old['title'] != r['title']:
                from interview_backend.services.changesets import ChangeSetService, ChangeRequest
                return ChangeSetService(self.database)._apply(c, ChangeRequest(operation_id=operation_id, targets=[{'resource_type':'recording', 'resource_id':r['id'], 'expected_revision':version(c,'recording',r['id']), 'fields':{'title':r['title']}}]), None)
            return None
        if action == 'remove':
            require(c, 'recordings', a['id'])
            for r in c.execute('SELECT id FROM runs WHERE recording_id=?', (a['id'],)).fetchall():
                for s in c.execute('SELECT id FROM segments WHERE run_id=?', (r[0],)).fetchall():
                    bump(c, 'segment', s[0])
            bump(c, 'recording', a['id'])
            c.execute('DELETE FROM recordings WHERE id=?', (a['id'],))
            return None
        if action == 'addTranscript':
            recording = require(c, 'recordings', a['recordingID'])
            protected = recording['active_run'] and self._protected(snapshot(c, recording['active_run']))
            c.execute('INSERT INTO runs VALUES(?,?,?)', (a['runID'], a['recordingID'], time.time()))
            for s in a['segments']:
                if not isinstance(s['original'], str) or s['start'] < 0 or s['end'] < s['start']:
                    raise ValueError()
                c.execute('INSERT INTO segments(id,run_id,start,end,original,edited,speaker,speaker_edited,needs_review,reviewed) VALUES(?,?,?,?,?,?,?,?,?,?)',
                          (s['id'], a['runID'], s['start'], s['end'], s['original'], s.get('edited'), s.get('speaker'), bool(s.get('speakerEdited')), bool(s.get('needsReview')), bool(s.get('reviewed'))))
            c.execute('UPDATE recordings SET active_run=?,duration=max(duration,?) WHERE id=?',
                      (recording['active_run'] if protected else a['runID'], a.get('duration') or 0, recording['id']))
            bump(c, 'recording', recording['id'])
            return not bool(protected)
        if action == 'saveAIDraft':
            draft = a['draft']; require(c, 'runs', draft['runID'])
            prior = c.execute('SELECT * FROM ai_drafts WHERE id=?', (draft['id'],)).fetchone()
            if prior and prior['run_id'] != draft['runID']:
                raise DomainError('wrong_scope', '整理稿版本不一致。', 409)
            c.execute('INSERT INTO ai_drafts VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload', (draft['id'], draft['runID'], draft['createdAt'], encode(draft)))
            bump(c, 'draft', draft['id'])
            return None
        if action == 'saveReadingCache':
            if not all(isinstance(k, str) and isinstance(v, str) for k, v in a['rendered'].items()):
                raise ValueError()
            c.execute('INSERT INTO reading_cache VALUES(?,?,?) ON CONFLICT(run_id,cache_key) DO UPDATE SET rendered=excluded.rendered', (run, a['key'], encode(a['rendered'])))
            c.execute('DELETE FROM reading_cache WHERE run_id=? AND rowid NOT IN (SELECT rowid FROM reading_cache WHERE run_id=? ORDER BY rowid DESC LIMIT 1000)', (run, run))
            return None
        if action == 'restoreEdit':
            row = c.execute('SELECT * FROM edit_history WHERE run_id=? AND applied=? ORDER BY id ' + ('ASC' if a.get('redo') else 'DESC') + ' LIMIT 1', (run, 0 if a.get('redo') else 1)).fetchone()
            if not row:
                return False
            current, expected = snapshot(c, run), json.loads(row['before_json' if a.get('redo') else 'after_json'])
            def normalized(state):
                if not isinstance(state, dict) or 'items' not in state or 'names' not in state:
                    return None
                return {'names': state['names'], 'items': [{k: item.get(k, False if k in {'speakerEdited', 'needsReview', 'reviewed'} else None)
                    for k in ['id', 'edited', 'speaker', 'speakerEdited', 'needsReview', 'reviewed']} for item in state['items']]}
            if normalized(current) != normalized(expected):
                raise DomainError('history_conflict', '后续内容与撤销记录冲突，未覆盖当前内容。', 409)
            restore(c, run, json.loads(row['after_json' if a.get('redo') else 'before_json']))
            c.execute('UPDATE edit_history SET applied=? WHERE id=?', (1 if a.get('redo') else 0, row['id']))
            return True
        if action == 'applySpeakers':
            ordered = sorted(a['turns'], key=lambda t: t['start'])
            mapping = {speaker: i for i, speaker in enumerate(dict.fromkeys(t['speaker'] for t in ordered))}
            for row in c.execute('SELECT * FROM segments WHERE run_id=? ORDER BY start,id', (run,)).fetchall():
                if row['speaker_edited'] or row['reviewed']:
                    continue
                weights = {}
                for t in ordered:
                    overlap = min(row['end'], t['end']) - max(row['start'], t['start'])
                    if overlap > 0:
                        index = mapping[t['speaker']]; weights[index] = weights.get(index, 0) + overlap
                ranked = sorted(weights, key=lambda k: (-weights[k], k))
                c.execute('UPDATE segments SET speaker=?,needs_review=? WHERE id=?', (ranked[0] if ranked else None, len(ranked) != 1, row['id']))
                bump(c, 'segment', row['id'])
            c.execute('DELETE FROM edit_history WHERE run_id=?', (run,))
            for row in c.execute('SELECT DISTINCT speaker FROM segments WHERE run_id=? AND speaker IS NOT NULL', (run,)).fetchall():
                c.execute('INSERT OR IGNORE INTO speakers VALUES(?,?,?)', (run, row[0], default_name(row[0])))
            return None
        if action in {'renameSpeaker', 'mergeSpeakers'}:
            def change():
                if action == 'renameSpeaker':
                    speaker = a['speaker']; name = ' '.join(a['name'].splitlines()).strip()
                    if type(speaker) is not int or speaker < 0 or not name:
                        raise ValueError()
                    c.execute('INSERT INTO speakers VALUES(?,?,?) ON CONFLICT(run_id,speaker) DO UPDATE SET name=excluded.name', (run, speaker, name))
                    bump(c, 'speaker', f'{run}:{speaker}')
                else:
                    if type(a['target']) is not int or a['target'] < 0 or any(type(s) is not int or s < 0 for s in a['sources']):
                        raise ValueError()
                    for source in set(a['sources']) - {a['target']}:
                        for s in c.execute('SELECT id FROM segments WHERE run_id=? AND speaker=?', (run, source)).fetchall():
                            bump(c, 'segment', s[0])
                        c.execute('UPDATE segments SET speaker=?,speaker_edited=1 WHERE run_id=? AND speaker=?', (a['target'], run, source))
                        c.execute('DELETE FROM speakers WHERE run_id=? AND speaker=?', (run, source))
                        bump(c, 'speaker', f'{run}:{source}')
                    c.execute('INSERT OR IGNORE INTO speakers VALUES(?,?,?)', (run, a['target'], default_name(a['target'])))
            return record_edit(c, run, '重命名说话人' if action == 'renameSpeaker' else '合并说话人', change)
        ids = list(a['edits']) if action == 'editTexts' else a.get('segmentIDs', [a.get('segmentID')])
        if not ids:
            return None
        rows = [require(c, 'segments', identifier) for identifier in ids]
        if len({r['run_id'] for r in rows}) != 1:
            raise DomainError('wrong_scope', '校对只能修改同一转写版本的句子。', 422)
        def change_segments():
            for row in rows:
                identifier = row['id']
                if action == 'editTexts':
                    text = a['edits'][identifier]
                    if not isinstance(text, str):
                        raise ValueError()
                    c.execute('UPDATE segments SET edited=? WHERE id=?', (text, identifier))
                elif action == 'saveCorrection':
                    if a.get('text') is not None:
                        if not isinstance(a['text'], str):
                            raise ValueError()
                        c.execute('UPDATE segments SET edited=? WHERE id=?', (a['text'], identifier))
                    if a.get('markReviewed'):
                        c.execute('UPDATE segments SET reviewed=1 WHERE id=?', (identifier,))
                elif action == 'editSpeakers':
                    speaker = a.get('speaker')
                    if speaker is not None and (type(speaker) is not int or speaker < 0):
                        raise ValueError()
                    c.execute('UPDATE segments SET speaker=?,speaker_edited=1,needs_review=0 WHERE id=?', (speaker, identifier))
                elif action == 'markReviewed':
                    if type(a['reviewed']) is not bool:
                        raise ValueError()
                    c.execute('UPDATE segments SET reviewed=?,needs_review=1 WHERE id=?', (a['reviewed'], identifier))
                else:
                    raise ValueError()
                bump(c, 'segment', identifier)
        return record_edit(c, rows[0]['run_id'], {'editTexts': '修改文字', 'saveCorrection': '校对句子', 'editSpeakers': '修改说话人归属', 'markReviewed': '标记核对状态'}[action], change_segments)

    @staticmethod
    def _protected(state):
        return any(s.get('edited') is not None or s['speakerEdited'] or s['reviewed'] for s in state['items']) or any(name != default_name(int(k)) for k, name in state['names'].items())

    def update_metadata(self, identifier, fields, revision, operation_id):
        from interview_backend.services.changesets import ChangeSetService
        if set(fields) - {'title','kind','interview_date','company','role'}:
            raise DomainError('invalid_metadata','资料信息字段不正确。',422)
        return ChangeSetService(self.database).submit({'operation_id':operation_id,'targets':[{'resource_type':'recording','resource_id':identifier,'expected_revision':revision,'fields':fields}]})
