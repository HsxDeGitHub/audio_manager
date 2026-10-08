#!/usr/bin/env python3
"""Download pinned native runtimes into this workspace; no global installations."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / '.runtime'
CACHE = RUNTIME / 'downloads'
TOOLS = RUNTIME / 'tools'
for directory in (CACHE, TOOLS):
    directory.mkdir(parents=True, exist_ok=True)

def download(url, target):
    if target.exists() and target.stat().st_size > 0:
        return target
    print('下载', target.name, flush=True)
    subprocess.run(['/usr/bin/curl', '-L', '--fail', '--retry', '5', '--retry-delay', '2',
                    '--connect-timeout', '30', '-o', str(target) + '.part', url], check=True)
    Path(str(target) + '.part').replace(target)
    return target

def whisper():
    archive = download('https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz', CACHE / 'whisper-v1.9.5.tar.gz')
    source = RUNTIME / 'whisper.cpp-1.9.5'
    if not source.exists():
        with tarfile.open(archive) as tar:
            tar.extractall(RUNTIME, filter='data')
    cmake = shutil.which('cmake')
    if not cmake:
        raise RuntimeError('需要 CMake 以构建 whisper.cpp（可通过 pip install cmake 安装）')
    build = source / 'build'
    subprocess.run([cmake, '-S', str(source), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
                    '-DBUILD_SHARED_LIBS=OFF', '-DGGML_METAL=ON', '-DGGML_METAL_EMBED_LIBRARY=ON',
                    '-DWHISPER_BUILD_TESTS=OFF', '-DWHISPER_BUILD_SERVER=OFF', '-DWHISPER_CURL=OFF'], check=True)
    subprocess.run([cmake, '--build', str(build), '--target', 'whisper-cli', '-j', '6'], check=True)
    shutil.copy2(build / 'bin/whisper-cli', TOOLS / 'whisper-cli')
    (TOOLS / 'Licenses').mkdir(exist_ok=True)
    shutil.copy2(source / 'LICENSE', TOOLS / 'Licenses/whisper-LICENSE')

def sherpa():
    name = 'sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts'
    archive = download(f'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/{name}.tar.bz2', CACHE / (name + '.tar.bz2'))
    if not (RUNTIME / name).exists():
        with tarfile.open(archive) as tar:
            tar.extractall(RUNTIME, filter='data')
    source = RUNTIME / name
    shutil.copytree(source, TOOLS / 'sherpa', dirs_exist_ok=True)

def ffmpeg():
    # macOS curl uses the system certificate store (some Python installations do not).
    metadata_file = download('https://pypi.org/pypi/imageio-ffmpeg/0.6.0/json', CACHE / 'imageio-ffmpeg-0.6.0.json')
    metadata = json.loads(metadata_file.read_text())
    wheel = next(item for item in metadata['urls'] if 'macosx' in item['filename'] and 'arm64' in item['filename'])
    archive = download(wheel['url'], CACHE / wheel['filename'])
    import hashlib
    if hashlib.sha256(archive.read_bytes()).hexdigest() != wheel['digests']['sha256']:
        raise RuntimeError('FFmpeg 下载校验失败')
    with zipfile.ZipFile(archive) as package:
        name = next(n for n in package.namelist() if '/binaries/ffmpeg-' in n)
        (TOOLS / 'ffmpeg').write_bytes(package.read(name))
        os.chmod(TOOLS / 'ffmpeg', 0o755)
        for name in package.namelist():
            if name.lower().endswith(('license', 'copying', 'license.txt')):
                (TOOLS / 'Licenses').mkdir(exist_ok=True)
                (TOOLS / 'Licenses' / ('ffmpeg-' + Path(name).name)).write_bytes(package.read(name))

with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    futures = [pool.submit(job) for job in (whisper, sherpa, ffmpeg)]
    for future in futures:
        future.result()
print('本地运行工具准备完成：', TOOLS, flush=True)
