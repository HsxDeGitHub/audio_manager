import json
from interview_backend.observability import AuditLog, redact


def test_redaction_removes_keys_tokens_and_upstream_content():
    value = redact({'apiKey': 'private-key', 'authorization': 'Bearer private-token',
                    'nested': {'content': '私人正文', 'query': '私人搜索', 'status': 200},
                    'message': '请求失败 Bearer abc.def sk-1234567890',
                    'items': ['正常状态', 'sk-secretsecret']})
    text = json.dumps(value, ensure_ascii=False)
    assert 'private-key' not in text and 'private-token' not in text and '私人正文' not in text
    assert '私人搜索' not in text and 'sk-1234567890' not in text and 'sk-secretsecret' not in text
    assert value['nested']['status'] == 200 and value['items'][0] == '正常状态'


def test_audit_log_is_owner_only_and_never_records_request_text(client, config):
    client.post('/api/v1/documents', json={'operation_id': 'private-doc', 'title': '合成材料',
                                           'format': 'txt', 'content': '不应进入日志的私人正文'})
    client.get('/api/v1/retrieval/search', params={'q': '不应进入日志的私人搜索'})
    log = config.backend_dir / 'logs' / 'backend.jsonl'
    text = log.read_text()
    assert '不应进入日志的私人正文' not in text and '不应进入日志的私人搜索' not in text
    assert 'synthetic-test-token' not in text
    assert 'request' in text and 'service_started' in text
    assert (log.stat().st_mode & 0o777) == 0o600
    rows = [json.loads(line) for line in text.splitlines()]
    assert all('authorization' not in row and 'content' not in row for row in rows)
    assert client.app.state.audit.status()['enabled'] is True
    assert client.get('/api/v1/system/status').json()['capabilities']['observability'] is True


def test_audit_status_does_not_expose_full_path(tmp_path):
    log = AuditLog(tmp_path / 'logs' / 'backend.jsonl')
    log.write('synthetic', apiKey='private-key', note='Bearer private-token', status='ok')
    value = log.status()
    assert value['enabled'] and value['file'] == 'backend.jsonl'
    text = (tmp_path / 'logs' / 'backend.jsonl').read_text()
    assert 'private-key' not in text and 'private-token' not in text
