#!/usr/bin/env python3
"""安装锁定的 Pi SDK，或复制可重定位的 Node/Pi 运行时进入应用。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess


PROJECT = Path(__file__).resolve().parent.parent
SOURCE = PROJECT / 'backend' / 'pi-agent'


def build_pi_runtime(destination=None):
    node = shutil.which('node')
    npm = shutil.which('npm')
    if not node or not npm:
        raise SystemExit('构建 Pi 助手需要 Node.js 22.19+ 和 npm。')
    version = subprocess.check_output([node, '--version'], text=True).strip()
    parts = tuple(int(part) for part in version.lstrip('v').split('.')[:2])
    if parts < (22, 19):
        raise SystemExit('Pi 助手需要 Node.js 22.19+，当前为 ' + version)
    target = Path(destination) if destination else SOURCE
    target.mkdir(parents=True, exist_ok=True)
    if target.resolve() != SOURCE.resolve():
        for name in ('runner.mjs', 'package.json', 'package-lock.json', 'LICENSE.pi'):
            shutil.copy2(SOURCE / name, target / name)
    environment = {**os.environ, 'PATH': str(Path(node).parent) + os.pathsep + os.environ.get('PATH', '')}
    subprocess.run([node, str(Path(npm).resolve()), 'ci', '--ignore-scripts', '--no-audit', '--no-fund',
                    '--registry=https://registry.npmjs.org', '--cache', str(PROJECT / '.build/npm-cache')],
                   cwd=target, env=environment, check=True)
    subprocess.run([node, '--input-type=module', '-e',
                    'import {createAgentSession} from "@earendil-works/pi-coding-agent"; '
                    'if(typeof createAgentSession!=="function")process.exit(1);'],
                   cwd=target, env=environment, check=True)
    if destination:
        binary_dir = target.parent / 'node' / 'bin'
        binary_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(node, binary_dir / 'node')
        license_file = Path(node).resolve().parent.parent / 'LICENSE'
        if not license_file.is_file():
            raise SystemExit('请使用含 LICENSE 的 Node 官方发行版进行应用打包。')
        shutil.copy2(license_file, binary_dir.parent / 'LICENSE')
    manifest = {'node': version, 'pi': json.loads((target / 'package.json').read_text())['dependencies']['@earendil-works/pi-coding-agent']}
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='准备听阅 Pi 助手运行时')
    parser.add_argument('--destination', type=Path, help='应用 Backend/pi-agent 目录，省略则安装开发依赖')
    arguments = parser.parse_args()
    print(json.dumps(build_pi_runtime(arguments.destination), ensure_ascii=False))
