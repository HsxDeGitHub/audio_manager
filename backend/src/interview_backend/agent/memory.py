"""从当前用户陈述提取记忆；历史摘要不能绕过实时有效性和删除抑制。"""
import json
import re
from interview_backend.agent.models import ModelSettings
from interview_backend.services.common import encode


class AutomaticMemory:
    def __init__(self, settings, service): self.settings, self.service = settings, service
    async def extract(self, context, model=None, result=None):
        instruction = context['instruction']
        results = self.service.remember_analysis(context, result or {})
        if not context.get('message_id') or not re.search(r'我|本人|喜欢|偏好|隔壁团队|更正|纠正|记住', instruction): return results
        from langchain_core.messages import SystemMessage, HumanMessage
        current = self.service.active(('global',))
        model = model or ModelSettings.load(self.settings.data_dir).client()
        response = await model.ainvoke([
            SystemMessage(content='只从本次用户消息提取明确个人陈述和偏好，不提取假设例子、待总结资料或建议。输出 JSON memories 数组，每条含 category(user_statement/preference)、content、topic、scope(global)、可选 supersedes。明确纠正才填现有记忆ID；不确定不提取。'),
            HumanMessage(content=encode({'user_message':instruction,'existing':[{'id':m['id'],'topic':m['topic'],'content':m['content']} for m in current]}))])
        values = json.loads(response.content).get('memories',[])
        for i,item in enumerate(values):
            if item.get('category') not in {'user_statement','preference'}: continue
            if item.get('supersedes') and not re.search(r'更正|纠正|其实|实际上|不是|没有|更新', instruction): item.pop('supersedes')
            item['sources'] = [{'resource_type':'message','resource_id':context['message_id'],'revision':1}]
            item['scope'] = 'global'
            results.append(self.service.add(item,context['message_id']+':memory:'+str(i)))
        return results
