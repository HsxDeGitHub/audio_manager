#!/usr/bin/env python3
"""Pinned Whisper model download with independently verified range sizes and final digest."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import subprocess
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
MODELS = ROOT / 'Models'
MODELS.mkdir(exist_ok=True)
URL = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3.bin'
SIZE = 3095033483
SHA = '64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2'
target = MODELS / 'ggml-large-v3.bin'
if target.exists():
    existing = hashlib.sha256()
    with target.open('rb') as source:
        while block := source.read(1024 * 1024): existing.update(block)
    if existing.hexdigest() == SHA:
        print('Whisper 模型已存在且校验通过', flush=True)
        sys.exit(0)
parts = MODELS / '.whisper-parts'
parts.mkdir(exist_ok=True)
prefix = MODELS / 'ggml-large-v3.bin.part'
base = prefix.stat().st_size if prefix.exists() else 0
if base > SIZE:
    raise RuntimeError('已有下载文件长度超过模型大小')
count = 4
chunk = (SIZE - base + count - 1) // count
def fetch(index):
    start, end = base + index * chunk, min(SIZE - 1, base + (index + 1) * chunk - 1)
    path = parts / f'{start}-{end}'
    if end < start:
        path.write_bytes(b'')
        return path
    if path.exists() and path.stat().st_size == end - start + 1:
        return path
    print('下载分段', index + 1, flush=True)
    downloaded = path.stat().st_size if path.exists() else 0
    if downloaded > end-start+1:
        path.unlink(); downloaded = 0
    # Keep requests small and use HTTP/1.1 to tolerate proxies that truncate long HTTP/2 streams.
    while downloaded < end-start+1:
        chunk_start = start + downloaded
        chunk_end = min(end, chunk_start + 16*1024*1024 - 1)
        partial = parts / f'{index}.chunk'
        subprocess.run(['/usr/bin/curl', '--http1.1', '-L', '--fail', '--silent', '--show-error',
                        '--retry', '5', '--retry-all-errors', '--connect-timeout', '30',
                        '--range', f'{chunk_start}-{chunk_end}', URL, '-o', str(partial)], check=True)
        if partial.stat().st_size != chunk_end-chunk_start+1:
            raise RuntimeError('服务器返回的分段长度不正确')
        with path.open('ab') as output, partial.open('rb') as source:
            shutil.copyfileobj(source, output)
        partial.unlink()
        downloaded = path.stat().st_size
        print('分段',index+1,round(downloaded/(end-start+1)*100),'%',flush=True)
    if path.stat().st_size != end - start + 1:
        raise RuntimeError('服务器返回的分段长度不正确')
    return path
with ThreadPoolExecutor(max_workers=count) as executor:
    files = list(executor.map(fetch, range(count)))
digest = hashlib.sha256()
with target.with_suffix('.merged').open('wb') as output:
    for path in ([prefix] if base else []) + files:
        with path.open('rb') as source:
            while block := source.read(1024 * 1024):
                output.write(block)
                digest.update(block)
if digest.hexdigest() != SHA:
    raise RuntimeError('模型 SHA-256 校验失败')
target.with_suffix('.merged').replace(target)
shutil.rmtree(parts)
if prefix.exists():
    prefix.unlink()
print('Whisper 模型校验通过', flush=True)
