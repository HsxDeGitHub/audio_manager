"""合成模型使用的 Pi 原生消息与流事件构造器。"""
from interview_backend.agent.protocol import Message


def assistant_message(content='', tool_calls=(), response_metadata=None, invalid_tool_calls=()):
    blocks = [{'type': 'text', 'text': content}]
    blocks += [{'type': 'toolCall', 'id': call['id'], 'name': call['name'], 'arguments': call['args']}
               for call in tool_calls]
    blocks += [{'type': 'toolCall', 'id': call['id'], 'name': call['name'], 'arguments': call['args']}
               for call in invalid_tool_calls]
    finish = (response_metadata or {}).get('finish_reason')
    return Message(role='assistant', content=blocks, api='openai-completions', provider='tingyue', model='host',
                   usage={'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 0,
                          'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0, 'total': 0}},
                   stopReason=finish or ('toolUse' if blocks[1:] else 'stop'))


def user_message(content):
    return Message(role='user', content=content)


def system_message(content):
    return Message(role='system', content=content)


def text_event(content):
    return {'type': 'text_delta', 'delta': content}
