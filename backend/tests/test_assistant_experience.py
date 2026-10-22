import asyncio
import json
import pytest
from langchain_core.messages import AIMessageChunk


def test_answer_parser_only_top_level_and_unicode():
    from interview_backend.agent.streaming import answer_prefix
    raw = json.dumps({'nested': {'answer': '不能展示'}, 'answer': '中文\n"引号"😀\\路径', 'claims': []}, ensure_ascii=True)
    assert answer_prefix(raw) == '中文\n"引号"😀\\路径'
    prefixes = [answer_prefix(raw[:i]) for i in range(len(raw) + 1)]
    assert all('不能展示' not in p and not any(0xD800 <= ord(c) <= 0xDFFF for c in p) for p in prefixes)
    assert any(p == '中文' for p in prefixes)


def test_stream_emits_before_model_finishes_and_preserves_tool_calls():
    from interview_backend.agent.streaming import invoke
    events = []
    class Model:
        async def astream(self, messages):
            yield AIMessageChunk(content='{"answer":"中文')
            await asyncio.sleep(.06)
            yield AIMessageChunk(content='输出')
            await asyncio.sleep(.06)
            assert any(k == 'answer_delta' for k, _ in events)
            yield AIMessageChunk(content='","claims":[]}')
    async def run():
        async def emit(kind, payload): events.append((kind, payload))
        result = await invoke(Model(), [], emit, 'block')
        assert json.loads(result.content)['answer'] == '中文输出'
    asyncio.run(run())
    assert ''.join(p['text'] for k,p in events if k=='answer_delta') == '中文输出'
    assert len([1 for k,p in events if k=='answer_delta']) >= 2


def test_output_snapshot_reset_and_resume_cursor(client):
    from interview_backend.agent.api import NewRun
    class Engine:
        async def execute(self, run_id, instruction, context, emit=None):
            await emit('answer_start', {'block_id':'a'})
            await emit('answer_delta', {'block_id':'a','text':'合成输出'})
            return {'answer':'合成输出','claims':[]}
    service=client.app.state.agent; service.engine=Engine()
    session=client.post('/api/v1/sessions', json={}).json()['id']
    response=client.post('/api/v1/agent/runs',json={'session_id':session,'message_id':'experience-msg','instruction':'合成提问','context':{'recording_id':'r1'}})
    import time
    identifier=response.json()['id']
    for _ in range(200):
        run=client.get('/api/v1/agent/runs/'+identifier).json()
        if run['state'] not in {'queued','running'}: break
        time.sleep(.005)
    assert run['output']['blocks'][0]['text']=='合成输出'
    assert run['output']['last_event_id']>0
    history=client.get('/api/v1/sessions/'+session).json()
    assert history['runs'][0]['message_id']=='experience-msg'
    assert client.get('/api/v1/sessions').json()['items'][0]['title']=='合成提问'
    assert 'answer_delta' in client.get('/api/v1/agent/runs/'+identifier+'/events').text


def test_history_frozen_and_retry_checked_before_stale_freeze(client):
    seen=[]
    class Engine:
        async def execute(self, run_id, instruction, context, emit=None):
            seen.append(context)
            return {'answer':'第一点：合成建议','claims':[]}
    service=client.app.state.agent; service.engine=Engine()
    session=client.post('/api/v1/sessions',json={}).json()['id']
    import time
    def send(mid,text):
        body={'session_id':session,'message_id':mid,'instruction':text,'context':{'recording_id':'r1'}}
        response=client.post('/api/v1/agent/runs',json=body)
        assert response.status_code==200
        for _ in range(200):
            run=client.get('/api/v1/agent/runs/'+response.json()['id']).json()
            if run['state'] not in {'queued','running'}:break
            time.sleep(.005)
        return body,response.json()['id']
    first,identifier=send('first','分析当前资料')
    send('second','把第一点展开，不要修改')
    assert seen[-1]['conversation_history'][1]['content']=='第一点：合成建议'
    assert not seen[-1]['allow_write']
    original=service.evidence.freeze
    service.evidence.freeze=lambda *args: (_ for _ in ()).throw(AssertionError('重试不应重新冻结'))
    try: assert client.post('/api/v1/agent/runs',json=first).json()['id']==identifier
    finally: service.evidence.freeze=original


def test_tool_arguments_and_reasoning_never_become_body():
    from interview_backend.agent.streaming import invoke
    events=[]
    class Model:
        async def astream(self,messages):
            yield AIMessageChunk(content='',additional_kwargs={'reasoning_content':'不可展示的内部推理'},tool_call_chunks=[{'name':'evidence__read','args':'{','id':'call','index':0}])
            yield AIMessageChunk(content='',tool_call_chunks=[{'name':None,'args':'}','id':None,'index':0}])
    async def run():
        async def emit(k,p):events.append((k,p))
        result=await invoke(Model(),[],emit,'tool')
        assert result.tool_calls[0]['args']=={}
    asyncio.run(run())
    assert not any(k=='answer_delta' for k,p in events)


def test_explicit_stream_unsupported_fallback_and_midstream_failure_not_retried():
    from interview_backend.agent.streaming import invoke
    from langchain_core.messages import AIMessage
    class Unsupported(Exception): status_code=501
    class Model:
        calls=0
        async def astream(self,messages):
            raise Unsupported()
            yield
        async def ainvoke(self,messages):
            self.calls+=1
            return AIMessage(content='{"answer":"完整回退","claims":[]}')
    model=Model()
    assert asyncio.run(invoke(model,[])).content
    assert model.calls==1
    class Broken(Model):
        async def astream(self,messages):
            yield AIMessageChunk(content='{"answer":"部分')
            raise Unsupported()
    broken=Broken()
    with pytest.raises(Unsupported):asyncio.run(invoke(broken,[]))
    assert broken.calls==0


def test_new_message_id_cannot_reuse_different_scope(client):
    class Engine:
        async def execute(self,*args,**kwargs):return {'answer':'合成','claims':[]}
    client.app.state.agent.engine=Engine()
    session=client.post('/api/v1/sessions',json={}).json()['id']
    body={'session_id':session,'message_id':'scope-stable','instruction':'分析','context':{'recording_id':'r1'}}
    assert client.post('/api/v1/agent/runs',json=body).status_code==200
    body['context']={'recording_id':'r2'}
    response=client.post('/api/v1/agent/runs',json=body)
    assert response.status_code==409 and response.json()['error']['code']=='message_conflict'
