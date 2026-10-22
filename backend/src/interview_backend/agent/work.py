"""推理缓存绑定输入与证据；业务副作用回执与可失效的推理缓存分开保存。"""
import hashlib,json
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
        return all(evidence.valid(r) if r['resource_type']=='memory' else evidence.valid_after_changes(r,changes) for r in dependencies)

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

    async def model(self,key,bound,messages,configuration=None,dependencies=(),emit=None):
        from langchain_core.messages import AIMessage
        signature=hashlib.sha256(encode({'messages':[m.model_dump(mode='json') for m in messages],'configuration':configuration}).encode()).hexdigest()
        cached=self.get(key)
        if cached is not None:
            response=cached.get('response',cached)
            self.preserve_legacy_effects(key,response)
            if cached.get('input_hash')==signature and self.valid(cached.get('dependencies',[])):
                value=AIMessage.model_validate(response)
                if emit and not value.tool_calls:
                    from interview_backend.agent.streaming import answer_prefix, text_content
                    await emit('answer_start',{'block_id':self.run_id+':'+key})
                    await emit('answer_delta',{'block_id':self.run_id+':'+key,'text':answer_prefix(text_content(value))})
                return value
        if not self.valid(dependencies):raise DomainError('stale_source','模型步骤的证据依赖已变化，未发送过期内容。',409)
        from interview_backend.agent.streaming import invoke
        response=await invoke(bound,messages,emit,self.run_id+':'+key)
        self.save(key,{'input_hash':signature,'dependencies':list(dependencies),'response':response.model_dump(mode='json')})
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
