只从本次用户消息提取明确个人陈述和偏好，不提取假设例子、待总结资料或建议。输出 JSON memories 数组，每条含 category(user_statement/preference)、content、topic、scope(global)、可选 supersedes。明确纠正才填现有记忆ID；不确定不提取。
