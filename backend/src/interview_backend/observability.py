"""本地运行状态与脱敏日志：只记录方法和状态，不记录正文、查询、令牌或上游错误内容。"""
from datetime import datetime, timezone
import json
import re
import threading
from pathlib import Path

SENSITIVE_KEYS = re.compile(r'(api[_-]?key|token|authorization|password|secret|credential|cookie|bookmark|content|text|payload|query|body)', re.IGNORECASE)
PATTERNS = [
    (re.compile(r'(?i)bearer\s+[A-Za-z0-9._~+/-]+=*'), 'Bearer [REDACTED]'),
    (re.compile(r'(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*["\']?[^"\'\s,}]+'), r'\1=[REDACTED]'),
    (re.compile(r'sk-[A-Za-z0-9_-]{8,}'), 'sk-[REDACTED]'),
]


def redact(value, key=None, depth=0):
    if depth > 8:
        return '[TRUNCATED]'
    if key is not None and SENSITIVE_KEYS.search(str(key)):
        return '[REDACTED]'
    if isinstance(value, dict):
        return {str(k): redact(v, k, depth + 1) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [redact(item, None, depth + 1) for item in value[:50]]
    if isinstance(value, str):
        result = value[:2000]
        for pattern, replacement in PATTERNS:
            result = pattern.sub(replacement, result)
        return result
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return redact(str(value), key, depth + 1)


class AuditLog:
    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        if not self.path.exists():
            self.path.touch(mode=0o600)
        try:
            self.path.chmod(0o600)
        except OSError:
            pass

    def write(self, event, **fields):
        record = {'time': datetime.now(timezone.utc).isoformat(), 'event': redact(event),
                  **redact(fields)}
        line = json.dumps(record, ensure_ascii=False, separators=(',', ':')) + '\n'
        with self.lock:
            with self.path.open('a', encoding='utf-8') as handle:
                handle.write(line)

    def status(self):
        try:
            return {'enabled': True, 'file': self.path.name, 'bytes': self.path.stat().st_size}
        except OSError:
            return {'enabled': False, 'file': self.path.name, 'bytes': 0}
