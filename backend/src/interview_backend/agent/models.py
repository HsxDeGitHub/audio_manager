from pathlib import Path
import json
import os
from urllib.parse import urlsplit
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from interview_backend.errors import DomainError


class ModelSettings(BaseModel):
    model_config = ConfigDict(extra='ignore', populate_by_name=True)
    base_url: str = Field(alias='baseURL')
    api_key: SecretStr = Field(default=SecretStr(''), alias='apiKey', exclude=True)
    model: str
    max_output_tokens: int = Field(default=8192, alias='maxOutputTokens', ge=512, le=32768)

    @classmethod
    def load(cls, data_dir):
        try:
            value = cls.model_validate_json((Path(data_dir) / 'llm-settings.json').read_text())
            parsed = urlsplit(value.base_url.strip())
            if parsed.scheme not in {'https', 'http'} or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or not value.model.strip():
                raise ValueError()
            return value
        except (OSError, ValueError):
            raise DomainError('model_not_configured', '请在大模型配置中填写有效接口、模型和凭据。', 409) from None

    def client(self):
        # 不允许环境中的追踪配置把私人上下文上传到遥测服务。
        os.environ['LANGCHAIN_TRACING_V2'] = 'false'
        os.environ['LANGSMITH_TRACING'] = 'false'
        from langchain_openai import ChatOpenAI
        base = self.base_url.strip().rstrip('/')
        if base.endswith('/chat/completions'):
            base = base[:-len('/chat/completions')]
        return ChatOpenAI(model=self.model.strip(), base_url=base, api_key=self.api_key.get_secret_value() or 'local-no-key',
                          max_tokens=self.max_output_tokens, timeout=60, max_retries=1)


async def tool_call_self_test(settings):
    from langchain_core.messages import HumanMessage
    definition = {'type': 'function', 'function': {'name': 'verify_connection', 'description': '仅用于连通测试',
        'parameters': {'type': 'object', 'properties': {'value': {'type': 'string'}}, 'required': ['value']}}}
    try:
        result = await settings.client().bind_tools([definition], tool_choice='verify_connection').ainvoke([HumanMessage(content='调用 verify_connection，value 为 ok。这是合成连接测试。')])
        if not result.tool_calls or result.tool_calls[0]['name'] != 'verify_connection' or result.tool_calls[0]['args'] != {'value': 'ok'}:
            raise ValueError()
        return {'available': True, 'tool_calling': True}
    except Exception:
        raise DomainError('model_tool_unavailable', '模型接口未通过工具调用测试；纯文本整理仍可独立使用。', 409) from None
