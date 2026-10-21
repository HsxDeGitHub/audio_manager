import hashlib
import importlib.metadata
import json
from pathlib import Path
import threading
from interview_backend.errors import DomainError

MODEL = 'BAAI/bge-small-zh-v1.5'


class SemanticIndex:
    def __init__(self, cache_dir):
        self.cache_dir = Path(cache_dir); self.model = None; self.tokenizer = None
        self.lock = threading.RLock()
    def status(self):
        try:
            manifest = json.loads((self.cache_dir / 'ready.json').read_text())
            ready = manifest['model'] == MODEL and manifest['dimension'] == 512 and Path(manifest['model_dir']).is_dir()
            return {**manifest,'ready':ready}
        except (OSError,KeyError,ValueError): return {'ready':False,'model':MODEL,'dimension':512}
    def prepare(self, download=False):
        with self.lock:
            if self.model is not None: return self.status()
            prior = self.status()
            if not download and not prior['ready']:
                raise DomainError('semantic_not_ready','本地语义模型未准备，当前可使用关键词检索。',409)
            try:
                from fastembed import TextEmbedding
                from tokenizers import Tokenizer
                self.cache_dir.mkdir(parents=True, exist_ok=True)
                self.model = TextEmbedding(model_name=MODEL,cache_dir=str(self.cache_dir),local_files_only=not download,threads=2)
                tokenizer = self.model.model.tokenizer
                self.tokenizer = Tokenizer.from_str(tokenizer.to_str())
                self.tokenizer.no_truncation(); self.tokenizer.no_padding()
                vector = next(iter(self.model.embed(['合成准备测试'])))
                if len(vector) != 512: raise ValueError()
                model_dir = Path(self.model.model._model_dir)
                fingerprint = hashlib.sha256((model_dir/'tokenizer.json').read_bytes()).hexdigest()
                manifest = {'model':MODEL,'dimension':512,'model_dir':str(model_dir),'tokenizer_sha256':fingerprint,'fastembed_version':importlib.metadata.version('fastembed')}
                manifest['version'] = hashlib.sha256(json.dumps(manifest,sort_keys=True).encode()).hexdigest()
                temporary = self.cache_dir/'ready.tmp'; temporary.write_text(json.dumps(manifest)); temporary.replace(self.cache_dir/'ready.json')
                return {**manifest,'ready':True}
            except Exception:
                self.model = self.tokenizer = None
                raise DomainError('semantic_prepare_failed','语义模型准备或校验失败，关键词检索仍可使用。',503) from None
    def split(self, text, limit=384, overlap=64):
        self.prepare(False)
        offsets = [(a,b) for a,b in self.tokenizer.encode(text).offsets if b>a]
        if not offsets: return [(0,len(text),text)]
        parts = []
        for i in range(0,len(offsets),limit-overlap):
            selected = offsets[i:i+limit]
            start = 0 if i==0 else selected[0][0]
            end = len(text) if i+limit>=len(offsets) else selected[-1][1]
            value = text[start:end]
            if len(self.tokenizer.encode(value).ids) > 512:
                raise DomainError('token_limit','文本超过模型实际 token 上限。',422)
            parts.append((start,end,value))
            if end==len(text): break
        return parts
    def vectors(self, texts):
        with self.lock:
            self.prepare(False)
            if any(len(self.tokenizer.encode(text).ids)>512 for text in texts):
                raise DomainError('token_limit','查询或片段超出语义模型上限。',422)
            import numpy as np
            values = np.asarray(list(self.model.embed(texts)),dtype=np.float32)
            if values.shape != (len(texts),512) or not np.isfinite(values).all():
                raise DomainError('invalid_vectors','语义模型输出维度或数值不合法。',503)
            return values
