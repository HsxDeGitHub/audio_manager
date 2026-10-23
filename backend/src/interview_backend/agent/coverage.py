"""资料分块完整处理后才计入覆盖；保留精确范围和可恢复进度。"""
import asyncio,hashlib
from interview_backend.services.common import encode


class Coverage:
    def __init__(self,work,chunks,excluded,dependencies,configuration):
        self.work,self.excluded,self.dependencies=work,excluded,list(dependencies)
        self.parts={}
        for chunk in chunks:
            for source in chunk:
                key=encode({k:source.get(k) for k in ('resource_type','resource_id','revision','char_start','char_end')})
                identifier=hashlib.sha256(key.encode()).hexdigest()[:24];source['part_id']=identifier
                self.parts[identifier]={k:source.get(k) for k in ('resource_type','resource_id','revision','char_start','char_end','start','line','title')}
                self.parts[identifier].update(id=identifier,state='pending')
        self.signature=hashlib.sha256(encode({'parts':list(self.parts.values()),'dependencies':self.dependencies,'configuration':configuration}).encode()).hexdigest()
        prior=work.get('coverage_progress')
        if prior and prior.get('signature')==self.signature and work.valid(prior.get('dependencies',[])):
            states={p['id']:p['state'] for p in prior['coverage']['parts']}
            for identifier,part in self.parts.items():part['state']=states.get(identifier,'pending')
        old=work.get('part_results')
        self.results=old['items'] if old and old.get('signature')==self.signature else {}
        self.chunk=0;self.chunks=len(chunks)

    def snapshot(self):
        groups={}
        for part in self.parts.values():groups.setdefault((part['resource_type'],part['resource_id'],part['revision']),[]).append(part)
        return {'unit':'parts','covered':sum(p['state']=='completed' for p in self.parts.values()),'total':len(self.parts),
                'source_covered':sum(all(p['state']=='completed' for p in values) for values in groups.values()),'source_total':len(groups),
                'parts':list(self.parts.values()),'excluded':self.excluded,'chunk':self.chunk,'chunks':self.chunks}

    async def publish(self,emit):
        value=self.snapshot()
        await asyncio.to_thread(self.work.save,'coverage_progress',{'signature':self.signature,'dependencies':self.dependencies,'coverage':value})
        if emit:await emit('coverage',value)

    async def begin(self,index,chunk,emit):
        self.chunk=index+1
        for p in chunk:
            if self.parts[p['part_id']]['state']!='completed':self.parts[p['part_id']]['state']='running'
        await self.publish(emit)

    async def fail(self,chunk,state,emit):
        for p in chunk:
            if self.parts[p['part_id']]['state']!='completed':self.parts[p['part_id']]['state']=state
        await self.publish(emit)

    async def complete(self,chunk,result,context,dependencies,emit):
        identifiers=[p['part_id'] for p in chunk]
        for identifier in identifiers:self.parts[identifier]['state']='completed'
        self.results[':'.join(identifiers)]={'part_ids':identifiers,'result':result,'context':context,'dependencies':dependencies}
        await asyncio.to_thread(self.work.save,'part_results',{'signature':self.signature,'items':self.results})
        await self.publish(emit)
