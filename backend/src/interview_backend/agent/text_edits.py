"""正文纠错与个人身份断言分开处理，实际修改仍经过统一事务。"""
import re

from interview_backend.errors import DomainError


def text_only_targets(targets):
    return bool(targets) and all(isinstance(target, dict) and target.get('resource_type') == 'segment'
        and isinstance(target.get('fields'), dict) and set(target['fields']) == {'text'} for target in targets)


def transcript_targets(targets):
    return bool(targets) and all(isinstance(t, dict) and isinstance(t.get('fields'), dict) and t['fields']
        and ((t.get('resource_type') == 'segment' and set(t['fields']) <= {'text', 'speaker', 'needs_review', 'reviewed'})
             or (t.get('resource_type') == 'speaker' and set(t['fields']) == {'name'})) for t in targets)


def validate_edit_claims(evidence, result, context, changes, targets):
    editing = context.get('allow_write') and (text_only_targets(targets) or
        (context.get('intent_policy') == 'semantic-v2' and transcript_targets(targets)))
    claims = []
    for claim in result['claims']:
        try:
            evidence.validate_result({'claims': [claim]}, context, changes)
        except DomainError as error:
            if error.code != 'identity_unconfirmed' or not editing or not claim.get('sources') or any(
                    source.get('resource_type') != 'segment' for source in claim['sources']):
                raise
            # 只剔除错误的身份归属，不能把它改成已确认事实；来源范围和版本仍需有效。
            evidence.validate_result({'claims': [{**claim, 'kind': 'original_statement'}]}, context, changes)
            continue
        claims.append(claim)
    result['claims'] = claims


def needs_edit_result(result, context, plan):
    if not context.get('allow_write') or result.get('targets') or result.get('clarification') or plan.targets or plan.documents:
        return False
    answer = result.get('answer', '')
    body = context.get('instruction', '') + '\n' + answer
    return bool(re.search(r'原文|正文|转写|翻译|文本|文字|片段|分段|说话人|发言归属', body)
        and re.search(r'planned|待提交|已登记|已(?:经)?(?:修改|修正|更正|替换|改好)|准备.{0,8}(?:修改|提交)', answer))
