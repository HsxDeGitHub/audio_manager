import hashlib
import json
from interview_backend.errors import DomainError
from interview_backend.services.common import encode, once, require


class JobService:
    def __init__(self, database, library):
        self.database, self.library = database, library

    def recover(self):
        with self.database.transaction(True) as c:
            c.execute("UPDATE jobs SET state='interrupted' WHERE state IN ('queued','running')")
            c.execute("UPDATE recordings SET state='interrupted',error='上次任务未完成，可重试。' WHERE state IN ('queued','preprocessing','transcribing','diarizing')")
            c.execute("UPDATE agent_runs SET state='interrupted' WHERE state IN ('queued','running')")
            c.execute("UPDATE device_commands SET state='unknown',owner=NULL WHERE state='running'")
            c.execute("UPDATE device_commands SET state='cancelled',result=? WHERE state='pending'", (encode({'reason':'restart','message':'上次命令尚未领取，需明确继续任务。'}),))

    def get(self, identifier):
        with self.database.transaction() as c:
            row = require(c, 'jobs', identifier)
            return {**row, 'payload':json.loads(row['payload']), 'result':json.loads(row['result']) if row['result'] else None}

    def start(self, request, state='running'):
        with self.database.transaction(True) as c:
            require(c, 'recordings', request['recordingID'])
            once(c, request['jobID'] + ':start', request, lambda: self._start(c, request, state))
            if state == 'running': c.execute("UPDATE jobs SET state='running' WHERE id=? AND state='queued'",(request['jobID'],))
            return {'state':require(c,'jobs',request['jobID'])['state'], 'job_id':request['jobID']}

    def _start(self, c, request, state='running'):
        c.execute('INSERT INTO jobs(id,kind,target,state,payload) VALUES(?,?,?,?,?)',
                  (request['jobID'], 'audio', request['recordingID'], state, encode(request)))
        return {'state': state, 'job_id': request['jobID']}

    def event(self, request, event):
        with self.database.transaction(True) as c:
            job = require(c, 'jobs', request['jobID'])
            if json.loads(job['payload']) != request or event['jobID'] != request['jobID']:
                raise DomainError('wrong_job', '任务目标不一致。', 409)
            digest = hashlib.sha256(encode(event).encode()).hexdigest()
            return once(c, request['jobID'] + ':event:' + digest, event, lambda: self._event(c, request, event, job))

    def _event(self, c, request, event, job):
        if job['state'] in {'cancelled', 'completed', 'failed', 'interrupted'}:
            return {'ignored': True}
        kind = event['kind']; rid = request['recordingID']
        result = {}
        if kind == 'transcript' and event.get('segments') is not None:
            result['activated'] = self.library._execute(c, 'addTranscript', {'recordingID': rid, 'runID': request['runID'], 'segments': event['segments'], 'duration': event.get('duration')})
        elif kind == 'diarization' and event.get('turns') is not None:
            self.library._execute(c, 'applySpeakers', {'runID': request['runID'], 'turns': event['turns']})
        elif kind in {'stage', 'done', 'error'}:
            state = event.get('state') if kind == 'stage' else 'completed' if kind == 'done' else 'failed'
            if state not in {'preprocessing', 'transcribing', 'diarizing', 'completed', 'failed'}:
                raise DomainError('invalid_event', '任务状态不合法。', 422)
            # 不把后台识别器的原始诊断内容写进模型或对话。
            c.execute('UPDATE recordings SET state=?,error=? WHERE id=?', (state, '后台处理失败，可重试。' if state == 'failed' else None, rid))
            c.execute('UPDATE jobs SET state=?,result=? WHERE id=?', ('running' if kind == 'stage' else state, encode(result), request['jobID']))
        return result

    def stop(self, job_id, state):
        if state not in {'cancelled', 'interrupted', 'failed'}:
            raise DomainError('invalid_state', '停止状态不合法。', 422)
        with self.database.transaction(True) as c:
            job = require(c, 'jobs', job_id)
            if job['state'] not in {'completed', 'failed', 'cancelled', 'interrupted'}:
                c.execute('UPDATE jobs SET state=? WHERE id=?', (state, job_id))
                c.execute('UPDATE recordings SET state=? WHERE id=?', (state, job['target']))
            return {'state': state}
