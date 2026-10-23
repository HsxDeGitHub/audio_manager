"""范围内内容默认可编辑；显式只读受服务端保护，设备动作仍按具体指令授权。"""
import re

ACTION_VERBS = {
    'device.locate': r'定位|回听|播放', 'device.export': r'导出|保存为',
    'device.copy': r'复制|剪贴板', 'device.choose_file': r'选择文件|打开文件',
    'jobs.transcribe': r'转写(?!文字|文本|内容|结果|问题)|重新识别',
}
NEGATIVE = r'不要|勿|禁止|不准|不许|不允许|不能|不可|不必|无需|不需要|暂不|先不|(?<![识区分告级])别|只读'
READONLY = r'(?:只|仅)(?:需要|需|要)?(?:分析|阅读|解释|总结|评估|检查|讨论|查看|告诉|提供建议)'
DISCUSSION = r'怎么|如何|怎样|能否|是否|可否|能不能|可不可以|(?:请|帮我)?(?:解释|说明|讨论|讲解|翻译).*(?:意思|含义|指令|句话)|^(?:请|帮我)?(?:解释|说明|讨论|讲解)'


def command_text(instruction):
    text = re.sub(r'(?m)^\s*>.*$', '', instruction)
    text = re.sub(r'```[\s\S]*?(?:```|$)|~~~[\s\S]*?(?:~~~|$)', '', text)
    return re.sub(r'“[^”]*”|「[^」]*」|『[^』]*』|‘[^’]*’|"[^"\n]*"|\'[^\'\n]*\'|`[^`]*`', '', text)


def write_permissions(instruction):
    command = command_text(instruction).strip()
    if transcript_organization(instruction): return True, False
    verbs = r'修改|修正|替换|改成|改为|删除|忘记|停用|重命名|撤销|合并|设置|更正|导入|添加材料|记住|更改|改动|编辑|写入'
    if not command or re.search(r'(?:'+NEGATIVE+r').{0,20}(?:'+verbs+r'|整理|润色|优化|梳理|执行|应用|实施|操作)',command) or re.search(READONLY,command) or re.search(DISCUSSION,command):
        return False,False
    if re.fullmatch(r'(?:以下|下面|上述)?(?:是|为)?(?:原文|资料|正文|转写|引用|内容)[：:\s]*', command):
        return False,False
    importing = bool(re.search(r'(?:帮我|请|把|将|直接).{0,40}(?:导入|添加材料)|^(?:导入|添加材料)',command))
    # “修改建议”是读任务；“总结后修改正文”仍有明确的编辑动作。
    executable = re.sub(r'(?:'+verbs+r'|整理|润色|优化|梳理)(?:建议|方案|思路|示例)', '', command)
    mutation = importing or bool(re.search(r'^(?:本周|这周)(?:只|仅)(?:'+verbs+r')|(?:帮我|请|把|将|直接).{0,40}(?:'+verbs+r')|^(?:'+verbs+r')',executable))
    read_task = r'分析|阅读|解释|说明|总结|摘要|评估|检查|讨论|查看|列出|罗列|提取|汇总|(?:提供|给出|提出|生成).*(?:建议|方案|思路|示例)|(?:整理|梳理).*(?:问题|清单|建议)'
    if not mutation and re.search(read_task, command): return False,False
    # 这是可用能力，不是执行命令。简短选择和自然表达交由模型结合历史理解，
    # 实际修改仍须遵循用户任务，并经过冻结范围、版本和事务校验。
    return True,importing


def transcript_organization(instruction):
    command = command_text(instruction)
    verbs = r'整理|润色|优化|梳理'
    if re.search(READONLY+'|'+DISCUSSION+r'|只读', command): return False
    if re.search(r'建议|方案|示例|思路|清单|摘要|总结', command): return False
    prohibited = r'执行|写入|提交|修改|改动|编辑|整理|润色|优化|梳理'
    if re.search('(?:'+NEGATIVE+r').{0,8}(?:'+prohibited+r')(?!原意|含义|意思|事实|细节)', command): return False
    target = r'原文|正文|转写文字|转写文本|转写内容|转写结果|当前资料|当前转写'
    action = r'(?:(?:'+verbs+r').{0,12}(?:'+target+r')|(?:'+target+r').{0,12}(?:'+verbs+r'))'
    return any(not re.search(NEGATIVE, clause) and bool(re.search(r'(?:帮我|请|把|将|直接).{0,30}'+action+r'|^'+action, clause.strip()))
               for clause in re.split(r'[，,。；;\n]|但(?:是)?', command))


def action_permissions(instruction):
    actions=set()
    for clause in re.split(r'[，,。；;\n]',command_text(instruction)):
        if re.search(NEGATIVE+'|'+READONLY+'|'+DISCUSSION,clause): continue
        # 先消费完整取消短语，转写/整理在这里是目标名词，不能授权启动。
        cancel = r'(?:取消|停止|终止|中止)(?:(?!并|然后|再).)*(?:任务|转写|识别|整理)'
        if re.search(cancel,clause):
            actions.add('jobs.cancel'); clause=re.sub(cancel,'',clause)
        for tool_id,verbs in ACTION_VERBS.items():
            if tool_id == 'jobs.transcribe' and transcript_organization(clause) and not re.search(r'(?:请|帮我|开始|重新|再|然后|并|直接)转写|重新识别|转写成', clause): continue
            if re.search(r'(?:帮我|请|把|将|直接|并|然后|再).{0,40}(?:'+verbs+r')|^(?:'+verbs+r')',clause.strip()): actions.add(tool_id)
        if re.search(r'调用|执行|使用',clause): actions.update(re.findall(r'\bmcp\.[a-z0-9_.-]+',clause))
    return sorted(actions)


def action_allowed(tool_id, frozen):
    granted=set(frozen.get('allowed_actions',[]))
    if frozen.get('intent_policy') in {'semantic-v1', 'semantic-v2'} and frozen.get('task_intent'):
        # 新运行使用服务端校验并持久化的语义结果；不再用关键词把自然表达二次否决。
        return tool_id in granted and tool_id in frozen['task_intent']['actions']
    # 持久化的旧上下文也必须服从当前授权规则。
    if frozen.get('instruction'): granted &= set(action_permissions(frozen['instruction']))
    return tool_id in granted
