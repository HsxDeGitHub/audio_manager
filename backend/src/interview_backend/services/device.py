"""设备命令账本：后端只登记命令，真实结果由客户端回报，不用“已发送”冒充完成。"""
import hashlib
import json
import time
import uuid
import asyncio
from interview_backend.errors import DomainError
from interview_backend.services.common import encode, require, once

KINDS = {'locate', 'clipboard', 'export', 'choose_file', 'transcribe', 'cancel'}
TERMINAL = {'completed', 'cancelled', 'failed', 'unknown'}


def _text(value, field, maximum=20000):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise DomainError('invalid_device_arguments', f'设备命令参数 {field} 不正确。', 422)
    return value


def _optional_text(value, field, maximum=20000):
    if value is None:
        return None
    return _text(value, field, maximum)


def validate_arguments(kind, arguments):
    if kind == 'organize':
        raise DomainError('organize_retired', '独立整理稿流程已停用，请让听阅助手直接整理正文。', 409)
    if not isinstance(arguments, dict) or kind not in KINDS:
        raise DomainError('invalid_device_command', '设备命令类型或参数不正确。', 422)
    value = dict(arguments)
    if kind == 'locate':
        result = {'recording_id': _text(value.get('recording_id'), 'recording_id'),
                  'run_id': _optional_text(value.get('run_id'), 'run_id'),
                  'segment_id': _optional_text(value.get('segment_id'), 'segment_id'),
                  'play': value.get('play', True)}
        start = value.get('start')
        if start is not None and (type(start) not in {int, float} or start < 0):
            raise DomainError('invalid_device_arguments', '定位时间不正确。', 422)
        result['start'] = start
        if type(result['play']) is not bool:
            raise DomainError('invalid_device_arguments', '播放参数不正确。', 422)
        return result
    if kind == 'clipboard':
        return {'text': _text(value.get('text'), 'text', 100000)}
    if kind == 'export':
        if value.get('format') not in {'txt', 'srt', 'md'}:
            raise DomainError('invalid_device_arguments', '导出格式只支持 txt、srt 或 md。', 422)
        result = {'format': value['format'],
                  'recording_id': _optional_text(value.get('recording_id'), 'recording_id'),
                  'run_id': _optional_text(value.get('run_id'), 'run_id'),
                  'draft_id': _optional_text(value.get('draft_id'), 'draft_id'),
                  'suggested_name': _optional_text(value.get('suggested_name'), 'suggested_name', 200)}
        if not result['recording_id'] and not result['draft_id']:
            raise DomainError('invalid_device_arguments', '导出需要资料或整理稿标识。', 422)
        if result['draft_id'] and not result['run_id']:
            raise DomainError('invalid_device_arguments', '导出整理稿需要转写版本标识。', 422)
        return result
    if kind == 'choose_file':
        extensions = value.get('extensions', [])
        if not isinstance(extensions, list) or len(extensions) > 10 or not all(
                isinstance(item, str) and 1 <= len(item) <= 16 and item.isalnum() for item in extensions):
            raise DomainError('invalid_device_arguments', '文件类型筛选不正确。', 422)
        return {'purpose': _text(value.get('purpose', '选择文件'), 'purpose', 200), 'extensions': extensions}
    if kind=='cancel':
        return {'recording_id':_text(value.get('recording_id'),'recording_id'),
                'task_id':_optional_text(value.get('task_id'),'task_id'),
                'task_type':_optional_text(value.get('task_type'),'task_type')}
    if kind == 'transcribe':
        return {'recording_id': _text(value.get('recording_id'), 'recording_id')}
    raise DomainError('invalid_device_command', '设备命令类型不正确。', 422)


def _decode(row):
    value = dict(row)
    value['arguments'] = json.loads(value['arguments']) if value.get('arguments') else {}
    value['result'] = json.loads(value['result']) if value.get('result') else None
    return value


class DeviceService:
    def __init__(self, database):
        self.database = database
        with database.transaction(True) as c:
            c.execute("UPDATE device_commands SET state=CASE state WHEN 'pending' THEN 'failed' ELSE 'unknown' END,result=?,updated_at=? WHERE kind='organize' AND state IN ('pending','running')",
                      (encode({'message':'独立整理稿流程已停用；旧结果不会重放，请直接整理正文。','retry_safe':False}), time.time()))

    @staticmethod
    def check_run(c, run_id):
        if not run_id: return
        run = c.execute('SELECT state FROM agent_runs WHERE id=?', (run_id,)).fetchone()
        if run and run[0] not in {'queued', 'running', 'completed'}:
            raise DomainError('run_not_active', '助手运行已结束或中断，设备命令不可执行。', 409)

    @staticmethod
    def cancel_run(c, run_id):
        now = time.time()
        c.execute("UPDATE device_commands SET state='cancelled',result=?,updated_at=? WHERE run_id=? AND state='pending'",
                  (encode({'reason':'run_cancelled', 'message':'运行取消，尚未领取的命令不再执行。'}),now,run_id))
        c.execute("UPDATE device_commands SET result=?,updated_at=? WHERE run_id=? AND state='running'",
                  (encode({'cancel_requested':True,'message':'已请求客户端取消，等待实际结果。'}),now,run_id))

    @staticmethod
    def resume_run(c, run_id):
        from interview_backend.services.device_targets import validate
        rows = c.execute("SELECT * FROM device_commands WHERE run_id=? AND state IN ('cancelled','failed')", (run_id,)).fetchall()
        for row in rows:
            if row['kind'] == 'organize': continue
            result = json.loads(row['result']) if row['result'] else {}
            if row['state']=='failed' and not result.get('retry_safe'): continue
            if row['state']=='cancelled' and row['owner'] is None and result.get('reason') not in {'run_cancelled','restart'}: continue
            validate(c, json.loads(row['arguments']))
            c.execute("UPDATE device_commands SET state='pending',result=NULL,owner=NULL,updated_at=? WHERE id=?", (time.time(),row['id']))

    def operation(self, operation_id, request):
        if not operation_id: return None
        with self.database.transaction() as c:
            prior=c.execute('SELECT digest,result FROM operations WHERE id=?',(operation_id,)).fetchone()
            if prior is None: return None
            digest=hashlib.sha256(encode({'device_request':request}).encode()).hexdigest()
            if prior['digest']!=digest: raise DomainError('operation_mismatch','同一操作标识不能用于不同请求。',409)
            return _decode(require(c,'device_commands',json.loads(prior['result'])['command_id']))

    def enqueue(self, kind, target, arguments, run_id=None, command_id=None, operation_id=None, request=None):
        raw = arguments
        arguments = validate_arguments(kind, arguments)
        if raw.get('frozen_target'):
            arguments.update({k: raw[k] for k in ('frozen_target', 'run_id') if k in raw})
        from interview_backend.services.device_targets import prepare
        with self.database.transaction() as c:
            if not arguments.get('frozen_target'): arguments = prepare(c, kind, arguments)
        identifier = command_id or str(uuid.uuid4())
        if not isinstance(identifier, str) or not 1 <= len(identifier) <= 200:
            raise DomainError('invalid_device_command', '设备命令标识不正确。', 422)
        if run_id is not None and (not isinstance(run_id, str) or len(run_id) > 200):
            raise DomainError('invalid_device_command', '运行标识不正确。', 422)
        with self.database.transaction(True) as c:
            self.check_run(c, run_id)
            def insert():
                prior=c.execute('SELECT * FROM device_commands WHERE id=?',(identifier,)).fetchone()
                if prior:
                    if prior['kind']!=kind or prior['target']!=target or prior['run_id']!=run_id or json.loads(prior['arguments'])!=arguments:
                        raise DomainError('command_mismatch','同一命令标识不能用于不同设备操作。',409)
                else:
                    c.execute('INSERT INTO device_commands VALUES(?,?,?,?,?,?,NULL,NULL,?)',
                              (identifier,run_id,kind,target,encode(arguments),'pending',time.time()))
                return {'command_id':identifier}
            result=once(c,operation_id,{'device_request':request},insert) if operation_id else insert()
            return _decode(require(c,'device_commands',result['command_id']))

    def pending(self):
        with self.database.transaction() as c:
            return [_decode(row) for row in c.execute(
                "SELECT * FROM device_commands WHERE state='pending' ORDER BY updated_at,id")]

    def list(self, after=0):
        if type(after) not in {int, float} or after < 0:
            raise DomainError('invalid_cursor', '设备命令游标不正确。', 422)
        with self.database.transaction() as c:
            return [_decode(row) for row in c.execute(
                'SELECT * FROM device_commands WHERE updated_at>=? ORDER BY updated_at,id LIMIT 200', (after,))]

    def get(self, identifier):
        with self.database.transaction() as c:
            return _decode(require(c, 'device_commands', identifier))

    def claim(self, identifier, owner):
        if not isinstance(owner, str) or not 1 <= len(owner) <= 200:
            raise DomainError('invalid_device_owner', '设备标识不正确。', 422)
        with self.database.transaction(True) as c:
            command = require(c, 'device_commands', identifier)
            self.check_run(c, command['run_id'])
            if command['state'] == 'running' and command['owner'] == owner:
                return _decode(command)
            if command['state'] != 'pending':
                raise DomainError('command_not_claimable', '设备命令已被领取或已结束。', 409)
            from interview_backend.services.device_targets import validate
            validate(c, json.loads(command['arguments']))
            c.execute("UPDATE device_commands SET state='running',owner=?,updated_at=? WHERE id=? AND state='pending'",
                      (owner, time.time(), identifier))
            return _decode(require(c, 'device_commands', identifier))

    def validate(self, identifier):
        from interview_backend.services.device_targets import validate
        with self.database.transaction() as c:
            command = require(c, 'device_commands', identifier)
            if command['state'] not in {'pending', 'running'}:
                raise DomainError('command_not_running', '设备命令已结束。', 409)
            self.check_run(c, command['run_id'])
            if command['result'] and json.loads(command['result']).get('cancel_requested'):
                raise DomainError('command_cancelled', '运行已取消，设备命令不得继续。', 409)
            validate(c, json.loads(command['arguments']))
            return {'id': identifier, 'state': command['state']}

    def complete(self, identifier, owner, state, result=None, reconcile=False):
        if state not in TERMINAL:
            raise DomainError('invalid_device_state', '设备结果状态不正确。', 422)
        if result is not None and not isinstance(result, dict):
            raise DomainError('invalid_device_result', '设备结果结构不正确。', 422)
        with self.database.transaction(True) as c:
            command = require(c, 'device_commands', identifier)
            if command['owner'] != owner:
                raise DomainError('wrong_device_owner', '设备命令不属于此客户端。', 409)
            if reconcile and state=='unknown' and command['state'] in TERMINAL: return _decode(command)
            if reconcile and command['state']=='unknown':
                if state=='unknown': return _decode(command)
                c.execute('UPDATE device_commands SET state=?,result=?,updated_at=? WHERE id=?',(state,encode(result) if result is not None else None,time.time(),identifier))
                return _decode(require(c,'device_commands',identifier))
            if command['state'] in TERMINAL:
                # 询问者重试回报时返回已保存结果；不同结果不能覆盖。
                if command['state'] == state and (json.loads(command['result']) if command['result'] else None) == result:
                    return _decode(command)
                raise DomainError('command_already_finished', '设备命令已结束，不能覆盖结果。', 409)
            if command['state'] != 'running':
                raise DomainError('command_not_running', '设备命令尚未领取。', 409)
            c.execute('UPDATE device_commands SET state=?,result=?,updated_at=? WHERE id=?',
                      (state, encode(result) if result is not None else None, time.time(), identifier))
            return _decode(require(c, 'device_commands', identifier))

    def reconnect(self, owner):
        _text(owner,'owner',200)
        with self.database.transaction(True) as c:
            changed=c.execute("UPDATE device_commands SET state='unknown',result=?,updated_at=? WHERE state='running' AND owner<>?",
                              (encode({'reason':'owner_replaced','message':'原设备连接丢失，结果未知，不自动重放。'}),time.time(),owner)).rowcount
            return {'id':owner,'state':'connected','unknown':changed}

    def cancel_pending(self, identifier):
        with self.database.transaction(True) as c:
            command = require(c, 'device_commands', identifier)
            if command['state'] == 'pending':
                c.execute("UPDATE device_commands SET state='cancelled',updated_at=? WHERE id=?", (time.time(), identifier))
            return _decode(require(c, 'device_commands', identifier))

    async def wait(self, identifier, timeout=10.0):
        deadline = time.monotonic() + timeout
        while True:
            value = self.get(identifier)
            if value['state'] in TERMINAL:
                return value
            if time.monotonic() >= deadline:
                return value
            await asyncio.sleep(0.1)
