import re


def tokens(text):
    words = set(re.findall(r'[a-zA-Z0-9_+#.]+', text.casefold()))
    try:
        import jieba
        jieba.setLogLevel(40)
        words.update(w.casefold() for w in jieba.cut_for_search(text) if w.strip())
    except ImportError:
        pass
    # 短中文和字面匹配不能依赖词典刚好收录技术术语。
    for phrase in re.findall(r'[\u3400-\u9fff]+', text):
        words.update(phrase[i:i+2] for i in range(max(1,len(phrase)-1)))
    return sorted(w for w in words if w and re.search(r'\w', w))


def query(text):
    return ' OR '.join('"' + token.replace('"','""') + '"' for token in tokens(text))
