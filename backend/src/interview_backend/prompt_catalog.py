"""从随包分发的唯一资源目录读取固定提示词；修改资源后重启生效。"""
from functools import cache
from importlib.resources import files
import json


@cache
def load_text(name: str) -> str:
    # Markdown 文件末尾的一个换行仅用于文件排版，不进入原有模型消息。
    value = files('interview_backend').joinpath('prompts', name).read_text(encoding='utf-8').removesuffix('\n')
    if not value.strip():
        raise ValueError(f'提示词资源为空：{name}')
    return value


@cache
def _descriptions() -> dict:
    return json.loads(load_text('tools/descriptions.json'))


def _description(section: str, name: str) -> str:
    value = _descriptions()[section][name]
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f'提示词描述为空或格式错误：{section}.{name}')
    return value


def tool_description(tool_id: str) -> str:
    return _description('tools', tool_id)


def field_description(name: str) -> str:
    return _description('fields', name)
