from pathlib import Path
import json
from urllib.parse import urlsplit
from pydantic import BaseModel, ConfigDict, Field, SecretStr
from interview_backend.errors import DomainError
from interview_backend.prompt_catalog import load_text, tool_description


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
        from interview_backend.agent.pi_model import PiModel
        return PiModel(self)


async def tool_call_self_test(settings):
    from interview_backend.agent.protocol import Message
    definition = {'type': 'function', 'function': {'name': 'verify_connection', 'description': tool_description('verify_connection'),
        'parameters': {'type': 'object', 'properties': {'value': {'type': 'string'}}, 'required': ['value']}}}
    try:
        result = await settings.client().with_tools([definition], tool_choice='verify_connection').complete([Message(role='user', content=load_text('connection/tool-user.md'))])
        if not result.tool_calls or result.tool_calls[0]['name'] != 'verify_connection' or result.tool_calls[0]['arguments'] != {'value': 'ok'}:
            raise ValueError()
        return {'available': True, 'tool_calling': True}
    except Exception:
        raise DomainError('model_tool_unavailable', '模型接口未通过工具调用测试，请选择支持工具调用的模型。', 409) from None


async def capability_self_test(settings):
    """仅使用固定合成消息，逐项报告，失败不回显上游正文或密钥。"""
    import asyncio
    import json
    from interview_backend.agent.protocol import Message
    checks = []
    client = settings.client()
    async def check(identifier, title, operation):
        try:
            await asyncio.wait_for(operation(), timeout=60)
            checks.append({'id':identifier,'title':title,'supported':True,'message':'已通过合成检测'})
        except asyncio.CancelledError:
            raise
        except Exception:
            checks.append({'id':identifier,'title':title,'supported':False,'message':'未通过，请检查模型能力、接口或额度'})
    messages = [Message(role='system', content=load_text('connection/text-system.md')),
                Message(role='user', content=load_text('connection/text-user.md'))]
    async def text():
        response = await client.complete(messages)
        if not isinstance(response.text,str) or not response.text.strip(): raise ValueError()
    async def structured():
        response = await client.complete([Message(role='user', content=load_text('connection/structured-user.md'))])
        if json.loads(response.text) != {'ok':True}: raise ValueError()
    async def tools():
        await tool_call_self_test(settings)
    async def streaming():
        received = False
        async for chunk in client.stream(messages):
            if chunk['type'] == 'text_delta' and chunk['delta']: received = True
        if not received: raise ValueError()
    for args in [('text','文本生成',text),('structured','结构化 JSON',structured),
                 ('tools','工具调用',tools),('streaming','流式输出协议',streaming)]:
        await check(*args)
    return {'checks':checks,'message':'检测仅使用合成消息；流式协议通过不代表实际网络始终逐字到达。'}
