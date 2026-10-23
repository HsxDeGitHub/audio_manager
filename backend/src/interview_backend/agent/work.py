"""推理缓存绑定输入与证据；业务副作用回执与可失效的推理缓存分开保存。"""
import asyncio,hashlib,json
from interview_backend.services.common import encode
from interview_backend.errors import DomainError


class WorkLog:
    def __init__(self,database,run_id,ledger_id=None):
        self.database,self.run_id=database,run_id
        self.ledger_id=ledger_id or run_id

    def get(self,key):
        with self.database.transaction() as c:
            row=c.execute('SELECT payload FROM agent_work WHERE run_id=? AND step_key=?',(self.run_id,key)).fetchone()
            return json.loads(row[0]) if row else None

    def save(self,key,payload):
        with self.database.transaction(True) as c:
            c.execute('INSERT INTO agent_work VALUES(?,?,?) ON CONFLICT(run_id,step_key) DO UPDATE SET payload=excluded.payload',
                      (self.run_id,key,encode(payload)))

    def discard(self,key):
        with self.database.transaction(True) as c:c.execute('DELETE FROM agent_work WHERE run_id=? AND step_key=?',(self.run_id,key))

    def valid(self,dependencies):
        from interview_backend.agent.tools import EvidenceService
        evidence=EvidenceService(self.database);changes=evidence.committed(self.ledger_id)
        return evidence.valid_many(dependencies,changes)

    def effect(self,digest):
        cached=self.get('effect:'+digest)
        if cached is not None:return cached
        # 兼容旧运行日志；传输回合号不作为业务副作用的身份。
        with self.database.transaction() as c:
            rows=c.execute("SELECT payload FROM agent_work WHERE run_id=? AND step_key LIKE 'chunk:%:tool:%' AND substr(step_key,-24)=?",(self.run_id,digest)).fetchall()
        for row in rows:
            output=json.loads(row[0])
            if output.get('result',{}).get('state')!='planned':return {'output':output,'dependencies':[],'legacy':True}
        return None

    def started(self,digest):
        if self.get('external_started:'+digest):return True
        suffix=digest+':started'
        with self.database.transaction() as c:
            return c.execute('SELECT 1 FROM agent_work WHERE run_id=? AND substr(step_key,-?)=?',(self.run_id,len(suffix),suffix)).fetchone() is not None

    def reserve(self,slot,tool_id,digest):
        prior=self.get(slot)
        if prior and prior['digest']!=digest:
            raise DomainError('recovery_plan_changed','恢复后的建议改变了已执行步骤；已完成操作不会重做，请重新指定后续操作。',409)
        self.save(slot,{'tool_id':tool_id,'digest':digest})

    def preserve_legacy_effects(self,key,response):
        for index,call in enumerate(response.get('tool_calls') or []):
            if not call['name'].startswith(('device__','jobs__','organize__','mcp__')):continue
            digest=hashlib.sha256(encode({'tool':call['name'],'arguments':call['args']}).encode()).hexdigest()[:24]
            if self.effect(digest) is not None or self.started(digest):self.reserve(key.replace(':model:',':slot:')+':'+str(index),call['name'],digest)

    async def model(self,key,bound,messages,configuration=None,dependencies=(),emit=None,validator=None):
        from langchain_core.messages import AIMessage, SystemMessage
        from interview_backend.agent import model_recovery as recovery
        import time
        def signature_for_input(values):
            payload=encode({'messages':[m.model_dump(mode='json') for m in values],'configuration':configuration}).encode()
            if (configuration or {}).get('input_budget_bytes') and len(payload)>configuration['input_budget_bytes']:
                raise DomainError('model_input_too_large','本批模型上下文超过处理上限，未发送请求；请缩小指令或选区后重新提问。',422)
            return hashlib.sha256(payload).hexdigest(),len(payload)
        signature,input_bytes=await asyncio.to_thread(signature_for_input,messages)
        cached=await asyncio.to_thread(self.get,key)
        if cached is not None:
            response=cached.get('response',cached)
            await asyncio.to_thread(self.preserve_legacy_effects,key,response)
            if cached.get('input_hash')==signature and await asyncio.to_thread(self.valid,cached.get('dependencies',[])):
                value=AIMessage.model_validate(response)
                try:
                    recovery.check_completion(value)
                    if validator: await asyncio.to_thread(validator,value)
                except (ValueError,DomainError):
                    await asyncio.to_thread(self.discard,key)
                else:
                    if emit and not value.tool_calls:
                        from interview_backend.agent.streaming import answer_prefix, text_content
                        await emit('answer_start',{'block_id':self.run_id+':'+key})
                        await emit('answer_delta',{'block_id':self.run_id+':'+key,'text':answer_prefix(text_content(value))})
                    return value
        from interview_backend.agent.streaming import invoke
        deadline=time.monotonic()+recovery.STEP_TIMEOUT
        request=list(messages); attempts=[]
        for attempt in range(1,recovery.ATTEMPTS+1):
            if not await asyncio.to_thread(self.valid,dependencies):
                raise DomainError('stale_source','模型步骤的证据依赖已变化，未发送过期内容。',409)
            _,request_bytes=await asyncio.to_thread(signature_for_input,request)
            response=None
            try:
                response=await asyncio.wait_for(invoke(bound,request,emit,self.run_id+':'+key),max(.001,deadline-time.monotonic()))
                recovery.check_completion(response)
                if validator: await asyncio.to_thread(validator,response)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                detail=recovery.diagnostic(error,attempt,response)
                attempts.append(detail)
                await asyncio.to_thread(self.save,'model_attempts:'+key,{'attempts':attempts})
                await asyncio.to_thread(self.save,'failure:'+key,detail)
                code,retryable,reason=recovery.classify(error)
                if not retryable or attempt==recovery.ATTEMPTS or time.monotonic()>=deadline:
                    raise recovery.failure(error) from None
                # 重试前确认仍是模型引用错误，实际资料变化必须停止，不能用新版本覆盖。
                if not await asyncio.to_thread(self.valid,dependencies):
                    raise DomainError('stale_source','重试前发现资料已变化，请基于当前资料重新提问。',409) from None
                if emit:
                    await emit('answer_start',{'block_id':self.run_id+':'+key})
                    label='返回格式或引用未通过校验，正在自动纠正' if reason in {'invalid_citation','invalid_json','invalid_structure','invalid_tool_arguments','invalid_response','output_truncated'} else '响应暂时异常，正在自动重试'
                    await emit('task_stage',{'message':f'模型{label}（{attempt}/{recovery.ATTEMPTS-1}），已完成批次保留…'})
                if reason in {'invalid_citation','invalid_json','invalid_structure','invalid_tool_arguments','invalid_response','output_truncated'}:
                    # 不拼接失败响应，避免非法工具消息、超长输出或未经校验内容进入下一步。
                    request=list(messages)+[SystemMessage(content='上次返回未通过校验。只返回完整 JSON 对象，answer 简短，claims 为数组；引用必须逐字使用本批输入中的类型、ID和版本，不猜测，不把建议写成事实。修改只提供必要字段，不重复登记已收到工具回执的操作。不要输出代码围栏或额外说明。')]
                await asyncio.sleep(min(recovery.BACKOFF_SECONDS*2**(attempt-1),max(0,deadline-time.monotonic())))
                continue
            await asyncio.to_thread(self.save,key,{'input_hash':signature,'input_bytes':request_bytes,'dependencies':list(dependencies),'response':response.model_dump(mode='json')})
            await asyncio.to_thread(self.discard,'failure:'+key)
            return response

    def finalization(self):
        payload=self.get('finalization')
        if payload is None:return None
        memories=[r for r in payload['context'].get('resources',[]) if r['resource_type']=='memory']
        if self.valid(memories):return payload
        if payload.get('request') or payload.get('steps'):
            raise DomainError('stale_context','设备/内容步骤的记忆依赖已变化，已完成操作保留，请重新指定后续操作。',409)
        self.discard('finalization');self.discard('finalization_result')
        return None
