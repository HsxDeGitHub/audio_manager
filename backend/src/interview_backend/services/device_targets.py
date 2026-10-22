"""设备命令固定层级目标及相关版本；不依赖执行时页面状态。"""
from interview_backend.errors import DomainError
from interview_backend.services.common import require, version


def snapshot(c, recording_id, run_id, draft_id=None):
    refs = [('recording', recording_id)]
    if run_id:
        if require(c, 'runs', run_id)['recording_id'] != recording_id:
            raise DomainError('wrong_scope', '转写版本不属于该资料。', 409)
        refs += [('segment', r[0]) for r in c.execute('SELECT id FROM segments WHERE run_id=?', (run_id,))]
        refs += [('speaker', f'{run_id}:{r[0]}') for r in c.execute('SELECT speaker FROM speakers WHERE run_id=?', (run_id,))]
        refs += [('draft', r[0]) for r in c.execute('SELECT id FROM ai_drafts WHERE run_id=?', (run_id,)) if not draft_id or r[0] == draft_id]
    return {'recording_id': recording_id, 'run_id': run_id,
            'versions': [{'resource_type': k, 'resource_id': i, 'revision': version(c, k, i)} for k, i in refs]}


def prepare(c, kind, arguments, context=None):
    args = dict(arguments)
    if kind not in {'locate', 'export', 'transcribe', 'cancel', 'organize'}: return args
    recording_id, run_id = args.get('recording_id'), args.get('run_id')
    draft_id, segment_id = args.get('draft_id'), args.get('segment_id')
    if draft_id:
        draft = require(c, 'ai_drafts', draft_id)
        if run_id and draft['run_id'] != run_id: raise DomainError('wrong_scope', '整理稿不属于该版本。', 409)
        run_id = draft['run_id']
    if segment_id:
        segment = require(c, 'segments', segment_id)
        if run_id and segment['run_id'] != run_id: raise DomainError('wrong_scope', '片段不属于该版本。', 409)
        run_id = segment['run_id']
    if run_id:
        owner = require(c, 'runs', run_id)['recording_id']
        if recording_id and owner != recording_id: raise DomainError('wrong_scope', '版本不属于该资料。', 409)
        recording_id = owner
    recording = require(c, 'recordings', recording_id)
    if context is not None:
        frozen = next((s for s in context.get('device_targets', []) if s['recording_id'] == recording_id), None)
        if frozen is None: raise DomainError('scope_denied', '设备目标超出本次消息的固定范围。', 403)
        if run_id and run_id != frozen['run_id']: raise DomainError('scope_denied', '设备版本超出本次消息的固定范围。', 403)
        allowed = {(v['resource_type'], v['resource_id']) for v in frozen['versions']}
        if draft_id and ('draft', draft_id) not in allowed: raise DomainError('scope_denied', '整理稿超出固定范围。', 403)
        if segment_id and context.get('segment_ids') and segment_id not in context['segment_ids']:
            raise DomainError('scope_denied', '片段超出固定选区。', 403)
    else:
        frozen = snapshot(c, recording_id, run_id or recording['active_run'])
    run_id = frozen['run_id']
    if kind in {'locate', 'export', 'organize'} and not run_id:
        raise DomainError('missing_transcript', '该资料没有可执行的转写版本。', 409)
    args.update(recording_id=recording_id, run_id=run_id, frozen_target=frozen)
    validate(c, args)
    return args


def validate(c, args):
    frozen = args.get('frozen_target')
    if not frozen: return
    require(c, 'recordings', frozen['recording_id'])
    if frozen.get('run_id') and require(c, 'runs', frozen['run_id'])['recording_id'] != frozen['recording_id']:
        raise DomainError('stale_device_target', '设备目标归属已变化。', 409)
    from interview_backend.services.changesets import read_object
    for ref in frozen['versions']:
        read_object(c, ref['resource_type'], ref['resource_id'])
        if version(c, ref['resource_type'], ref['resource_id']) != ref['revision']:
            raise DomainError('stale_device_target', '设备目标内容已变化，请基于当前版本重新发起。', 409)
