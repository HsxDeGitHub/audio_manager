"""Pi 原生消息结构，业务服务直接使用 role/content/stopReason。"""
from typing import Literal
from pydantic import BaseModel, ConfigDict


class Message(BaseModel):
    model_config = ConfigDict(extra='allow')
    role: Literal['system', 'user', 'assistant', 'toolResult']
    content: str | list[dict]
    timestamp: int = 0
    stopReason: str | None = None

    @property
    def text(self):
        if isinstance(self.content, str):
            return self.content
        return ''.join(block.get('text', '') for block in self.content if block.get('type') == 'text')

    @property
    def tool_calls(self):
        if isinstance(self.content, str):
            return []
        return [block for block in self.content if block.get('type') == 'toolCall']

    def native(self):
        return self.model_dump(mode='json', exclude_none=True)
