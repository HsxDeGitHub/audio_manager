import asyncio,json
import pytest
from langchain_core.messages import AIMessage
from interview_backend.errors import DomainError
from interview_backend.services.memory import MemoryService


def memory_fixture(client):
    db=client.app.state.database
    with db.transaction(True) as c:
        c.execute("INSERT INTO sessions VALUES('integrity-session','合成','{}',1)")
        c.execute("INSERT INTO messages VALUES('integrity-message','integrity-session','user','合成旧偏好唯一标记','{}',1)")
    service=MemoryService(db,client.app.state.evidence)
    item=service.add({'category':'preference','content':'合成旧偏好唯一标记','scope':'global','topic':'表达',
                      'sources':[{'resource_type':'message','resource_id':'integrity-message','revision':1}]},'integrity-memory')
    return service,item


@pytest.mark.parametrize('field,value',[('state','deleted'),('state','disabled'),('content','纠正后的内容')])
@pytest.mark.parametrize('question',[False,True])
def test_final_readonly_result_rechecks_all_earlier_memory_references(client,field,value,question):
    service,item=memory_fixture(client)
    with client.app.state.database.transaction(True) as c:c.execute("UPDATE segments SET original=?,edited=NULL WHERE run_id='run1'",('合成'*3000,))
    class Model:
        step=0
        def bind_tools(self,tools):return self
        async def ainvoke(self,messages):
            self.step+=1
            if self.step==1:
                ref={'resource_type':'memory','resource_id':item['id'],'revision':1}
                return AIMessage(content=json.dumps({'answer':'第一块','claims':[] if question else [{'kind':'analysis','text':'分析','sources':[ref]}],
                    'questions':[{'text':'合成问题','source':ref}] if question else []}))
            service.update(item['id'],{field:value},1,'change-memory')
            return AIMessage(content=json.dumps({'answer':'第二块','claims':[]}))
    instruction='列出全部问题' if question else '分析全部资料'
    context=client.app.state.evidence.freeze({'recording_id':'r1'},instruction)
    with pytest.raises(DomainError) as error:
        asyncio.run(client.app.state.agent.engine.execute('final-memory',instruction,context,model=Model()))
    assert error.value.code=='stale_source'
