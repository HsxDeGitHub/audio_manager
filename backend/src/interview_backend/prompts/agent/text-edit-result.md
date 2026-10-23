上一条回复描述了正文修改，但没有返回可执行目标，也没有通过写工具登记修改，正文尚未改变。
请根据当前用户指令、历史中明确选择的方案以及当前块的 scope/untrusted_evidence，返回真正需要的逐片段修订。
只输出 JSON：answer 中文字符串，claims 数组，以及 targets 数组。每个目标包含 resource_type="segment"、resource_id、expected_revision 和 fields={"text":"修改后的完整片段文字"}。
只改用户要求的字词，不改说话人、时间或识别原稿；无需确认说话人身份即可按用户指令纠错。不要为纠错创建 user_statement 身份断言，claims 可以为空。
如果当前块没有匹配文字，返回 no_match=true、claims=[]，如实说明该块未修改，不编造目标。如果无法确定修改对象或替换文字，返回 clarification 说明缺少什么。
不要只回复“已登记”“待提交”“planned”或“已修改”；只有返回有效 targets 后应用才能提交正文。
