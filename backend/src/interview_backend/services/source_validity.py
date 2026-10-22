"""注入、引用与检索共用的递归当前证据判定。"""
import json
from interview_backend.errors import DomainError
from interview_backend.services.common import version
from interview_backend.services.draft_sources import draft_current


def source_valid(c, reference, trail=frozenset()):
    from interview_backend.services.changesets import read_object
    try:
        kind, identifier, revision = reference['resource_type'], reference['resource_id'], reference['revision']
        key = (kind, identifier)
        if key in trail or len(trail) >= 128 or version(c, kind, identifier) != revision: return False
        obj = read_object(c, kind, identifier)
        if obj.get('removed'): return False
        if kind == 'draft': return draft_current(c, obj)
        if kind == 'memory':
            sources = json.loads(obj['sources'])
            return obj['state'] == 'active' and bool(sources) and all(source_valid(c, s, trail | {key}) for s in sources)
        return True
    except (DomainError, KeyError, TypeError, ValueError):
        return False
