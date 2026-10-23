"""同时限制片段数和序列化大小；正文很短时也不能塞入数百份元数据。"""
from interview_backend.services.common import encode
from interview_backend.errors import DomainError

MAX_PARTS = 32
MAX_EVIDENCE_BYTES = 14000
MAX_INPUT_BYTES = 64000
MODEL_PART_CHARACTERS = 1800


def bounded(context):
    return context.get('intent_policy') in {'semantic-v1', 'semantic-v2'}


def make_chunks(sources, compact=False, editing=False):
    chunks = []; current = []; length = 0
    part_size = MODEL_PART_CHARACTERS if compact else 6000
    for source in sources:
        text = source['text']
        if compact and editing and len(encode(source).encode())>MAX_EVIDENCE_BYTES:
            raise DomainError('source_too_large','单个来源过长，尚未修改；请缩小所选资料，避免用节选覆盖完整正文。',422)
        size_for_source = max(1,len(text)) if compact and editing else part_size
        for start in range(0, max(1, len(text)), size_for_source):
            part = {**source, 'text': text[start:start+size_for_source], 'char_start':source.get('char_start',0)+start,
                    'char_end':source.get('char_start',0)+min(start+size_for_source,len(text))}
            if source['resource_type']=='document': part['line']=source.get('line',1)+text[:start].count('\n')
            size = len(encode(part).encode()) if compact else len(part['text'])
            if current and (length+size > (MAX_EVIDENCE_BYTES if compact else 10000) or (compact and len(current)>=MAX_PARTS)):
                chunks.append(current); current = []; length = 0
            current.append(part); length += size
    if current: chunks.append(current)
    return chunks or [[]]


def batch_scope(context, chunk):
    keys = {(s['resource_type'],s['resource_id']) for s in chunk}
    runs = {s.get('run_id') for s in chunk if s.get('run_id')}
    recordings = {s.get('recording_id') for s in chunk if s.get('recording_id')}
    speakers = [s for s in context.get('speaker_catalog',[]) if s['run_id'] in runs]
    keys.update(('speaker',s['resource_id']) for s in speakers)
    keys.update(('recording',identifier) for identifier in recordings)
    # 导入任务或纯设备任务可能没有现存正文。
    if not chunk: return context['resources'], speakers
    return [r for r in context['resources'] if (r['resource_type'],r['resource_id']) in keys], speakers


def short_history(history, budget=6000):
    result = []; used = 0
    for item in reversed(history):
        size = len(encode(item).encode())
        if used+size>budget: break
        result.append(item); used+=size
    return list(reversed(result))


def bounded_memories(items, budget=6000):
    selected = []; used = 0
    # 优先保留用户偏好；每条记忆及其来源作为整体取舍，不截断后冒充完整依据。
    for item in sorted(items,key=lambda m:m.get('category')!='preference'):
        size=len(encode(item).encode())
        if used+size<=budget:
            selected.append(item); used+=size
    return selected
