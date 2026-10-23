"""待执行方案只是建议；当前用户选择后仍校验冻结对象和版本。"""
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from interview_backend.errors import DomainError


class Proposal(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    title: str = Field(min_length=1, max_length=120)
    instruction: str = Field(min_length=1, max_length=2000)
    sources: list[dict] = Field(min_length=1, max_length=100)


def prepare(evidence, run_id, values, context):
    proposals = []; seen = set()
    for value in values:
        try:
            item = Proposal.model_validate(value).model_dump()
            evidence.validate_result({'claims':[{'text':item['title'],'kind':'analysis','sources':item['sources']}]}, context)
        except (ValidationError, DomainError):
            raise DomainError('invalid_proposal','修改方案的来源不完整或已经变化，未保存待执行方案。',409) from None
        key = (item['title'],item['instruction'])
        if key in seen:
            continue
        seen.add(key)
        proposals.append({'id':f'{run_id}:proposal:{len(proposals)+1}', **item})
        if len(proposals) >= 10:
            break
    return proposals


def pending(c, context):
    row = c.execute("SELECT result FROM agent_runs WHERE session_id=? AND state IN ('completed','awaiting_input') AND json_array_length(json_extract(result,'$.proposals'))>0 ORDER BY created_at DESC,id DESC LIMIT 1",(context['session_id'],)).fetchone()
    if row is None:
        return []
    import json
    allowed = {(r['resource_type'],r['resource_id'],r['revision']) for r in context['resources']}
    return [p for p in json.loads(row['result'])['proposals']
            if p.get('sources') and all((s.get('resource_type'),s.get('resource_id'),s.get('revision')) in allowed for s in p['sources'])]


def select(evidence, context, identifier):
    proposal = next((p for p in context.get('pending_proposals',[]) if p['id'] == identifier), None)
    if proposal is None or not all(evidence.valid(s) for s in proposal['sources']):
        raise DomainError('stale_proposal','所选方案已不属于当前资料版本，请重新分析或选择方案。',409)
    allowed = {(s['resource_type'],s['resource_id']) for s in proposal['sources']}
    return {**context,'selected_proposal':proposal,
            'write_resources':[r for r in context['write_resources'] if (r['resource_type'],r['resource_id']) in allowed]}
