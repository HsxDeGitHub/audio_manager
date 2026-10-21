import asyncio
from dataclasses import dataclass, field
import inspect
import math
import re
from typing import Callable

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from interview_backend.errors import DomainError


@dataclass(frozen=True)
class ToolContext:
    request_id: str
    allowed_effects: frozenset[str] = field(default_factory=lambda: frozenset({'read'}))
    operation_id: str | None = None
    resource_scope: frozenset[tuple[str, str]] | None = None
    frozen_context: dict | None = None


@dataclass(frozen=True)
class ToolSpec:
    tool_id: str
    version: str
    title: str
    description: str
    input_model: type[BaseModel]
    output_model: type[BaseModel]
    handler: Callable
    effect: str = 'read'
    idempotent: bool = True
    timeout_seconds: float = 5.0

    @property
    def framework_name(self):
        return self.tool_id.replace('.', '__')


class ToolInvocation(BaseModel):
    model_config = ConfigDict(extra='forbid')
    arguments: dict = Field(default_factory=dict)
    operation_id: str | None = None


class ToolRegistry:
    def __init__(self):
        self._tools: dict[str, ToolSpec] = {}
        self._enabled: dict[str, bool] = {}

    def register(self, spec: ToolSpec):
        if not re.fullmatch(r'[a-z][a-z0-9_.-]{0,63}', spec.tool_id) or not spec.version:
            raise ValueError('工具必须有合法的稳定标识和版本。')
        if spec.effect not in {'read', 'write', 'device', 'external'}:
            raise ValueError('工具副作用类别不合法。')
        if not math.isfinite(spec.timeout_seconds) or spec.timeout_seconds <= 0:
            raise ValueError('工具超时必须为正数。')
        if spec.tool_id in self._tools or any(item.framework_name == spec.framework_name for item in self._tools.values()):
            raise ValueError('工具标识或框架别名冲突。')
        self._tools[spec.tool_id] = spec
        self._enabled[spec.tool_id] = True

    def set_enabled(self, tool_id: str, enabled: bool):
        if tool_id not in self._tools:
            raise DomainError('tool_not_found', '指定工具不存在。', 404)
        self._enabled[tool_id] = enabled

    def list(self, include_disabled=False):
        return [{'id': spec.tool_id, 'framework_name': spec.framework_name, 'version': spec.version,
                 'title': spec.title, 'description': spec.description, 'effect': spec.effect,
                 'idempotent': spec.idempotent, 'enabled': self._enabled[spec.tool_id],
                 'input_schema': spec.input_model.model_json_schema(),
                 'output_schema': spec.output_model.model_json_schema()}
                for spec in sorted(self._tools.values(), key=lambda item: item.tool_id)
                if include_disabled or self._enabled[spec.tool_id]]

    async def execute(self, tool_id: str, arguments: dict, context: ToolContext):
        spec = self._tools.get(tool_id)
        if spec is None:
            raise DomainError('tool_not_found', '指定工具不存在。', 404)
        if not self._enabled[tool_id]:
            raise DomainError('tool_disabled', '指定工具已停用。', 409)
        if spec.effect not in context.allowed_effects:
            raise DomainError('tool_effect_denied', '当前指令上下文不允许此类操作。', 403)
        if spec.effect == 'write' and not context.operation_id:
            raise DomainError('operation_id_required', '内容修改需要稳定的操作标识。', 422)
        try:
            args = spec.input_model.model_validate(arguments)
        except ValidationError:
            raise DomainError('invalid_tool_arguments', '工具参数不合法。', 422) from None

        async def invoke():
            if inspect.iscoroutinefunction(spec.handler):
                return await spec.handler(args, context)
            value = await asyncio.to_thread(spec.handler, args, context)
            return await value if inspect.isawaitable(value) else value
        try:
            raw = await asyncio.wait_for(invoke(), timeout=spec.timeout_seconds)
        except DomainError:
            raise
        except TimeoutError:
            # 同步线程或外部副作用不因超时自动撤回，调用方不能盲目重试。
            raise DomainError('tool_timeout', '工具执行超时，请核对任务状态。', 504) from None
        except Exception:
            raise DomainError('tool_failed', '工具执行失败，请检查任务状态。', 503) from None
        try:
            data = spec.output_model.model_validate(raw).model_dump(mode='json')
        except ValidationError:
            raise DomainError('invalid_tool_result', '工具返回结果不符合约定。', 503) from None
        return {'tool_id': spec.tool_id, 'tool_version': spec.version,
                'request_id': context.request_id, 'data': data}
