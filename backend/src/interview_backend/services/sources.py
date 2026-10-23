"""显式区分当前证据与保留历史，历史不通过当前证据验证。"""
import json
from interview_backend.errors import DomainError
from interview_backend.services.common import version
from interview_backend.services.changesets import read_object
from interview_backend.services.source_validity import source_valid


def location(c, kind, row):
    if kind not in {'segment', 'draft', 'speaker'}: return {}
    run_id = row['run_id']
    run = c.execute('SELECT recording_id FROM runs WHERE id=?',(run_id,)).fetchone()
    return {'run_id':run_id,'recording_id':run[0] if run else None,
            'segment_id':row['id'] if kind=='segment' else None,'start':row.get('start'),'end':row.get('end')}


def snapshot(c,kind,identifier,revision,changes=()):
    def find(values):
        for item in values:
            if (item['resource_type'],item['resource_id'])!=(kind,identifier):continue
            for side in ['after','before']:
                if item[side+'_revision']==revision:return item[side],item.get('source_location',{})
        return None
    for change in changes:
        found=find(change.get('items',[]))
        if found:return found
    if version(c,kind,identifier)==revision:
        try:return read_object(c,kind,identifier),{}
        except (DomainError,ValueError,KeyError,TypeError):pass
    for change in c.execute('SELECT items FROM changesets ORDER BY created_at DESC,id DESC'):
        found=find(json.loads(change[0]))
        if found:return found
    raise DomainError('historical_source_unavailable','未保留该版本的来源快照，无法打开历史内容。',409)


def resolve(c, kind, identifier, revision, historical=False, line=1, block_id=None):
    ref={'resource_type':kind,'resource_id':identifier,'revision':revision}
    row=None; origin={}
    if not historical:
        if not source_valid(c,ref): raise DomainError('stale_source','来源已变化或移除，不能作为当前证据。',409)
        row=read_object(c,kind,identifier)
    else:
        row,origin=snapshot(c,kind,identifier,revision)
    text=row.get('name','') if kind=='speaker' else row.get('content',row.get('edited') if row.get('edited') is not None else row.get('original',''))
    result={**ref,'text':text,'historical':historical,**location(c,kind,row),**origin}
    if historical: result['message']='历史来源，仅供回看，不代表当前有效证据。'
    if kind=='draft':
        payload=json.loads(row['payload'])
        blocks=[b for chunk in payload.get('chunks',[]) for b in chunk.get('blocks') or []]
        selected=next((b for b in blocks if b.get('id')==block_id),None) if block_id else (blocks[0] if blocks else None)
        if block_id and selected is None: raise DomainError('invalid_block','整理稿中不存在该段落。',422)
        visible=[selected] if block_id else blocks
        result.update(draft_id=identifier,block_id=selected.get('id') if selected else None,
                      text='\n\n'.join('\n'.join(v for v in [b.get('title'),b.get('text')] if v) for b in visible))
        if selected and selected.get('sourceIDs'):
            segment_id=selected['sourceIDs'][0]
            source=next((s for s in payload.get('sources',[]) if s.get('id')==segment_id),None)
            if source is None:
                stored=c.execute('SELECT * FROM segments WHERE id=? AND run_id=?',(segment_id,row['run_id'])).fetchone()
                source=dict(stored) if stored else {}
            result.update(segment_id=segment_id,start=source.get('start'),end=source.get('end'))
        result['recording_id']=result.get('recording_id') or payload.get('recordingID')
    if kind=='document':
        lines=result['text'].split('\n')
        if line>len(lines): raise DomainError('invalid_line','引用行超出该版本材料范围。',422)
        result.update(line=line,line_text=lines[line-1])
    return result
