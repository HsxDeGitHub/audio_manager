"""只预览顶层 answer；完整结构与工具调用仍经原有校验和执行器。"""
import json
import time


def answer_prefix(content):
    text = content.lstrip()
    if text.startswith('```'):
        if '\n' not in text: return ''
        text = text.split('\n', 1)[1].lstrip()
    if not text.startswith('{'): return ''
    decoder = json.JSONDecoder()
    i = 1
    while i < len(text):
        while i < len(text) and text[i] in ' \r\n\t,': i += 1
        try: key, end = decoder.raw_decode(text, i)
        except ValueError: return ''
        i = end
        while i < len(text) and text[i].isspace(): i += 1
        if i >= len(text) or text[i] != ':': return ''
        i += 1
        while i < len(text) and text[i].isspace(): i += 1
        if key != 'answer':
            try: _, i = decoder.raw_decode(text, i)
            except ValueError: return ''
            continue
        if i >= len(text) or text[i] != '"': return ''
        i += 1
        result = []
        while i < len(text):
            char = text[i]
            if char == '"': break
            if char != '\\':
                if ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF: break
                result.append(char); i += 1; continue
            if i + 1 >= len(text): break
            escape = text[i + 1]
            if escape != 'u':
                value = {'"':'"', '\\':'\\', '/':'/', 'b':'\b', 'f':'\f', 'n':'\n', 'r':'\r', 't':'\t'}.get(escape)
                if value is None: break
                result.append(value); i += 2; continue
            if i + 6 > len(text): break
            try: number = int(text[i+2:i+6], 16)
            except ValueError: break
            if 0xD800 <= number <= 0xDBFF:
                if i + 12 > len(text) or text[i+6:i+8] != '\\u': break
                try: low = int(text[i+8:i+12], 16)
                except ValueError: break
                if not 0xDC00 <= low <= 0xDFFF: break
                result.append(chr(0x10000 + ((number - 0xD800) << 10) + low - 0xDC00)); i += 12
            elif 0xDC00 <= number <= 0xDFFF: break
            else: result.append(chr(number)); i += 6
        return ''.join(result)
    return ''


def text_content(message):
    if isinstance(message.content, str): return message.content
    return ''.join(b.get('text', '') for b in message.content if isinstance(b, dict) and b.get('type') == 'text')


async def invoke(bound, messages, emit=None, block_id='answer'):
    from langchain_core.messages import AIMessageChunk, message_chunk_to_message
    if emit: await emit('answer_start', {'block_id': block_id})
    aggregate = None
    emitted = ''
    last = 0.0
    async def preview(force=False):
        nonlocal emitted, last
        value = answer_prefix(text_content(aggregate))
        if value.startswith(emitted) and len(value) > len(emitted) and (force or time.monotonic()-last >= .05):
            if emit: await emit('answer_delta', {'block_id':block_id, 'text':value[len(emitted):]})
            emitted = value; last = time.monotonic()
    if not hasattr(bound, 'astream'):
        aggregate = await bound.ainvoke(messages)
    else:
        try:
            async for chunk in bound.astream(messages):
                aggregate = chunk if aggregate is None else aggregate + chunk
                if emit: await preview()
        except Exception as error:
            # 本层只处理明确不支持stream的回退。中途失败交给WorkLog重试当前模型步骤，工具由外层执行。
            body = getattr(error, 'body', None) or {}
            detail = body.get('error', body) if isinstance(body, dict) else {}
            unsupported = getattr(error, 'status_code', None) == 501 or (detail.get('param') == 'stream' and detail.get('code') in {'unsupported_value','unsupported_parameter','not_supported'})
            if aggregate is not None or not unsupported: raise
            if emit: await emit('generation_mode', {'message':'模型接口不支持流式，正在等待完整回答。'})
            aggregate = await bound.ainvoke(messages)
    if aggregate is None: raise ValueError('empty model stream')
    if getattr(aggregate, 'tool_calls', None):
        if emit: await emit('answer_start', {'block_id':block_id})
    elif emit: await preview(force=True)
    return message_chunk_to_message(aggregate) if isinstance(aggregate, AIMessageChunk) else aggregate


def output_snapshot(c, run_id):
    reset = c.execute("SELECT seq,payload FROM events WHERE run_id=? AND kind='answer_reset' ORDER BY seq DESC LIMIT 1", (run_id,)).fetchone()
    if reset is None: return None
    attempt = json.loads(reset['payload'])['attempt_id']
    blocks = {}; last = reset['seq']
    for row in c.execute('SELECT seq,kind,payload FROM events WHERE run_id=? AND seq>? ORDER BY seq', (run_id, last)):
        last = row['seq']
        if row['kind'] not in {'answer_start','answer_delta'}: continue
        payload = json.loads(row['payload'])
        if payload.get('attempt_id') != attempt: continue
        key = payload['block_id']
        if row['kind'] == 'answer_start': blocks[key] = ''
        else: blocks[key] = blocks.get(key, '') + payload['text']
    return {'attempt_id':attempt, 'blocks':[{'block_id':k,'text':v} for k,v in blocks.items()], 'last_event_id':last}
