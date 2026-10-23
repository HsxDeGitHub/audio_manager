"""只重试尚未执行工具的模型步骤；诊断不保存上游正文、地址或凭据。"""
import json
import re

from interview_backend.errors import DomainError

ATTEMPTS = 3
STEP_TIMEOUT = 600
BACKOFF_SECONDS = 1
REPAIRABLE = frozenset({'stale_source', 'invalid_claim', 'missing_source', 'invalid_line',
                       'identity_unconfirmed', 'analysis_not_user_fact'})


class OutputError(ValueError):
    def __init__(self, reason):
        self.reason = reason


def check_completion(response):
    finish = (getattr(response, 'response_metadata', None) or {}).get('finish_reason')
    if finish in {'length', 'max_tokens'}:
        raise OutputError('output_truncated')
    if getattr(response, 'invalid_tool_calls', None):
        raise OutputError('invalid_tool_arguments')


def parse_result(response):
    check_completion(response)
    content = response.content if isinstance(response.content, str) else ''.join(
        b.get('text', '') for b in response.content if isinstance(b, dict))
    try:
        result = json.loads(re.sub(r'^```(?:json)?\s*|\s*```$', '', content.strip()))
    except (ValueError, TypeError):
        raise OutputError('invalid_json') from None
    if not isinstance(result, dict) or not isinstance(result.get('answer'), str) or not isinstance(result.get('claims'), list):
        raise OutputError('invalid_structure')
    for claim in result['claims']:
        if not isinstance(claim, dict) or not isinstance(claim.get('text'), str) or not isinstance(claim.get('kind'), str):
            raise OutputError('invalid_structure')
        sources = claim.get('sources', [])
        if not isinstance(sources, list) or any(not isinstance(s, dict) or
                not all(k in s for k in ('resource_type', 'resource_id', 'revision')) for s in sources):
            raise OutputError('invalid_structure')
    for key in ('targets', 'questions', 'proposals'):
        if result.get(key) is not None and (not isinstance(result[key], list) or any(not isinstance(v, dict) for v in result[key])):
            raise OutputError('invalid_structure')
    return result


def classify(error):
    import httpx
    from openai import APIConnectionError, APIResponseValidationError
    status = getattr(error, 'status_code', None)
    status = status if type(status) is int else None
    if isinstance(error, OutputError):
        return 'model_invalid_output', True, error.reason
    if isinstance(error, DomainError):
        return error.code, error.code in REPAIRABLE, 'invalid_citation'
    if isinstance(error, (TimeoutError, httpx.TimeoutException)) or type(error).__name__ == 'APITimeoutError':
        return 'model_timeout', True, 'timeout'
    if status in {401, 403}:
        return 'model_auth_failed', False, 'authentication'
    if status == 429:
        return 'model_rate_limited', True, 'rate_limit'
    if status is not None and status >= 500:
        return 'model_unavailable', True, 'upstream_unavailable'
    if status is not None and 400 <= status < 500:
        return 'model_request_rejected', False, 'request_rejected'
    if isinstance(error, (APIConnectionError, httpx.TransportError)):
        return 'model_connection_failed', True, 'connection'
    if isinstance(error, (APIResponseValidationError, ValueError)):
        return 'model_invalid_output', True, 'invalid_response'
    return 'model_failed', False, 'unknown'


def diagnostic(error, attempt, response=None):
    code, _, reason = classify(error)
    value = {'code': code, 'reason': reason, 'attempt': attempt, 'error_type': type(error).__name__[:80]}
    status = getattr(error, 'status_code', None)
    if type(status) is int: value['http_status'] = status
    finish = (getattr(response, 'response_metadata', None) or {}).get('finish_reason')
    if finish in {'stop', 'length', 'max_tokens', 'tool_calls', 'content_filter'}: value['finish_reason'] = finish
    return value


def failure(error):
    if isinstance(error, DomainError):
        if error.code=='stale_source':
            return DomainError('stale_source','模型引用未通过范围或版本校验，自动纠正仍未成功；已完成批次保留，可继续任务。',409)
        return error
    code, _, reason = classify(error)
    messages = {
        'model_timeout': '模型响应超时，自动重试仍未完成；已保留已完成批次，可继续任务。',
        'model_rate_limited': '模型接口限流，自动重试仍未恢复；请稍后继续任务。',
        'model_unavailable': '模型服务暂时不可用，自动重试仍未恢复；已完成批次保留。',
        'model_connection_failed': '模型连接或流式传输中断，自动重试仍未恢复；可继续任务。',
        'model_auth_failed': '模型接口拒绝认证，请检查 API Key 或访问权限后继续任务。',
        'model_request_rejected': '模型接口拒绝请求，请检查接口、模型及参数配置后继续任务。',
        'model_invalid_output': ('模型输出达到长度上限；请提高输出上限或缩小处理范围，已完成批次保留。'
                                 if reason == 'output_truncated' else
                                 '模型返回格式未通过校验，自动纠正仍未成功；已完成批次保留，可继续任务。'),
        'model_failed': '模型步骤未完成；已完成批次和操作回执已保留，可继续任务。',
    }
    return DomainError(code, messages[code], 503)
