#!/usr/bin/env python3
"""为 .app 构建锁定的独立 Python 运行时；不复制开发虚拟环境，不依赖目标机 Python。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from datetime import datetime, timezone

PROJECT = Path(__file__).resolve().parent.parent
BACKEND = PROJECT / 'backend'
PYTHON_SERIES = '3.12'


def run(command, **kwargs):
    printable = ' '.join(str(part) for part in command)
    print('> ' + printable, flush=True)
    environment = {**os.environ, 'UV_CACHE_DIR': os.environ.get('UV_CACHE_DIR', str(PROJECT / '.build' / 'uv-cache'))}
    subprocess.run([str(part) for part in command], check=True, env=environment, **kwargs)


def uv():
    path = shutil.which('uv')
    if not path:
        raise SystemExit('需要 uv 来构建锁定依赖；未在 PATH 中找到。')
    return path


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def build(app_dir, embeddings):
    app_dir = Path(app_dir).resolve()
    resources = app_dir / 'Contents' / 'Resources'
    if not (app_dir.suffix == '.app' and resources.is_dir()):
        raise SystemExit('传入的 .app 目录不存在或结构不正确：' + str(app_dir))
    runtime = resources / 'Backend'
    if runtime.exists():
        if app_dir not in runtime.parents:
            raise SystemExit('拒绝清理非目标 .app 内的运行时目录。')
        shutil.rmtree(runtime)
    runtime.mkdir(parents=True)
    base_root = runtime / 'python-base'
    install_root = runtime / '.python-install'
    venv = runtime / 'python'
    wheel_dir = runtime / '.build'

    run([uv(), 'python', 'install', '--no-bin', '--install-dir', install_root, PYTHON_SERIES])
    interpreters = [path for path in sorted(install_root.glob(f'cpython-{PYTHON_SERIES}*/bin/python3.12'))
                    if path.is_file() and not path.parent.parent.is_symlink()]
    if len(interpreters) != 1:
        raise SystemExit('未找到唯一的 Python 解释器安装。')
    shutil.move(str(interpreters[0].parents[1]), str(base_root))
    shutil.rmtree(install_root)
    run([uv(), 'venv', '--python', base_root / 'bin' / 'python3.12', venv])

    extras = ['agent'] + (['local-embeddings'] if embeddings else [])
    requirements = runtime / 'requirements.lock.txt'
    command = [uv(), 'export', '--project', BACKEND, '--frozen', '--no-dev', '--no-emit-project',
               '-o', requirements]
    for extra in extras:
        command += ['--extra', extra]
    run(command)
    run([uv(), 'pip', 'install', '--python', venv / 'bin' / 'python', '-r', requirements])

    run([uv(), 'build', BACKEND, '--out-dir', wheel_dir])
    wheels = list(wheel_dir.glob('interview_audio_backend-*.whl'))
    if len(wheels) != 1:
        raise SystemExit('未生成唯一的后端 wheel。')
    run([uv(), 'pip', 'install', '--python', venv / 'bin' / 'python', wheels[0]])

    # venv 内解释器的符号链接和 pyvenv.cfg 必须是相对路径，应用移动到其他目录后仍能启动。
    config = venv / 'pyvenv.cfg'
    lines = []
    for line in config.read_text().splitlines():
        if line.startswith('home = '):
            line = 'home = ../python-base/bin'
        lines.append(line)
    config.write_text('\n'.join(lines) + '\n')
    for name in ('python', 'python3', 'python3.12'):
        link = venv / 'bin' / name
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to('../../python-base/bin/python3' if name == 'python' else 'python')

    modules = ['interview_backend', 'interview_backend.app', 'fastapi', 'mcp', 'langchain', 'langgraph']
    if embeddings:
        modules += ['fastembed', 'numpy', 'jieba']
    run([venv / 'bin' / 'python', '-c', 'import ' + ', '.join(modules) + '; print("runtime imports ok")'])

    requirement_hash = sha256(requirements)
    wheel_hash = sha256(wheels[0])
    (runtime / 'manifest.json').write_text(json.dumps({
        'python': PYTHON_SERIES, 'extras': extras, 'requirements_sha256': requirement_hash,
        'wheel_sha256': wheel_hash, 'created_at': datetime.now(timezone.utc).isoformat(),
        'relocatable': True,
    }, ensure_ascii=False, indent=2) + '\n')
    shutil.rmtree(wheel_dir)
    requirements.unlink()
    return runtime


def codesign(runtime):
    count = 0
    for path in sorted(runtime.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        executable = path.parent.name == 'bin' and os.access(path, os.X_OK)
        if path.suffix in {'.so', '.dylib'} or executable or path.name.startswith('python3'):
            subprocess.run(['codesign', '--force', '--sign', '-', str(path)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            count += 1
    print(f'已签名 {count} 个运行时二进制。')


def main():
    parser = argparse.ArgumentParser(description='构建听阅独立 Python 后端运行时')
    parser.add_argument('app', type=Path, help='已创建 Contents/Resources 的 .app 目录')
    parser.add_argument('--without-embeddings', action='store_true', help='不打包本地语义检索依赖')
    parser.add_argument('--skip-sign', action='store_true', help='仅用于本地验证，不签名运行时')
    args = parser.parse_args()
    runtime = build(args.app, not args.without_embeddings)
    if not args.skip_sign:
        codesign(runtime)
    print('后端运行时：' + str(runtime))


if __name__ == '__main__':
    main()
