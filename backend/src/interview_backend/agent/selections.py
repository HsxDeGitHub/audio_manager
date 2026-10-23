"""用户主动附加的正文选区；仅作为资料，权限仍由本轮指令决定。"""
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field
from interview_backend.errors import DomainError


class QuoteSource(BaseModel):
    model_config = ConfigDict(extra='forbid')
    resource_type: Literal['segment', 'document']
    resource_id: str = Field(min_length=1, max_length=200)
    revision: int = Field(ge=1)
    line: int | None = Field(default=None, ge=1)


class SelectedQuote(BaseModel):
    model_config = ConfigDict(extra='forbid')
    id: str = Field(min_length=1, max_length=200)
    text: str = Field(min_length=1, max_length=12000)
    title: str = Field(max_length=500)
    location: str = Field(max_length=200)
    sources: list[QuoteSource] = Field(min_length=1, max_length=200)
    recording_id: str | None = None
    run_id: str | None = None


def validate_quotes(quotes, resources, sources):
    if sum(len(quote.text) for quote in quotes) > 20000:
        raise DomainError('quote_too_large', '引用文字过长，请缩小选区后重试。', 422)
    allowed = {(r['resource_type'], r['resource_id']): r['revision'] for r in resources}
    texts = {(r['resource_type'], r['resource_id']): r['text'] for r in sources}
    for quote in quotes:
        for source in quote.sources:
            key = (source.resource_type, source.resource_id)
            if key not in texts or allowed.get(key) != source.revision:
                raise DomainError('stale_quote', '引用的正文已变化或不在当前范围，请移除旧引用并重新选择。', 409)
            if source.line and (source.resource_type != 'document' or source.line > len(texts[key].split('\n'))):
                raise DomainError('invalid_line', '引用行超出材料范围，请重新选择。', 422)
